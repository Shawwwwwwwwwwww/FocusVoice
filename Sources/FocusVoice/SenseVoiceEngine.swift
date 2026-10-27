// SenseVoiceEngine.swift
//
// On-device speech-to-text for FocusVoice, using exactly the same runtime and
// models as DeepSeek Harness' built-in speech input:
//
//   sherpa-onnx 1.13.8 (CPU) + SenseVoiceSmall int8 + Silero VAD
//
// Design
// ------
// * `SenseVoiceEngine` is the small @MainActor façade the controller talks to.
// * `SenseVoiceSession` owns a serial queue and the native recognizer; all heavy
//   work (PCM conversion, VAD feeding, decoding) happens there, never on the
//   main thread. `push(_:)` only enqueues.
// * Segmentation follows the DSH worker: the Silero VAD cuts completed speech
//   segments (threshold 0.5 / minSpeech 0.25s / minSilence 0.5s / maxSpeech
//   20s), each completed segment is decoded once and cached as `confirmed`.
//   The in-progress speech is re-decoded every ~450ms (adaptive) as `partial`
//   so the HUD can show text while the user is still talking.
// * `finish()` flushes the VAD, decodes the last segment, and falls back to
//   decoding any trailing audio that the VAD did not complete, so no content is
//   lost and nothing is decoded twice (segment timeline is tracked in samples).
//
// Public contract (frozen for the controller):
//
//   @MainActor final class SenseVoiceEngine {
//       static var isAvailable: Bool { get }
//       static var locationDescription: String { get }
//       static func transcribeFile(_ url: URL) async throws -> String
//       init()
//       func warmUp() async
//       var onUpdate: ((_ confirmed: String, _ partial: String) -> Void)?
//       func begin(language: String = "auto")
//       func push(_ pcm16: Data)
//       func finish() async -> String
//       func cancel()
//   }
//
// `onUpdate` is delivered on the main actor, at most ~5 times per second, and
// receives (confirmed, partial) which concatenated form the full preview text.

import AVFoundation
import CSherpa
import Foundation

// MARK: - Errors

enum SenseVoiceError: LocalizedError {
    case modelsUnavailable
    case audioUnreadable(String)
    case modelLoadFailed(String)
    case engineNotReady

    var errorDescription: String? {
        switch self {
        case .modelsUnavailable:
            return "未找到 SenseVoice 模型（内置 Resources/models/sensevoice 或 ~/.dsh 缓存）"
        case .audioUnreadable(let detail):
            return "无法读取音频文件：\(detail)"
        case .modelLoadFailed(let detail):
            return "SenseVoice 模型加载失败：\(detail)"
        case .engineNotReady:
            return "SenseVoice 引擎尚未完成加载"
        }
    }
}

// MARK: - Model discovery

struct SenseVoiceModelSet {
    enum Source {
        case downloaded
        case bundled
        case dshCache
        case customDirectory

        var description: String {
            switch self {
            case .downloaded: return "已下载模型"
            case .bundled: return "App 内置模型"
            case .dshCache: return "DSH 本地模型缓存"
            case .customDirectory: return "自定义模型目录"
            }
        }
    }

    let model: String
    let tokens: String
    let vad: String
    let source: Source
    let directory: String

    var locationDescription: String { source.description }
}

