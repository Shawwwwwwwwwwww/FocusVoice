// Engine-level probe for SenseVoiceEngine (compiled together with
// Sources/FocusVoice/SenseVoiceEngine.swift by scripts/build-engine-probe.sh).
//
// It exercises the real streaming path with 200 ms PCM chunks scheduled in real
// time (like a microphone callback), records every `onUpdate`, and reports
// whole-file vs. streaming transcription, first-partial latency, finish cost,
// session reuse (finish -> begin -> finish, cancel -> begin) and peak RSS.
//
// This file is a development tool; it is not part of the app target.
import Darwin
import Foundation

@main
struct SenseVoiceEngineProbe {
    /// Mutable feed position shared between the pacing loop and the callbacks.
    final class FeedCounter {
        var samples = 0
        var seconds: Double { Double(samples) / 16000.0 }
    }

    struct Update {
        let wallMilliseconds: Double
        let fedSeconds: Double
        let confirmed: String
        let partial: String
        let partialDecodeMilliseconds: Double
    }

    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let fileManager = FileManager.default
        let defaultWav = "/tmp/focusvoice-audio/zh_4s.wav"
        let wavPath: String
        if let first = arguments.first, fileManager.fileExists(atPath: first) {
            wavPath = first
        } else {
            wavPath = defaultWav
        }

        let warmOnly = arguments.contains("--warm-only")
        print("=== SenseVoiceEngine engine probe ===")
        print("isAvailable=\(SenseVoiceEngine.isAvailable) location=\(SenseVoiceEngine.locationDescription)")
        print("models: \(SenseVoiceEngine.modelPathsDescription)")
        guard SenseVoiceEngine.isAvailable else {
            print("FATAL: models unavailable")
            exit(2)
        }
        guard fileManager.fileExists(atPath: wavPath) else {
            print("FATAL: missing wav \(wavPath); run scripts/make-test-audio.sh first")
            exit(2)
        }

        if warmOnly {
            print(String(format: "[memory] RSS at process start: %.0f MB", currentRssMegabytes()))
            let warmEngine = SenseVoiceEngine()
            let started = nowMilliseconds()
            await warmEngine.warmUp()
            print(String(format: "[warmUp] %.0f ms (modelLoadSeconds=%.2f), RSS after warmUp %.0f MB, peak %.0f MB",
                         nowMilliseconds() - started, warmEngine.modelLoadSeconds,
                         currentRssMegabytes(), peakRssMegabytes()))
            print("[warm-only] ready=\(warmEngine.isReady) error=\(warmEngine.lastError ?? "none")")
            exit(0)
        }

        // ---- whole-file reference ----
        let wholeStart = nowMilliseconds()
        var referenceText = ""
        do {
            referenceText = try await SenseVoiceEngine.transcribeFile(URL(fileURLWithPath: wavPath))
        } catch {
            print("FATAL: transcribeFile failed: \(error.localizedDescription)")
            exit(1)
        }
        print(String(format: "[whole-file] transcribeFile: %.0f ms -> [%@]", nowMilliseconds() - wholeStart, referenceText))

        let samples: [Float]
        do {
            samples = try AudioFileLoader.load16kMono(URL(fileURLWithPath: wavPath))
        } catch {
            print("FATAL: cannot load audio: \(error.localizedDescription)")
            exit(1)
        }
        let audioSeconds = Double(samples.count) / 16000.0
        let speechOnsetSeconds = Double(firstSpeechOffset(samples)) / 16000.0
        let leadSilenceSeconds = 0.5
        print(String(format: "[input] %.2fs audio, speech onset at %.2fs, 200 ms chunks, %.0f ms leading silence",
                     audioSeconds, speechOnsetSeconds, leadSilenceSeconds * 1000))
        print(String(format: "[memory] RSS before warmUp: %.0f MB", currentRssMegabytes()))

        // ---- warm up once ----
        let engine = SenseVoiceEngine()
        let warmStart = nowMilliseconds()
        await engine.warmUp()
        guard engine.isReady else {
            print("FATAL: warmUp failed: \(engine.lastError ?? "unknown")")
            exit(1)
        }
        print(String(format: "[warmUp] %.0f ms (modelLoadSeconds=%.2f), RSS after warmUp %.0f MB, peak %.0f MB",
                     nowMilliseconds() - warmStart, engine.modelLoadSeconds,
                     currentRssMegabytes(), peakRssMegabytes()))

        // ---- session 1: real-time streaming ----
        let counter = FeedCounter()
        var updates: [Update] = []
        let sessionStart = nowMilliseconds()
        engine.onUpdate = { confirmed, partial in
            updates.append(Update(
                wallMilliseconds: nowMilliseconds() - sessionStart,
                fedSeconds: counter.seconds,
                confirmed: confirmed,
                partial: partial,
                partialDecodeMilliseconds: engine.lastPartialDecodeMilliseconds
            ))
            print(String(format: "[update] wall=%6.0fms fed=%5.2fs confirmed=[%@] partial=[%@] (partial decode %.0f ms)",
                         nowMilliseconds() - sessionStart, counter.seconds, confirmed, partial,
                         engine.lastPartialDecodeMilliseconds))
        }
        let silence = [Float](repeating: 0, count: Int(leadSilenceSeconds * 16000))
        engine.begin(language: "auto")
        await feed(pcm: silence, chunkMilliseconds: 200, realtime: true, engine: engine, counter: counter)
        await feed(pcm: samples, chunkMilliseconds: 200, realtime: true, engine: engine, counter: counter)

