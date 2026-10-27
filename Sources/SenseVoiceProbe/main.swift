// Development probe for the CSherpa shim.
//
//   swift run -c release SenseVoiceProbe [model-dir] [audio.wav]
//
// model-dir: optional; defaults to $FOCUSVOICE_SENSEVOICE_DIR, the bundled
// layout relative to the executable, or ~/.dsh/speech-to-text/sensevoice/models.
// Prints sherpa version, model load time, whole-file decode timing, VAD segment
// timeline and peak RSS. This tool is not shipped in the .app.
import CSherpa
import Foundation

// MARK: - Model discovery

struct ModelPaths {
    let model: String
    let tokens: String
    let vad: String
}

func findModels(in directory: String) -> ModelPaths? {
    let candidates: [(model: String, tokens: String, vad: String)] = [
        (
            directory + "/model.int8.onnx",
            directory + "/tokens.txt",
            directory + "/silero_vad.onnx"
        ),
        (
            directory + "/sensevoice-onnx/model.int8.onnx",
            directory + "/sensevoice-onnx/tokens.txt",
            directory + "/silero/silero_vad.onnx"
        ),
    ]
    let fm = FileManager.default
    for candidate in candidates {
        if fm.fileExists(atPath: candidate.model),
           fm.fileExists(atPath: candidate.tokens),
           fm.fileExists(atPath: candidate.vad) {
            return ModelPaths(model: candidate.model, tokens: candidate.tokens, vad: candidate.vad)
        }
    }
    return nil
}

func defaultModels() -> (ModelPaths, String)? {
    let fm = FileManager.default
    var directories: [String] = []
    if let env = ProcessInfo.processInfo.environment["FOCUSVOICE_SENSEVOICE_DIR"], !env.isEmpty {
        directories.append(env)
    }
    if let resourceURL = Bundle.main.resourceURL {
        directories.append(resourceURL.appendingPathComponent("models/sensevoice").path)
    }
    directories.append((fm.homeDirectoryForCurrentUser.path)
        + "/.dsh/speech-to-text/sensevoice/models")
    for directory in directories {
        if let paths = findModels(in: directory) {
            return (paths, directory)
        }
    }
    return nil
}

// MARK: - WAV reading (16-bit PCM RIFF)

struct WavAudio {
    let samples: [Float]
    let sampleRate: Int
}

func readWav(_ path: String) throws -> WavAudio {
    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    func u16(_ offset: Int) -> Int {
        Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }
    func u32(_ offset: Int) -> Int {
        u16(offset) | (u16(offset + 2) << 16)
    }
    func ascii(_ offset: Int, _ count: Int) -> String {
        String(decoding: bytes[offset..<(offset + count)], as: UTF8.self)
    }
    guard bytes.count > 44, ascii(0, 4) == "RIFF", ascii(8, 4) == "WAVE" else {
        throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "not a RIFF/WAVE file: \(path)"])
    }
    var sampleRate = 0
    var channels = 0
    var bits = 0
    var dataOffset = -1
    var dataLength = 0
    var cursor = 12
    while cursor + 8 <= bytes.count {
        let chunkID = ascii(cursor, 4)
        let chunkSize = u32(cursor + 4)
        let body = cursor + 8
        if chunkID == "fmt " {
            channels = u16(body + 2)
            sampleRate = u32(body + 4)
            bits = u16(body + 14)
        } else if chunkID == "data" {
            dataOffset = body
            dataLength = min(chunkSize, bytes.count - body)
        }
        cursor = body + chunkSize + (chunkSize % 2)
        if dataOffset >= 0 { break }
    }
    guard dataOffset >= 0, channels == 1, bits == 16, sampleRate > 0 else {
        throw NSError(domain: "probe", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "expected mono 16-bit PCM wav, got channels=\(channels) bits=\(bits) rate=\(sampleRate)",
        ])
    }
    let count = dataLength / 2
    var samples = [Float](repeating: 0, count: count)
    for i in 0..<count {
        let offset = dataOffset + i * 2
        let raw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        samples[i] = Float(Int16(bitPattern: raw)) / 32768.0
    }
    return WavAudio(samples: samples, sampleRate: sampleRate)
}

// MARK: - Helpers

func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

func peakRssMegabytes() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / (1024 * 1024)
}

func errorString(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
    guard let pointer else { return "" }
    defer { fv_sherpa_free_text(pointer) }
    return String(cString: pointer)
}

// MARK: - main

let arguments = Array(CommandLine.arguments.dropFirst())
let fm = FileManager.default