enum SenseVoiceModelLocator {
    /// Resolution order:
    ///   1. `FOCUSVOICE_SENSEVOICE_DIR` (development / test override)
    ///   2. `<Bundle>.resources/models/sensevoice` (packaged app)
    ///   3. `~/.dsh/speech-to-text/sensevoice/models` (DeepSeek Harness cache)
    /// Each directory may be flat (model.int8.onnx / tokens.txt / silero_vad.onnx)
    /// or mirror the DSH layout (sensevoice-onnx/… + silero/silero_vad.onnx).
    static func resolve() -> SenseVoiceModelSet? {
        if ProcessInfo.processInfo.environment["FOCUSVOICE_SIMULATE_MISSING_MODEL"] == "1" { return nil }
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment

        var candidates: [(directory: String, source: SenseVoiceModelSet.Source)] = []
        if let override = environment["FOCUSVOICE_SENSEVOICE_DIR"], !override.isEmpty {
            candidates.append((override, .customDirectory))
        }
        let downloaded = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FocusVoice/Models/sensevoice", isDirectory: true)
        candidates.append((downloaded.path, .downloaded))
        if let resources = Bundle.main.resourceURL {
            candidates.append((resources.appendingPathComponent("models/sensevoice").path, .bundled))
        }
        candidates.append((
            fileManager.homeDirectoryForCurrentUser.path + "/.dsh/speech-to-text/sensevoice/models",
            .dshCache
        ))

        for candidate in candidates {
            if let files = findFiles(in: candidate.directory) {
                return SenseVoiceModelSet(
                    model: files.model,
                    tokens: files.tokens,
                    vad: files.vad,
                    source: candidate.source,
                    directory: candidate.directory
                )
            }
        }
        return nil
    }

    private static func findFiles(in directory: String) -> (model: String, tokens: String, vad: String)? {
        let fileManager = FileManager.default
        let layouts: [(String, String, String)] = [
            ("/model.int8.onnx", "/tokens.txt", "/silero_vad.onnx"),
            ("/sensevoice-onnx/model.int8.onnx", "/sensevoice-onnx/tokens.txt", "/silero/silero_vad.onnx"),
            ("/model.int8.onnx", "/tokens.txt", "/silero/silero_vad.onnx"),
        ]
        for layout in layouts {
            let model = directory + layout.0
            let tokens = directory + layout.1
            let vad = directory + layout.2
            if fileManager.fileExists(atPath: model),
               fileManager.fileExists(atPath: tokens),
               fileManager.fileExists(atPath: vad) {
                return (model, tokens, vad)
            }
        }
        return nil
    }
}

// MARK: - Native recognizer wrapper (single-threaded, call from one queue)

/// Thin synchronous wrapper over the CSherpa handles. Not thread safe by design:
/// every call must happen on the owning session's serial queue.
final class SherpaRecognizerCore {
    private var handle: OpaquePointer?
    private static let threads: Int32 = 2
    private static let maxSpeechSeconds: Float = 20.0

    var isLoaded: Bool { handle != nil }

    deinit { unload() }

    func load(_ models: SenseVoiceModelSet) throws {
        if handle != nil { return }
        var errorBuffer = [CChar](repeating: 0, count: 1024)
        let created: OpaquePointer? = models.model.withCString { model in
            models.tokens.withCString { tokens in
                models.vad.withCString { vad in
                    fv_sherpa_create(
                        model, tokens, vad,
                        Self.threads, Self.maxSpeechSeconds,
                        &errorBuffer, errorBuffer.count
                    )
                }
            }
        }
        guard let created else {
            throw SenseVoiceError.modelLoadFailed(Self.message(from: errorBuffer))
        }
        handle = created
    }

    func unload() {
        if let handle {
            fv_sherpa_destroy(handle)
            self.handle = nil
        }
    }

    func recognize(_ samples: [Float], language: String) -> String {
        guard let handle, !samples.isEmpty else { return "" }
        let text: UnsafeMutablePointer<CChar>? = samples.withUnsafeBufferPointer { buffer in
            language.withCString { languagePointer in
                fv_sherpa_recognize_float(handle, buffer.baseAddress, Int32(buffer.count), languagePointer)
            }
        }
        return Self.take(text)
    }

    func streamReset(language: String) {
        guard let handle else { return }
        language.withCString { fv_sherpa_stream_reset(handle, $0) }
    }

    func streamFeed(_ samples: [Float]) {
        guard let handle, !samples.isEmpty else { return }
        samples.withUnsafeBufferPointer { buffer in
            fv_sherpa_stream_feed(handle, buffer.baseAddress, Int32(buffer.count))
        }
    }