        let finishStart = nowMilliseconds()
        let streamedText = await engine.finish()
        let finishMilliseconds = nowMilliseconds() - finishStart
        engine.onUpdate = nil
        let totalMilliseconds = nowMilliseconds() - sessionStart

        print(String(format: "[finish] %.0f ms -> [%@]", finishMilliseconds, streamedText))
        print(String(format: "[session1] wall %.0f ms for %.2fs audio (real-time feed)", totalMilliseconds, audioSeconds))

        let partials = updates.filter { !$0.partial.isEmpty }
        if let firstPartial = partials.first {
            print(String(format: "[first-partial] wall=%.0f ms, fed=%.2fs, from speech onset=%.0f ms -> [%@]",
                         firstPartial.wallMilliseconds, firstPartial.fedSeconds,
                         (firstPartial.fedSeconds - speechOnsetSeconds) * 1000, firstPartial.partial))
        } else {
            print("[first-partial] NONE - no provisional text was produced")
        }
        let decodeTimes = partials.map { $0.partialDecodeMilliseconds }
        if !decodeTimes.isEmpty {
            let average = decodeTimes.reduce(0, +) / Double(decodeTimes.count)
            print(String(format: "[partial-decode] avg %.0f ms, max %.0f ms over %d provisional decodes",
                         average, decodeTimes.max() ?? 0, decodeTimes.count))
        }
        let confirmedUpdates = updates.filter { !$0.confirmed.isEmpty }
        print("[updates] total=\(updates.count) partial=\(partials.count) confirmed=\(confirmedUpdates.count) over \(String(format: "%.1f", totalMilliseconds / 1000))s, max rate \(String(format: "%.1f", updateRate(updates)))/s")

        let matches = normalizeForCompare(streamedText) == normalizeForCompare(referenceText)
        print("[verify] streamed == whole-file: \(matches ? "YES" : "NO")")
        if !matches {
            print("         streamed:   [\(streamedText)]")
            print("         whole-file: [\(referenceText)]")
        }

        // ---- session 2: reuse after finish (same instance, model stays loaded) ----
        let reuseStart = nowMilliseconds()
        engine.begin(language: "auto")
        let reuseCounter = FeedCounter()
        await feed(pcm: samples, chunkMilliseconds: 200, realtime: false, engine: engine, counter: reuseCounter)
        let reuseText = await engine.finish()
        let reuseMatches = normalizeForCompare(reuseText) == normalizeForCompare(referenceText)
        print(String(format: "[reuse-after-finish] %.0f ms (fast feed) -> [%@] %@",
                     nowMilliseconds() - reuseStart, reuseText, reuseMatches ? "MATCH" : "MISMATCH"))

        // ---- session 3: cancel, then reuse after cancel ----
        engine.begin(language: "auto")
        let cancelCounter = FeedCounter()
        let half = Array(samples.prefix(16000 * 2))
        await feed(pcm: half, chunkMilliseconds: 200, realtime: false, engine: engine, counter: cancelCounter)
        engine.cancel()
        let cancelledText = await engine.finish()

        engine.begin(language: "auto")
        let reuseCounter2 = FeedCounter()
        await feed(pcm: samples, chunkMilliseconds: 200, realtime: false, engine: engine, counter: reuseCounter2)
        let afterCancelText = await engine.finish()
        let afterCancelMatches = normalizeForCompare(afterCancelText) == normalizeForCompare(referenceText)
        print("[cancel] finish after cancel -> [\(cancelledText)] (expected empty)")
        print("[reuse-after-cancel] -> [\(afterCancelText)] \(afterCancelMatches ? "MATCH" : "MISMATCH")")

        print(String(format: "[memory] RSS %.0f MB, peak %.0f MB", currentRssMegabytes(), peakRssMegabytes()))
        print("=== probe done ===")
    }

    // MARK: - Streaming helpers

    @MainActor
    private static func feed(pcm: [Float], chunkMilliseconds: Int, realtime: Bool,
                             engine: SenseVoiceEngine, counter: FeedCounter) async {
        let chunkSize = 16000 * chunkMilliseconds / 1000
        let start = nowMilliseconds()
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + chunkSize, pcm.count)
            engine.push(pcm16Data(pcm[offset..<end]))
            counter.samples = end
            offset = end
            if realtime {
                // Pace the feed to real time like a microphone callback would.
                let target = start + Double(offset) / 16000.0 * 1000.0
                let delay = target - nowMilliseconds()
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000))
                }
            }
        }
    }

    private static func pcm16Data(_ samples: ArraySlice<Float>) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let value = Int16((clamped * 32767.0).rounded())
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func firstSpeechOffset(_ samples: [Float]) -> Int {
        for (index, sample) in samples.enumerated() where abs(sample) > 0.008 {
            return index
        }
        return 0
    }

    private static func normalizeForCompare(_ text: String) -> String {
        text.filter { !$0.isWhitespace && !"，。？！?,".contains($0) }
    }

    private static func updateRate(_ updates: [Update]) -> Double {
        var maxRate = 0.0
        var left = 0
        for right in updates.indices {
            while updates[right].wallMilliseconds - updates[left].wallMilliseconds > 1000 {
                left += 1
            }
            maxRate = max(maxRate, Double(right - left + 1))
        }
        return maxRate
    }

    // MARK: - Measurements

    private static func nowMilliseconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e6
    }

    private static func peakRssMegabytes() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / (1024 * 1024)
    }

    private static func currentRssMegabytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / (1024 * 1024)
    }
}