let models: ModelPaths
let source: String
if let first = arguments.first, fm.fileExists(atPath: first) {
    guard let found = findModels(in: first) else {
        FileHandle.standardError.write(Data("no model files under \(first)\n".utf8))
        exit(2)
    }
    models = found
    source = first
} else {
    guard let (found, directory) = defaultModels() else {
        FileHandle.standardError.write(Data("SenseVoice models not found (pass a model dir or set FOCUSVOICE_SENSEVOICE_DIR)\n".utf8))
        exit(2)
    }
    models = found
    source = directory
}

let wavPath = arguments.count >= 2 ? arguments[1] : "/tmp/svprobe/zh.wav"
let audio: WavAudio
do {
    audio = try readWav(wavPath)
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(2)
}

print("[probe] sherpa-onnx \(String(cString: fv_sherpa_version()))")
print("[probe] models: \(source)")
print("[probe] wav: \(wavPath) \(audio.samples.count) samples @ \(audio.sampleRate) Hz = \(String(format: "%.2f", Double(audio.samples.count) / Double(audio.sampleRate)))s")

// ---- load ----
var errorBuffer = [CChar](repeating: 0, count: 1024)
let loadStart = nowMs()
let engine = models.model.withCString { model in
    models.tokens.withCString { tokens in
        models.vad.withCString { vad in
            fv_sherpa_create(model, tokens, vad, 2, 20.0, &errorBuffer, errorBuffer.count)
        }
    }
}
let loadMs = nowMs() - loadStart
guard let engine else {
    FileHandle.standardError.write(Data("fv_sherpa_create failed: \(errorString(errorBuffer))\n".utf8))
    exit(1)
}
defer { fv_sherpa_destroy(engine) }
print(String(format: "[probe] model load: %.1f ms, peak RSS %.0f MB", loadMs, peakRssMegabytes()))

// ---- whole-file recognition ----
let decodeStart = nowMs()
let text = audio.samples.withUnsafeBufferPointer { buffer in
    takeString(fv_sherpa_recognize_float(engine, buffer.baseAddress, Int32(buffer.count), "auto"))
}
let decodeMs = nowMs() - decodeStart
let audioSeconds = Double(audio.samples.count) / Double(audio.sampleRate)
print(String(format: "[probe] whole-file decode: %.1f ms (RTF %.3f)", decodeMs, decodeMs / 1000 / audioSeconds))
print("[probe] text = [\(text)]")

// ---- VAD streaming (feed 200 ms chunks as fast as possible) ----
let chunk = 3200
fv_sherpa_stream_reset(engine, "auto")
var segmentIndex = 0
let streamStart = nowMs()
var offset = 0
var segmentTexts: [String] = []
var firstPartialPrinted = false
while offset < audio.samples.count {
    let end = min(offset + chunk, audio.samples.count)
    audio.samples.withUnsafeBufferPointer { buffer in
        fv_sherpa_stream_feed(engine, buffer.baseAddress! + offset, Int32(end - offset))
    }
    while fv_sherpa_stream_has_segment(engine) != 0 {
        var start: Int32 = 0
        var count: Int32 = 0
        let segmentText = takeString(fv_sherpa_stream_take_segment(engine, &start, &count))
        segmentTexts.append(segmentText)
        print(String(format: "[probe] segment #%d start=%d n=%d (%.2fs) text=[%@]",
                     segmentIndex, start, count, Double(count) / 16000, segmentText))
        segmentIndex += 1
    }
    // Demo: print the first provisional decode of the in-progress speech.
    if !firstPartialPrinted, fv_sherpa_stream_detected(engine) != 0, end - offset > 0 {
        let window = min(end, 4 * 16000)
        let partial = audio.samples[0..<window].withUnsafeBufferPointer { buffer in
            takeString(fv_sherpa_recognize_float(engine, buffer.baseAddress, Int32(buffer.count), "auto"))
        }
        print("[probe] first provisional decode after \(end) samples: [\(partial)]")
        firstPartialPrinted = true
    }
    offset = end
}
fv_sherpa_stream_flush(engine)
while fv_sherpa_stream_has_segment(engine) != 0 {
    var start: Int32 = 0
    var count: Int32 = 0
    let segmentText = takeString(fv_sherpa_stream_take_segment(engine, &start, &count))
    segmentTexts.append(segmentText)
    print(String(format: "[probe] flushed segment #%d start=%d n=%d (%.2fs) text=[%@]",
                 segmentIndex, start, count, Double(count) / 16000, segmentText))
    segmentIndex += 1
}
let streamMs = nowMs() - streamStart
print(String(format: "[probe] stream: %d segment(s) in %.1f ms (RTF %.3f); joined=[%@]",
             segmentIndex, streamMs, streamMs / 1000 / audioSeconds, segmentTexts.filter { !$0.isEmpty }.joined(separator: " ")))
print(String(format: "[probe] peak RSS %.0f MB", peakRssMegabytes()))
print("[probe] OK")