    func hasSegment() -> Bool {
        guard let handle else { return false }
        return fv_sherpa_stream_has_segment(handle) != 0
    }

    /// Pops the oldest completed VAD segment without decoding it.
    /// The caller re-decodes it (possibly with onset padding prepended).
    func takeSegmentAudio() -> (start: Int, count: Int, samples: [Float])? {
        guard let handle, hasSegment() else { return nil }
        var start: Int32 = 0
        var count: Int32 = 0
        var samplesPointer: UnsafeMutablePointer<Float>?
        let ok = fv_sherpa_stream_take_segment_audio(handle, &start, &count, &samplesPointer)
        guard ok != 0 else { return nil }
        var samples: [Float] = []
        if let samplesPointer, count > 0 {
            samples = Array(UnsafeBufferPointer(start: samplesPointer, count: Int(count)))
            fv_sherpa_free_samples(samplesPointer)
        }
        return (Int(start), Int(count), samples)
    }

    func streamFlush() {
        guard let handle else { return }
        fv_sherpa_stream_flush(handle)
    }

    func streamClear() {
        guard let handle else { return }
        fv_sherpa_stream_clear(handle)
    }

    var isSpeechDetected: Bool {
        guard let handle else { return false }
        return fv_sherpa_stream_detected(handle) != 0
    }

    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        defer { fv_sherpa_free_text(pointer) }
        return String(cString: pointer)
    }

    private static func message(from buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let message = String(decoding: bytes, as: UTF8.self)
        return message.isEmpty ? "unknown native error" : message
    }
}

// MARK: - Session (serial queue owns all streaming state)

/// One dictation session. All mutable streaming state is confined to `queue`;
/// the only cross-thread state is the small control block behind `controlLock`.
final class SenseVoiceSession: @unchecked Sendable {
    private struct StreamState {
        var generation: UInt64 = 0
        var active = false
        var language = "auto"
        var segments: [String] = []
        var confirmed = ""
        var partial = ""
        /// Captured audio, `history[0]` corresponds to absolute sample `historyBase`.
        var history: [Float] = []
        var historyBase = 0
        var totalFed = 0
        var lastSegmentEnd = 0
        var lastPartialMediaTime = -1.0
        var lastPartialDecodeSeconds = 0.0
        var lastEmitTime: UInt64 = 0
        var lastEmittedConfirmed = ""
        var lastEmittedPartial = ""
    }

    private struct Control {
        var accepting = false
        var pendingSamples = 0
        var generation: UInt64 = 0
    }

    private let queue = DispatchQueue(label: "com.focusvoice.sensevoice.session", qos: .userInitiated)
    private let core = SherpaRecognizerCore()
    private let controlLock = NSLock()
    private var control = Control()
    private var stream = StreamState()

    /// Invoked from the session queue; the façade re-dispatches to the main actor.
    /// Arguments: confirmed, partial, duration of the last provisional decode (ms).
    var onUpdateHandler: ((String, String, Double) -> Void)?

    /// Small critical section for the few values crossing the queue boundary.
    private func withControl<T>(_ body: (inout Control) -> T) -> T {
        controlLock.lock()
        defer { controlLock.unlock() }
        return body(&control)
    }

    private static let sampleRate = 16000
    private static let partialIntervalFloor: TimeInterval = 0.45
    private static let partialIntervalCeiling: TimeInterval = 1.5
    private static let maxPartialWindowSamples = 20 * 16000
    /// A provisional decode needs enough speech context to be meaningful;
    /// shorter windows make SenseVoice hallucinate single stray characters.
    private static let minPartialWindowSamples = 5600  // 350 ms
    /// Pre-segment audio restored before decoding (same 0.3 s as the DSH worker's
    /// `vadOnsetPaddingSeconds`), compensating for Silero VAD trigger latency.
    private static let onsetPaddingSamples = 4800
    private static let emitInterval: UInt64 = 200_000_000  // <= 5 updates / second

