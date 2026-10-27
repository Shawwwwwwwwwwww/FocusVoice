import Foundation
import Combine

/// SenseVoice 模型按需下载器：App 安装包不再内置 230MB 模型，
/// 用户在设置里点一次按钮，下载到 Application Support 后即可离线使用。
@MainActor
final class SenseVoiceModelManager: ObservableObject {
    enum State: Equatable {
        case unknown
        case missing
        case downloading
        case installing
        case ready
        case failed(String)
    }

    static let shared = SenseVoiceModelManager()

    @Published private(set) var state: State = .unknown
    @Published private(set) var progress: Double = 0
    @Published private(set) var detail: String = ""

    static var installDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FocusVoice/Models/sensevoice", isDirectory: true)
    }

    private static let modelBase = "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/"
    private static let vadURL = "https://huggingface.co/csukuangfj/vad/resolve/fba88cd2e921609e7675c3aaf51e0b9b295da4bc/silero_vad.onnx"

    private struct Asset {
        let name: String
        let url: URL
        let minBytes: Int64
    }

    private static let assets: [Asset] = [
        Asset(name: "model.int8.onnx", url: URL(string: modelBase + "model.int8.onnx")!, minBytes: 100_000_000),
        Asset(name: "tokens.txt", url: URL(string: modelBase + "tokens.txt")!, minBytes: 1_000),
        Asset(name: "silero_vad.onnx", url: URL(string: vadURL)!, minBytes: 100_000)
    ]

    private var currentTask: URLSessionDownloadTask?
    private var currentSession: URLSession?
    private var currentDelegate: DownloadDelegate?
    private var downloadTask: Task<Void, Never>?

    private init() {
        refresh()
    }

    static var isInstalled: Bool {
        if ProcessInfo.processInfo.environment["FOCUSVOICE_SIMULATE_MISSING_MODEL"] == "1" { return false }
        return assets.allSatisfy { asset in
            let path = installDirectory.appendingPathComponent(asset.name).path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int64 else { return false }
            return size >= asset.minBytes
        }
    }

    func refresh() {
        guard !Self.isInstalled else {
            state = .ready
            detail = "模型已安装，可离线使用"
            progress = 1
            return
        }
        state = .missing
        detail = "模型未安装 · 约 230MB · 下载一次后离线使用"
        progress = 0
    }

    func install() {
        guard state != .downloading, state != .installing else { return }
        downloadTask?.cancel()
        downloadTask = Task { [weak self] in await self?.performInstall() }
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        currentTask?.cancel()
        currentSession?.invalidateAndCancel()
        currentTask = nil
        currentSession = nil
        currentDelegate = nil
        state = .missing
        detail = "已取消下载"
        progress = 0
    }

    func installAwait() async { await performInstall() }

    private func performInstall() async {
        state = .downloading
        progress = 0
        detail = "正在准备下载…"

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("FocusVoice-Model-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for (index, asset) in Self.assets.enumerated() {
                try Task.checkCancellation()
                detail = "正在下载 \(asset.name)（\(index + 1)/\(Self.assets.count)）…"
                let destination = staging.appendingPathComponent(asset.name)
                try await download(asset, to: destination, fileIndex: index)
                try Task.checkCancellation()
            }

            state = .installing
            detail = "正在安装模型…"
            let target = Self.installDirectory
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for asset in Self.assets {
                let src = staging.appendingPathComponent(asset.name)
                let dst = target.appendingPathComponent(asset.name)
                if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
                try fm.moveItem(at: src, to: dst)
            }
            try? fm.removeItem(at: staging)
            guard Self.isInstalled else { throw FVError.message("下载完成但模型文件校验失败，请重试") }
            state = .ready
            progress = 1
            detail = "模型已安装，可离线使用"
            FVDebug.log("SenseVoice model downloaded to \(target.path)")
        } catch {
            try? fm.removeItem(at: staging)
            if (error as? CancellationError) != nil || Task.isCancelled {
                state = .missing
                detail = "已取消下载"
                progress = 0
            } else {
                state = .failed(error.localizedDescription)
                detail = "下载失败：\(error.localizedDescription)"
                FVDebug.log("SenseVoice model download failed: \(error.localizedDescription)")
            }
        }
        currentTask = nil
        currentSession = nil
        currentDelegate = nil
    }

    private func download(_ asset: Asset, to destination: URL, fileIndex: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = DownloadDelegate(
                destination: destination,
                onProgress: { [weak self] written, expected in
                    Task { @MainActor in
                        guard let self else { return }
                        let fileFraction = expected > 0 ? min(1, Double(written) / Double(expected)) : 0
                        let overall = (Double(fileIndex) + fileFraction) / Double(Self.assets.count)
                        self.progress = overall
                        if expected > 0 {
                            self.detail = "正在下载 \(asset.name) · \(Int(fileFraction * 100))%"
                        }
                    }
                },
                completion: { result in
                    continuation.resume(with: result)
                }
            )
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 900
            configuration.waitsForConnectivity = true
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: asset.url)
            self.currentDelegate = delegate
            self.currentSession = session
            self.currentTask = task
            task.resume()
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: (Int64, Int64) -> Void
    private let completion: (Result<Void, Error>) -> Void
    private let lock = NSLock()
    private var finished = false

    init(destination: URL,
         onProgress: @escaping (Int64, Int64) -> Void,
         completion: @escaping (Result<Void, Error>) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
        self.completion = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            let fm = FileManager.default
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        completion(result)
    }
}