    // MARK: Lifecycle

    /// Loads the native models. Returns the load duration in seconds.
    func prepare(models: SenseVoiceModelSet) async -> Result<TimeInterval, Error> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<TimeInterval, Error>, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .failure(SenseVoiceError.engineNotReady))
                    return
                }
                if self.core.isLoaded {
                    continuation.resume(returning: .success(0))
                    return
                }
                let started = DispatchTime.now()
                do {
                    try self.core.load(models)
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
                    continuation.resume(returning: .success(elapsed))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    // MARK: Session control

    func begin(language: String) {
        let sessionGeneration = withControl { control -> UInt64 in
            control.generation &+= 1
            control.accepting = true
            return control.generation
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.stream = StreamState()
            self.stream.generation = sessionGeneration
            self.stream.active = true
            self.stream.language = language
            self.core.streamReset(language: language)
        }
    }

    func push(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        let snapshot = withControl { control -> (accepting: Bool, generation: UInt64) in
            if control.accepting { control.pendingSamples += pcm16.count / 2 }
            return (control.accepting, control.generation)
        }
        guard snapshot.accepting else { return }
        let sessionGeneration = snapshot.generation

        queue.async { [weak self] in
            self?.process(pcm16, generation: sessionGeneration)
        }
    }

    func cancel() {
        let sessionGeneration = withControl { control -> UInt64 in
            control.accepting = false
            control.generation &+= 1
            return control.generation
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.core.streamClear()
            self.stream = StreamState()
            self.stream.generation = sessionGeneration
        }
    }

    func finish() async -> String {
        let sessionGeneration = withControl { control -> UInt64 in
            control.accepting = false
            return control.generation
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            queue.async { [weak self] in
                let text = self?.finalize(generation: sessionGeneration) ?? ""
                continuation.resume(returning: text)
            }
        }
    }

    // MARK: Queue-confined processing

    private func process(_ pcm16: Data, generation sessionGeneration: UInt64) {
        let sampleCount = pcm16.count / 2
        withControl { control in
            control.pendingSamples = max(0, control.pendingSamples - sampleCount)
        }

        guard stream.active, stream.generation == sessionGeneration, core.isLoaded else { return }

        let samples = Self.pcm16ToFloat(pcm16)
        guard !samples.isEmpty else { return }
        stream.totalFed += samples.count
        stream.history.append(contentsOf: samples)
        core.streamFeed(samples)

        drainSegments()
        emit()

        if let window = partialWindow() {
            let started = DispatchTime.now()
            let text = core.recognize(window, language: stream.language)
            stream.lastPartialDecodeSeconds =
                Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
            let mediaTime = Double(stream.totalFed) / Double(Self.sampleRate)
            stream.lastPartialMediaTime = mediaTime
            let normalized = Self.normalize(text)
            if !normalized.isEmpty {
                stream.partial = normalized
                emit()
            }
        }
    }

    private func drainSegments() {
        while core.hasSegment() {
            guard let segment = core.takeSegmentAudio() else { break }
            let previousSegmentEnd = stream.lastSegmentEnd
            stream.lastSegmentEnd = max(stream.lastSegmentEnd, segment.start + segment.count)

            // The Silero VAD needs some speech before it triggers, so the raw
            // segment start can clip the first syllable ("我们" -> "需要").
            // The DSH worker restores 0.3 s of audio before the segment start;
            // do the same here (never reaching back into an already decoded
            // segment, so nothing is transcribed twice).
            var audio = segment.samples
            let padBegin = max(
                stream.historyBase,
                max(previousSegmentEnd, segment.start - Self.onsetPaddingSamples)
            )
            if padBegin < segment.start {
                let from = padBegin - stream.historyBase
                let to = min(segment.start - stream.historyBase, stream.history.count)
                if from >= 0, from < to {
                    audio = Array(stream.history[from..<to]) + audio
                }
            }

            let text = Self.normalize(core.recognize(audio, language: stream.language))
            if !text.isEmpty {
                stream.segments.append(text)
                stream.confirmed = Self.joinSegments(stream.segments)
            }
            stream.partial = ""
            stream.lastPartialMediaTime = -1.0
            trimHistory()
            emit(force: true)
        }
    }

    private func trimHistory() {
        let drop = stream.lastSegmentEnd - stream.historyBase
        guard drop > 0 else { return }
        let removable = min(drop, stream.history.count)
        if removable > 0 {
            stream.history.removeFirst(removable)
            stream.historyBase += removable
        }
    }

    /// Audio window for the next provisional decode, or nil when there is no
    /// speech-like audio pending (pure silence must not be decoded).
    private func partialWindow() -> [Float]? {
        guard core.isLoaded else { return nil }
        let backlog = withControl { control in control.pendingSamples }
        // Behind on audio? Skip this provisional decode so latency does not grow.
        if backlog > Self.sampleRate / 2 { return nil }

        let mediaTime = Double(stream.totalFed) / Double(Self.sampleRate)
        let interval = min(
            max(Self.partialIntervalFloor, stream.lastPartialDecodeSeconds * 2.5),
            Self.partialIntervalCeiling
        )
        if stream.lastPartialMediaTime >= 0, mediaTime - stream.lastPartialMediaTime < interval {
            return nil
        }

        let searchStart = max(stream.lastSegmentEnd, stream.totalFed - Self.maxPartialWindowSamples)
        let searchIndex = max(0, searchStart - stream.historyBase)
        guard searchIndex < stream.history.count else { return nil }

        var onsetIndex: Int?
        var index = searchIndex
        while index < stream.history.count {
            if abs(stream.history[index]) > 0.008 {
                onsetIndex = index
                break
            }
            index += 1
        }

        var startIndex: Int
        if let onsetIndex {
            startIndex = max(searchIndex, onsetIndex - 2400)  // 150 ms pre-roll
        } else if core.isSpeechDetected {
            startIndex = searchIndex
        } else {
            return nil
        }

        let endIndex = stream.history.count
        guard endIndex - startIndex >= Self.minPartialWindowSamples else { return nil }
        if endIndex - startIndex > Self.maxPartialWindowSamples {
            startIndex = endIndex - Self.maxPartialWindowSamples
        }
        return Array(stream.history[startIndex..<endIndex])
    }

    private func finalize(generation sessionGeneration: UInt64) -> String {
        guard stream.generation == sessionGeneration, stream.active, core.isLoaded else {
            return stream.confirmed
        }
        drainSegments()
        core.streamFlush()
        drainSegments()

        // Trailing audio the VAD did not turn into a segment (very short tail,
        // unusual pacing, or cancel/stop right after speaking).
        if let trailing = trailingSamples(), !trailing.isEmpty {
            let text = Self.normalize(core.recognize(trailing, language: stream.language))
            if !text.isEmpty { stream.segments.append(text) }
        }
        if stream.segments.isEmpty, stream.totalFed > Self.sampleRate / 10 {
            let capture = Array(stream.history)
            var energy: Float = 0
            for sample in capture { energy += sample * sample }
            let rms = capture.isEmpty ? 0 : (energy / Float(capture.count)).squareRoot()
            // 全静音录音不要去解码，否则会得到凭空冒出的词
            if rms > 0.006 {
                let text = Self.normalize(core.recognize(capture, language: stream.language))
                if !text.isEmpty { stream.segments.append(text) }
            }
        }

        stream.confirmed = Self.joinSegments(stream.segments)
        stream.partial = ""
        emit(force: true)

        let finalText = stream.confirmed
        stream.active = false
        core.streamClear()
        stream = StreamState()
        return finalText
    }

    /// Samples after the last completed segment that were never decoded as part
    /// of a segment. Returns nil when the tail is too short to matter.
    private func trailingSamples() -> [Float]? {
        let trailingStart = max(stream.lastSegmentEnd, stream.historyBase)
        let startIndex = max(0, trailingStart - stream.historyBase)
        guard startIndex < stream.history.count else { return nil }
        let tail = Array(stream.history[startIndex...])
        guard tail.count >= Self.sampleRate / 8 else { return nil }

        // 只解码「确实有人声」的尾段：旧实现把尾部静音也丢给 SenseVoice，
        // 模型会在静音上幻觉出 "yeah" / "Okay" 之类的英文词。
        let threshold: Float = 0.008
        var lastVoiced = -1
        var index = tail.count - 1
        while index >= 0 {
            if abs(tail[index]) > threshold { lastVoiced = index; break }
            index -= 1
        }
        guard lastVoiced >= 0 else { return nil }

        var firstVoiced = 0
        while firstVoiced < tail.count, abs(tail[firstVoiced]) <= threshold { firstVoiced += 1 }
        let start = max(0, firstVoiced - 1600)          // 100ms 前导
        let end = min(tail.count, lastVoiced + 1600)    // 100ms 尾随
        guard end - start >= Int(0.15 * Double(Self.sampleRate)) else { return nil }

        let trimmed = Array(tail[start..<end])
        var energy: Float = 0
        for sample in trimmed { energy += sample * sample }
        let rms = (energy / Float(trimmed.count)).squareRoot()
        guard rms > 0.006 else { return nil }
        return trimmed
    }

    private func emit(force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        if !force, now &- stream.lastEmitTime < Self.emitInterval { return }
        let confirmed = stream.confirmed
        let partial = stream.partial
        if confirmed == stream.lastEmittedConfirmed, partial == stream.lastEmittedPartial {
            return
        }
        stream.lastEmitTime = now
        stream.lastEmittedConfirmed = confirmed
        stream.lastEmittedPartial = partial
        onUpdateHandler?(confirmed, partial, stream.lastPartialDecodeSeconds * 1000)
    }

    // MARK: Conversion / text helpers

    static func pcm16ToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            for index in 0..<count {
                let value = base.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
                samples[index] = Float(Int16(littleEndian: value)) * (1.0 / 32768.0)
            }
        }
        return samples
    }

    static func normalize(_ raw: String) -> String {
        // 统一走全局清洗：去掉 <|HAPPY|> 之类的标签、句尾 yeah/Okay 幻觉词与重复标点。
        TranscriptSanitizer.sanitize(raw)
    }

    /// Joins segment texts: no space between CJK pieces, one space between two
    /// ASCII word pieces (e.g. English).
    static func joinSegments(_ segments: [String]) -> String {
        var output = ""
        for raw in segments {
            let piece = normalize(raw)
            guard !piece.isEmpty else { continue }
            if output.isEmpty {
                output = piece
                continue
            }
            if let last = output.last, let first = piece.first, needsSpace(between: last, and: first) {
                output += " "
            }
            output += piece
        }
        return output
    }

    private static func needsSpace(between left: Character, and right: Character) -> Bool {
        func isAsciiWord(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character.isNumber)
        }
        return isAsciiWord(left) && isAsciiWord(right)
    }
}

// MARK: - Audio file loading (for --selftest stt)

enum AudioFileLoader {
    static func load16kMono(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw SenseVoiceError.audioUnreadable(error.localizedDescription)
        }
        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else {
            throw SenseVoiceError.audioUnreadable("empty audio file")
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw SenseVoiceError.audioUnreadable("cannot allocate input buffer")
        }
        do {
            try file.read(into: input)
        } catch {
            throw SenseVoiceError.audioUnreadable(error.localizedDescription)
        }

        if abs(sourceFormat.sampleRate - 16000) < 0.5,
           sourceFormat.channelCount == 1,
           let channel = input.floatChannelData {
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(input.frameLength)))
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw SenseVoiceError.audioUnreadable(
                "cannot convert \(Int(sourceFormat.sampleRate)) Hz / \(sourceFormat.channelCount) ch to 16 kHz mono"
            )
        }
        let ratio = 16000.0 / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw SenseVoiceError.audioUnreadable("cannot allocate output buffer")
        }
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return input
        }
        if let conversionError {
            throw SenseVoiceError.audioUnreadable(conversionError.localizedDescription)
        }
        if status == .error {
            throw SenseVoiceError.audioUnreadable("audio conversion failed")
        }
        guard let channel = output.floatChannelData else {
            throw SenseVoiceError.audioUnreadable("converted buffer has no float data")
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}

// MARK: - Public façade

@MainActor
final class SenseVoiceEngine {
    /// Full preview text updates: (confirmed, partial). Main actor, <= 5/s.
    /// `confirmed + partial` is the complete preview text to display.
    var onUpdate: ((_ confirmed: String, _ partial: String) -> Void)?

    /// Last failure, kept for HUD diagnostics. Never throws from callbacks.
    private(set) var lastError: String?
    /// True once the ~228 MB model has been loaded into memory.
    private(set) var isReady = false
    /// Model load duration of the last successful `warmUp()`, in seconds.
    private(set) var modelLoadSeconds: TimeInterval = 0
    /// Duration of the most recent provisional decode in milliseconds (diagnostics).
    private(set) var lastPartialDecodeMilliseconds: Double = 0

    private let session = SenseVoiceSession()

    init() {
        session.onUpdateHandler = { [weak self] confirmed, partial, partialDecodeMilliseconds in
            guard let self else { return }
            Task { @MainActor in
                self.lastPartialDecodeMilliseconds = partialDecodeMilliseconds
                self.onUpdate?(confirmed, partial)
            }
        }
    }

    // MARK: Availability

    static var isAvailable: Bool { SenseVoiceModelLocator.resolve() != nil }

    static var locationDescription: String {
        SenseVoiceModelLocator.resolve()?.locationDescription ?? "不可用"
    }

    /// Absolute paths of the models that would be used (diagnostics).
    static var modelPathsDescription: String {
        guard let models = SenseVoiceModelLocator.resolve() else { return "未找到模型" }
        return "\(models.locationDescription)：\(models.directory)"
    }

    // MARK: Lifecycle

    /// Loads the native models on the session queue. Safe to call repeatedly.
    func warmUp() async {
        guard !isReady else { return }
        guard let models = SenseVoiceModelLocator.resolve() else {
            lastError = SenseVoiceError.modelsUnavailable.localizedDescription
            return
        }
        switch await session.prepare(models: models) {
        case .success(let seconds):
            isReady = true
            modelLoadSeconds = seconds
            lastError = nil
        case .failure(let error):
            isReady = false
            lastError = error.localizedDescription
        }
    }

    // MARK: Streaming

    func begin(language: String = "auto") {
        guard isReady else {
            lastError = SenseVoiceError.engineNotReady.localizedDescription
            return
        }
        session.begin(language: language)
    }

    /// Non-blocking: converts PCM later on the session queue.
    func push(_ pcm16: Data) {
        guard isReady else { return }
        session.push(pcm16)
    }

    /// Flushes the VAD, decodes the last segment and returns the final text.
    func finish() async -> String {
        await session.finish()
    }

    func cancel() {
        session.cancel()
    }

    // MARK: Whole-file transcription (--selftest stt)

    static func transcribeFile(_ url: URL) async throws -> String {
        guard let models = SenseVoiceModelLocator.resolve() else {
            throw SenseVoiceError.modelsUnavailable
        }
        let samples = try AudioFileLoader.load16kMono(url)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let core = SherpaRecognizerCore()
                do {
                    try core.load(models)
                    let text = core.recognize(samples, language: "auto")
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
