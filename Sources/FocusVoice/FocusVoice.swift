import AppKit
import SwiftUI
import AVFoundation
@preconcurrency import AVFAudio
import Speech
import ApplicationServices
import Carbon.HIToolbox
import Security
import Combine
import Darwin
import QuartzCore
import ServiceManagement
import ScreenCaptureKit
import CryptoKit
import CommonCrypto

enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }
}

// MARK: - Local model defaults

func bundledWhisperDirectory() -> URL? {
    guard let resources = Bundle.main.resourceURL else { return nil }
    let dir = resources.appendingPathComponent("whisper", isDirectory: true)
    return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
}

func bundledWhisperBinary() -> String? {
    guard let url = bundledWhisperDirectory()?.appendingPathComponent("whisper-cli") else { return nil }
    return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
}

func defaultWhisperBinaryPath() -> String {
    bundledWhisperBinary() ?? "/opt/homebrew/bin/whisper-cli"
}

func defaultWhisperModelPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
        "\(home)/Library/Application Support/Memo/models/ggml-large-v3.bin",
        "\(home)/Library/Application Support/Memo/models/ggml-tiny.bin"
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? ""
}

func resolvedWhisperBinary(_ stored: String) -> String {
    if !stored.isEmpty, FileManager.default.isExecutableFile(atPath: stored) { return stored }
    return defaultWhisperBinaryPath()
}

private func defaultsString(_ key: String) -> String? {
    guard let value = UserDefaults.standard.string(forKey: key), !value.isEmpty else { return nil }
    return value
}

private func defaultsBool(_ key: String, _ fallback: Bool) -> Bool {
    guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
    return UserDefaults.standard.bool(forKey: key)
}

/// 中英切换：语言在启动时快照，切换后提示重启，避免半中半英。
enum L10n {
    static var isEnglish: Bool {
        (UserDefaults.standard.string(forKey: "uiLanguage") ?? "中文") == "English"
    }

    static var locale: Locale {
        Locale(identifier: isEnglish ? "en" : "zh-Hans")
    }

    /// 直接解析 en.lproj/Localizable.strings，避免自组装 App 里 Bundle(path:) 找不到本地化包。
    static let english: [String: String] = {
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("en.lproj/Localizable.strings"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/en.lproj/Localizable.strings"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("../Resources/en.lproj/Localizable.strings")
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\""), let eq = line.range(of: "\" = \"") else { continue }
            var key = String(line[line.index(after: line.startIndex)..<eq.lowerBound])
            var value = String(line[eq.upperBound...])
            if value.hasSuffix("\";") { value.removeLast(2) }
            key = key.replacingOccurrences(of: "\\\"", with: "\"")
            value = value.replacingOccurrences(of: "\\\"", with: "\"")
            map[key] = value
        }
        FVDebug.log("L10n english entries=\(map.count) path=\(url.path)")
        return map
    }()

    static func t(_ key: String) -> String {
        guard isEnglish else { return key }
        return english[key] ?? key
    }
}


private func defaultsDouble(_ key: String, _ fallback: Double) -> Double {
    guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
    return UserDefaults.standard.double(forKey: key)
}

// MARK: - 诊断日志

/// 轻量诊断日志：只写关键状态迁移，便于用户反馈问题时定位。
enum FVDebug {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FocusVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostic.log")
    }()

    static func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - SenseVoice (DeepSeek Harness 同款本地模型) 资产定位

/// 定位 SenseVoiceSmall + Silero VAD 资源目录。
/// 优先使用 App Bundle 内置（正式安装包），其次回退到 DSH 已下载的缓存，便于 `swift run` / 自测。
enum FVSenseVoiceAssets {
    static func modelDirectory() -> URL? {
        if ProcessInfo.processInfo.environment["FOCUSVOICE_SIMULATE_MISSING_MODEL"] == "1" { return nil }
        let fm = FileManager.default
        let downloaded = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FocusVoice/Models/sensevoice", isDirectory: true)
        if fm.fileExists(atPath: downloaded.appendingPathComponent("model.int8.onnx").path) {
            return downloaded
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("models/sensevoice", isDirectory: true),
           fm.fileExists(atPath: res.appendingPathComponent("sensevoice-onnx/model.int8.onnx").path) {
            return res
        }
        let dsh = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/speech-to-text/sensevoice/models", isDirectory: true)
        if fm.fileExists(atPath: dsh.appendingPathComponent("sensevoice-onnx/model.int8.onnx").path) {
            return dsh
        }
        return nil
    }

    static var isAvailable: Bool { modelDirectory() != nil }

    static var locationDescription: String {
        guard let dir = modelDirectory() else { return "未找到模型" }
        if dir.path.contains("Application Support/FocusVoice/Models") { return "已下载模型" }
        return dir.path.contains(".dsh") ? "DSH 本地模型缓存" : "App 内置模型"
    }
}

// MARK: - Audio Source & Devices

enum AudioSource: String, CaseIterable, Identifiable {
    case mic = "外录 · 麦克风"
    case system = "内录 · 系统声音"
    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .mic: return "外录 · 麦克风"
        case .system: return "内录 · 系统声"
        }
    }

    var icon: String {
        switch self {
        case .mic: return "mic.fill"
        case .system: return "speaker.wave.2.fill"
        }
    }
}

enum AudioDeviceLookup {
    static func findBuiltInMicrophone() -> AVCaptureDevice? {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        for dev in discovery.devices where dev.uniqueID == "BuiltInMicrophoneDevice" {
            return dev
        }
        for dev in discovery.devices {
            let name = dev.localizedName.lowercased()
            if name.contains("macbook") || name.contains("built-in") || name.contains("内置") || name.contains("咪高風") {
                return dev
            }
        }
        // 找不到内置麦时绝不回退到 AirPods/外接设备；宁可报错也不偷偷换设备
        return nil
    }

    static func builtInMicrophoneName() -> String {
        findBuiltInMicrophone()?.localizedName ?? "MacBook Pro 麦克风 (内置阵列)"
    }
}

// MARK: - Settings / Preferences

@MainActor final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published var speechEngine: String = defaultsString("speechEngine") ?? "SenseVoice 本地" {
        didSet { UserDefaults.standard.set(speechEngine, forKey: "speechEngine") }
    }
    @Published var language: String = defaultsString("language") ?? "zh-CN" {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    @Published var whisperBinary: String = resolvedWhisperBinary(defaultsString("whisperBinary") ?? "") {
        didSet { UserDefaults.standard.set(whisperBinary, forKey: "whisperBinary") }
    }
    @Published var whisperModel: String = defaultsString("whisperModel") ?? defaultWhisperModelPath() {
        didSet { UserDefaults.standard.set(whisperModel, forKey: "whisperModel") }
    }
    @Published var useWhisperServer: Bool = defaultsBool("useWhisperServer", true) {
        didSet { UserDefaults.standard.set(useWhisperServer, forKey: "useWhisperServer") }
    }
    @Published var whisperPrompt: String = defaultsString("whisperPrompt") ?? "" {
        didSet { UserDefaults.standard.set(whisperPrompt, forKey: "whisperPrompt") }
    }
    @Published var audioSource: String = defaultsString("audioSource") ?? AudioSource.mic.rawValue {
        didSet { UserDefaults.standard.set(audioSource, forKey: "audioSource") }
    }
    @Published var transcriptionURL: String = defaultsString("transcriptionURL") ?? "https://api.openai.com/v1/audio/transcriptions" {
        didSet { UserDefaults.standard.set(transcriptionURL, forKey: "transcriptionURL") }
    }
    @Published var transcriptionModel: String = defaultsString("transcriptionModel") ?? "gpt-4o-mini-transcribe" {
        didSet { UserDefaults.standard.set(transcriptionModel, forKey: "transcriptionModel") }
    }
    @Published var processingMode: String = defaultsString("processingMode") ?? "原文" {
        didSet { UserDefaults.standard.set(processingMode, forKey: "processingMode") }
    }
    @Published var llmURL: String = defaultsString("llmURL") ?? "https://api.openai.com/v1/chat/completions" {
        didSet { UserDefaults.standard.set(llmURL, forKey: "llmURL") }
    }
    @Published var llmModel: String = defaultsString("llmModel") ?? "gpt-4o-mini" {
        didSet { UserDefaults.standard.set(llmModel, forKey: "llmModel") }
    }
    @Published var keepClipboard: Bool = defaultsBool("keepClipboard", true) {
        didSet { UserDefaults.standard.set(keepClipboard, forKey: "keepClipboard") }
    }
    @Published var previewBeforeInsert: Bool = defaultsBool("previewBeforeInsert", false) {
        didSet { UserDefaults.standard.set(previewBeforeInsert, forKey: "previewBeforeInsert") }
    }
    @Published var playSounds: Bool = defaultsBool("playSounds", true) {
        didSet { UserDefaults.standard.set(playSounds, forKey: "playSounds") }
    }
    @Published var soundVolume: Double = defaultsDouble("soundVolume", 0.3) {
        didSet { UserDefaults.standard.set(soundVolume, forKey: "soundVolume") }
    }
    @Published var startSoundStyle: String = defaultsString("startSoundStyle") ?? "开始录音" {
        didSet { UserDefaults.standard.set(startSoundStyle, forKey: "startSoundStyle") }
    }
    @Published var endSoundStyle: String = defaultsString("endSoundStyle") ?? "结束录音" {
        didSet { UserDefaults.standard.set(endSoundStyle, forKey: "endSoundStyle") }
    }
    @Published var overlayLiquidGlass: Bool = defaultsBool("overlayLiquidGlass", true) {
        didSet { UserDefaults.standard.set(overlayLiquidGlass, forKey: "overlayLiquidGlass") }
    }
    @Published var overlayGlassIntensity: Double = defaultsDouble("overlayGlassIntensity", 0.65) {
        didSet { UserDefaults.standard.set(overlayGlassIntensity, forKey: "overlayGlassIntensity") }
    }
    @Published var overlayShadowStrength: Double = defaultsDouble("overlayShadowStrength", 0.55) {
        didSet { UserDefaults.standard.set(overlayShadowStrength, forKey: "overlayShadowStrength") }
    }
    @Published var uiLanguage: String = defaultsString("uiLanguage") ?? "中文" {
        didSet { UserDefaults.standard.set(uiLanguage, forKey: "uiLanguage") }
    }
    @Published var ringStyle: String = {
        let stored = defaultsString("ringStyle") ?? "声纹"
        return HoldRingHUD.styles.contains(stored) ? stored : "声纹"
    }() {
        didSet { UserDefaults.standard.set(ringStyle, forKey: "ringStyle") }
    }
    @Published var ringCompleteBurst: Bool = defaultsBool("ringCompleteBurst", true) {
        didSet { UserDefaults.standard.set(ringCompleteBurst, forKey: "ringCompleteBurst") }
    }

    // 交互触发（v0.8 新增）
    @Published var holdToTalkEnabled: Bool = defaultsBool("holdToTalkEnabled", true) {
        didSet { UserDefaults.standard.set(holdToTalkEnabled, forKey: "holdToTalkEnabled") }
    }
    @Published var holdToTalkDelay: Double = defaultsDouble("holdToTalkDelay", 0.6) {
        didSet { UserDefaults.standard.set(holdToTalkDelay, forKey: "holdToTalkDelay") }
    }
    @Published var optionClickTrigger: Bool = defaultsBool("optionClickTrigger", false) {
        didSet { UserDefaults.standard.set(optionClickTrigger, forKey: "optionClickTrigger") }
    }
    @Published var requireEditableTarget: Bool = defaultsBool("requireEditableTarget", false) {
        didSet { UserDefaults.standard.set(requireEditableTarget, forKey: "requireEditableTarget") }
    }
    @Published var autoFinishOnSilence: Bool = defaultsBool("autoFinishOnSilence", false) {
        didSet { UserDefaults.standard.set(autoFinishOnSilence, forKey: "autoFinishOnSilence") }
    }
    @Published var hotkeyStyle: String = defaultsString("hotkeyStyle") ?? "⌃⌥Space" {
        didSet { UserDefaults.standard.set(hotkeyStyle, forKey: "hotkeyStyle") }
    }
    @Published var warmUpSenseVoice: Bool = defaultsBool("warmUpSenseVoice", true) {
        didSet { UserDefaults.standard.set(warmUpSenseVoice, forKey: "warmUpSenseVoice") }
    }

    // Tencent Cloud ASR Configuration
    @Published var tencentAppId: String = defaultsString("tencentAppId") ?? "" {
        didSet { UserDefaults.standard.set(tencentAppId, forKey: "tencentAppId") }
    }
    @Published var tencentSecretId: String = defaultsString("tencentSecretId") ?? "" {
        didSet { UserDefaults.standard.set(tencentSecretId, forKey: "tencentSecretId") }
    }
    @Published var tencentRegion: String = defaultsString("tencentRegion") ?? "ap-shanghai" {
        didSet { UserDefaults.standard.set(tencentRegion, forKey: "tencentRegion") }
    }
    @Published var tencentEngineType: String = defaultsString("tencentEngineType") ?? "16k_zh" {
        didSet { UserDefaults.standard.set(tencentEngineType, forKey: "tencentEngineType") }
    }
    @Published var tencentSecretKey: String = KeyStore.load("tencent_sk")

    @Published var transcriptionKey = KeyStore.load("stt")
    @Published var llmKey = KeyStore.load("llm")

    init() {
        // 音色库换成「科技助手提示音」：旧音色一次性迁移到新默认（轻启 / 确认）
        if !SoundPreset.validNames.contains(startSoundStyle) {
            startSoundStyle = "轻启"
            UserDefaults.standard.set(startSoundStyle, forKey: "startSoundStyle")
        }
        if !SoundPreset.validNames.contains(endSoundStyle) {
            endSoundStyle = "确认"
            UserDefaults.standard.set(endSoundStyle, forKey: "endSoundStyle")
        }
        if !UserDefaults.standard.bool(forKey: "didMigrateAssistantSoundsV089") {
            startSoundStyle = "轻启"
            endSoundStyle = "确认"
            UserDefaults.standard.set(startSoundStyle, forKey: "startSoundStyle")
            UserDefaults.standard.set(endSoundStyle, forKey: "endSoundStyle")
            UserDefaults.standard.set(true, forKey: "didMigrateAssistantSoundsV089")
        }
        // v0.9.1：默认改用 Apple 原生的「收到信息 / iMessage 已发送」
        if !UserDefaults.standard.bool(forKey: "didMigrateAppleDefaultsV091") {
            startSoundStyle = "收到信息"
            endSoundStyle = "iMessage 已发送"
            UserDefaults.standard.set(startSoundStyle, forKey: "startSoundStyle")
            UserDefaults.standard.set(endSoundStyle, forKey: "endSoundStyle")
            UserDefaults.standard.set(true, forKey: "didMigrateAppleDefaultsV091")
        }
        // 蓄力环外观：已删除的旧外观（含「锋线」）回退到默认「声纹」
        if !HoldRingHUD.styles.contains(ringStyle) {
            ringStyle = "声纹"
            UserDefaults.standard.set(ringStyle, forKey: "ringStyle")
        }
        // v0.9.1：用户选择声纹方向，一次性切到「声纹」
        if ringStyle == "锋线" {
            ringStyle = "声纹"
            UserDefaults.standard.set(ringStyle, forKey: "ringStyle")
        }
        if !UserDefaults.standard.bool(forKey: "didMigrateVoiceprintRingV091") {
            ringStyle = "声纹"
            UserDefaults.standard.set(ringStyle, forKey: "ringStyle")
            UserDefaults.standard.set(true, forKey: "didMigrateVoiceprintRingV091")
        }
        // 音效库已换成纯低频版本：旧的系统音/高频音色一次性迁移到新的推荐值
        if !SoundPreset.validNames.contains(startSoundStyle) {
            startSoundStyle = "启动"
            UserDefaults.standard.set(startSoundStyle, forKey: "startSoundStyle")
        }
        if !SoundPreset.validNames.contains(endSoundStyle) {
            endSoundStyle = "余韵"
            UserDefaults.standard.set(endSoundStyle, forKey: "endSoundStyle")
        }
        if !UserDefaults.standard.bool(forKey: "didMigrateLowFreqSoundsV086") {
            if ["低鸣", "引擎", "脉冲"].contains(endSoundStyle) {
                endSoundStyle = "余韵"
                UserDefaults.standard.set(endSoundStyle, forKey: "endSoundStyle")
            }
            UserDefaults.standard.set(true, forKey: "didMigrateLowFreqSoundsV086")
        }
        // v0.12.8：默认音效统一为 Apple 原声「开始录音 / 结束录音」
        if !UserDefaults.standard.bool(forKey: "didDefaultAppleRecordSoundsV0128") {
            startSoundStyle = "开始录音"
            endSoundStyle = "结束录音"
            UserDefaults.standard.set(startSoundStyle, forKey: "startSoundStyle")
            UserDefaults.standard.set(endSoundStyle, forKey: "endSoundStyle")
            UserDefaults.standard.set(true, forKey: "didDefaultAppleRecordSoundsV0128")
        }
        if defaultsString("speechEngine") == nil {
            let preferred: String
            if FVSenseVoiceAssets.isAvailable {
                preferred = "SenseVoice 本地"
            } else {
                preferred = "SenseVoice 本地"
            }
            speechEngine = preferred
            UserDefaults.standard.set(preferred, forKey: "speechEngine")
        }
        // v0.8 迁移：老用户之前默认是 whisper.cpp（大模型但慢），升级到与 DSH 同款的 SenseVoice。
        // 只迁移「本地慢引擎」与首次安装；用户明确选择的腾讯云/API 不覆盖。
        if !UserDefaults.standard.bool(forKey: "didMigrateToSenseVoiceV08") {
            if FVSenseVoiceAssets.isAvailable, ["whisper.cpp", "Apple 本地"].contains(speechEngine) {
                speechEngine = "SenseVoice 本地"
                UserDefaults.standard.set("SenseVoice 本地", forKey: "speechEngine")
            }
            UserDefaults.standard.set(true, forKey: "didMigrateToSenseVoiceV08")
        }
        // v0.10.3：Apple 设备端识别在多数机器上不可用，直接移除该引擎
        if speechEngine == "Apple 本地" {
            speechEngine = "SenseVoice 本地"
            UserDefaults.standard.set(speechEngine, forKey: "speechEngine")
        }
        // v0.10.5：彻底移除 whisper 引擎
        if speechEngine == "whisper.cpp" {
            speechEngine = "SenseVoice 本地"
            UserDefaults.standard.set(speechEngine, forKey: "speechEngine")
        }
        // v0.10.3：腾讯云只保留中文通用版（其他版本效果不稳定）
        if !["16k_zh"].contains(tencentEngineType) {
            tencentEngineType = "16k_zh"
            UserDefaults.standard.set(tencentEngineType, forKey: "tencentEngineType")
        }
    }

    func saveKeys() {
        KeyStore.save("stt", transcriptionKey)
        KeyStore.save("llm", llmKey)
        KeyStore.save("tencent_sk", tencentSecretKey)
    }

    func chooseModelFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.title = "选择 whisper.cpp 模型文件 (.bin)"
        panel.prompt = "选择"
        if let memoDir = URL(string: "file://" + (defaultWhisperModelPath() as NSString).deletingLastPathComponent) {
            panel.directoryURL = memoDir
        }
        if panel.runModal() == .OK, let url = panel.url {
            whisperModel = url.path
        }
    }
}

enum KeyStore {
    private static var storageURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FocusVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".keys.json")
    }

    static func load(_ account: String) -> String {
        if let val = UserDefaults.standard.string(forKey: "key_\(account)"), !val.isEmpty {
            return val
        }
        guard let data = try? Data(contentsOf: storageURL),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let val = dict[account] else {
            return ""
        }
        return val
    }

    static func save(_ account: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: "key_\(account)")
        var dict: [String: String] = [:]
        if let data = try? Data(contentsOf: storageURL),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
            dict = existing
        }
        dict[account] = value
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: storageURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        }
    }
}

// MARK: - Accessibility helpers

enum AX {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        value(element, attribute) as? Bool
    }

    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func focusedElement() -> AXUIElement? {
        focusedElement(timeout: 0.25)
    }

    /// 带消息超时的焦点查询：AX IPC 在 Chromium/Electron 上可能卡住数百毫秒甚至数秒，
    /// 旧版把这些同步查询全放在主线程，是「按了没反应」和界面卡顿的第一因。
    static func focusedElement(timeout: Float) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        return element(value(system, kAXFocusedUIElementAttribute))
    }

    /// 为整个进程的 AX 查询设置超时（避免单次查询阻塞主线程）。
    static func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    /// Chromium/Electron 默认只在无障碍客户端真正访问时才构建 AX 树；
    /// 先打开 AXManualAccessibility 再查询，可显著提升微信/Codex/Chrome 的命中率。
    static func enableManualAccessibility(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    /// 判断元素是否为可编辑文本区域。
    /// 顺序：原生角色 → AXEditable 属性 → 「AXSelectedText 可写」强信号（Chromium/Electron contenteditable）。
    static func isEditable(_ element: AXUIElement, depth: Int = 0) -> Bool {
        if let subrole = string(element, kAXSubroleAttribute), subrole == "AXSecureTextField" { return false }
        let role = string(element, kAXRoleAttribute) ?? ""

        if ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role) {
            if let enabled = bool(element, kAXEnabledAttribute), !enabled { return false }
            if bool(element, "AXEditable") == true { return true }
            if acceptsTextInput(element) { return true }
            // 有些 Electron 输入框 AXEditable 缺失；只有 AXValue 确实可写时才放行。
            // 不能仅凭「有选区」判断，否则网页正文/只读文本也会被当成输入框。
            var valueSettable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable) == .success,
               valueSettable.boolValue { return true }
            return false
        }
        // Chromium 把焦点放在 AXWebArea 上：只有它自身确实持有焦点时才算可编辑，
        // 否则“页面里存在选区”会把整页都误判成输入框。
        if role == "AXWebArea" {
            guard isFocused(element) else { return false }
            // 只读网页也可能有 AXSelectedTextRange；必须确认 SelectedText 真的可写
            return acceptsTextInput(element)
        }
        if bool(element, "AXEditable") == true { return true }
        // AXGroup/AXUnknown 的“可写选区”只在它持有焦点时可信
        if acceptsTextInput(element), isFocused(element) { return true }
        if depth < 4, let parent = self.element(value(element, kAXParentAttribute)) {
            return isEditable(parent, depth: depth + 1)
        }
        return false
    }

    /// 能否直接写入选中文本 —— 这是识别网页/Electron contenteditable 最可靠的信号。
    static func acceptsTextInput(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        let role = string(element, kAXRoleAttribute) ?? ""
        return ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox",
                "AXWebArea", "AXGroup", "AXScrollArea", "AXUnknown"].contains(role)
    }

    static func isTextRole(_ element: AXUIElement) -> Bool {
        let role = string(element, kAXRoleAttribute) ?? ""
        return ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role)
    }

    static func isFocused(_ element: AXUIElement) -> Bool {
        bool(element, "AXFocused") == true || bool(element, kAXFocusedAttribute) == true
    }

    static func isFocusedElementEditable() -> Bool {
        guard let focused = focusedElement() else { return false }
        return isEditable(focused)
    }

    /// 焦点文本的光标/选区屏幕矩形（Chromium contenteditable 用来判断点击点是否真的在输入框里）。
    static func selectionBounds(_ element: AXUIElement) -> CGRect? {
        guard let rangeValue = value(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        var boundsValue: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        )
        guard status == .success, let boundsValue,
              CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// 从命中元素向上找可编辑祖先（最多 8 层）。
    static func editableAncestor(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let el = current, depth < 8 {
            let role = string(el, kAXRoleAttribute) ?? ""
            // WebArea/Group 只是容器：页面里任何位置都可能挂在它下面，不能据此把所有落点判成输入框
            if role != "AXWebArea", role != "AXGroup", role != "AXUnknown", isEditable(el) {
                return el
            }
            current = self.element(value(el, kAXParentAttribute))
            depth += 1
        }
        return nil
    }

    /// 按钮/滑块/菜单等「非文本」控件，长按不应触发录音。
    static func isControlElement(_ element: AXUIElement) -> Bool {
        let role = string(element, kAXRoleAttribute) ?? ""
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        if ["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton"].contains(subrole) { return true }
        return ["AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXScrollBar", "AXScrollThumb",
                "AXMenuBar", "AXMenuBarItem", "AXMenuItem", "AXMenu", "AXDock", "AXDockItem",
                "AXPopUpButton", "AXSegmentedControl", "AXTabGroup", "AXToolbar", "AXTitleBar",
                "AXSplitter", "AXDisclosureTriangle", "AXLink"].contains(role)
    }

    /// 元素所在窗口的真实标题栏矩形（用它替代「顶部 42pt 一刀切」）。
    static func titleBarFrame(around element: AXUIElement) -> CGRect? {
        var current: AXUIElement? = element
        var depth = 0
        while let el = current, depth < 30 {
            if string(el, kAXRoleAttribute) == "AXTitleBar" { return frame(of: el) }
            current = self.element(value(el, kAXParentAttribute))
            depth += 1
        }
        return nil
    }

    /// 向上找到元素所属的 AXWindow（穿透网页/Electron 深 DOM）。
    static func window(containing element: AXUIElement) -> AXUIElement? {
        if string(element, kAXRoleAttribute) == "AXWindow" { return element }
        var current: AXUIElement? = element
        var depth = 0
        while let el = current, depth < 30 {
            if string(el, kAXRoleAttribute) == "AXWindow" { return el }
            current = self.element(value(el, kAXParentAttribute))
            depth += 1
        }
        return nil
    }

    static func cgPoint(fromAppKit point: CGPoint) -> CGPoint {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func element(atAppKitPoint point: CGPoint) -> AXUIElement? {
        let cgP = self.cgPoint(fromAppKit: point)
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(cgP.x), Float(cgP.y), &element) == .success else { return nil }
        return element
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = value(element, kAXPositionAttribute),
              let sizeValue = value(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}

// MARK: - Smart Input Area Detection

/// 长按落点判定结果。
enum InputVerdict {
    /// 明确的文本编辑区域（原生输入框 / 网页 contenteditable / 富文本）
    case editable
    /// 窗口内容区但并非文本控件（聊天区、文档区、网页正文…）
    case contentArea
    /// 标题栏拖拽区、窗口按钮、滚动条、菜单栏、桌面等
    case blocked
}

enum InputDetector {
    /// 判定长按落点。`requireText` 为 true 时只接受 .editable。
    static func verdict(atAppKitPoint point: CGPoint, hit: AXUIElement, cursorIsIBeam: Bool = false) -> InputVerdict {
        if AX.isControlElement(hit) { return .blocked }

        let cgPoint = AX.cgPoint(fromAppKit: point)

        // 命中点本身或其祖先在可编辑文本控件里（覆盖原生输入框、Electron 内部静态文本节点）
        if AX.isEditable(hit) || AX.editableAncestor(of: hit) != nil {
            return .editable
        }

        // 当前焦点输入框包含落点。Chromium/Electron 的 AX 命中节点经常是 WebArea/StaticText，
        // 但焦点框的 frame 仍然可靠。
        let focused = AX.focusedElement()
        if let focused, AX.isEditable(focused) {
            if let frame = AX.frame(of: focused), frame.contains(cgPoint) {
                return .editable
            }

        }

        // 先做 App 级兜底：微信/飞书/设计软件的 AX 窗口结构可能根本不完整，
        // 不能因为拿不到 AXWindow 就直接 blocked。
        let hitPid = AX.pid(of: hit)
        let hitApp = NSRunningApplication(processIdentifier: hitPid)
        if isWeChatApp(hitApp) || isFeishuApp(hitApp) {
            if let winInfo = cgWindowAtPoint(cgPoint),
               cgPoint.y > winInfo.frame.maxY - 190 {
                return .editable
            }
        }
        if isDesignApp(hitApp, windowTitle: nil) {
            if isAdobeTypeTool(pid: hitPid) { return .editable }
            if cursorIsIBeam, let winInfo = cgWindowAtPoint(cgPoint),
               winInfo.frame.contains(cgPoint) { return .editable }
        }

        guard let win = AX.window(containing: hit), let winFrame = AX.frame(of: win) else { return .blocked }

        // 真实标题栏区域只对非文本落点生效（地址栏 / 搜索框本身可编辑时已在上方放行）
        if let titleBar = AX.titleBarFrame(around: hit), titleBar.insetBy(dx: 0, dy: -3).contains(cgPoint) {
            return .blocked
        }

        // Finder 桌面
        var pid: pid_t = 0
        AXUIElementGetPid(win, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        if app?.bundleIdentifier == "com.apple.finder",
           (AX.string(win, kAXTitleAttribute) ?? "").isEmpty {
            return .blocked
        }

        guard winFrame.insetBy(dx: -2, dy: -2).contains(cgPoint) else { return .blocked }

        // 设计软件的文字工具（Photoshop/Figma/Sketch/Affinity 等）没有传统 AX 输入框，
        // 但文字工具激活时光标是 I-beam。只对设计类 App 放行，避免网页正文的 I-beam 误触发。
        let designApp = isDesignApp(app, windowTitle: AX.string(win, kAXTitleAttribute))
        if designApp, cursorIsIBeam {
            return .editable
        }
        if designApp, isAdobeTypeTool(pid: pid) {
            return .editable
        }

        // 微信：部分版本对 AX/截屏做保护，输入框只暴露 Group。
        // 输入框固定在窗口底部区域；只在该区域用 I-beam 兜底，避免聊天正文误触发。
        // 微信/飞书的输入框在部分版本里只暴露 AXGroup，且不使用 I-beam 光标；
        // 输入区固定在窗口底部，只对底部区域放行，避免聊天正文误触发。
        if isWeChatApp(app) || isFeishuApp(app) {
            let hitWindow = cgWindowAtPoint(cgPoint)
            let actual = hitWindow?.frame ?? cgWindowFrame(pid: pid) ?? winFrame
            let ownerApp = hitWindow.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
            if (isWeChatApp(ownerApp) || isFeishuApp(ownerApp) || isWeChatApp(app) || isFeishuApp(app)),
               cgPoint.y > actual.maxY - 190, actual.contains(cgPoint) {
                return .editable
            }
        }

        return .contentArea
    }

    private static func isFeishuApp(_ app: NSRunningApplication?) -> Bool {
        let haystack = ((app?.localizedName ?? "") + " " + (app?.bundleIdentifier ?? "")).lowercased()
        return haystack.contains("feishu") || haystack.contains("lark") || haystack.contains("飞书")
    }

    private static func isWeChatApp(_ app: NSRunningApplication?) -> Bool {
        let haystack = ((app?.localizedName ?? "") + " " + (app?.bundleIdentifier ?? "")).lowercased()
        return haystack.contains("wechat") || haystack.contains("weixin") || haystack.contains("微信")
    }

    /// 落点最上层的普通窗口（用于微信/飞书识别真实窗口边界，AX 的窗口 frame 常是整屏）。
    private static func cgWindowAtPoint(_ point: CGPoint) -> (pid: pid_t, frame: CGRect, name: String)? {
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.05,
                  let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? Double, let y = b["Y"] as? Double,
                  let w = b["Width"] as? Double, let h = b["Height"] as? Double else { continue }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            guard rect.contains(point), w > 100, h > 100 else { continue }
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let name = info[kCGWindowOwnerName as String] as? String ?? ""
            return (pid, rect, name)
        }
        return nil
    }

    /// 取 App 当前前台窗口的 CG 边界（AX 对微信/飞书返回的窗口 frame 常常是整个屏幕，不能用于底部判断）。
    static func cgWindowFrame(pid: pid_t) -> CGRect? {
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var best: CGRect?
        for info in infos {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.05,
                  let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? Double, let y = b["Y"] as? Double,
                  let w = b["Width"] as? Double, let h = b["Height"] as? Double,
                  w > 80, h > 80 else { continue }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            if best == nil || rect.width * rect.height > best!.width * best!.height { best = rect }
        }
        return best
    }

    /// Photoshop 通过 AppleScript 暴露 current tool；文字工具名称包含 type。
    private static func isAdobeTypeTool(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundle = app.bundleIdentifier,
              bundle.contains("adobe") else { return false }
        let script = NSAppleScript(source: "tell application id \"\(bundle)\" to get current tool")
        var error: NSDictionary?
        guard let result = script?.executeAndReturnError(&error).stringValue else { return false }
        return result.lowercased().contains("type")
    }

    /// 设计/图形软件的「文字工具」状态：AX 命中通常是画布/Group，没有 AXTextField。
    private static func isDesignApp(_ app: NSRunningApplication?, windowTitle: String?) -> Bool {
        let names = ["photoshop", "illustrator", "indesign", "figma", "sketch", "affinity",
                     "pixelmator", "procreate", "canva", "coreldraw"]
        let haystack = ((app?.localizedName ?? "") + " " + (app?.bundleIdentifier ?? "") + " " + (windowTitle ?? "")).lowercased()
        return names.contains { haystack.contains($0) }
    }

    static func isTextTarget(atAppKitPoint point: CGPoint, hit: AXUIElement) -> Bool {
        verdict(atAppKitPoint: point, hit: hit) == .editable
    }

    /// 后台线程安全探测（带 AX 消息超时）。返回 nil 表示 AX 不可用/超时。
    static func probe(atAppKitPoint point: CGPoint, cursorIsIBeam: Bool = false) -> InputVerdict? {
        AX.setMessagingTimeout(0.25)
        guard let hit = AX.element(atAppKitPoint: point) else { return nil }
        var verdict = self.verdict(atAppKitPoint: point, hit: hit, cursorIsIBeam: cursorIsIBeam)
        if verdict != .editable {
            // 给 Chromium/Electron 一次开启无障碍树的机会后重试
            AX.enableManualAccessibility(pid: AX.pid(of: hit))
            if let hit2 = AX.element(atAppKitPoint: point) {
                verdict = self.verdict(atAppKitPoint: point, hit: hit2, cursorIsIBeam: cursorIsIBeam)
            }
        }
        return verdict
    }
}

// MARK: - Dedicated Built-in Microphone Recorder (AVCaptureSession)

/// Captures audio specifically from the MacBook Pro built-in array microphone.
/// Bypasses connected Bluetooth headsets / external earphones.
final class BuiltInMicRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onPCMChunk: (@Sendable (Data) -> Void)?
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "dev.focusvoice.mic.capture")
    // 只在 queue 上访问，避免 stop() 与音频回调之间的数据竞争（旧版会因此偶发崩溃）
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var fileURL: URL?

    func start(to fileURL: URL) throws {
        self.fileURL = fileURL
        try? FileManager.default.removeItem(at: fileURL)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: fileURL, settings: settings)
        queue.sync {
            self.audioFile = file
            self.converter = nil
        }

        guard let mic = AudioDeviceLookup.findBuiltInMicrophone() else {
            throw FVError.message("未检测到 MacBook Pro 内置麦克风设备")
        }
        FVDebug.log("mic selected=\(mic.localizedName) uid=\(mic.uniqueID)")

        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: mic)
        if session.canAddInput(input) { session.addInput(input) }

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        session.startRunning()
        self.session = session
    }

    func stop() {
        session?.stopRunning()
        session = nil
        queue.sync {
            self.audioFile = nil
            self.converter = nil
        }
    }

    func cancel() {
        stop()
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else { return }

        let interleaved = asbd.mFormatFlags & (1 << 3) != 0
        guard let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame, interleaved: interleaved) else { return }

        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: (AudioBuffer(),))
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let buf = AVAudioPCMBuffer(pcmFormat: srcFormat, bufferListNoCopy: &list) else { return }

        guard let file = self.audioFile else { return }
        if converter == nil || converter?.inputFormat != srcFormat {
            converter = AVAudioConverter(from: srcFormat, to: file.processingFormat)
        }
        guard let conv = converter else { return }
        let ratio = file.processingFormat.sampleRate / srcFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return }

        var hasFed = false
        var convError: NSError?
        conv.convert(to: out, error: &convError) { _, outStatus in
            if hasFed {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasFed = true
            outStatus.pointee = .haveData
            return buf
        }
        if convError == nil, out.frameLength > 0 {
            try? file.write(from: out)
            // 关键修复：AVAudioFile 的 processingFormat 是 Float32，旧版取 int16ChannelData 恒为 nil，
            // 导致 onPCMChunk 从不回调（腾讯云实时字幕永远空白、流式引擎拿不到音频）。
            if let onChunk = self.onPCMChunk, let floats = out.floatChannelData {
                onChunk(Self.pcm16Data(from: floats[0], count: Int(out.frameLength)))
            }
        }
    }

    static func pcm16Data(from samples: UnsafePointer<Float>, count: Int) -> Data {
        var pcm = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let value = max(-1.0, min(1.0, samples[i]))
            pcm[i] = Int16(value * 32767.0)
        }
        return pcm.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

// MARK: - System Audio Recorder (ScreenCaptureKit)

final class SystemAudioRecorder: NSObject, SCStreamOutput {
    var onPCMChunk: (@Sendable (Data) -> Void)?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "dev.focusvoice.system.capture")
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var fileURL: URL?

    func start(to fileURL: URL) async throws {
        self.fileURL = fileURL
        try? FileManager.default.removeItem(at: fileURL)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: fileURL, settings: settings)
        queue.sync {
            self.audioFile = file
            self.converter = nil
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw FVError.message("未找到显示器，无法采集系统声音")
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.queueDepth = 12
        config.width = 2
        config.height = 2

        let s = SCStream(filter: filter, configuration: config, delegate: nil)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        self.stream = s
    }

    func stop() {
        // 不阻塞主线程等待 stopCapture（旧版最多卡 2 秒）
        if let s = stream {
            stream = nil
            Task.detached { try? await s.stopCapture() }
        }
        queue.sync {
            self.audioFile = nil
            self.converter = nil
        }
    }

    func cancel() {
        stop()
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else { return }
        guard let file = self.audioFile else { return }

        let interleaved = asbd.mFormatFlags & (1 << 3) != 0
        guard let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame, interleaved: interleaved) else { return }

        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: (AudioBuffer(),))
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let buf = AVAudioPCMBuffer(pcmFormat: srcFormat, bufferListNoCopy: &list) else { return }

        if converter == nil || converter?.inputFormat != srcFormat {
            converter = AVAudioConverter(from: srcFormat, to: file.processingFormat)
        }
        guard let conv = converter else { return }
        let ratio = file.processingFormat.sampleRate / srcFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return }

        var hasFed = false
        var convError: NSError?
        conv.convert(to: out, error: &convError) { _, outStatus in
            if hasFed {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasFed = true
            outStatus.pointee = .haveData
            return buf
        }
        if convError == nil, out.frameLength > 0 {
            try? file.write(from: out)
            if let onChunk = self.onPCMChunk, let floats = out.floatChannelData {
                onChunk(BuiltInMicRecorder.pcm16Data(from: floats[0], count: Int(out.frameLength)))
            }
        }
    }
}

// MARK: - Unified Recorder (Source switching & Audio merging)

@MainActor final class UnifiedRecorder {
    var onPCMData: ((Data) -> Void)?
    private var micRecorder: BuiltInMicRecorder?
    private var sysRecorder: SystemAudioRecorder?
    private var segments: [URL] = []
    private var generation = 0
    private(set) var currentSource: AudioSource = .mic
    private(set) var isRecording = false

    func start(source: AudioSource) async throws {
        cleanSegments()
        currentSource = source
        isRecording = true
        try await beginSegment(source: source)
    }

    func switchSource() async throws -> AudioSource {
        guard isRecording else { throw FVError.message("当前没有录音") }
        let next: AudioSource = currentSource == .mic ? .system : .mic
        try await beginSegment(source: next)
        currentSource = next
        return next
    }

    func stop() -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        finishActiveRecorder()
        guard !segments.isEmpty else { return nil }
        if segments.count == 1 {
            return segments[0]
        }
        let merged = FileManager.default.temporaryDirectory.appendingPathComponent("focusvoice-merged-\(UUID().uuidString).wav")
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let outFile = try AVAudioFile(forWriting: merged, settings: settings)
            for seg in segments {
                guard let src = try? AVAudioFile(forReading: seg) else { continue }
                guard let buf = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: 4096) else { continue }
                while src.framePosition < src.length {
                    buf.frameLength = 0
                    try? src.read(into: buf)
                    if buf.frameLength == 0 { break }
                    try? outFile.write(from: buf)
                }
            }
            return merged
        } catch {
            return segments.first
        }
    }

    func cancel() {
        isRecording = false
        finishActiveRecorder()
        cleanSegments()
    }

    private func beginSegment(source: AudioSource) async throws {
        // 先停旧设备并切断旧回调，再启动新设备；generation 防止 stop 延迟时旧流继续送入识别
        finishActiveRecorder()
        generation += 1
        let activeGeneration = generation
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("focusvoice-\(UUID().uuidString).wav")
        switch source {
        case .mic:
            let mic = BuiltInMicRecorder()
            mic.onPCMChunk = { [weak self] chunk in
                Task { @MainActor in
                    guard let self, self.generation == activeGeneration else { return }
                    self.onPCMData?(chunk)
                }
            }
            try mic.start(to: file)
            micRecorder = mic
        case .system:
            guard CGPreflightScreenCaptureAccess() else {
                CGRequestScreenCaptureAccess()
                throw FVError.message("内录需要“屏幕录制”权限，请在系统设置中允许后重试")
            }
            let sys = SystemAudioRecorder()
            sys.onPCMChunk = { [weak self] chunk in
                Task { @MainActor in
                    guard let self, self.generation == activeGeneration else { return }
                    self.onPCMData?(chunk)
                }
            }
            try await sys.start(to: file)
            sysRecorder = sys
        }
        segments.append(file)
    }

    private func finishActiveRecorder() {
        // 立即断回调，避免旧设备 stop 异步完成期间仍有音频进入识别/被写进同一轮转写
        micRecorder?.onPCMChunk = nil
        sysRecorder?.onPCMChunk = nil
        micRecorder?.stop()
        micRecorder = nil
        sysRecorder?.stop()
        sysRecorder = nil
    }

    private func cleanSegments() {
        for f in segments { try? FileManager.default.removeItem(at: f) }
        segments = []
    }
}

enum FVError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// MARK: - Tencent Cloud Real-time Streaming WebSocket ASR

@MainActor final class TencentStreamRecognizer: NSObject, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isConnected = false
    private var accumulatedText = ""
    private var finalCompletion: ((String) -> Void)?
    var onLiveText: ((String) -> Void)?
    var onError: ((String) -> Void)?

    func start(
        appId: String,
        secretId: String,
        secretKey: String,
        engine: String
    ) throws {
        stop()
        accumulatedText = ""

        guard let url = buildTencentWSURL(
            appId: appId.trimmingCharacters(in: .whitespacesAndNewlines),
            secretId: secretId.trimmingCharacters(in: .whitespacesAndNewlines),
            secretKey: secretKey.trimmingCharacters(in: .whitespacesAndNewlines),
            engine: engine.isEmpty ? "16k_zh_large" : engine
        ) else {
            throw FVError.message("腾讯云 WebSocket 实时流式 URL 生成失败")
        }

        let config = URLSessionConfiguration.default
        let sess = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = sess
        let ws = sess.webSocketTask(with: url)
        self.webSocketTask = ws
        ws.resume()
        self.isConnected = true
        receiveNext()
    }

    func sendPCMChunk(_ data: Data) {
        guard isConnected, let ws = webSocketTask else { return }
        ws.send(.data(data)) { [weak self] error in
            if let error {
                Task { @MainActor in self?.onError?(error.localizedDescription) }
            }
        }
    }

    func finish() async -> String {
        guard isConnected, let ws = webSocketTask else {
            return accumulatedText
        }
        ws.send(.string("{\"type\": \"end\"}")) { _ in }

        let result: String = await withCheckedContinuation { continuation in
            var resumed = false
            self.finalCompletion = { text in
                if !resumed {
                    resumed = true
                    continuation.resume(returning: text)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if !resumed {
                    resumed = true
                    continuation.resume(returning: self?.accumulatedText ?? "")
                }
            }
        }
        stop()
        return result
    }

    func stop() {
        isConnected = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func receiveNext() {
        guard isConnected, let ws = webSocketTask else { return }
        ws.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.isConnected else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleIncomingJSON(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleIncomingJSON(text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveNext()
                case .failure(let error):
                    self.onError?(error.localizedDescription)
                }
            }
        }
    }

    private func handleIncomingJSON(_ text: String) {
        struct WSResp: Decodable {
            let code: Int?
            let message: String?
            let final: Int?
            struct Res: Decodable {
                let slice_type: Int?
                let voice_text_str: String?
            }
            let result: Res?
        }
        guard let data = text.data(using: .utf8),
              let resp = try? JSONDecoder().decode(WSResp.self, from: data) else { return }

        if let code = resp.code, code != 0 {
            onError?("腾讯云实时 ASR [\(code)]: \(resp.message ?? "")")
            return
        }

        if let piece = resp.result?.voice_text_str, !piece.isEmpty {
            self.accumulatedText = piece
            self.onLiveText?(piece)
        }

        if resp.final == 1 || resp.result?.slice_type == 2 {
            finalCompletion?(accumulatedText)
        }
    }

    private func buildTencentWSURL(
        appId: String,
        secretId: String,
        secretKey: String,
        engine: String
    ) -> URL? {
        let host = "asr.cloud.tencent.com"
        let path = "/asr/v2/\(appId)"
        let timestamp = Int64(Date().timeIntervalSince1970)
        let expired = timestamp + 86400
        let nonce = Int.random(in: 100000...999999)
        let voiceId = "fv_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")

        let params: [String: String] = [
            "secretid": secretId,
            "timestamp": String(timestamp),
            "expired": String(expired),
            "nonce": String(nonce),
            "engine_model_type": engine,
            "voice_id": voiceId,
            "voice_format": "1",
            "needvad": "1",
            "filter_dirty": "0",
            "filter_modal": "0",
            "filter_punc": "0",
            "convert_num_mode": "1",
            "word_info": "0"
        ]

        let sortedKeys = params.keys.sorted()
        let queryString = sortedKeys.map { "\($0)=\(params[$0]!)" }.joined(separator: "&")
        let signSource = "GET\(host)\(path)?\(queryString)"

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), secretKey, secretKey.count, signSource, signSource.count, &digest)
        let signature = Data(digest).base64EncodedString()

        guard let encodedSig = signature.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        let fullURLString = "wss://\(host)\(path)?\(queryString)&signature=\(encodedSig)"
        return URL(string: fullURLString)
    }
}

// MARK: - Persistent whisper.cpp server

@MainActor final class WhisperServer {
    static let shared = WhisperServer()
    private var process: Process?
    private var port = 0
    private var serverPath = ""
    private var modelPath = ""
    private var language = ""
    private var prompt = ""
    private var logURL: URL?
    private var idleTimer: Timer?

    static func locateServer(for cliPath: String) -> String? {
        let dir = URL(fileURLWithPath: cliPath).deletingLastPathComponent()
        let candidate = dir.appendingPathComponent("whisper-server").path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    private func promptArgument(_ value: String) -> String {
        value.isEmpty ? "" : " --prompt \(shellDoubleQuoted(value))"
    }

    func transcribe(file: URL, server: String, model: String, language: String, prompt: String) async throws -> String {
        try await ensureRunning(server: server, model: model, language: language, prompt: prompt)
        idleTimer?.invalidate()
        idleTimer = nil
        defer { scheduleIdleStop() }
        do {
            return try await request(file: file)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        process?.terminate()
        process = nil
        serverPath = ""
        modelPath = ""
        language = ""
        prompt = ""
        port = 0
    }

    private func ensureRunning(server: String, model: String, language: String, prompt: String) async throws {
        if process?.isRunning == true, serverPath == server, modelPath == model, self.language == language, self.prompt == prompt {
            if await isReachable() { return }
        }
        stop()
        guard FileManager.default.isExecutableFile(atPath: server) else { throw FVError.message("找不到 whisper-server") }
        guard FileManager.default.fileExists(atPath: model) else { throw FVError.message("模型文件不存在：\(model)") }

        let chosenPort = Int.random(in: 20000...39999)
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("FocusVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let log = workDir.appendingPathComponent("whisper-server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let script = workDir.appendingPathComponent("start-whisper-server.zsh")
        let parentPID = ProcessInfo.processInfo.processIdentifier
        let scriptText = """
        #!/bin/zsh
        trap 'kill $child 2>/dev/null; exit 0' TERM INT
        "\(shellDoubleQuoted(server))" -m "\(shellDoubleQuoted(model))" -l \(language)\(promptArgument(prompt)) --host 127.0.0.1 --port \(chosenPort) >> "\(shellDoubleQuoted(log.path))" 2>&1 &
        child=$!
        while kill -0 \(parentPID) 2>/dev/null; do sleep 2; done
        kill $child 2>/dev/null
        """
        try scriptText.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()

        process = p
        port = chosenPort
        serverPath = server
        modelPath = model
        self.language = language
        self.prompt = prompt
        logURL = log
        do {
            try await waitUntilReady(process: p, log: log)
        } catch {
            stop()
            throw error
        }
    }

    private func waitUntilReady(process: Process, log: URL) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !process.isRunning {
                throw FVError.message("whisper-server 启动失败：\(tail(log))")
            }
            if await isReachable() { return }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw FVError.message("whisper-server 启动超时：\(tail(log))")
    }

    private func isReachable() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5
        request.httpMethod = "GET"
        do {
            _ = try await URLSession.shared.data(for: request)
            return true
        } catch {
            return false
        }
    }

    private func request(file: URL) async throws -> String {
        let boundary = "FV-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        guard let url = URL(string: "http://127.0.0.1:\(port)/inference") else { throw FVError.message("whisper-server 地址无效") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        try Recognizer.validate(response, data)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty, !text.hasPrefix("{") {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw FVError.message("whisper-server 返回内容不包含 text")
    }

    private func scheduleIdleStop() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    private func tail(_ url: URL, limit: Int = 400) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "无日志" }
        let text = String(decoding: data.suffix(limit), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shellDoubleQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }
}

// MARK: - Speech engines

struct Recognizer {
    @MainActor static func recognize(_ file: URL, preferences p: Preferences, engineOverride: String? = nil, forceNoServer: Bool = false) async throws -> String {
        switch engineOverride ?? p.speechEngine {
        case "SenseVoice 本地":
            return try await SenseVoiceEngine.transcribeFile(file)
        case "腾讯云 ASR", "腾讯云":
            return try await tencentCloud(file, secretId: p.tencentSecretId, secretKey: p.tencentSecretKey, region: p.tencentRegion, engineType: p.tencentEngineType)
        default:
            return try await api(file, endpoint: p.transcriptionURL, model: p.transcriptionModel, key: p.transcriptionKey, language: p.language)
        }
    }

    static func apple(_ file: URL, language: String) async throws -> String {
        let lang = (language.isEmpty || language == "auto") ? "zh-CN" : language
        let auth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard auth == .authorized else { throw FVError.message("请允许 FocusVoice 使用语音识别") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: lang)), recognizer.isAvailable else { throw FVError.message("当前系统不支持该语言的语音识别") }
        guard recognizer.supportsOnDeviceRecognition else { throw FVError.message("该语言未提供 Apple 设备端识别。请选择 whisper.cpp 或 API") }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            var finished = false
            let lock = NSLock()
            _ = recognizer.recognitionTask(with: request) { result, error in
                lock.lock(); defer { lock.unlock() }
                if finished { return }
                if let error = error { finished = true; c.resume(throwing: error) }
                else if let result = result, result.isFinal { finished = true; c.resume(returning: result.bestTranscription.formattedString) }
            }
        }
    }

    @MainActor static func whisper(_ file: URL, binary: String, model: String, language: String, useServer: Bool, prompt: String) async throws -> String {
        guard !model.isEmpty else { throw FVError.message("请在设置中配置 whisper.cpp 模型文件路径") }
        guard FileManager.default.fileExists(atPath: model) else { throw FVError.message("模型文件不存在：\(model)") }
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw FVError.message("找不到 whisper-cli：\(binary)") }
        let lang = language.hasPrefix("zh") ? "zh" : (language.hasPrefix("en") ? "en" : "auto")
        if useServer, let server = WhisperServer.locateServer(for: binary) {
            do {
                return try await WhisperServer.shared.transcribe(file: file, server: server, model: model, language: lang, prompt: prompt)
            } catch {
                NSLog("FocusVoice: whisper-server failed, falling back to CLI: %@", error.localizedDescription)
            }
        }
        return try await whisperViaCLI(file, binary: binary, model: model, language: lang, prompt: prompt)
    }

    @MainActor static func whisperViaCLI(_ file: URL, binary: String, model: String, language: String, prompt: String) async throws -> String {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("focusvoice-whisper-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: log) else { throw FVError.message("无法创建 whisper.cpp 日志文件") }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        var args = ["-m", model, "-f", file.path, "-l", language, "-otxt", "-of", output.path, "-np"]
        if !prompt.isEmpty { args += ["--prompt", prompt] }
        task.arguments = args
        task.standardError = handle
        task.standardOutput = handle
        do {
            try task.run()
        } catch {
            try? handle.close()
            throw FVError.message("无法启动 whisper-cli：\(error.localizedDescription)")
        }

        let status: Int32 = await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                task.waitUntilExit()
                c.resume(returning: task.terminationStatus)
            }
        }
        try? handle.close()
        let textFile = output.appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: textFile)
            try? FileManager.default.removeItem(at: log)
        }
        if status == 0, let text = try? String(contentsOf: textFile, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            throw FVError.message("whisper.cpp 没有识别到语音")
        }
        let detail = (try? String(contentsOf: log, encoding: .utf8))?.suffix(400) ?? ""
        throw FVError.message("whisper.cpp 执行失败（\(status)）：\(String(detail).trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    static func api(_ file: URL, endpoint: String, model: String, key: String, language: String) async throws -> String {
        guard let url = URL(string: endpoint), url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1" else { throw FVError.message("转写 API 地址无效，远程地址必须使用 HTTPS") }
        let boundary = "FV-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) { body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)) }
        field("model", model)
        if !language.isEmpty, language != "auto" { field("language", String(language.prefix(2))) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: file)); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data)
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = obj["text"] as? String { return text }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty, !text.hasPrefix("{") { return text }
        throw FVError.message("转写 API 返回内容不包含 text")
    }

    // MARK: - Tencent Cloud ASR (SentenceRecognition)

    static func tencentCloud(
        _ file: URL,
        secretId: String,
        secretKey: String,
        region: String,
        engineType: String
    ) async throws -> String {
        let sId = secretId.trimmingCharacters(in: .whitespacesAndNewlines)
        let sKey = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sId.isEmpty, !sKey.isEmpty else {
            throw FVError.message("请在设置「语音模型」中配置腾讯云 SecretId 与 SecretKey")
        }

        let audioData = try Data(contentsOf: file)
        guard !audioData.isEmpty else {
            throw FVError.message("录音音频数据为空")
        }
        let base64Audio = audioData.base64EncodedString()

        let payloadObj: [String: Any] = [
            "ProjectId": 0,
            "SubServiceType": 2,
            "EngSerViceType": engineType.isEmpty ? "16k_zh_large" : engineType,
            "SourceType": 1,
            "VoiceFormat": "wav",
            "Data": base64Audio,
            "DataLen": audioData.count,
            "ConvertNumMode": 1
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payloadObj)

        let host = "asr.tencentcloudapi.com"
        let action = "SentenceRecognition"
        let version = "2019-06-14"
        let service = "asr"

        let now = Date()
        let timestamp = Int64(now.timeIntervalSince1970)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let dateString = dateFormatter.string(from: now)

        let authHeader = tc3Authorization(
            secretId: sId,
            secretKey: sKey,
            service: service,
            host: host,
            timestamp: timestamp,
            dateString: dateString,
            payloadData: payloadData
        )

        guard let url = URL(string: "https://\(host)") else {
            throw FVError.message("腾讯云 ASR 请求地址无效")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(action, forHTTPHeaderField: "X-TC-Action")
        request.setValue(version, forHTTPHeaderField: "X-TC-Version")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(region.isEmpty ? "ap-shanghai" : region, forHTTPHeaderField: "X-TC-Region")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = payloadData

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data)

        struct TCResponse: Decodable {
            struct Body: Decodable {
                let Result: String?
                let AudioDuration: Int?
                let RequestId: String?
                struct Err: Decodable {
                    let Code: String
                    let Message: String
                }
                let Error: Err?
            }
            let Response: Body
        }

        let decoded = try JSONDecoder().decode(TCResponse.self, from: data)
        if let err = decoded.Response.Error {
            throw FVError.message("腾讯云 ASR [\(err.Code)]: \(err.Message)")
        }
        guard let result = decoded.Response.Result, !result.isEmpty else {
            throw FVError.message("腾讯云 ASR 未识别到有效内容")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tc3Authorization(
        secretId: String,
        secretKey: String,
        service: String,
        host: String,
        timestamp: Int64,
        dateString: String,
        payloadData: Data
    ) -> String {
        func sha256Hex(_ data: Data) -> String {
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        func hmacSha256(key: Data, data: String) -> Data {
            let symmetricKey = SymmetricKey(data: key)
            let mac = HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: symmetricKey)
            return Data(mac)
        }

        let httpRequestMethod = "POST"
        let canonicalURI = "/"
        let canonicalQueryString = ""
        let canonicalHeaders = "content-type:application/json; charset=utf-8\nhost:\(host)\n"
        let signedHeaders = "content-type;host"
        let hashedRequestPayload = sha256Hex(payloadData)

        let canonicalRequest = "\(httpRequestMethod)\n\(canonicalURI)\n\(canonicalQueryString)\n\(canonicalHeaders)\n\(signedHeaders)\n\(hashedRequestPayload)"

        let algorithm = "TC3-HMAC-SHA256"
        let credentialScope = "\(dateString)/\(service)/tc3_request"
        let hashedCanonicalRequest = sha256Hex(Data(canonicalRequest.utf8))
        let stringToSign = "\(algorithm)\n\(timestamp)\n\(credentialScope)\n\(hashedCanonicalRequest)"

        let kDate = hmacSha256(key: Data(("TC3" + secretKey).utf8), data: dateString)
        let kService = hmacSha256(key: kDate, data: service)
        let kSigning = hmacSha256(key: kService, data: "tc3_request")
        let signatureData = hmacSha256(key: kSigning, data: stringToSign)
        let signature = signatureData.map { String(format: "%02x", $0) }.joined()

        return "\(algorithm) Credential=\(secretId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    static func validate(_ response: URLResponse, _ data: Data) throws {
        guard let r = response as? HTTPURLResponse, (200...299).contains(r.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let message = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw FVError.message("API HTTP \(code): \(message)")
        }
    }
}

// MARK: - Language reasoning

struct Rewriter {
    @MainActor static func process(_ input: String, preferences p: Preferences) async throws -> String {
        if p.processingMode == "原文" { return input }

        let hasRemoteModel = !p.llmKey.isEmpty
            || URL(string: p.llmURL)?.host == "localhost"
            || URL(string: p.llmURL)?.host == "127.0.0.1"

        if p.processingMode == "结构化" {
            // 未配置语言模型时，用本地规则做换行 / 分段 / 要点整理，保证这个选项永远可用
            guard hasRemoteModel else { return StructuredTextFormatter.format(input) }
            do {
                return try await request(input, preferences: p, structured: true)
            } catch {
                FVDebug.log("structured LLM failed, fallback to local: \(error.localizedDescription)")
                return StructuredTextFormatter.format(input)
            }
        }

        guard hasRemoteModel else { return input }
        return try await request(input, preferences: p, structured: false)
    }

    @MainActor private static func request(_ input: String, preferences p: Preferences, structured: Bool) async throws -> String {
        guard let url = URL(string: p.llmURL), url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1" else {
            throw FVError.message("语义 API 地址无效")
        }
        let direction = structured
            ? "你是语音思考整理器。将口语整理为清晰的要点：该换行的地方换行，该分段的地方分段，列举项逐条成行。保留原意和不确定性，不编造、不总结掉信息、不强行加标题。仅输出整理后的文本。"
            : "你是精准的中文语音转写编辑器。只纠正明显同音识别错误、重复口头禅和标点，不总结、不改写事实，不增补内容，不删除有效信息。仅输出修改后的文本。对不确定的专名保留原样。"
        let payload: [String: Any] = ["model": p.llmModel, "temperature": 0.1, "messages": [["role": "system", "content": direction], ["role": "user", "content": input]]]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !p.llmKey.isEmpty { request.setValue("Bearer \(p.llmKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Recognizer.validate(response, data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String,
              !text.isEmpty else {
            throw FVError.message("语义 API 返回格式不兼容 Chat Completions")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 本地结构化整理（无需任何模型）

/// 只做「排版」不做「改写」：按句子与话语标记分组，列举项逐行，段落之间空行。
enum StructuredTextFormatter {
    private static let markers = [
        "首先", "其次", "再次", "然后", "接下来", "另外", "此外", "还有",
        "最后", "总之", "总结", "所以", "因此", "不过", "但是", "另一方面",
        "第一", "第二", "第三", "第四", "第五", "其一", "其二"
    ]

    static func format(_ input: String) -> String {
        var text = input
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        guard !text.isEmpty else { return "" }

        var sentences = splitSentences(text)
        // 没有句末标点时，按逗号切成短句，避免整段挤在一起
        if sentences.count == 1 {
            sentences = text.split(separator: "，").map { String($0) + "，" }
            if let last = sentences.popLast() {
                sentences.append(String(last.dropLast()))
            }
        }

        var blocks: [String] = []
        var paragraph = ""
        var paragraphSentenceCount = 0

        func flushParagraph() {
            var trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            // 段落结尾如果是逗号/顿号，收成句号，读起来更像整理后的笔记
            if let last = trimmed.last, "，,、；;".contains(last) {
                trimmed.removeLast()
                trimmed += "。"
            }
            if !trimmed.isEmpty { blocks.append(trimmed) }
            paragraph = ""
            paragraphSentenceCount = 0
        }

        for raw in sentences {
            let sentence = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { continue }

            if startsWithMarker(sentence) {
                flushParagraph()
                blocks.append(sentence)
            } else {
                paragraph += sentence
                paragraphSentenceCount += 1
                if paragraphSentenceCount >= 3 || paragraph.count >= 90 {
                    flushParagraph()
                }
            }
        }
        flushParagraph()

        // 段落之间空行；连续列举项之间单换行
        var output = ""
        var previousWasItem = false
        for block in blocks {
            let isItem = startsWithMarker(block)
            if output.isEmpty {
                output = block
            } else if isItem && previousWasItem {
                output += "\n" + block
            } else {
                output += "\n\n" + block
            }
            previousWasItem = isItem
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func startsWithMarker(_ sentence: String) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: CharacterSet(charactersIn: "，,。！？!?；;：:、 "))
        if markers.contains(where: { trimmed.hasPrefix($0) }) { return true }
        // 1. / 2、 / ① 这类列举
        if let first = trimmed.first, "①②③④⑤⑥⑦⑧⑨".contains(first) { return true }
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty, trimmed.dropFirst(digits.count).first.map({ "。.、)".contains($0) }) == true { return true }
        return false
    }

    private static func splitSentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if "。！？!?；;".contains(ch) {
                result.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(current)
        }
        return result
    }
}

// MARK: - Focus-preserving text insertion

struct FVHistory {
    let text: String
    let date: Date
    let app: String?
}

final class TextInsertion: @unchecked Sendable {
    let app: NSRunningApplication?
    let element: AXUIElement?
    let isEditableTarget: Bool
    var appName: String? { app?.localizedName }

    init(app: NSRunningApplication?, element: AXUIElement?, editable: Bool) {
        self.app = app
        self.element = element
        self.isEditableTarget = editable
    }

    /// 在后台解析当前焦点输入框。所有 AX 调用都带消息超时，绝不阻塞主线程。
    static func capture(at point: CGPoint) async -> TextInsertion {
        let app = NSWorkspace.shared.frontmostApplication
        return await withCheckedContinuation { (continuation: CheckedContinuation<TextInsertion, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                AX.setMessagingTimeout(0.25)
                if let pid = app?.processIdentifier { AX.enableManualAccessibility(pid: pid) }

                var focused = AX.focusedElement(timeout: 0.25)
                var editable = focused.map { AX.isEditable($0) } ?? false
                if let focused {
                    FVDebug.log("capture focused role=\(AX.string(focused, kAXRoleAttribute) ?? "nil") subrole=\(AX.string(focused, kAXSubroleAttribute) ?? "nil") editable=\(editable) app=\(app?.localizedName ?? "nil")")
                } else {
                    FVDebug.log("capture focused=nil app=\(app?.localizedName ?? "nil")")
                }
                var targetElement = focused

                // 焦点元素不是输入框时，再看鼠标落点（很多聊天窗口点击后焦点在消息列表）
                if !editable {
                    if let hit = AX.element(atAppKitPoint: point), AX.isEditable(hit) {
                        targetElement = hit
                        editable = true
                    }
                }
                if focused == nil { focused = targetElement }
                continuation.resume(returning: TextInsertion(app: app, element: targetElement ?? focused, editable: editable))
            }
        }
    }

    /// 把文字写入目标输入框。
    /// 只使用「一条」粘贴通道并做结果校验；旧版 postToPid + session tap + AppleScript 三重粘贴会重复插入。
    @MainActor func insert(_ text: String) async throws {
        guard let app else { throw FVError.message("未找到原始输入应用") }
        guard AXIsProcessTrusted() else { throw FVError.message("需要辅助功能权限才能粘贴") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let keep = Preferences.shared.keepClipboard
        let previousItems: [NSPasteboardItem]? = keep ? nil : NSPasteboard.general.pasteboardItems?.compactMap { $0.copy() as? NSPasteboardItem }
        writeClipboard(trimmed)

        if !app.isActive {
            app.activate(options: [.activateIgnoringOtherApps])
            try? await Task.sleep(nanoseconds: 90_000_000)
        }

        let probe = String(trimmed.suffix(8))
        FVDebug.log("insert begin app=\(app.localizedName ?? "nil") editable=\(isEditableTarget) len=\(trimmed.count)")

        // 1) 先走「剪贴板 + ⌘V」：Electron/网页聊天框对 AX 写入经常返回 success 但并不落地。
        postCommandV(to: app.processIdentifier)
        FVDebug.log("insert paste posted to pid \(app.processIdentifier) app=\(app.localizedName ?? "nil")")
        // Electron / 远程桌面 / 重负载 App 处理 ⌘V 可能超过 300ms；等久一点再读回/恢复剪贴板
        try? await Task.sleep(nanoseconds: 550_000_000)

        let pastedValue = readableValue()
        if let value = pastedValue, !value.isEmpty {
            if value.contains(probe) {
                FVDebug.log("insert verified via paste")
                restoreClipboardIfNeeded(previousItems)
                return
            }
            FVDebug.log("insert paste not reflected readLen=\(value.count) -> AX fallback")
        } else {
            // 读不到 AXValue（很多 Electron contenteditable）→ 信任 ⌘V 已粘贴；
            // 再等一段时间，避免目标 App 还没消费剪贴板就恢复旧内容。
            FVDebug.log("insert AX value unreadable -> trust paste")
            try? await Task.sleep(nanoseconds: 900_000_000)
            restoreClipboardIfNeeded(previousItems)
            return
        }

        // 2) 粘贴没生效时才尝试 AX 直接写入
        if let el = currentElement(), AX.isEditable(el) || AX.acceptsTextInput(el) {
            _ = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            collapseSelectionIfNeeded(el)
            let setError = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, trimmed as CFTypeRef)
            FVDebug.log("insert AX set err=\(setError.rawValue)")
            if setError == .success {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let value = readableValue(), value.contains(probe) {
                    FVDebug.log("insert verified via AX")
                    restoreClipboardIfNeeded(previousItems)
                    return
                }
            }
        }

        // 3) 最后兜底一次系统粘贴
        let script = "tell application \"System Events\" to keystroke \"v\" using command down"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
        FVDebug.log("insert fallback AppleScript paste sent")
        try? await Task.sleep(nanoseconds: 600_000_000)
        restoreClipboardIfNeeded(previousItems)
    }

    private func restoreClipboardIfNeeded(_ items: [NSPasteboardItem]?) {
        guard let items else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }

    private func writeClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func currentElement() -> AXUIElement? {
        AX.setMessagingTimeout(0.25)
        if let focused = AX.focusedElement(timeout: 0.25) {
            if AX.isEditable(focused) || AX.acceptsTextInput(focused) { return focused }
            FVDebug.log("insert focused not editable role=\(AX.string(focused, kAXRoleAttribute) ?? "nil") -> fallback to captured element")
        }
        return element
    }

    private func readableValue() -> String? {
        guard let el = currentElement() else { return nil }
        return AX.value(el, kAXValueAttribute) as? String
    }

    private func collapseSelectionIfNeeded(_ element: AXUIElement) {
        guard let raw = AX.value(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.length > 0 else { return }
        var collapsed = CFRange(location: range.location + range.length, length: 0)
        if let value = AXValueCreate(.cfRange, &collapsed) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        }
    }

    private func postCommandV(to pid: pid_t) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
    }
}

// MARK: - 转写文本清洗（去掉尾随 yeah/Okay 等幻觉词与异常标点）

/// SenseVoice 在句尾静音/噪声上偶尔会幻觉出 "yeah"、"Okay" 之类英文词，
/// 也会产生「，，」「。。」这类重复标点。这里统一做保守清洗：
/// 只清理句首/句尾的英文填充词与标点赘余，不动正文。
enum TranscriptSanitizer {
    private static let fillerWords = [
        "yeah", "yea", "yep", "okay", "ok", "oh", "ah", "uh", "um", "hmm", "hm",
        "mm", "mhm", "eh", "alright", "right", "well", "thanks", "thank you"
    ]

    private static let hanRegex = try! NSRegularExpression(pattern: "[\\p{Han}]")
    private static let contentRegex = try! NSRegularExpression(pattern: "[\\p{Han}A-Za-z0-9]")

    static func sanitize(_ raw: String) -> String {
        var text = raw
        // 1) 去掉 SenseVoice 控制/情绪标签
        while let open = text.range(of: "<|"), let close = text.range(of: "|>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        // 2) 空白规整
        text = text.replacingOccurrences(of: "\r", with: " ")
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = collapse(text, pattern: "[ \\t]{2,}", to: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 3) 去掉汉字之间多余的空格（SenseVoice 偶发插入）
        text = replaceMatches(text, pattern: "(?<=\\p{Han})\\s+(?=\\p{Han})") { _ in "" }

        // 4) 标点赘余合并：「，，」→「，」，「，。」→「。」，「。。。」→「。」
        text = replaceMatches(text, pattern: "[，。！？；：、]{2,}") { match in
            if match.contains("。") { return "。" }
            if match.contains("，") { return "，" }
            return String(match.suffix(1))
        }
        text = replaceMatches(text, pattern: "[,;!?]{2,}") { match in String(match.suffix(1)) }

        // 4.1) 去掉中文标点两侧空格、重复标点、句首标点
        text = replaceMatches(text, pattern: "\\s*([，。！？；：、])\\s*") { match in String(match.suffix(1)) }
        text = replaceMatches(text, pattern: "([，、])[，、]+") { match in String(match.prefix(1)) }
        text = replaceMatches(text, pattern: "[，、；：]+([。！？])") { match in String(match.suffix(1)) }
        text = replaceMatches(text, pattern: "([。！？])[，、；：]+") { match in String(match.prefix(1)) }
        text = replaceMatches(text, pattern: "([。！？])\\1+") { match in String(match.prefix(1)) }
        text = replaceMatches(text, pattern: "^[，。！？；：、,.;:!?\\s]+") { _ in "" }

        // 5) 去掉句首/句尾的英文填充词（只处理中文上下文或整句就是填充词的情况）
        text = stripEdgeFillers(text)

        // 6) 尾随标点收敛：以逗号/顿号/分号/冒号结尾时改成句号或去掉
        if let last = text.last, "，、；：,;:".contains(last) {
            text.removeLast()
            if hasHan(text) { text.append("。") }
        } else if let last = text.last, "!.?!".contains(last) {
            // 半角标点转全角，观感统一
            text.removeLast()
            text.append(last == "?" ? "？" : (last == "!" ? "！" : "。"))
        }

        // 7) 只有标点或空白的输出视为没有识别到内容
        if !hasContent(text) { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripEdgeFillers(_ text: String) -> String {
        var result = text
        for _ in 0..<4 {
            var changed = false
            for filler in fillerWords.sorted(by: { $0.count > $1.count }) {
                let escaped = NSRegularExpression.escapedPattern(for: filler)
                // 句尾：「…yeah」「…，okay.」
                let endPattern = "(?i)(?<![A-Za-z])" + escaped + "[\\s]*[,.!?，。！？、;；:：]*$"
                if let range = matchRange(result, pattern: endPattern) {
                    if shouldStrip(prefix: String(result[result.startIndex..<range.lowerBound])) {
                        result.removeSubrange(range)
                        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
                        changed = true
                        break
                    }
                }
                // 句首：「yeah，今天…」「Okay. 我觉得…」
                let startPattern = "^(?i)" + escaped + "[\\s]*[,.!?，。！？、;；:：]*"
                if let range = matchRange(result, pattern: startPattern) {
                    if shouldStrip(prefix: String(result[range.upperBound...])) {
                        result.removeSubrange(range)
                        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
                        changed = true
                        break
                    }
                }
            }
            if !changed { break }
        }
        return result
    }

    /// 只在「中文上下文中」或「整句就是填充词」时删除，避免误伤正常英文句子（如 "That's okay"）。
    private static func shouldStrip(prefix: String) -> Bool {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return hasHan(trimmed)
    }

    private static func hasHan(_ text: String) -> Bool {
        hanRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func hasContent(_ text: String) -> Bool {
        contentRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func collapse(_ text: String, pattern: String, to replacement: String) -> String {
        replaceMatches(text, pattern: pattern) { _ in replacement }
    }

    private static func replaceMatches(_ text: String, pattern: String, transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var output = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: transform(String(output[range])))
        }
        return output
    }

    private static func matchRange(_ text: String, pattern: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return range
    }
}

// MARK: - 音频反馈（低频电影感 · 无噪声 · 开始/结束分别可选）

/// 音色库分四组整理：合成 · 科技助手 / 合成 · 低频电影 / Apple 原声 / 静音。
/// Apple 原声直接调用 macOS 自带音频文件（不打包分发），缺失时自动回退合成音。
struct SoundPreset: Identifiable, Hashable {
    enum Kind: Hashable {
        case synth(String)
        case system(String)
        case silent
    }
    let id: String
    let name: String
    let group: String
    let kind: Kind

    var displayName: String { "\(group) · \(name)" }

    static let groups = ["科技", "低频", "Apple", "静音"]

    static let all: [SoundPreset] = [
        // 合成 · 科技助手（短、干净、中频）
        .init(id: "synth:wake", name: "轻启", group: "科技", kind: .synth("wake")),
        .init(id: "synth:message", name: "讯息", group: "科技", kind: .synth("message")),
        .init(id: "synth:summon", name: "唤醒", group: "科技", kind: .synth("summon")),
        .init(id: "synth:confirm", name: "确认", group: "科技", kind: .synth("confirm")),
        .init(id: "synth:tick", name: "轻点", group: "科技", kind: .synth("tick")),
        .init(id: "synth:ripple", name: "波纹", group: "科技", kind: .synth("ripple")),
        // 合成 · 低频电影（更长、更沉）
        .init(id: "synth:launch", name: "启动", group: "低频", kind: .synth("launch")),
        .init(id: "synth:cinema", name: "影院", group: "低频", kind: .synth("cinema")),
        .init(id: "synth:boom", name: "低鸣", group: "低频", kind: .synth("boom")),
        .init(id: "synth:tail", name: "余韵", group: "低频", kind: .synth("tail")),
        .init(id: "synth:rumble", name: "地鸣", group: "低频", kind: .synth("rumble")),
        .init(id: "synth:engine", name: "引擎", group: "低频", kind: .synth("engine")),
        .init(id: "synth:deep", name: "深海", group: "低频", kind: .synth("deep")),
        .init(id: "synth:pulse", name: "脉冲", group: "低频", kind: .synth("pulse")),
        // Apple 原声（系统自带，运行时不打包）
        .init(id: "sys:received", name: "收到信息", group: "Apple", kind: .system("received")),
        .init(id: "sys:sent", name: "iMessage 已发送", group: "Apple", kind: .system("sent")),
        .init(id: "sys:beginRecord", name: "开始录音", group: "Apple", kind: .system("beginRecord")),
        .init(id: "sys:endRecord", name: "结束录音", group: "Apple", kind: .system("endRecord")),
        .init(id: "sys:sentSystem", name: "系统已发送", group: "Apple", kind: .system("sentSystem")),
        .init(id: "sys:siriBegin", name: "Siri 唤醒", group: "Apple", kind: .system("siriBegin")),
        .init(id: "sys:newMail", name: "收到邮件", group: "Apple", kind: .system("newMail")),
        .init(id: "sys:mailSent", name: "邮件已发送", group: "Apple", kind: .system("mailSent")),
        // 静音
        .init(id: "synth:silent", name: "静音", group: "静音", kind: .silent)
    ]

    static func named(_ name: String) -> SoundPreset {
        all.first { $0.name == name } ?? all.first { $0.id == name } ?? all[0]
    }

    static let validNames: Set<String> = Set(all.map(\.name))
}

/// macOS 自带提示音的路径（不同系统版本可能有差异，全部列候选；不存在则回退合成音）。
enum AppleSoundLibrary {
    static func path(for key: String) -> String? {
        let candidates: [String]
        switch key {
        case "beginRecord":
            candidates = [systemSounds + "begin_record.caf"]
        case "endRecord":
            candidates = [systemSounds + "end_record.caf"]
        case "sentSystem":
            candidates = [systemSounds + "SentMessage.caf"]
        case "received":
            candidates = [toneLibrary + "AlertTones/ReceivedMessage.caf"]
        case "sent":
            candidates = [imDaemon + "Sent Message.aiff"]
        case "siriBegin":
            candidates = [assistant + "siri-begin-improved.caf"]
        case "newMail":
            candidates = ["/System/Applications/Mail.app/Contents/Resources/New Mail.aiff"]
        case "mailSent":
            candidates = ["/System/Applications/Mail.app/Contents/Resources/Mail Sent.aiff"]
        default:
            candidates = []
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    static let systemSounds = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
    static let toneLibrary = "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/"
    static let imDaemon = "/System/Library/PrivateFrameworks/IMDaemonCore.framework/Versions/A/Resources/"
    static let assistant = "/System/Library/PrivateFrameworks/AssistantServices.framework/Versions/A/Resources/"
}

@MainActor final class SoundFeedback {
    static let shared = SoundFeedback()

    enum Cue {
        case start
        case success
        case error
    }

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var systemSounds: [NSSound] = []

    /// 打包进 App 的音效文件（Resources/Sounds），优先于系统路径与合成音。
    private func bundledSoundURL(for preset: SoundPreset) -> URL? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Sounds", isDirectory: true) else { return nil }
        for ext in ["wav", "caf", "aiff", "m4a"] {
            let url = dir.appendingPathComponent("\(preset.name).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private func playFileSound(_ url: URL, gainFactor: Double) -> Bool {
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return false }
        for old in systemSounds { old.stop() }
        systemSounds.removeAll()
        sound.volume = Float(max(0, min(1, Preferences.shared.soundVolume * gainFactor)))
        sound.play()
        systemSounds.append(sound)
        if systemSounds.count > 4 { systemSounds.removeFirst(systemSounds.count - 4) }
        return true
    }

    /// 播放 macOS 原生提示音；路径不存在或加载失败时返回 false（由调用方回退合成音）。
    private func playSystemSound(key: String, gainFactor: Double) -> Bool {
        guard let path = AppleSoundLibrary.path(for: key),
              let sound = NSSound(contentsOfFile: path, byReference: true) else { return false }
        for old in systemSounds { old.stop() }
        systemSounds.removeAll()
        let prefs = Preferences.shared
        sound.volume = Float(max(0, min(1, prefs.soundVolume * gainFactor)))
        sound.play()
        systemSounds.append(sound)
        // 清理已播放完的引用，避免累积
        if systemSounds.count > 4 { systemSounds.removeFirst(systemSounds.count - 4) }
        return true
    }
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    func play(_ cue: Cue) {
        guard Preferences.shared.playSounds else { return }
        let prefs = Preferences.shared
        let presetName: String
        let gainFactor: Double
        switch cue {
        case .start:
            presetName = prefs.startSoundStyle
            gainFactor = 0.70
        case .success:
            presetName = prefs.endSoundStyle
            gainFactor = 1.0
        case .error:
            presetName = prefs.endSoundStyle
            gainFactor = 0.85
        }

        let preset = SoundPreset.named(presetName)
        FVDebug.log("sound cue=\(cue) preset=\(preset.displayName) kind=\(preset.kind)")
        switch preset.kind {
        case .silent:
            return
        default:
            if let bundled = bundledSoundURL(for: preset), playFileSound(bundled, gainFactor: gainFactor) {
                return
            }
        }
        switch preset.kind {
        case .silent:
            return
        case .system(let key):
            if cue == .error {
                playSynth(key: "error", gainFactor: gainFactor)
                return
            }
            if playSystemSound(key: key, gainFactor: gainFactor) { return }
            // 文件缺失时回退到同语义的合成音
            let fallback: String
            switch key {
            case "beginRecord", "siriBegin": fallback = "wake"
            case "endRecord", "sent", "sentSystem", "mailSent": fallback = "confirm"
            case "received", "newMail": fallback = "ripple"
            default: fallback = "confirm"
            }
            playSynth(key: fallback, gainFactor: gainFactor)
        case .synth(let key):
            playSynth(key: cue == .error ? "error" : key, gainFactor: gainFactor)
        }
    }

    private func playSynth(key: String, gainFactor: Double) {
        guard let buffer = makeBuffer(key: key, cueGain: gainFactor) else { return }
        ensureEngine()
        guard let engine, let player else { return }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        engine.mainMixerNode.outputVolume = Float(max(0, min(1, Preferences.shared.soundVolume)))
        player.play()
    }

    private func ensureEngine() {
        guard engine == nil else { return }
        let e = AVAudioEngine()
        let p = AVAudioPlayerNode()
        e.attach(p)
        e.connect(p, to: e.mainMixerNode, format: format)
        do {
            try e.start()
            engine = e
            player = p
        } catch {
            engine = nil
            player = nil
        }
    }

    /// 自测/导出用：返回某音色的浮点采样
    func debugSamples(key: String) -> [Float]? {
        guard let buffer = makeBuffer(key: key, cueGain: 1.0),
              let pointer = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: pointer, count: Int(buffer.frameLength)))
    }

    private func makeBuffer(key: String, cueGain: Double) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        var samples: [Float] = []
        switch key {
        case "wake":
            // 轻启：参考 Siri 唤醒的双音，D5 → A5，柔和上行
            samples = mix([
                (0.00, chime(587.33, sr: sr, duration: 0.22, gain: 0.24 * cueGain, decay: 12.0, partials: [(2.0, 0.10)])),
                (0.09, chime(880.0, sr: sr, duration: 0.30, gain: 0.21 * cueGain, decay: 9.0, partials: [(2.0, 0.08)]))
            ], sr: sr, duration: 0.40)
        case "message":
            // 讯息：参考 iMessage 发送的短促"嗖"，从高到低的干净滑音，无噪声
            samples = mix([
                (0.00, glide(1_150, 620, sr, 0.17, 0.18 * cueGain, 16)),
                (0.02, chime(740.0, sr: sr, duration: 0.13, gain: 0.10 * cueGain, decay: 20, partials: []))
            ], sr: sr, duration: 0.22)
        case "summon":
            // 唤醒：三音上行 C5-E5-G5，像语音助手被唤起
            samples = mix([
                (0.00, chime(523.25, sr: sr, duration: 0.42, gain: 0.17 * cueGain, decay: 5.0, partials: [(2.0, 0.10)])),
                (0.09, chime(659.25, sr: sr, duration: 0.44, gain: 0.15 * cueGain, decay: 4.6, partials: [(2.0, 0.09)])),
                (0.18, chime(783.99, sr: sr, duration: 0.50, gain: 0.13 * cueGain, decay: 4.2, partials: [(2.0, 0.08)]))
            ], sr: sr, duration: 0.70)
        case "confirm":
            // 确认：G5 → C6 双音，像 Apple Pay / 发送成功
            samples = mix([
                (0.00, chime(783.99, sr: sr, duration: 0.40, gain: 0.20 * cueGain, decay: 7.0, partials: [(2.0, 0.09)])),
                (0.10, chime(1_046.50, sr: sr, duration: 0.50, gain: 0.17 * cueGain, decay: 6.0, partials: [(2.0, 0.06)]))
            ], sr: sr, duration: 0.62)
        case "tick":
            // 轻点：极短的柔和点按，像 AirPods 连接提示
            samples = mix([
                (0.00, chime(987.77, sr: sr, duration: 0.08, gain: 0.16 * cueGain, decay: 26.0, partials: []))
            ], sr: sr, duration: 0.10)
        case "launch":
            samples = mix([(0.00, subSwell(from: 110, to: 220, sr: sr, duration: 1.15, gain: 0.55 * cueGain))], sr: sr, duration: 1.35)
        case "cinema":
            samples = mix([(0.00, subSwell(from: 90, to: 180, sr: sr, duration: 1.35, gain: 0.52 * cueGain))], sr: sr, duration: 1.55)
        case "boom":
            samples = mix([(0.00, subSwell(from: 75, to: 150, sr: sr, duration: 0.95, gain: 0.50 * cueGain))], sr: sr, duration: 1.15)
        case "tail":
            samples = mix([(0.00, subSwell(from: 190, to: 95, sr: sr, duration: 1.30, gain: 0.48 * cueGain))], sr: sr, duration: 1.50)
        case "rumble":
            samples = mix([(0.00, subSwell(from: 70, to: 130, sr: sr, duration: 1.45, gain: 0.46 * cueGain))], sr: sr, duration: 1.65)
        case "engine":
            samples = mix([(0.00, subSwell(from: 120, to: 185, sr: sr, duration: 1.25, gain: 0.50 * cueGain))], sr: sr, duration: 1.45)
        case "deep":
            samples = mix([(0.00, subSwell(from: 80, to: 140, sr: sr, duration: 1.65, gain: 0.46 * cueGain))], sr: sr, duration: 1.85)
        case "pulse":
            samples = mix([(0.00, subSwell(from: 100, to: 200, sr: sr, duration: 0.80, gain: 0.52 * cueGain))], sr: sr, duration: 1.00)
        case "ripple":
            // 波纹：C5 → G4 轻柔下行，用于中性提醒
            samples = mix([
                (0.00, chime(523.25, sr: sr, duration: 0.34, gain: 0.18 * cueGain, decay: 6.0, partials: [(2.0, 0.10)])),
                (0.10, chime(392.00, sr: sr, duration: 0.42, gain: 0.15 * cueGain, decay: 5.0, partials: [(2.0, 0.08)]))
            ], sr: sr, duration: 0.54)
        case "error":
            // 失败：A4 → F4 双音下行，柔和
            samples = mix([
                (0.00, chime(440.00, sr: sr, duration: 0.26, gain: 0.18 * cueGain, decay: 8.0, partials: [(2.0, 0.08)])),
                (0.12, chime(349.23, sr: sr, duration: 0.38, gain: 0.15 * cueGain, decay: 6.0, partials: [(2.0, 0.08)]))
            ], sr: sr, duration: 0.52)
        default:
            return nil
        }
        // 响度归一：提示音统一到一个舒适的峰值（轻点更克制），避免某些音色偏小听不到
        var peak: Float = 0
        for sample in samples { peak = max(peak, abs(sample)) }
        if peak > 0.001 {
            let target: Float = (key == "tick") ? 0.34 : 0.52
            let scale = target / peak
            for i in samples.indices { samples[i] *= min(scale, 22) }
        }
        let frames = samples.count
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        if let data = buffer.floatChannelData?[0] {
            for i in 0..<frames { data[i] = samples[i] }
        }
        return buffer
    }

    // MARK: - 合成基元（纯正弦，无噪声）

    private func tone(_ freq: Double, _ sr: Double, _ duration: Double, _ gain: Double,
                      _ decay: Double, _ harmonics: [(Double, Double)]) -> [Float] {
        let count = Int(duration * sr)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sr
            let attack = 0.012
            let env: Double
            if t < attack {
                env = pow(t / attack, 1.3)
            } else {
                env = exp(-(t - attack) * decay)
            }
            var value = sin(2 * .pi * freq * t)
            for (multiple, weight) in harmonics { value += weight * sin(2 * .pi * freq * multiple * t) }
            out[i] = Float(value * env * gain)
        }
        fadeTail(&out, sr: sr, ms: 12)
        return out
    }

    /// 低频缓起：从 from 平滑滑到 to，慢起、长尾，全程纯正弦（无沙沙声）
    private func subSwell(from: Double, to: Double, sr: Double, duration: Double, gain: Double) -> [Float] {
        let count = Int(duration * sr)
        var out = [Float](repeating: 0, count: count)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / sr
            let p = min(1, t / duration)
            // 频率缓慢上抬（前段更慢）
            let glide = 0.5 - 0.5 * cos(.pi * pow(p, 0.65))
            let freq = from + (to - from) * glide
            phase += 2 * .pi * freq / sr
            let attack = 0.10
            let env: Double
            if t < attack {
                env = pow(t / attack, 1.6)
            } else {
                env = exp(-(t - attack) * 2.4) * (1.0 - 0.18 * p)
            }
            out[i] = Float(sin(phase) * env * gain)
        }
        fadeTail(&out, sr: sr, ms: 22)
        return out
    }

    /// 干净滑音（用于 iMessage 式短促「嗖」）：无噪声，纯正弦扫频
    private func glide(_ from: Double, _ to: Double, _ sr: Double, _ duration: Double,
                       _ gain: Double, _ decay: Double, _ cueGain: Double = 1) -> [Float] {
        let count = Int(duration * sr)
        var out = [Float](repeating: 0, count: count)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / sr
            let p = min(1, t / duration)
            let freq = from + (to - from) * p
            phase += 2 * .pi * freq / sr
            let attack = 0.006
            let env = t < attack ? t / attack : exp(-(t - attack) * decay)
            out[i] = Float(sin(phase) * env * gain * cueGain)
        }
        fadeTail(&out, sr: sr, ms: 8)
        return out
    }

    /// 柔和钟音：基音 + 弱泛音，软起音；用于科技提示音，避免刺耳高频
    private func chime(_ freq: Double, sr: Double, duration: Double, gain: Double,
                       decay: Double, partials: [(Double, Double)]) -> [Float] {
        let count = Int(duration * sr)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sr
            let attack = 0.012
            let env: Double
            if t < attack {
                env = pow(t / attack, 1.4)
            } else {
                env = exp(-(t - attack) * decay)
            }
            var value = sin(2 * .pi * freq * t)
            for (multiple, weight) in partials {
                value += weight * sin(2 * .pi * freq * multiple * t) * exp(-t * decay * 1.3)
            }
            out[i] = Float(value * env * gain)
        }
        fadeTail(&out, sr: sr, ms: 10)
        return out
    }

    /// 中低频「温暖和弦」：基音 + 五度 + 八度，柔和起音与长衰减，无高频铃声感
    private func warmChord(_ freq: Double, sr: Double, duration: Double, gain: Double, decay: Double) -> [Float] {
        let count = Int(duration * sr)
        var out = [Float](repeating: 0, count: count)
        let partials: [(Double, Double, Double)] = [
            (1.0, 1.00, decay),
            (1.5, 0.30, decay * 1.15),
            (2.0, 0.16, decay * 1.25)
        ]
        for i in 0..<count {
            let t = Double(i) / sr
            let attack = 0.02
            var value = 0.0
            for (multiple, weight, partialDecay) in partials {
                let env = t < attack ? pow(t / attack, 1.3) : exp(-(t - attack) * partialDecay)
                value += weight * env * sin(2 * .pi * freq * multiple * t)
            }
            out[i] = Float(value * gain)
        }
        fadeTail(&out, sr: sr, ms: 14)
        return out
    }

    /// 中低频缓起（基音滑动 + 五度/八度泛音），慢起、长尾、无高频
    private func warmGlide(from: Double, to: Double, sr: Double, duration: Double, gain: Double) -> [Float] {
        let count = Int(duration * sr)
        var out = [Float](repeating: 0, count: count)
        var phase = 0.0
        var phaseFifth = 0.0
        for i in 0..<count {
            let t = Double(i) / sr
            let p = min(1, t / duration)
            let glide = 0.5 - 0.5 * cos(.pi * pow(p, 0.65))
            let freq = from + (to - from) * glide
            phase += 2 * .pi * freq / sr
            phaseFifth += 2 * .pi * freq * 1.5 / sr
            let attack = 0.12
            let env: Double
            if t < attack {
                env = pow(t / attack, 1.5)
            } else {
                env = exp(-(t - attack) * 2.2) * (1.0 - 0.15 * p)
            }
            let value = sin(phase) + 0.26 * sin(phaseFifth) * 0.8
            out[i] = Float(value * env * gain)
        }
        fadeTail(&out, sr: sr, ms: 24)
        return out
    }

    private func mix(_ layers: [(Double, [Float])], sr: Double, duration: Double) -> [Float] {
        let count = Int(duration * sr) + 1
        var out = [Float](repeating: 0, count: count)
        for (offsetSeconds, layer) in layers {
            let offset = Int(offsetSeconds * sr)
            for (index, sample) in layer.enumerated() where offset + index < count {
                out[offset + index] += sample
            }
        }
        return out
    }

    private func fadeTail(_ samples: inout [Float], sr: Double, ms: Double = 10) {
        let count = samples.count
        let fade = min(count, Int(ms / 1000 * sr))
        guard fade > 0 else { return }
        for i in 0..<fade {
            samples[count - fade + i] *= Float(1.0 - Double(i) / Double(fade))
        }
    }
}

// MARK: - AppKit Liquid Glass 背景（macOS 26 原生，旧系统回退毛玻璃）

enum GlassBackgroundFactory {
    static func make(cornerRadius: CGFloat, tint: NSColor? = nil, liquid: Bool = true) -> NSView {
        if liquid, #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            view.cornerRadius = cornerRadius
            view.style = .regular
            view.tintColor = tint
            return view
        }
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        return view
    }
}

// MARK: - Frosted-Glass Floating HUD

@MainActor final class HUDView: NSView {
    enum State {
        case preparing
        case recording(startedAt: Date)
        case transcribing(detail: String)
        case inserted(title: String, detail: String)
        case toast(title: String, detail: String)
        case error(String)
    }

    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSourceToggle: (() -> Void)?
    var targetName: String = ""

    private let margin: CGFloat = 18
    private let content = NSView()
    private let shadowView = NSView()
    private var glass = GlassBackgroundFactory.make(cornerRadius: 22)
    private var glassIsLiquid = true
    private let veilLayer = CALayer()
    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let timerLabel = NSTextField(labelWithString: "")
    private let liveScroll = NSScrollView()
    private let liveTextView = NSTextView()
    private let hintLabel = NSTextField(labelWithString: "")
    private let finishButton = FirstMouseButton(title: L10n.t("完成"))
    private let cancelButton = FirstMouseButton(title: L10n.t("取消"))
    private let sourceButton = FirstMouseButton(title: L10n.t(AudioSource.mic.shortLabel))
    private let spinner = NSProgressIndicator()
    private var timer: Timer?
    private var startedAt: Date?
    private var confirmedText = ""
    private var partialText = ""
    private var sheenLayer: CAGradientLayer?
    private var lastState: State?
    private var sourceName = AudioSource.mic.shortLabel

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        glass.wantsLayer = true

        // 内容容器：圆角裁切，所有控件都放在里面
        content.wantsLayer = true
        content.layer?.cornerRadius = 22
        content.layer?.masksToBounds = true
        addSubview(content)

        // 圆角投影（放在内容下层；窗口四周留了 18pt 余量，阴影不会被裁成方形）
        shadowView.wantsLayer = true
        shadowView.layer?.cornerRadius = 22
        shadowView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.001).cgColor
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.26
        shadowView.layer?.shadowRadius = 16
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -4)
        shadowView.layer?.shadowPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 470, height: 150),
                                              cornerWidth: 22, cornerHeight: 22, transform: nil)
        addSubview(shadowView, positioned: .below, relativeTo: content)
        content.addSubview(glass)
        veilLayer.frame = content.bounds
        veilLayer.cornerRadius = 22
        veilLayer.masksToBounds = true
        content.layer?.addSublayer(veilLayer)

        // Liquid Glass 顶部高光（极轻的一道白色渐变，让玻璃有体积感）
        let sheen = CAGradientLayer()
        sheen.colors = [
            NSColor.white.withAlphaComponent(0.16).cgColor,
            NSColor.white.withAlphaComponent(0.04).cgColor,
            NSColor.clear.cgColor
        ]
        sheen.locations = [0, 0.28, 1]
        sheen.startPoint = CGPoint(x: 0.5, y: 1.0)
        sheen.endPoint = CGPoint(x: 0.5, y: 0.0)
        sheen.cornerRadius = 22
        sheen.masksToBounds = true
        sheenLayer = sheen
        content.layer?.addSublayer(sheen)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        titleLabel.lineBreakMode = .byTruncatingTail

        timerLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        timerLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        timerLabel.alignment = .right

        liveScroll.borderType = .noBorder
        liveScroll.drawsBackground = false
        liveScroll.hasVerticalScroller = true
        liveScroll.autohidesScrollers = true
        liveScroll.scrollerStyle = .overlay
        liveScroll.verticalScrollElasticity = .allowed
        liveScroll.contentView.drawsBackground = false
        liveTextView.isEditable = false
        liveTextView.isSelectable = true
        liveTextView.isRichText = true
        liveTextView.drawsBackground = false
        liveTextView.textContainerInset = NSSize(width: 0, height: 0)
        liveTextView.textContainer?.lineFragmentPadding = 0
        liveTextView.textContainer?.widthTracksTextView = true
        liveTextView.isHorizontallyResizable = false
        liveTextView.isVerticallyResizable = true
        liveTextView.autoresizingMask = [.width]
        liveScroll.documentView = liveTextView

        hintLabel.font = .systemFont(ofSize: 10.5)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        hintLabel.lineBreakMode = .byTruncatingTail

        finishButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        finishButton.layer?.cornerRadius = 13

        cancelButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        cancelButton.layer?.cornerRadius = 13

        sourceButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        sourceButton.layer?.cornerRadius = 13
        sourceButton.updateTitleFont(size: 10.5)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        content.addSubview(dot)
        content.addSubview(titleLabel)
        content.addSubview(timerLabel)
        content.addSubview(liveScroll)
        content.addSubview(hintLabel)
        content.addSubview(sourceButton)
        content.addSubview(cancelButton)
        content.addSubview(finishButton)
        content.addSubview(spinner)

        finishButton.onClick = { [weak self] in self?.onFinish?() }
        cancelButton.onClick = { [weak self] in self?.onCancel?() }
        sourceButton.onClick = { [weak self] in self?.onSourceToggle?() }
        applyAppearance()
        apply(.preparing)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let contentRect = bounds.insetBy(dx: margin, dy: margin)
        content.frame = contentRect
        shadowView.frame = contentRect
        shadowView.layer?.shadowPath = CGPath(roundedRect: content.bounds,
                                              cornerWidth: 22, cornerHeight: 22, transform: nil)
        glass.frame = content.bounds
        veilLayer.frame = content.bounds
        sheenLayer?.frame = content.bounds
        sheenLayer?.cornerRadius = 22
        let h = content.bounds.height
        let w = content.bounds.width
        dot.frame = NSRect(x: 18, y: h - 27, width: 9, height: 9)
        titleLabel.frame = NSRect(x: 35, y: h - 34, width: 220, height: 18)
        timerLabel.frame = NSRect(x: w - 96, y: h - 32, width: 62, height: 16)
        spinner.frame = NSRect(x: w - 30, y: h - 30, width: 15, height: 15)

        liveScroll.frame = NSRect(x: 18, y: 50, width: w - 36, height: h - 88)
        hintLabel.frame = NSRect(x: 156, y: 18, width: max(40, w - 156 - 180), height: 14)

        sourceButton.frame = NSRect(x: 16, y: 12, width: 130, height: 26)
        cancelButton.frame = NSRect(x: w - 172, y: 12, width: 72, height: 26)
        finishButton.frame = NSRect(x: w - 94, y: 12, width: 78, height: 26)
    }

    /// 语言切换后立即刷新固定文案；不重置计时器/转写内容。
    func refreshLanguage() {
        finishButton.updateTitle(L10n.t("完成"))
        cancelButton.updateTitle(L10n.t("取消"))
        hintLabel.stringValue = L10n.t("Esc 取消 · ↵ 完成")
        sourceButton.updateTitle(L10n.t(sourceName))
        switch lastState {
        case .preparing:
            titleLabel.stringValue = L10n.t("正在启动录音…")
            setPlaceholder(L10n.t("请稍候"))
        case .recording:
            titleLabel.stringValue = targetName.isEmpty ? L10n.t("正在聆听") : L10n.t("正在聆听") + " · \(targetName)"
            hintLabel.stringValue = L10n.t("Esc 取消 · ↵ 完成")
            setPlaceholder(L10n.t("开始说话，文字会实时出现在这里…"))
        case .transcribing:
            titleLabel.stringValue = L10n.t("正在整理文字…")
        case .inserted:
            titleLabel.stringValue = L10n.t("已插入文字")
            setPlaceholder(L10n.t("已粘贴回原始输入框"))
        case .error:
            titleLabel.stringValue = L10n.t("无法完成")
        default:
            break
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func apply(_ state: State) {
        lastState = state
        stopTimer()
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        finishButton.isHidden = false
        cancelButton.isHidden = false
        dot.isHidden = false
        sourceButton.isHidden = true
        dot.layer?.removeAnimation(forKey: "pulse")
        confirmedText = ""
        partialText = ""

        switch state {
        case .preparing:
            dot.layer?.backgroundColor = NSColor.systemGray.cgColor
            titleLabel.stringValue = L10n.t("正在启动录音…")
            timerLabel.stringValue = ""
            setPlaceholder("请稍候")
            hintLabel.stringValue = ""
            finishButton.isHidden = true
            cancelButton.isHidden = true

        case .recording(let start):
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            titleLabel.stringValue = targetName.isEmpty ? L10n.t("正在聆听") : L10n.t("正在聆听") + " · \(targetName)"
            startedAt = start
            updateElapsed(start)
            startPulse()
            sourceButton.isHidden = false
            hintLabel.stringValue = L10n.t("Esc 取消 · ↵ 完成")
            setPlaceholder("开始说话，文字会实时出现在这里…")
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let startedAt = self.startedAt else { return }
                    self.updateElapsed(startedAt)
                }
            }

        case .transcribing(let detail):
            dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
            titleLabel.stringValue = L10n.t("正在整理文字…")
            timerLabel.stringValue = ""
            setPlaceholder(detail)
            hintLabel.stringValue = ""
            finishButton.isHidden = true
            cancelButton.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)

        case .toast:
            break

        case .inserted:
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            titleLabel.stringValue = L10n.t("已插入文字")
            timerLabel.stringValue = ""
            setPlaceholder("已粘贴回原始输入框")
            hintLabel.stringValue = ""
            finishButton.isHidden = true
            cancelButton.isHidden = true

        case .error(let message):
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            titleLabel.stringValue = L10n.t("无法完成")
            timerLabel.stringValue = ""
            setPlaceholder(message)
            hintLabel.stringValue = ""
            finishButton.isHidden = true
            cancelButton.isHidden = true
        }
    }

    /// 用户可调的浮层外观：液态玻璃开/关、毛玻璃程度、投影强度
    func applyAppearance() {
        let prefs = Preferences.shared
        let liquid = prefs.overlayLiquidGlass
        let availableLiquid: Bool
        if #available(macOS 26.0, *) { availableLiquid = true } else { availableLiquid = false }
        let useLiquid = liquid && availableLiquid

        if useLiquid != glassIsLiquid {
            glass.removeFromSuperview()
            glass = GlassBackgroundFactory.make(cornerRadius: 22, liquid: useLiquid)
            glass.frame = content.bounds
            glass.wantsLayer = true
            content.addSubview(glass, positioned: .below, relativeTo: content.subviews.first)
            glassIsLiquid = useLiquid
        }

        let intensity = max(0, min(1, prefs.overlayGlassIntensity))
        // 毛玻璃程度：越高越"实"，用一层极轻的窗口色蒙版模拟材质厚度
        veilLayer.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.06 + 0.30 * intensity).cgColor
        let shadow = max(0, min(1, prefs.overlayShadowStrength))
        shadowView.layer?.shadowOpacity = Float(shadow * 0.42)
    }

    func setSource(_ name: String) {
        sourceName = name
        sourceButton.updateTitle(L10n.t(name))
    }

    /// 录音过程中目标解析完成/变化时刷新标题（不重建 HUD）。
    func refreshTargetTitle() {
        guard startedAt != nil else { return }
        titleLabel.stringValue = targetName.isEmpty ? L10n.t("正在聆听") : L10n.t("正在聆听") + " · \(targetName)"
    }

    func setLiveTranscript(_ text: String) {
        setLiveTranscript(confirmed: text, partial: "")
    }

    /// confirmed = 已定稿的整段文字（深色）；partial = 当前正在说的片段（浅色）。
    func setLiveTranscript(confirmed: String, partial: String) {
        var c = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        // 段边界可能短暂回传空 confirmed：保留上一段文字，只更新 partial
        if c.isEmpty && !confirmedText.isEmpty { c = confirmedText }
        if c == confirmedText && p == partialText { return }
        confirmedText = c
        partialText = p
        guard !c.isEmpty || !p.isEmpty else {
            // 切换录音来源时流式引擎可能先发一次空更新；不要用它清空已显示的文字
            if confirmedText.isEmpty && partialText.isEmpty {
                setPlaceholder("开始说话，文字会实时出现在这里…")
            }
            return
        }

        // 可滚动区域保留完整内容，用户可回看之前说过的文字
        let shownConfirmed = c
        let shownPartial = p

        let attr = NSMutableAttributedString()
        if !shownConfirmed.isEmpty {
            attr.append(NSAttributedString(string: shownConfirmed, attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.96),
                .font: NSFont.systemFont(ofSize: 13.5, weight: .regular)
            ]))
        }
        if !shownPartial.isEmpty {
            if !shownConfirmed.isEmpty { attr.append(NSAttributedString(string: " ")) }
            attr.append(NSAttributedString(string: shownPartial, attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.52),
                .font: NSFont.systemFont(ofSize: 13.5, weight: .regular)
            ]))
        }
        setLiveText(attr)
    }

    private func setPlaceholder(_ text: String) {
        setLiveText(NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.42),
            .font: NSFont.systemFont(ofSize: 13, weight: .regular)
        ]))
    }

    private func setLiveText(_ attributed: NSAttributedString) {
        let visibleWidth = max(1, liveScroll.contentSize.width)
        let visibleHeight = max(1, liveScroll.contentSize.height)
        let wasAtBottom = liveTextView.frame.height <= visibleHeight + 6
            || liveScroll.contentView.bounds.maxY >= liveTextView.frame.height - 6

        liveTextView.textStorage?.setAttributedString(attributed)
        // 先固定宽度再排版，否则首帧宽度为 0 会算出错误高度，内容可能瞬间不可见
        liveTextView.frame = NSRect(x: 0, y: 0, width: visibleWidth, height: max(visibleHeight, 1))
        if let container = liveTextView.textContainer {
            container.containerSize = NSSize(width: visibleWidth, height: .greatestFiniteMagnitude)
            container.widthTracksTextView = true
            liveTextView.layoutManager?.ensureLayout(for: container)
            let used = liveTextView.layoutManager?.usedRect(for: container).height ?? visibleHeight
            liveTextView.frame = NSRect(x: 0, y: 0, width: visibleWidth, height: max(visibleHeight, ceil(used) + 4))
        }
        if wasAtBottom {
            liveTextView.scrollToEndOfDocument(nil)
        }
    }

    private func updateElapsed(_ startedAt: Date) {
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
        timerLabel.stringValue = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        if !confirmedText.isEmpty || !partialText.isEmpty { setLiveTranscript(confirmed: confirmedText, partial: partialText) }
    }

    private func startPulse() {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.25
        anim.duration = 0.75
        anim.autoreverses = true
        anim.repeatCount = .infinity
        dot.layer?.add(anim, forKey: "pulse")
    }
}

final class FirstMouseButton: NSButton {
    var onClick: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        focusRingType = .none
        applyTitle(title, font: .systemFont(ofSize: 12, weight: .medium))
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updateTitle(_ title: String) {
        applyTitle(title, font: .systemFont(ofSize: 11, weight: .medium))
    }

    func updateTitleFont(size: CGFloat) {
        applyTitle(title, font: .systemFont(ofSize: size, weight: .medium))
    }

    private func applyTitle(_ title: String, font: NSFont) {
        let prominent = title.contains("完成") || title.contains("插入") || title == "Done" || title == "Insert"
        let white = prominent ? NSColor.white : NSColor.white.withAlphaComponent(0.85)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: white,
            .font: font
        ])
    }

    @objc private func fire() { onClick?() }
}

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class RecordingHUD {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSourceToggle: (() -> Void)?

    private let panel: HUDPanel
    private let hudView: HUDView
    private let toast = ToastHUD()
    private var autoHideWork: DispatchWorkItem?

    init() {
        let size = NSSize(width: 506, height: 186)
        hudView = HUDView(frame: NSRect(origin: .zero, size: size))
        panel = HUDPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = hudView
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 关键：透明圆角窗口若开启系统阴影，阴影是矩形，会在四角露出方框
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hudView.onFinish = { [weak self] in self?.onFinish?() }
        hudView.onCancel = { [weak self] in self?.onCancel?() }
        hudView.onSourceToggle = { [weak self] in self?.onSourceToggle?() }
    }

    var frame: CGRect? { panel.isVisible ? panel.frame : nil }

    func setTarget(_ name: String) { hudView.targetName = name }
    func refreshTargetTitle() { hudView.refreshTargetTitle() }
    func setSource(_ name: String) { hudView.setSource(name) }
    func refreshLanguage() { hudView.refreshLanguage() }
    func setLiveTranscript(_ text: String) { hudView.setLiveTranscript(text) }
    func setLiveTranscript(confirmed: String, partial: String) {
        hudView.setLiveTranscript(confirmed: confirmed, partial: partial)
    }

    func show(_ state: HUDView.State, near point: CGPoint? = nil, autoHide: TimeInterval? = nil) {
        autoHideWork?.cancel()
        autoHideWork = nil

        // 完成类提示走小胶囊，不再弹出大 HUD 遮挡背后的内容
        switch state {
        case .inserted(let title, let detail):
            hudView.stopTimer()
            panel.orderOut(nil)
            toast.show(title: title, detail: detail, icon: "checkmark.circle.fill",
                       tint: .systemGreen, at: point ?? NSEvent.mouseLocation)
            return
        case .toast(let title, let detail):
            hudView.stopTimer()
            panel.orderOut(nil)
            toast.show(title: title, detail: detail, icon: "doc.on.clipboard.fill",
                       tint: .systemBlue, at: point ?? NSEvent.mouseLocation)
            return
        default:
            break
        }
        toast.hide()
        hudView.applyAppearance()
        hudView.apply(state)
        if !panel.isVisible {
            position(near: point ?? defaultPoint())
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        if let autoHide {
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.hide() }
            }
            autoHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    func hide() {
        autoHideWork?.cancel()
        autoHideWork = nil
        hudView.stopTimer()
        panel.orderOut(nil)
        toast.hide()
    }

    private func defaultPoint() -> CGPoint {
        if let screen = NSScreen.main {
            return CGPoint(x: screen.frame.midX, y: screen.visibleFrame.midY)
        }
        return CGPoint(x: 400, y: 400)
    }

    private func position(near point: CGPoint) {
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = point.x - size.width / 2
        var y = point.y + 18
        if y + size.height > visible.maxY { y = point.y - size.height - 18 }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - 长按「蓄力环」HUD v6（纯线条 + 先慢后快的缓动）

/// 设计原则：
/// 1) 96pt 画布、38pt 线条环居中，光效不会被方形窗口裁切；
/// 2) 只有线：无填充面、无整体缩放；
/// 3) 所有绘制动画使用 easeIn（先慢、后快，总时长不变）；
/// 4) 蓄满只在线条上辉光脉冲 + 高光扫过。
@MainActor final class HoldRingHUD {
    static let styles = ["声纹", "双弧", "刻度", "电弧"]

    private var panel: NSPanel?
    private var host: CALayer?
    private var progressLayers: [CAShapeLayer] = []
    private var currentStyle = "声纹"
    private var voiceGlowLayer: CAShapeLayer?
    private var voiceMask: CAShapeLayer?
    private var voiceTicker: Timer?
    private var voiceStartTime: CFTimeInterval = 0
    private var voiceDuration: TimeInterval = 0
    private var voiceCenter: CGPoint = .zero
    private var voiceHeights: [CGFloat] = []
    private var voiceRadii: [CGFloat] = []
    private let panelSize: CGFloat = 84
    private let ringRadius: CGFloat = 15.5
    private var ringCenter: CGPoint { CGPoint(x: panelSize / 2, y: panelSize / 2) }
    private var ringPath: CGPath {
        CGPath(ellipseIn: CGRect(x: ringCenter.x - ringRadius,
                                 y: ringCenter.y - ringRadius,
                                 width: ringRadius * 2,
                                 height: ringRadius * 2), transform: nil)
    }

    func show(at point: CGPoint, duration: TimeInterval, style: String) {
        hide()
        currentStyle = style
        let origin = NSPoint(x: point.x + 4, y: point.y - panelSize + 8)
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: panelSize, height: panelSize)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false

        let view = NSView(frame: NSRect(x: 0, y: 0, width: panelSize, height: panelSize))
        view.wantsLayer = true
        view.layer?.masksToBounds = false

        // 内容放进独立图层，整圈缓慢旋转 —— 提供「环动」的感觉
        let content = CALayer()
        content.frame = CGRect(x: 0, y: 0, width: panelSize, height: panelSize)
        view.layer?.addSublayer(content)
        build(style: style, duration: duration, in: content)

        // 声纹是「App 图形」取向：保持静止，靠刻度依次点亮表达进度；其他样式保留环动
        if style != "声纹" {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 0.85
            spin.duration = max(0.12, duration)
            spin.timingFunction = Self.eased
            spin.fillMode = .forwards
            spin.isRemovedOnCompletion = false
            content.add(spin, forKey: "spin")
        }

        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
        self.host = content
    }

    /// 蓄满：只在线条上发光（辉光脉冲 + 高光扫过）。
    func complete() {
        guard let panel, let layer = host else { hide(); return }
        let path = ringPath

        for arc in progressLayers {
            let glow = CABasicAnimation(keyPath: "shadowOpacity")
            glow.fromValue = 0.0
            glow.toValue = 0.95
            glow.duration = 0.10
            glow.autoreverses = true
            glow.repeatCount = 2
            arc.shadowColor = NSColor.white.cgColor
            arc.shadowRadius = 4
            arc.shadowOffset = .zero
            arc.add(glow, forKey: "glow")

            let dim = CABasicAnimation(keyPath: "opacity")
            dim.fromValue = 1.0
            dim.toValue = 0.35
            dim.duration = 0.38
            dim.fillMode = .forwards
            dim.isRemovedOnCompletion = false
            arc.add(dim, forKey: "dim")
        }

        if currentStyle == "声纹" {
            stopVoiceTicker()
            // 声纹：让整圈刻度短暂发亮，而不是整面闪
            if let glow = voiceGlowLayer {
                glow.lineWidth = 4.8
                glow.shadowRadius = 8
                glow.shadowOpacity = 1.0
                let flash = CAKeyframeAnimation(keyPath: "opacity")
                flash.values = [0.0, 1.0, 0.92, 0.0]
                flash.keyTimes = [0.0, 0.22, 0.58, 1.0]
                flash.duration = 0.46
                glow.add(flash, forKey: "flash")
                glow.opacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) { [weak self] in
                self?.hide()
            }
            return
        }

        let highlight = CAShapeLayer()
        highlight.path = path
        highlight.fillColor = NSColor.clear.cgColor
        highlight.strokeColor = NSColor.white.cgColor
        highlight.lineWidth = 3.0
        highlight.lineCap = .round
        highlight.strokeStart = 0
        highlight.strokeEnd = 0.14
        highlight.opacity = 0
        layer.addSublayer(highlight)

        let sweepStart = CABasicAnimation(keyPath: "strokeStart")
        sweepStart.fromValue = 0.0
        sweepStart.toValue = 0.86
        sweepStart.duration = 0.30
        sweepStart.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let sweepEnd = CABasicAnimation(keyPath: "strokeEnd")
        sweepEnd.fromValue = 0.14
        sweepEnd.toValue = 1.0
        sweepEnd.duration = 0.30
        sweepEnd.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [0.0, 1.0, 0.9, 0.0]
        flash.keyTimes = [0.0, 0.25, 0.6, 1.0]
        flash.duration = 0.40
        highlight.add(sweepStart, forKey: "sweepStart")
        highlight.add(sweepEnd, forKey: "sweepEnd")
        highlight.add(flash, forKey: "flash")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                panel.animator().alphaValue = 0
            }) {
                MainActor.assumeIsolated { self.hide() }
            }
        }
    }

    func hide() {
        stopVoiceTicker()
        panel?.orderOut(nil)
        panel = nil
        host = nil
        progressLayers.removeAll()
        voiceGlowLayer = nil
    }

    // MARK: - 绘制

    /// 先慢后快：easeIn 曲线
    private static let eased = CAMediaTimingFunction(name: .easeIn)

    private func build(style: String, duration: TimeInterval, in layer: CALayer) {
        let path = ringPath
        progressLayers = []

        // 极细轨道（线，不是面）；声纹不需要轨道，否则背景会多出一圈细线
        if style != "声纹" {
            let track = CAShapeLayer()
            track.path = path
            track.fillColor = NSColor.clear.cgColor
            track.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
            track.lineWidth = 1
            layer.addSublayer(track)
        }

        switch style {
        case "声纹":
            buildVoiceprint(center: ringCenter, duration: duration, layer: layer)
        case "双弧":
            buildTwin(center: ringCenter, path: path, duration: duration, layer: layer)
        case "刻度":
            buildTicks(center: ringCenter, duration: duration, layer: layer)
        case "电弧":
            buildElectric(center: ringCenter, duration: duration, layer: layer)
        default:
            buildEdge(center: ringCenter, path: path, duration: duration, layer: layer)
        }
    }

    /// 声纹：12 根长短不一的刻度共用一条「蓝→青」连续渐变；
    /// 蓄力过程中每根刻度独立伸缩，配合沿环渐次点亮的色彩填充。
    private func buildVoiceprint(center: CGPoint, duration: TimeInterval, layer: CALayer) {
        // 与 App 图标方案 06 同一组长短节奏
        let heights: [CGFloat] = [0.38, 0.95, 0.52, 0.78, 0.34, 1.0, 0.45, 0.86, 0.32, 0.72, 0.55, 0.92]
        let radii: [CGFloat] = [12.9, 12.4, 13.1, 12.6, 12.9, 12.3, 13.3, 12.7, 12.9, 12.4, 13.1, 12.7]
        voiceCenter = center
        voiceHeights = heights
        voiceRadii = radii
        voiceDuration = max(0.12, duration)
        voiceStartTime = CACurrentMediaTime()

        // 一条连续的 conic 渐变，覆盖整圈；颜色只有干净的蓝与青
        let gradient = CAGradientLayer()
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1.0, y: 0.5)
        gradient.colors = [
            NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor,
            NSColor.systemCyan.withAlphaComponent(0.92).cgColor,
            NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
        ]
        gradient.locations = [0, 0.5, 1]
        gradient.frame = CGRect(x: 0, y: 0, width: panelSize, height: panelSize)

        let mask = CAShapeLayer()
        mask.fillColor = NSColor.clear.cgColor
        mask.strokeColor = NSColor.white.cgColor
        mask.lineWidth = 3.4
        mask.lineCap = .round
        gradient.mask = mask
        layer.addSublayer(gradient)
        voiceMask = mask

        // 蓄满时用于"整圈刻度发亮"的白色覆盖层
        let glow = CAShapeLayer()
        glow.fillColor = NSColor.clear.cgColor
        glow.strokeColor = NSColor.white.cgColor
        glow.lineWidth = 3.0
        glow.lineCap = .round
        glow.opacity = 0
        glow.shadowColor = NSColor.white.cgColor
        glow.shadowRadius = 4
        glow.shadowOpacity = 0.65
        glow.shadowOffset = .zero
        layer.addSublayer(glow)
        voiceGlowLayer = glow

        // 中心焦点
        let dot = CALayer()
        dot.frame = CGRect(x: center.x - 1.9, y: center.y - 1.9, width: 3.8, height: 3.8)
        dot.cornerRadius = 1.9
        dot.backgroundColor = NSColor.white.cgColor
        dot.shadowColor = NSColor.white.cgColor
        dot.shadowOpacity = 0.55
        dot.shadowRadius = 4
        dot.shadowOffset = .zero
        layer.addSublayer(dot)
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.85
        pulse.toValue = 1.25
        pulse.duration = 0.5
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.add(pulse, forKey: "pulse")

        updateVoiceprintPath(progress: 0, elapsed: 0, settle: false)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickVoiceprint() }
        }
        RunLoop.main.add(timer, forMode: .common)
        voiceTicker = timer
    }

    private func stopVoiceTicker() {
        voiceTicker?.invalidate()
        voiceTicker = nil
    }

    private func tickVoiceprint() {
        guard voiceTicker != nil else { return }
        let elapsed = CACurrentMediaTime() - voiceStartTime
        let progress = min(1, elapsed / max(0.1, voiceDuration))
        updateVoiceprintPath(progress: progress, elapsed: elapsed, settle: false)
        if progress >= 1 {
            stopVoiceTicker()
            updateVoiceprintPath(progress: 1, elapsed: voiceDuration, settle: true)
        }
    }

    private func updateVoiceprintPath(progress: Double, elapsed: TimeInterval, settle: Bool) {
        guard let mask = voiceMask, voiceHeights.count == voiceRadii.count else { return }
        let count = voiceHeights.count
        let eased = pow(progress, 1.18)
        let path = CGMutablePath()
        for index in 0..<count {
            let threshold = Double(index) / Double(count)
            if eased + 0.08 < threshold { continue }
            let grow = 0.52 + 0.48 * eased
            let wave = settle ? 1.0 : 1.0 + 0.30 * sin(elapsed * 19.0 + Double(index) * 1.7) * (1.0 - 0.35 * eased)
            let r0 = voiceRadii[index] + (settle ? 0 : CGFloat(sin(elapsed * 12 + Double(index)))) * 0.35
            let length = max(1.5, voiceHeights[index] * 5.2 * grow * wave)
            let angle = Double(index) / Double(count) * 2 * .pi - .pi / 2
            let start = CGPoint(x: voiceCenter.x + CGFloat(cos(angle)) * r0,
                                y: voiceCenter.y + CGFloat(sin(angle)) * r0)
            let end = CGPoint(x: voiceCenter.x + CGFloat(cos(angle)) * (r0 + length),
                              y: voiceCenter.y + CGFloat(sin(angle)) * (r0 + length))
            path.move(to: start)
            path.addLine(to: end)
        }
        mask.path = path
        voiceGlowLayer?.path = path
    }

    private func drawAnimation(duration: TimeInterval, from: CGFloat = 0, to: CGFloat = 1) -> CABasicAnimation {
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = from
        draw.toValue = to
        draw.duration = max(0.12, duration)
        draw.timingFunction = Self.eased
        return draw
    }

    /// 锋线：单色线 + 白色前端高光段，先慢后快
    private func buildEdge(center: CGPoint, path: CGPath, duration: TimeInterval, layer: CALayer) {
        let arc = CAShapeLayer()
        arc.path = path
        arc.fillColor = NSColor.clear.cgColor
        arc.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
        arc.lineWidth = 1.5
        arc.lineCap = .round
        arc.strokeEnd = 0
        layer.addSublayer(arc)
        progressLayers.append(arc)
        arc.add(drawAnimation(duration: duration), forKey: "draw")
        arc.strokeEnd = 1

        let tip = CAShapeLayer()
        tip.path = path
        tip.fillColor = NSColor.clear.cgColor
        tip.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        tip.lineWidth = 1.5
        tip.lineCap = .round
        tip.strokeStart = 0
        tip.strokeEnd = 0.045
        tip.opacity = 0.9
        layer.addSublayer(tip)
        progressLayers.append(tip)

        let tipDraw = CABasicAnimation(keyPath: "strokeStart")
        tipDraw.fromValue = 0
        tipDraw.toValue = 0.955
        tipDraw.duration = max(0.12, duration)
        tipDraw.timingFunction = Self.eased
        tip.add(tipDraw, forKey: "tip")
    }

    /// 双弧：外弧顺时针 + 内弧逆时针，两条线先慢后快同时画
    private func buildTwin(center: CGPoint, path: CGPath, duration: TimeInterval, layer: CALayer) {
        let outer = CAShapeLayer()
        outer.path = path
        outer.fillColor = NSColor.clear.cgColor
        outer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        outer.lineWidth = 1.5
        outer.lineCap = .round
        outer.strokeEnd = 0
        layer.addSublayer(outer)
        progressLayers.append(outer)
        outer.add(drawAnimation(duration: duration), forKey: "draw")
        outer.strokeEnd = 1

        let innerRadius = ringRadius - 3.6
        let inner = CAShapeLayer()
        inner.path = CGPath(ellipseIn: CGRect(x: center.x - innerRadius, y: center.y - innerRadius,
                                              width: innerRadius * 2, height: innerRadius * 2), transform: nil)
        inner.fillColor = NSColor.clear.cgColor
        inner.strokeColor = NSColor.systemCyan.withAlphaComponent(0.6).cgColor
        inner.lineWidth = 0.95
        inner.lineCap = .round
        inner.strokeEnd = 0
        layer.addSublayer(inner)
        progressLayers.append(inner)
        inner.add(drawAnimation(duration: duration), forKey: "draw")
        inner.strokeEnd = 1
        inner.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -panelSize, y: 0))
    }

    /// 刻度：24 条短径向线依次点亮；点亮时刻按 easeIn 反解，最后一段明显加速
    private func buildTicks(center: CGPoint, duration: TimeInterval, layer: CALayer) {
        let tickCount = 24
        for index in 0..<tickCount {
            let angle = Double(index) / Double(tickCount) * 2 * .pi - .pi / 2
            let inner = ringRadius - 2.8
            let outer = ringRadius + 1.9
            let path = CGMutablePath()
            path.move(to: CGPoint(x: center.x + CGFloat(cos(angle)) * inner,
                                  y: center.y + CGFloat(sin(angle)) * inner))
            path.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle)) * outer,
                                     y: center.y + CGFloat(sin(angle)) * outer))
            let tick = CAShapeLayer()
            tick.path = path
            tick.strokeColor = NSColor.controlAccentColor.cgColor
            tick.lineWidth = 1.4
            tick.lineCap = .round
            tick.opacity = 0.10
            layer.addSublayer(tick)
            progressLayers.append(tick)

            // easeIn 反解：进度 p 在 t 时刻的近似 → 后面更密（先慢后快）
            let progress = Double(index) / Double(tickCount)
            let easedTime = pow(progress, 1.7)
            let light = CABasicAnimation(keyPath: "opacity")
            light.fromValue = 0.10
            light.toValue = 1.0
            light.duration = 0.07
            light.beginTime = CACurrentMediaTime() + max(0.01, duration * easedTime)
            light.fillMode = .forwards
            light.isRemovedOnCompletion = false
            tick.add(light, forKey: "light")
        }
    }

    /// 电弧：带轻微抖动的线，不规则但有速度感
    private func buildElectric(center: CGPoint, duration: TimeInterval, layer: CALayer) {
        let points = 96
        let path = CGMutablePath()
        for index in 0...points {
            let angle = -Double.pi / 2 + Double(index) / Double(points) * 2 * .pi
            let jitter = Double.random(in: -0.9...0.9) + sin(angle * 9) * 0.55
            let radius = ringRadius + jitter
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * radius,
                                y: center.y + CGFloat(sin(angle)) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }

        let arc = CAShapeLayer()
        arc.path = path
        arc.fillColor = NSColor.clear.cgColor
        arc.strokeColor = NSColor.systemTeal.withAlphaComponent(0.95).cgColor
        arc.lineWidth = 1.1
        arc.lineCap = .round
        arc.lineJoin = .round
        arc.strokeEnd = 0
        layer.addSublayer(arc)
        progressLayers.append(arc)
        arc.add(drawAnimation(duration: duration), forKey: "draw")
        arc.strokeEnd = 1

        let flicker = CAKeyframeAnimation(keyPath: "opacity")
        flicker.values = [0.7, 1.0, 0.8, 1.0, 0.85, 1.0]
        flicker.keyTimes = [0, 0.2, 0.35, 0.55, 0.75, 1.0]
        flicker.duration = max(0.2, duration)
        flicker.repeatCount = .infinity
        arc.add(flicker, forKey: "flicker")
    }

}

// MARK: - 浮层外观预览（设置页用）

@MainActor enum OverlayPreview {
    static var keeper: RecordingHUD?

    private static func anchor() -> CGPoint {
        let screen = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: screen.midX, y: screen.midY)
    }

    static func showHUD() {
        let hud = RecordingHUD()
        hud.setTarget("备忘录")
        hud.show(.recording(startedAt: Date()), near: anchor())
        hud.setLiveTranscript(confirmed: "今天下午三点开会，", partial: "记得带上项目文档")
        keeper = hud
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { hud.hide() }
    }

    static func showToast() {
        let hud = RecordingHUD()
        hud.show(.inserted(title: "已插入", detail: "⌘V 可再用"), near: anchor())
        keeper = hud
    }
}

// MARK: - 蓄力环预览（设置页用）

@MainActor enum RingPreview {
    static var keeper: HoldRingHUD?

    static func show(style: String) {
        let screen = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let ring = HoldRingHUD()
        keeper = ring
        ring.show(at: CGPoint(x: screen.midX, y: screen.midY), duration: 1.1, style: style)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            ring.complete()
        }
    }
}

// MARK: - 轻量结果提示（Liquid Glass 胶囊，单行、少层级）

/// 像系统原生 HUD：一枚胶囊，左边一个小对勾，右边一行字（主文案 + 次要提示）。
/// 不使用图标方块、不画进度线，界面层级尽量少。
@MainActor final class ToastHUD {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(title: String, detail: String, icon: String, tint: NSColor, at point: CGPoint) {
        hide()
        let height: CGFloat = 36
        let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let detailFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        let titleSize = (title as NSString).size(withAttributes: [.font: titleFont])
        let detailSize = detail.isEmpty ? .zero : (detail as NSString).size(withAttributes: [.font: detailFont])
        let separator = "   ·   "
        let separatorWidth: CGFloat = detail.isEmpty ? 0 : (separator as NSString).size(withAttributes: [.font: detailFont]).width
        let iconSide: CGFloat = 13
        let leading: CGFloat = 14
        let gap: CGFloat = 8
        let trailing: CGFloat = 18
        let needed = leading + iconSide + gap + titleSize.width + separatorWidth + detailSize.width + trailing
        let width = min(400, max(112, ceil(needed) + 10))

        let margin: CGFloat = 12
        let panelW = width + margin * 2
        let panelH = height + margin * 2

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: panelW, height: panelH)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))
        container.wantsLayer = true

        // 卡片（仅用于圆角阴影）；内容放在 clip 里做胶囊裁切
        let card = NSView(frame: NSRect(x: margin, y: margin, width: width, height: height))
        card.wantsLayer = true
        card.layer?.cornerRadius = height / 2
        card.layer?.masksToBounds = false
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = Float(max(0, min(1, Preferences.shared.overlayShadowStrength)) * 0.40)
        card.layer?.shadowRadius = 14
        card.layer?.shadowOffset = CGSize(width: 0, height: -2)
        card.layer?.shadowPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                                        cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
        container.addSubview(card)

        let clip = NSView(frame: card.bounds)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = height / 2
        clip.layer?.masksToBounds = true
        card.addSubview(clip)

        // 胶囊玻璃：只有一层材质 + 一点顶部高光
        let capsule = GlassBackgroundFactory.make(cornerRadius: height / 2, liquid: Preferences.shared.overlayLiquidGlass)
        capsule.frame = clip.bounds
        capsule.autoresizingMask = [.width, .height]
        capsule.wantsLayer = true
        clip.addSubview(capsule)

        let veil = CALayer()
        veil.frame = clip.bounds
        veil.cornerRadius = height / 2
        veil.masksToBounds = true
        veil.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.06 + 0.30 * max(0, min(1, Preferences.shared.overlayGlassIntensity))).cgColor
        clip.layer?.addSublayer(veil)

        let sheen = CAGradientLayer()
        sheen.colors = [NSColor.white.withAlphaComponent(0.16).cgColor, NSColor.clear.cgColor]
        sheen.startPoint = CGPoint(x: 0.5, y: 1.0)
        sheen.endPoint = CGPoint(x: 0.5, y: 0.0)
        sheen.frame = clip.bounds
        sheen.cornerRadius = height / 2
        sheen.masksToBounds = true
        clip.layer?.addSublayer(sheen)

        // 单色小对勾（不再做圆形/方形底座）
        let iconView = NSImageView(frame: NSRect(x: leading,
                                                 y: (height - iconSide) / 2,
                                                 width: iconSide, height: iconSide))
        iconView.imageScaling = .scaleProportionallyDown
        iconView.imageAlignment = .alignCenter
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        iconView.contentTintColor = tint
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        clip.addSubview(iconView)

        // 一行文字：主文案 + 次要提示（用透明度区分层级）
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: titleFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.96)
        ])
        if !detail.isEmpty {
            text.append(NSAttributedString(string: "   ·   ", attributes: [
                .font: detailFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.30)
            ]))
            text.append(NSAttributedString(string: detail, attributes: [
                .font: detailFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.58)
            ]))
        }
        label.attributedStringValue = text
        let textX = leading + iconSide + gap
        label.frame = NSRect(x: textX, y: (height - 17) / 2, width: width - textX - 10, height: 17)
        clip.addSubview(label)

        panel.contentView = container
        position(panel: panel, size: NSSize(width: panelW, height: panelH), near: point)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        // 轻微上浮 + 淡入（胶囊整体动，不叠额外装饰）
        container.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        container.layer?.position = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
        let rise = CASpringAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 5
        rise.toValue = 0
        rise.damping = 20
        rise.duration = 0.26
        container.layer?.add(rise, forKey: "rise")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.20
                    panel.animator().alphaValue = 0
                }) {
                    MainActor.assumeIsolated {
                        panel.orderOut(nil)
                        if self.panel === panel { self.panel = nil }
                    }
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func position(panel: NSPanel, size: NSSize, near point: CGPoint) {
        let anchor = NSEvent.mouseLocation == .zero ? point : NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchor.x - size.width / 2
        var y = anchor.y + 22
        if y + size.height > visible.maxY { y = anchor.y - size.height - 22 }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - 长按 / ⌥+单击 触发中枢

@MainActor final class MouseHoldWatcher {
    private var monitor: Any?
    private var downPoint: CGPoint?
    private var holdWork: DispatchWorkItem?
    private var armWork: DispatchWorkItem?
    private var probeGeneration = 0
    private var probeVerdict: InputVerdict?
    private var completeWork: DispatchWorkItem?
    private var ringDidComplete = false
    private var enabled = true
    private let moveTolerance: CGFloat = 5
    private let ring = HoldRingHUD()

    /// 蓄力时长：默认 0.6s（旧版固定 1.2s，过长导致「笨重」体感）。
    var holdDelay: TimeInterval = 0.6
    var optionClickEnabled = true
    /// true 时只在明确可编辑控件上触发；false 时窗口内容区也可触发（更不容易「没反应」）。
    var requireTextTarget = false

    var onHold: ((CGPoint) -> Void)?
    var onOptionClick: ((CGPoint) -> Void)?
    var isPointInsideHUD: ((CGPoint) -> Bool)?

    func start() {
        // 全局鼠标监听回调运行在主线程；这里同步处理，保证 down/up 处理顺序绝不颠倒，
        // 也避免旧版每个事件都 Task 跳一次 MainActor 造成的状态竞态。
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
            let type = event.type
            let point = NSEvent.mouseLocation
            let flags = event.modifierFlags
            MainActor.assumeIsolated {
                self?.handle(type: type, point: point, flags: flags)
            }
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value { cancelPending() }
    }

    func refreshSettings() {
        let p = Preferences.shared
        holdDelay = min(max(p.holdToTalkDelay, 0.25), 2.0)
        optionClickEnabled = p.optionClickTrigger
        requireTextTarget = p.requireEditableTarget
        setEnabled(p.holdToTalkEnabled)
    }

    private func handle(type: NSEvent.EventType, point: CGPoint, flags: NSEvent.ModifierFlags) {
        switch type {
        case .leftMouseDown:
            guard enabled else { return }
            if isPointInsideHUD?(point) == true { return }
            guard NSScreen.screens.contains(where: { $0.frame.contains(point) }) else { return }
            cancelPending()
            downPoint = point
            ringDidComplete = false
            startTargetProbe(point: point, cursorIsIBeam: NSCursor.current == .iBeam)

            // ⌥ + 单击：明确意图，立即触发（无需长按）
            if optionClickEnabled, flags.contains(.option) {
                if let hit = AX.element(atAppKitPoint: point),
                   InputDetector.verdict(atAppKitPoint: point, hit: hit) == .editable {
                    downPoint = nil
                    onOptionClick?(point)
                }
                return
            }

            // 50ms 后显示蓄力环（更早出现，绘制时长正好贴合 0.6s 的触发时间）
            let arm = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.downPoint != nil else { return }
                    self.ring.show(
                        at: point,
                        duration: max(0.18, self.holdDelay * 0.60),
                        style: Preferences.shared.ringStyle
                    )
                }
            }
            armWork = arm
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: arm)

            // 0.6s 阈值之前就把高亮打出来，用户松手时能看到完整蓄满效果
            let complete = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.downPoint != nil,
                          NSEvent.pressedMouseButtons & 0x1 != 0 else { return }
                    if self.requireTextTarget, self.probeVerdict != .editable { return }
                    self.ringDidComplete = true
                    self.ring.complete()
                }
            }
            completeWork = complete
            DispatchQueue.main.asyncAfter(
                deadline: .now() + max(0.15, holdDelay - 0.12),
                execute: complete
            )

            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.checkHold() }
            }
            holdWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)

        case .leftMouseDragged:
            if let start = downPoint, hypot(point.x - start.x, point.y - start.y) > moveTolerance {
                cancelPending()
            }

        case .leftMouseUp:
            cancelPending()

        default:
            break
        }
    }

    private func checkHold() {
        guard enabled, let start = downPoint else { return }
        downPoint = nil
        holdWork = nil
        armWork?.cancel()
        armWork = nil

        // 关键修复：确认鼠标仍然按住。旧版在「按下/松开事件乱序」时会在松手后凭空开始录音。
        guard NSEvent.pressedMouseButtons & 0x1 != 0 else { return }

        let current = NSEvent.mouseLocation
        guard hypot(current.x - start.x, current.y - start.y) <= moveTolerance else { return }

        // 落点判定在后台线程完成（带 AX 超时），这里只读缓存结果：
        // 只有明确命中标题栏/按钮/桌面才放弃；AX 超时或未知一律放行（旧版在这里静默失败）。
        if let verdict = probeVerdict {
            if verdict == .blocked {
                completeWork?.cancel(); completeWork = nil
                ring.hide()
                return
            }
            if requireTextTarget, verdict != .editable {
                completeWork?.cancel(); completeWork = nil
                ring.hide()
                return
            }
        }

        if !ringDidComplete {
            ringDidComplete = true
            ring.complete()
        }
        onHold?(start)
    }

    /// 按下鼠标时立刻在后台探测落点（不阻塞主线程），到 0.6s 触发时结果通常已就绪。
    private func startTargetProbe(point: CGPoint, cursorIsIBeam: Bool) {
        // 未开启「只在文本输入框触发」时完全不探测：
        // 避免多余的 AX/AppleScript 工作，也避免历史版本弹自动化授权。
        guard requireTextTarget else {
            probeGeneration += 1
            probeVerdict = nil
            return
        }
        probeGeneration += 1
        let generation = probeGeneration
        probeVerdict = nil

        func runProbe() {
            DispatchQueue.global(qos: .userInteractive).async {
                let verdict = InputDetector.probe(atAppKitPoint: point, cursorIsIBeam: cursorIsIBeam)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.probeGeneration == generation else { return }
                        self.probeVerdict = verdict
                    }
                }
            }
        }

        runProbe()
        // mouseDown 瞬间焦点可能还停在旧元素（网页/画布）；等点击生效后再探测一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, self.probeGeneration == generation, self.downPoint != nil else { return }
            runProbe()
        }
    }

    private func cancelPending() {
        holdWork?.cancel()
        holdWork = nil
        armWork?.cancel()
        armWork = nil
        completeWork?.cancel()
        completeWork = nil
        downPoint = nil
        ring.hide()
    }
}

// MARK: - 全局快捷键 Option + Space

enum HotkeySpec {
    static let keyNames: [UInt16: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc",
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    static func name(for keyCode: UInt16) -> String? { keyNames[keyCode] }

    static func code(for name: String) -> UInt16? {
        keyNames.first(where: { $0.value == name })?.key
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    static func display(name: String, flags: NSEvent.ModifierFlags) -> String {
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out + name
    }

    static func parse(_ raw: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        let symbols: [(Character, Int)] = [("⌃", controlKey), ("⌥", optionKey), ("⇧", shiftKey), ("⌘", cmdKey)]
        var mods = 0
        for (symbol, carbon) in symbols where raw.contains(symbol) { mods |= carbon }
        let name = raw.filter { !"⌃⌥⇧⌘".contains($0) }
        guard let code = code(for: name) else { return nil }
        return (UInt32(code), UInt32(mods))
    }

    /// 常见系统/桌面快捷键提醒（不做硬拦截，允许用户坚持使用）。
    static func conflict(_ raw: String) -> String? {
        let key = raw.filter { !"⌃⌥⇧⌘".contains($0) }
        let mods = Set(raw.filter { "⌃⌥⇧⌘".contains($0) })
        if key == "Space", mods == ["⌘"] { return "与系统 Spotlight（⌘Space）冲突" }
        if key == "Space", mods == ["⌃"] { return "与系统输入法切换（⌃Space）冲突" }
        if key == "Space", mods == ["⌥"] { return "与 Codex 桌面宠物的 ⌥Space 冲突，建议加一个 ⌃" }
        if key == "Tab", mods == ["⌘"] { return "与系统应用切换（⌘Tab）冲突" }
        if key == "Q", mods == ["⌘"] { return "与系统退出应用（⌘Q）冲突" }
        if key == "W", mods == ["⌘"] { return "与系统关闭窗口（⌘W）冲突" }
        return nil
    }}

@MainActor final class Hotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    var handler: (() -> Void)?

    func install() -> Bool {
        if hotKeyRef != nil { return true }

        let ref = Unmanaged.passUnretained(self).toOpaque()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handlerCallback: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            let owner = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { owner.handler?() }
            return noErr
        }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handlerCallback,
            1,
            &eventType,
            ref,
            &eventHandler
        )
        guard installStatus == noErr else { return false }

        let parsed = HotkeySpec.parse(Preferences.shared.hotkeyStyle) ?? (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        let hotKeyID = EventHotKeyID(signature: OSType(0x4656), id: 1)
        let regStatus = RegisterEventHotKey(
            parsed.keyCode,
            parsed.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return regStatus == noErr
    }

    func uninstall() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}

// MARK: - Recording Controller

@MainActor final class Controller: ObservableObject {
    struct PendingInsert {
        let insertion: TextInsertion
        let text: String
        let note: String
    }

    @Published var status = "就绪 · 长按左键 0.6 秒，或按 \(Preferences.shared.hotkeyStyle)"
    @Published var busy = false
    @Published var recording = false
    @Published private(set) var startedAt: Date?

    private let recorder = UnifiedRecorder()
    private let hud = RecordingHUD()
    private let senseVoice = SenseVoiceEngine()
    private var senseVoiceActive = false
    private var target: TextInsertion?
    private var clipboardOnly = false
    private var streamRecognizer: TencentStreamRecognizer?
    private var liveText = ""
    private var liveConfirmed = ""
    private var livePrefix = ""
    private var sessionID = UUID()
    private var runningTask: Task<Void, Never>?
    private var capTask: Task<Void, Never>?
    private var escMonitor: Any?
    private var lastAnchor: CGPoint = .zero
    private var pending: PendingInsert?
    private(set) var historyItems: [FVHistory] = []
    private var heardSpeech = false
    private var lastLoudAt: Date?
    private var targetTask: Task<Void, Never>?

    init() {
        hud.onFinish = { [weak self] in self?.finish() }
        hud.onCancel = { [weak self] in self?.cancel() }
        hud.onSourceToggle = { [weak self] in self?.toggleSource() }
        senseVoice.onUpdate = { [weak self] confirmed, partial in
            guard let self else { return }
            // 个别分段边界会短暂回传空 confirmed；保留上一段已定稿文字，避免 HUD 整段消失
            if !confirmed.isEmpty { self.liveConfirmed = confirmed }
            var displayConfirmed = confirmed.isEmpty ? self.liveConfirmed : confirmed
            if !self.livePrefix.isEmpty,
               !displayConfirmed.contains(String(self.livePrefix.suffix(20))) {
                displayConfirmed = self.livePrefix + displayConfirmed
            }
            self.liveText = (displayConfirmed + partial).trimmingCharacters(in: .whitespacesAndNewlines)
            self.hud.setLiveTranscript(confirmed: displayConfirmed, partial: partial)
        }
        if Preferences.shared.speechEngine == "SenseVoice 本地",
           Preferences.shared.warmUpSenseVoice, FVSenseVoiceAssets.isAvailable {
            Task { @MainActor [weak self] in await self?.senseVoice.warmUp() }
        }
    }

    var hudFrame: CGRect? { hud.frame }
    var isSenseVoiceReady: Bool { SenseVoiceEngine.isAvailable }

    func clearHistory() { historyItems.removeAll() }

    func refreshLanguage() {
        hud.refreshLanguage()
    }

    func toggle(at point: CGPoint? = nil) {
        if recording { finish(); return }
        guard !busy else { return }
        start(at: point ?? HUDAnchor.currentPoint())
    }

    func start(at point: CGPoint) {
        guard !recording, !busy else { return }
        guard AXIsProcessTrusted() else {
            status = "需要辅助功能权限，请在设置中授权"
            hud.show(.error("需要辅助功能权限，请前往设置开启"), near: point, autoHide: 4)
            return
        }

        let prefs = Preferences.shared
        let id = UUID()
        sessionID = id
        lastAnchor = point
        pending = nil
        liveText = ""
        liveConfirmed = ""
        livePrefix = ""
        heardSpeech = false
        lastLoudAt = nil
        busy = true
        target = nil
        clipboardOnly = false

        // 目标输入框在后台异步解析（AX 带 0.25s 超时），录音启动不再等 AX，
        // 这是「长按必定有反应」的关键：解析失败也会先录音，结束再走剪贴板兜底。
        hud.setTarget("")
        status = "正在准备录音…"
        hud.show(.preparing, near: point, autoHide: 8)
        targetTask?.cancel()
        targetTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let insertion = await TextInsertion.capture(at: point)
            guard self.sessionID == id else { return }
            FVDebug.log("target app=\(insertion.appName ?? "nil") editable=\(insertion.isEditableTarget) point=\(Int(point.x)),\(Int(point.y))")
            self.target = insertion
            self.clipboardOnly = !insertion.isEditableTarget
            self.hud.setTarget(insertion.appName ?? (self.clipboardOnly ? "剪贴板" : ""))
            self.hud.refreshTargetTitle()
            if Preferences.shared.requireEditableTarget, !insertion.isEditableTarget {
                self.status = "这里不是输入框"
                self.hud.show(.error("这里不是输入框 · 请在文本框内长按"), autoHide: 1.8)
                self.cancel()
            }
        }

        let source = AudioSource(rawValue: prefs.audioSource) ?? .mic
        Task { @MainActor in
            if source == .mic {
                let granted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                    AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
                }
                guard self.sessionID == id else { return }
                guard granted else {
                    self.target = nil
                    self.busy = false
                    self.status = "需要麦克风权限"
                    self.hud.show(.error("需要麦克风权限"), autoHide: 4)
                    return
                }
            }

            let engine = prefs.speechEngine
            let useSenseVoice = engine == "SenseVoice 本地" && SenseVoiceEngine.isAvailable
            if useSenseVoice {
                self.status = "正在准备 SenseVoice 模型…"
                await self.senseVoice.warmUp()
                guard self.sessionID == id else { return }
                self.senseVoice.begin(language: Self.senseVoiceLanguage(prefs.language))
                self.recorder.onPCMData = { [weak self] pcm in
                    guard let self else { return }
                    self.senseVoice.push(pcm)
                    self.trackSilence(pcm)
                }
                self.senseVoiceActive = true
            }

            do {
                try await self.recorder.start(source: source)
                guard self.sessionID == id else {
                    // 新会话已经接管同一个 recorder，这里绝不能 cancel（否则会停掉新录音）
                    return
                }
                let now = Date()
                self.startedAt = now
                self.recording = true
                self.busy = false
                self.liveText = ""

                if engine != "SenseVoice 本地" && engine != "腾讯云 ASR" {
                    // API 等无流式能力的引擎：至少保证自动结束能工作
                    self.recorder.onPCMData = { [weak self] pcm in
                        self?.trackSilence(pcm)
                    }
                }

                // 腾讯云实时流式（保留旧引擎能力）
                if engine == "腾讯云 ASR", !prefs.tencentAppId.isEmpty, !prefs.tencentSecretId.isEmpty {
                    let sr = TencentStreamRecognizer()
                    sr.onLiveText = { [weak self] live in
                        self?.liveText = live
                        self?.hud.setLiveTranscript(live)
                    }
                    sr.onError = { err in NSLog("FocusVoice: Tencent stream error: %@", err) }
                    do {
                        try sr.start(
                            appId: prefs.tencentAppId,
                            secretId: prefs.tencentSecretId,
                            secretKey: prefs.tencentSecretKey,
                            engine: prefs.tencentEngineType
                        )
                        self.streamRecognizer = sr
                        self.recorder.onPCMData = { [weak self] pcm in
                            self?.streamRecognizer?.sendPCMChunk(pcm)
                            self?.trackSilence(pcm)
                        }
                    } catch {
                        NSLog("FocusVoice: Tencent stream init failed, fallback: %@", error.localizedDescription)
                        self.streamRecognizer = nil
                        self.recorder.onPCMData = { [weak self] pcm in
                            self?.trackSilence(pcm)
                        }
                    }
                }

                // 开始录音音效必须走用户选择的音色（此前残留的系统 Tink 会盖掉设置）
                SoundFeedback.shared.play(.start)
                self.status = self.clipboardOnly ? "正在聆听 · 完成后复制到剪贴板" : "正在聆听 · 点击完成插入"
                self.hud.setSource(source.shortLabel)
                self.hud.show(.recording(startedAt: now))
                self.installEscMonitor()
                self.scheduleCap()
            } catch {
                guard self.sessionID == id else { return }
                self.senseVoiceActive = false
                self.senseVoice.cancel()
                self.target = nil
                self.busy = false
                self.status = "录音失败：\(error.localizedDescription)"
                self.hud.show(.error(error.localizedDescription), autoHide: 4.5)
            }
        }
    }

    func toggleSource() {
        guard recording else { return }
        status = "正在切换录音来源…"
        Task { @MainActor in
            do {
                let next = try await recorder.switchSource()
                livePrefix = liveText
                hud.setSource(next.shortLabel)
                if !liveText.isEmpty {
                    hud.setLiveTranscript(confirmed: liveText, partial: "")
                }
                status = next == .system ? "已切换为内录（系统声音）" : "已切换为外录（MacBook Pro 麦克风）"
            } catch {
                hud.setSource(recorder.currentSource.shortLabel)
                status = "切换失败：\(error.localizedDescription)"
            }
        }
    }

    func finish() {
        guard recording else { return }
        recording = false
        removeEscMonitor()
        capTask?.cancel()
        capTask = nil
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil

        let liveSnapshot = liveText
        let activeStream = streamRecognizer
        streamRecognizer = nil
        recorder.onPCMData = nil
        let useSenseVoice = senseVoiceActive
        senseVoiceActive = false

        busy = true
        status = "正在整理文字…"
        // 用户要求：点完成后不要跳到「转录中」大面板，直接收尾并插入
        hud.hide()

        guard let file = recorder.stop() else {
            busy = false
            status = "没有录音内容"
            hud.show(.error("没有录音内容"), autoHide: 2)
            return
        }
        if duration < 0.4 {
            busy = false
            try? FileManager.default.removeItem(at: file)
            target = nil
            status = "录音太短 · 长按左键 0.6 秒重新录音"
            hud.show(.error("录音太短"), autoHide: 2)
            return
        }
        let knownTarget = target
        target = nil
        targetTask?.cancel()
        targetTask = nil
        clipboardOnly = false

        let id = sessionID
        runningTask = Task { @MainActor in
            defer {
                try? FileManager.default.removeItem(at: file)
                self.busy = false
            }
            do {
                let prefs = Preferences.shared
                var output = ""

                if let activeStream {
                    self.status = "正在完成实时转录…"
                    let streamed = await activeStream.finish()
                    output = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                if useSenseVoice {
                    let sv = (await self.senseVoice.finish()).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sv.isEmpty { output = sv }
                }

                if output.isEmpty {
                    let transcript = try await Recognizer.recognize(file, preferences: prefs)
                    output = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                // 去掉句尾 yeah/Okay 等幻觉词与重复标点（SenseVoice 尾段常见）
                output = TranscriptSanitizer.sanitize(output)
                // 原文模式：用户在 HUD 看到什么，就插入什么
                if prefs.processingMode == "原文", !liveSnapshot.isEmpty {
                    let live = TranscriptSanitizer.sanitize(liveSnapshot)
                    if !live.isEmpty { output = live }
                }
                FVDebug.log("finish text len=\(output.count) live=\(liveSnapshot.count)")
                // 切换录音来源时若引擎丢失前半段，用切换前的文本兜底拼接
                if !livePrefix.isEmpty,
                   !output.contains(String(livePrefix.suffix(20))) {
                    output = livePrefix + output
                }

                guard !Task.isCancelled, self.sessionID == id else { return }
                guard !output.isEmpty else { throw FVError.message("没有识别到语音") }

                var finalOutput = output
                var note = ""
                do {
                    let rewritten = try await Rewriter.process(output, preferences: prefs)
                    if !rewritten.isEmpty { finalOutput = rewritten }
                } catch {
                    note = "（语义润色失败，已直接插入原文）"
                }

                guard !Task.isCancelled, self.sessionID == id else { return }

                let resolvedTarget: TextInsertion
                if let knownTarget {
                    resolvedTarget = knownTarget
                } else {
                    resolvedTarget = await TextInsertion.capture(at: self.lastAnchor)
                }
                // 即使 AX 判定为非可编辑，也主动向目标 App 发一次 ⌘V：
                // 飞书/微信/Electron 的自绘输入框往往无法被 AX 识别，但能正常接收粘贴。
                guard !Task.isCancelled, self.sessionID == id else { return }

                if resolvedTarget.app == nil {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(finalOutput, forType: .string)
                    self.completeClipboard(finalOutput)
                } else if prefs.previewBeforeInsert {
                    self.pending = PendingInsert(insertion: resolvedTarget, text: finalOutput, note: note)
                    self.status = "请确认文字…"
                    self.hud.hide()
                    PreviewController.shared.present(
                        text: finalOutput,
                        targetName: resolvedTarget.appName ?? "目标应用",
                        onInsert: { [weak self] in self?.performInsert() },
                        onRetry: { [weak self] in self?.retryAfterPreview() },
                        onCancel: { [weak self] in self?.abortAfterPreview() }
                    )
                } else {
                    try await resolvedTarget.insert(finalOutput)
                    let uncertain = !resolvedTarget.isEditableTarget && note.isEmpty
                    self.completeInsert(finalOutput, app: resolvedTarget.appName,
                                        note: uncertain ? "（若未出现请按 ⌘V 粘贴）" : note)
                }
            } catch {
                guard self.sessionID == id else { return }
                let message = error.localizedDescription
                self.status = "失败：\(message)"
                self.hud.show(.error(message), autoHide: 4.5)
            }
        }
    }

    func cancel() {
        sessionID = UUID()
        runningTask?.cancel()
        runningTask = nil
        capTask?.cancel()
        capTask = nil
        removeEscMonitor()
        streamRecognizer?.stop()
        streamRecognizer = nil
        targetTask?.cancel()
        targetTask = nil
        senseVoice.cancel()
        senseVoiceActive = false
        recorder.onPCMData = nil
        if recording { recorder.cancel() }
        recording = false
        startedAt = nil
        busy = false
        target = nil
        clipboardOnly = false
        pending = nil
        PreviewController.shared.hide()
        status = "已取消 · 长按左键 0.6 秒重新录音"
        hud.hide()
    }

    private func performInsert() {
        guard let pending else { return }
        self.pending = nil
        Task { @MainActor in
            do {
                try await pending.insertion.insert(pending.text)
                completeInsert(pending.text, app: pending.insertion.appName, note: pending.note)
            } catch {
                status = "失败：\(error.localizedDescription)"
                hud.show(.error(error.localizedDescription), autoHide: 4.5)
            }
        }
    }

    private func retryAfterPreview() {
        pending = nil
        status = "重新录音…"
        start(at: lastAnchor)
    }

    private func abortAfterPreview() {
        pending = nil
        status = "已取消 · 长按左键 0.6 秒重新录音"
        hud.hide()
    }

    private func completeInsert(_ text: String, app: String?, note: String) {
        historyItems.insert(FVHistory(text: text, date: Date(), app: app), at: 0)
        if historyItems.count > 20 { historyItems.removeLast(historyItems.count - 20) }
        SoundFeedback.shared.play(.success)
        status = "已插入\(note) · 长按左键继续"
        let retained = Preferences.shared.keepClipboard
        hud.show(
            .inserted(
                title: L10n.t("已插入"),
                detail: retained ? "⌘V 可再用" : "原剪贴板已恢复"
            ),
            near: NSEvent.mouseLocation,
            autoHide: 1.9
        )
    }

    private func completeClipboard(_ text: String) {
        historyItems.insert(FVHistory(text: text, date: Date(), app: "剪贴板"), at: 0)
        if historyItems.count > 20 { historyItems.removeLast(historyItems.count - 20) }
        SoundFeedback.shared.play(.success)
        status = "已复制到剪贴板 · 按 ⌘V 粘贴"
        hud.show(.toast(title: L10n.t("已复制"), detail: L10n.t("⌘V 粘贴")), near: NSEvent.mouseLocation, autoHide: 2.0)
    }

    /// 说话停顿自动结束（可选）：检测到说过话后静音 1.8 秒即收尾。
    private func trackSilence(_ pcm: Data) {
        guard Preferences.shared.autoFinishOnSilence, recording else { return }
        let rms = Self.rms(pcm)
        let now = Date()
        if rms > 0.02 {
            heardSpeech = true
            lastLoudAt = now
        } else if heardSpeech, let lastLoud = lastLoudAt, now.timeIntervalSince(lastLoud) > 1.8 {
            lastLoudAt = nil
            finish()
        }
    }

    private static func rms(_ data: Data) -> Double {
        let total = data.count / MemoryLayout<Int16>.size
        guard total > 0 else { return 0 }
        let step = max(1, total / 1024)
        var sum = 0.0
        var count = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            var i = 0
            while i < total {
                let v = Double(samples[i]) / 32768.0
                sum += v * v
                count += 1
                i += step
            }
        }
        guard count > 0 else { return 0 }
        return (sum / Double(count)).squareRoot()
    }

    private static func senseVoiceLanguage(_ language: String) -> String {
        if language.hasPrefix("zh") { return "zh" }
        if language.hasPrefix("en") { return "en" }
        return "auto"
    }

    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                MainActor.assumeIsolated { self?.cancel() }
            }
        }
    }

    private func removeEscMonitor() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }

    private static func engineDetail(_ engine: String) -> String {
        switch engine {
        case "SenseVoice 本地": return "SenseVoice 本地模型处理中…"
        case "whisper.cpp": return "本地 large-v3 模型处理中…"
        case "腾讯云 ASR", "腾讯云": return "腾讯云语音识别大模型处理中…"
        default: return "云端 API 转写中…"
        }
    }

    private func scheduleCap() {
        capTask?.cancel()
        capTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }
}

enum HUDAnchor {
    static func currentPoint() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        if NSScreen.screens.contains(where: { $0.visibleFrame.contains(mouse) }) { return mouse }
        if let screen = NSScreen.main {
            return CGPoint(x: screen.frame.midX, y: screen.visibleFrame.midY)
        }
        return CGPoint(x: 400, y: 400)
    }
}

// MARK: - Frosted-Glass Preview Controller

final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class PreviewController: NSObject, NSTextViewDelegate {
    static let shared = PreviewController()

    private var panel: PreviewPanel?
    private var textView: NSTextView?
    private var countLabel: NSTextField?
    private var onInsert: (() -> Void)?
    private var onRetry: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var keyMonitor: Any?

    private enum Outcome { case insert, retry, cancel }

    func present(text: String, targetName: String,
                 onInsert: @escaping () -> Void,
                 onRetry: @escaping () -> Void,
                 onCancel: @escaping () -> Void) {
        hide()
        self.onInsert = onInsert
        self.onRetry = onRetry
        self.onCancel = onCancel

        let size = NSSize(width: 480, height: 260)
        let panel = PreviewPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true

        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.autoresizingMask = [.width, .height]
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 16
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 1
        glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        container.addSubview(glass)

        let title = NSTextField(labelWithString: "预览微调 · 目标：\(targetName)")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = NSColor.white.withAlphaComponent(0.85)
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 18, y: size.height - 34, width: size.width - 180, height: 16)
        container.addSubview(title)

        let count = NSTextField(labelWithString: "")
        count.font = .systemFont(ofSize: 10)
        count.textColor = NSColor.white.withAlphaComponent(0.5)
        count.alignment = .right
        count.frame = NSRect(x: size.width - 158, y: size.height - 33, width: 140, height: 14)
        container.addSubview(count)
        self.countLabel = count

        let hint = NSTextField(labelWithString: "⌘↩ 插入 · Esc 取消")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = NSColor.white.withAlphaComponent(0.5)
        hint.frame = NSRect(x: 18, y: 19, width: 180, height: 14)
        container.addSubview(hint)

        let scroll = NSScrollView(frame: NSRect(x: 18, y: 50, width: size.width - 36, height: size.height - 94))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let tv = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        tv.isRichText = false
        tv.drawsBackground = false
        tv.textColor = .white
        tv.font = .systemFont(ofSize: 13)
        tv.isEditable = true
        tv.isSelectable = true
        tv.autoresizingMask = [.width]
        tv.delegate = self
        tv.string = text
        scroll.documentView = tv
        container.addSubview(scroll)
        self.textView = tv

        let cancelButton = FirstMouseButton(title: L10n.t("取消"))
        cancelButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        cancelButton.layer?.cornerRadius = 7
        cancelButton.frame = NSRect(x: size.width - 216, y: 12, width: 56, height: 28)
        cancelButton.onClick = { [weak self] in self?.finish(.cancel) }
        container.addSubview(cancelButton)

        let retryButton = FirstMouseButton(title: "重新录音")
        retryButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        retryButton.layer?.cornerRadius = 7
        retryButton.frame = NSRect(x: size.width - 152, y: 12, width: 80, height: 28)
        retryButton.onClick = { [weak self] in self?.finish(.retry) }
        container.addSubview(retryButton)

        let insertButton = FirstMouseButton(title: L10n.t("插入"))
        insertButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertButton.layer?.cornerRadius = 7
        insertButton.frame = NSRect(x: size.width - 64, y: 12, width: 48, height: 28)
        insertButton.onClick = { [weak self] in self?.finish(.insert) }
        container.addSubview(insertButton)

        panel.contentView = container
        position(panel: panel, size: size)
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(tv)
        updateCount()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === panel else { return event }
            if event.keyCode == UInt16(kVK_Escape) { self.finish(.cancel); return nil }
            if event.keyCode == UInt16(kVK_Return), event.modifierFlags.contains(.command) { self.finish(.insert); return nil }
            return event
        }
    }

    private func finish(_ outcome: Outcome) {
        let insert = onInsert
        let retry = onRetry
        let cancel = onCancel
        hide()
        switch outcome {
        case .insert: insert?()
        case .retry: retry?()
        case .cancel: cancel?()
        }
    }

    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        textView = nil
        countLabel = nil
        onInsert = nil
        onRetry = nil
        onCancel = nil
    }

    func textDidChange(_ notification: Notification) { updateCount() }

    private func updateCount() {
        guard let tv = textView, let countLabel else { return }
        countLabel.stringValue = "\(tv.string.count) 字"
    }

    private func position(panel: NSPanel, size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = mouse.x - size.width / 2
        var y = mouse.y + 24
        if y + size.height > visible.maxY { y = mouse.y - size.height - 24 }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Commercial Apple-Style Native Settings View (SwiftUI)

// MARK: - Liquid Glass 兼容层与组件

/// 去掉设置页控件残留的蓝色键盘焦点高亮环（用户反馈：切换分页后环仍停在原处）。
extension View {
    @ViewBuilder func fvNoFocusRing() -> some View {
        if #available(macOS 14.0, *) {
            self.focusEffectDisabled()
        } else {
            self.focusable(false)
        }
    }
}

/// 玻璃折射背景（用于滑块圆钮等需要「透出背景」的小控件）
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

extension View {
    /// macOS 26 用原生 Liquid Glass；老系统回退到 ultraThinMaterial + 细描边。
    @ViewBuilder func fvGlassCard(cornerRadius: CGFloat = 20) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        }
    }

    /// 内容层用标准材质（HIG：Liquid Glass 不用于内容层）
    @ViewBuilder func fvContentCard(cornerRadius: CGFloat = 20) -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
    }

    @ViewBuilder func fvGlassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
    }

    @ViewBuilder func fvGlassProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder func fvGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

/// 漂浮的玻璃导航条：选中项是一枚会滑动的小胶囊（iPhone 标签栏手感）。
struct GlassTabBar: View {
    @Binding var selection: Int
    let items: [(icon: String, title: String)]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items.indices, id: \.self) { index in
                Button {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.58)) {
                        selection = index
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: items[index].icon)
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(LocalizedStringKey(items[index].title))
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .minimumScaleFactor(0.88)
                    }
                    .foregroundStyle(selection == index ? Color.primary : Color.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .background {
                        if selection == index {
                            Capsule()
                                .fill(Color.white.opacity(0.18))
                                .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.8))
                                .matchedGeometryEffect(id: "tabPill", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fvNoFocusRing()
            }
        }
        .padding(5)
        .fvGlassCapsule()
        .clipShape(Capsule())
        .animation(.spring(response: 0.30, dampingFraction: 0.62), value: selection)
    }
}

/// iPhone 风格玻璃滑块：可拉伸的折射圆钮 + 渐变进度 + 玻璃轨道。
struct GlassSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0
    var widthLimit: CGFloat = 220

    @State private var stretch: CGFloat = 0
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knobHeight: CGFloat = 22
            let baseKnobWidth: CGFloat = 22
            let knobWidth = baseKnobWidth + stretch
            let fraction = max(0, min(1, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.8))
                    .frame(height: 8)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.95), Color.cyan.opacity(0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(8, width * fraction), height: 8)

                // 圆钮：玻璃折射 + 拖动时横向拉伸（松开回弹）
                ZStack {
                    VisualEffectBackground(material: .hudWindow)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.85), Color.white.opacity(0.25)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                        )
                    Circle()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 6, height: 6)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                }
                .frame(width: knobWidth, height: knobHeight)
                .shadow(color: .black.opacity(0.28), radius: 4, x: 0, y: 1)
                .offset(x: max(0, min(width - knobWidth, width * fraction - knobWidth / 2)))
                .animation(dragging ? nil : .spring(response: 0.28, dampingFraction: 0.6), value: stretch)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        dragging = true
                        // 拖动速度/方向决定拉伸程度，最大 +12pt
                        let velocityStretch = min(12, abs(gesture.translation.width) * 0.06 + 3)
                        stretch = velocityStretch
                        let ratio = max(0, min(1, gesture.location.x / max(1, width)))
                        var next = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
                        if step > 0 { next = (next / step).rounded() * step }
                        value = min(max(next, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        dragging = false
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.55)) { stretch = 0 }
                    }
            )
        }
        .frame(width: widthLimit, height: 28)
    }
}

/// 设置窗口背后的整窗玻璃（macOS 26 由窗口透明 + 材质共同呈现）。
struct WindowGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct LanguageSwitch: View {
    @Binding var language: String
    @Namespace private var namespace
    private let options: [(id: String, label: String)] = [("中文", "中"), ("English", "EN")]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.id) { option in
                Button {
                    guard language != option.id else { return }
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                        language = option.id
                    }
                } label: {
                    Text(option.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(language == option.id ? Color.primary : Color.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background {
                            if language == option.id {
                                Capsule()
                                    .fill(Color.white.opacity(0.18))
                                    .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 0.8))
                                    .matchedGeometryEffect(id: "languagePill", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fvNoFocusRing()
            }
        }
        .padding(2)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.8))
    }
}

struct HotkeyRecorderView: View {
    @Binding var hotkey: String
    @State private var recording = false
    @State private var monitor: Any?
    @State private var warning: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                recording ? cancel() : begin()
            } label: {
                Text(recording ? "请按快捷键…" : hotkey)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .frame(minWidth: 110)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(recording ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("点击后按下新的组合键；Esc 取消")

            if let warning {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
        .onAppear { warning = HotkeySpec.conflict(hotkey) }
        .onDisappear { cancel() }
    }

    private func begin() {
        cancel()
        recording = true
        warning = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { cancel(); return nil }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.isEmpty else {
                warning = "至少按一个修饰键（⌘ / ⌃ / ⌥ / ⇧）"
                return nil
            }
            guard let name = HotkeySpec.name(for: event.keyCode) else {
                warning = "这个按键暂不支持，请换一个"
                return nil
            }
            let value = HotkeySpec.display(name: name, flags: flags)
            hotkey = value
            warning = HotkeySpec.conflict(value)
            cancel()
            return nil
        }
    }

    private func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

struct PreferencesView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject private var modelManager = SenseVoiceModelManager.shared
    @State private var selectedTab: Int

    init(initialTab: Int = 0) {
        _selectedTab = State(initialValue: initialTab)
    }
    @State private var savedNoticeText: String?

    // Live permission states
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var screenCaptureAuthorized = CGPreflightScreenCaptureAccess()
    @State private var permTimer: Timer?

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSLog("FocusVoice: launch-at-login failed: %@", error.localizedDescription)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                GlassTabBar(
                    selection: $selectedTab,
                    items: [
                        ("gearshape", "通用"),
                        ("waveform", "语音模型"),
                        ("mic", "音频输入"),
                        ("sparkles", "智能整理"),
                        ("lock.shield", "权限管理")
                    ]
                )
                Spacer(minLength: 12)
                Text("v\(AppInfo.version)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                LanguageSwitch(language: $prefs.uiLanguage)
            }
            .padding(.top, 14)

            Group {
                switch selectedTab {
                case 0: generalTab
                case 1: speechTab
                case 2: audioTab
                case 3: aiTab
                default: privacyTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.18), value: selectedTab)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 8)
        .frame(width: 760, height: 620)
        .background(Color.clear)
        .environment(\.locale, L10n.locale)
        .fvNoFocusRing()
        .onAppear { startPermissionPolling() }
        .onDisappear { stopPermissionPolling() }
    }

    // MARK: - Tab 1: 通用
    var generalTab: some View {
        ScrollView(.vertical, showsIndicators: false) {

            VStack(alignment: .leading, spacing: 20) {
                cardSection(
                    title: "触发方式",
                    subtitle: "三种方式任选，默认全部开启",
                    icon: "hand.tap.fill",
                    iconColor: .blue
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(isOn: $prefs.holdToTalkEnabled) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("长按左键说话")
                                    .font(.body).fontWeight(.medium)
                                Text("在任意输入框按住左键，光标旁出现蓄力环，松手后继续说话")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }

                        HStack(spacing: 12) {
                            Text("触发时长")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .leading)
                            GlassSlider(value: $prefs.holdToTalkDelay, range: 0.4...1.2, step: 0.1, widthLimit: 220)
                            Text(L10n.isEnglish
                                 ? String(format: "%.1f s", prefs.holdToTalkDelay)
                                 : String(format: "%.1f 秒", prefs.holdToTalkDelay))
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .disabled(!prefs.holdToTalkEnabled)
                        .opacity(prefs.holdToTalkEnabled ? 1 : 0.45)

                        HStack(spacing: 12) {
                            Text("蓄力环外观")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .leading)
                            Picker("", selection: $prefs.ringStyle) {
                                ForEach(HoldRingHUD.styles, id: \.self) { style in
                                    Text(LocalizedStringKey(style)).tag(style)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 300, alignment: .leading)
                            Spacer()
                            Button("预览") { RingPreview.show(style: prefs.ringStyle) }
                                .fvGlassButton()
                                .controlSize(.regular)
                        }
                        .disabled(!prefs.holdToTalkEnabled)
                        .opacity(prefs.holdToTalkEnabled ? 1 : 0.45)

                        Divider().opacity(0.6)

                        Toggle(isOn: $prefs.optionClickTrigger) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("⌥ + 单击立即录音")
                                    .font(.body).fontWeight(.medium)
                                Text("按住 Option 点击输入框，立刻开始录音；明确意图、零等待")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }

                        Divider().opacity(0.6)

                        Toggle(isOn: $prefs.requireEditableTarget) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("只在文本输入框触发")
                                    .font(.body).fontWeight(.medium)
                                Text("更严格、不误触；关闭时窗口内容区也能触发，成功率更高")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }

                        Divider().opacity(0.6)

                        Toggle(isOn: $prefs.autoFinishOnSilence) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("说完自动结束")
                                    .font(.body).fontWeight(.medium)
                                Text("检测到停止说话 1.8 秒后自动收尾并插入，无需再点“完成”")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }

                        Divider().opacity(0.6)

                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("全局快捷键")
                                    .font(.body).fontWeight(.medium)
                                Text("按一次开始，再按一次结束并粘贴")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            HotkeyRecorderView(hotkey: $prefs.hotkeyStyle)
                                .frame(width: 190, alignment: .trailing)
                        }
                    }
                }

                cardSection(
                    title: "浮层外观",
                    subtitle: "正在聆听与已插入提示的玻璃、投影与液态玻璃",
                    icon: "rectangle.on.rectangle",
                    iconColor: .cyan
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        if #available(macOS 26.0, *) {
                            Toggle(isOn: $prefs.overlayLiquidGlass) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("液态玻璃效果")
                                        .font(.body).fontWeight(.medium)
                                    Text("开启时使用 macOS 26 原生 Liquid Glass；关闭则退回经典毛玻璃")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text("当前系统低于 macOS 26，将使用经典毛玻璃材质")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            Text("毛玻璃程度")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .leading)
                            GlassSlider(value: $prefs.overlayGlassIntensity, range: 0...1, widthLimit: 220)
                            Text("\(Int(prefs.overlayGlassIntensity * 100))%")
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .leading)
                            Spacer()
                        }

                        HStack(spacing: 12) {
                            Text("投影强度")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .leading)
                            GlassSlider(value: $prefs.overlayShadowStrength, range: 0...1, widthLimit: 220)
                            Text("\(Int(prefs.overlayShadowStrength * 100))%")
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .leading)
                            Spacer()
                        }

                        HStack(spacing: 10) {
                            Spacer()
                            Button("预览聆听") { OverlayPreview.showHUD() }
                                .fvGlassButton().controlSize(.regular)
                            Button("预览提示") { OverlayPreview.showToast() }
                                .fvGlassButton().controlSize(.regular)
                        }
                    }
                }

                cardSection(
                    title: "粘贴与输入偏好",
                    subtitle: "自定义转录完成后的行为与剪贴板管理",
                    icon: "doc.on.clipboard.fill",
                    iconColor: .indigo
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle(isOn: $prefs.previewBeforeInsert) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("插入前显示微调预览窗口")
                                    .font(.body).fontWeight(.medium)
                                Text("转录完成后弹出微调浮窗，支持二次修改后再插入（默认关闭，识别完成直接粘贴）")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }

                        Divider().opacity(0.6)

                        Toggle(isOn: $prefs.keepClipboard) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("转录文字保留在剪贴板")
                                    .font(.body).fontWeight(.medium)
                                Text("随时按 ⌘V 都能贴入最近一次转录；关闭后粘贴完会恢复你原来的剪贴板内容")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }

                        Divider().opacity(0.6)

                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: $prefs.playSounds) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("柔和提示音")
                                        .font(.body).fontWeight(.medium)
                                    Text("科技助手 / 低频电影 / Apple 原生 三组音色；开始音自动比结束音轻")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }

                            HStack(spacing: 10) {
                                Text("开始录音")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 64, alignment: .leading)
                                Picker("", selection: $prefs.startSoundStyle) {
                                    ForEach(SoundPreset.all) { preset in
                                        Text(preset.displayName).tag(preset.name)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 250)
                                Button("试听") { SoundFeedback.shared.play(.start) }
                                    .fvGlassButton()
                                    .controlSize(.small)
                                Spacer()
                            }
                            .disabled(!prefs.playSounds)
                            .opacity(prefs.playSounds ? 1 : 0.45)

                            HStack(spacing: 10) {
                                Text("完成录音")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 64, alignment: .leading)
                                Picker("", selection: $prefs.endSoundStyle) {
                                    ForEach(SoundPreset.all) { preset in
                                        Text(preset.displayName).tag(preset.name)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 250)
                                Button("试听") { SoundFeedback.shared.play(.success) }
                                    .fvGlassButton()
                                    .controlSize(.small)
                                Spacer()
                            }
                            .disabled(!prefs.playSounds)
                            .opacity(prefs.playSounds ? 1 : 0.45)

                            HStack(spacing: 12) {
                                Text("音量")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                GlassSlider(value: $prefs.soundVolume, range: 0...1, widthLimit: 200)
                                Text("\(Int(prefs.soundVolume * 100))%")
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 42, alignment: .leading)
                                Spacer()
                            }
                            .disabled(!prefs.playSounds)
                            .opacity(prefs.playSounds ? 1 : 0.45)
                        }

                        Divider().opacity(0.6)

                        Toggle(isOn: launchAtLogin) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("登录 macOS 时自动启动")
                                    .font(.body).fontWeight(.medium)
                                Text("开机登录时在后台静默启动 FocusVoice，并在菜单栏常驻就绪")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.never)
    }

    private var senseModelReady: Bool {
        modelManager.state == .ready || FVSenseVoiceAssets.isAvailable
    }

    // MARK: - 引擎摘要

    private var engineSummaryTitle: String {
        switch prefs.speechEngine {
        case "SenseVoice 本地": return "SenseVoice · 本地实时"
        case "腾讯云 ASR": return "腾讯云 · 实时流式"
        default: return "自定义 · OpenAI 兼容 API"
        }
    }

    private var engineSummaryDetail: String {
        switch prefs.speechEngine {
        case "SenseVoice 本地": return "边说边出字 · 说完零等待 · 全离线 · 默认推荐"
        case "腾讯云 ASR": return "需要 AppId/密钥 · 实时流式 · 走网络"
        default: return "填写接口地址与模型名后使用"
        }
    }

    private var engineSummaryIcon: String {
        switch prefs.speechEngine {
        case "SenseVoice 本地": return "bolt.fill"
        case "腾讯云 ASR": return "cloud.fill"
        default: return "network"
        }
    }

    private var engineSummaryColor: Color {
        switch prefs.speechEngine {
        case "SenseVoice 本地": return .orange
        case "腾讯云 ASR": return .cyan
        default: return .indigo
        }
    }

    private var engineBadgeText: String {
        switch prefs.speechEngine {
        case "SenseVoice 本地": return FVSenseVoiceAssets.isAvailable ? "就绪" : "模型缺失"
        case "腾讯云 ASR": return prefs.tencentAppId.isEmpty ? "未配置" : "就绪"
        default: return prefs.llmKey.isEmpty ? "未配置" : "就绪"
        }
    }

    // MARK: - Tab 2: 语音模型
    var speechTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                cardSection(
                    title: "语音识别引擎",
                    subtitle: "先选引擎，再选语言；下方只显示当前引擎的配置",
                    icon: "cpu.fill",
                    iconColor: .purple
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("识别引擎", selection: $prefs.speechEngine) {
                            Text("SenseVoice").tag("SenseVoice 本地")
                            Text("腾讯云").tag("腾讯云 ASR")
                            Text("API").tag("API")
                        }
                        .pickerStyle(.segmented)

                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: engineSummaryIcon)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(engineSummaryColor)
                                .frame(width: 26, height: 26)
                                .background(engineSummaryColor.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(LocalizedStringKey(engineSummaryTitle))
                                    .font(.body).fontWeight(.semibold)
                                Text(LocalizedStringKey(engineSummaryDetail))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(LocalizedStringKey(engineBadgeText))
                                .font(.caption2).fontWeight(.bold)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(engineSummaryColor.opacity(0.14))
                                .foregroundStyle(engineSummaryColor)
                                .clipShape(Capsule())
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        Divider().opacity(0.6)

                        // 语言选择：固定标签宽度，和上面的控件左对齐，避免位置漂移
                        HStack(alignment: .center, spacing: 12) {
                            Text("识别语言")
                                .font(.body).fontWeight(.medium)
                                .frame(width: 96, alignment: .leading)
                            Picker("", selection: $prefs.language) {
                                Text("中文普通话").tag("zh-CN")
                                Text("英语").tag("en-US")
                                Text("自动多语种检测").tag("auto")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 220, alignment: .leading)
                            Spacer()
                        }

                        if prefs.language == "auto" {
                            Text("自动多语种检测：按音频内容自动判断中/英/粤/日/韩，不需要你指定语言。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("指定语言可以让识别更稳定、标点更准确。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if prefs.speechEngine == "SenseVoice 本地" {
                    cardSection(
                        title: "SenseVoice 本地模型",
                        subtitle: "与 DeepSeek Harness 同款 · 边说边出字 · 全程离线",
                        icon: "bolt.fill",
                        iconColor: .orange
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                Image(systemName: senseModelReady ? "checkmark.seal.fill" : "arrow.down.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(senseModelReady ? .green : .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("SenseVoiceSmall · 中文/英文/粤语/日文/韩文")
                                        .font(.headline)
                                    Text(senseModelReady
                                         ? "\(L10n.t(FVSenseVoiceAssets.locationDescription)) · \(L10n.isEnglish ? "about 1s to load" : "首次加载约 1 秒")"
                                         : L10n.t("首次使用需下载约 230MB 模型，一次下载后完全离线"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if case .downloading = modelManager.state {
                                    Text("\(Int(modelManager.progress * 100))%")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                } else if senseModelReady {
                                    Toggle("启动时预热", isOn: $prefs.warmUpSenseVoice)
                                        .toggleStyle(.switch)
                                        .controlSize(.small)
                                }
                            }

                            if case .downloading = modelManager.state {
                                VStack(alignment: .leading, spacing: 8) {
                                    ProgressView(value: modelManager.progress)
                                    HStack {
                                        Text(modelManager.detail)
                                            .font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Spacer()
                                        Button("取消") { modelManager.cancel() }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                    }
                                }
                            } else if case .installing = modelManager.state {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(modelManager.detail).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                }
                            } else if !senseModelReady {
                                if case .failed(let message) = modelManager.state {
                                    Text(message).font(.caption).foregroundStyle(.red)
                                }
                                Button {
                                    modelManager.install()
                                } label: {
                                    Label("一键下载并安装模型", systemImage: "arrow.down.circle")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.regular)
                            }
                        }
                    }
                }

                if prefs.speechEngine == "腾讯云 ASR" {
                    cardSection(
                        title: "腾讯云实时流式语音识别 (ASR)",
                        subtitle: "毫秒级实时流式识别，边说边动态出字；说完直接粘贴，极速流畅零等待",
                        icon: "bolt.horizontal.circle.fill",
                        iconColor: .cyan,
                        minHeight: 320
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            Divider().opacity(0.6)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("AppId (账号 ID)")
                                        .font(.subheadline).fontWeight(.semibold)
                                    Spacer()
                                    Text("实时流式转录必需")
                                        .font(.caption2).fontWeight(.bold)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.12))
                                        .foregroundStyle(.blue)
                                        .clipShape(Capsule())
                                }
                                TextField("可在腾讯云控制台「账号信息」查看，如 125xxxxxxx 或 13xxxxxxx", text: $prefs.tencentAppId)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.regular)
                            }

                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("SecretId")
                                        .font(.subheadline).fontWeight(.semibold)
                                    TextField("AKID...", text: $prefs.tencentSecretId)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("SecretKey")
                                        .font(.subheadline).fontWeight(.semibold)
                                    SecureField("本地加密保存", text: $prefs.tencentSecretKey)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }

                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("服务地域")
                                        .font(.subheadline).fontWeight(.semibold)
                                    Picker("", selection: $prefs.tencentRegion) {
                                        Text("华东 (上海)").tag("ap-shanghai")
                                        Text("华南 (广州)").tag("ap-guangzhou")
                                        Text("华北 (北京)").tag("ap-beijing")
                                    }
                                    .labelsHidden()
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("转录模型")
                                        .font(.subheadline).fontWeight(.semibold)
                                    Text("16k 中文通用 (16k_zh)")
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(savedNoticeText ?? "保存配置") {
                                    prefs.saveKeys()
                                    savedNoticeText = "已保存配置 ✓"
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                        savedNoticeText = nil
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }
                } else if prefs.speechEngine == "API" {
                    cardSection(
                        title: "自定义云端转写 API 配置",
                        subtitle: "兼容 OpenAI /v1/audio/transcriptions 接口规范",
                        icon: "cloud.fill",
                        iconColor: .orange
                    ) {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("接口 URL")
                                    .font(.subheadline).fontWeight(.medium)
                                TextField("https://api.openai.com/v1/audio/transcriptions", text: $prefs.transcriptionURL)
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("模型名称")
                                    .font(.subheadline).fontWeight(.medium)
                                TextField("如 whisper-1 或 gpt-4o-mini-transcribe", text: $prefs.transcriptionModel)
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("API Key")
                                    .font(.subheadline).fontWeight(.medium)
                                SecureField("API Key 存储在本地安全配置中", text: $prefs.transcriptionKey)
                                    .textFieldStyle(.roundedBorder)
                            }

                            HStack {
                                Spacer()
                                Button(savedNoticeText ?? "保存配置") {
                                    prefs.saveKeys()
                                    savedNoticeText = "已保存配置 ✓"
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                        savedNoticeText = nil
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Tab 3: 音频输入
    var audioTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                cardSection(
                    title: "默认录音模式",
                    subtitle: "设定每次启动录音时的默认音频采集方式（录音中可在 HUD 随时切换）",
                    icon: "waveform.badge.magnifyingglass",
                    iconColor: .blue
                ) {
                    Picker("默认模式", selection: $prefs.audioSource) {
                        Text("外录 · 麦克风").tag(AudioSource.mic.rawValue)
                        Text("内录 · 系统声音").tag(AudioSource.system.rawValue)
                    }
                    .pickerStyle(.segmented)
                }

                cardSection(
                    title: "外录硬件设备 (MacBook Pro 内置麦克风)",
                    subtitle: "硬件级直连采集，保障极致纯净的语音输入",
                    icon: "mic.fill",
                    iconColor: .green
                ) {
                    HStack(spacing: 16) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 34))
                            .foregroundStyle(.tint)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(AudioDeviceLookup.builtInMicrophoneName())
                                    .font(.headline)
                                Text("硬件直连 · 锁定使用")
                                    .font(.caption2).fontWeight(.bold)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.14))
                                    .foregroundStyle(.blue)
                                    .clipShape(Capsule())
                            }
                            Text("已强制锁定使用 MacBook Pro 本机高保真阵列麦克风，不走蓝牙耳机或外接耳麦，彻底避免耳机断联、休眠或单声道音质劣化。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                cardSection(
                    title: "内录系统声音说明 (ScreenCaptureKit)",
                    subtitle: "捕获 Mac 本机正在播放的声音或会议音频",
                    icon: "speaker.wave.2.fill",
                    iconColor: .purple
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("内录基于 Apple ScreenCaptureKit 音频回路技术，高保真采集 Mac 正在播放的视频声音、会议讨论或系统音频。")
                            .font(.subheadline)
                        Text("提示：录音期间可在浮动 HUD 左下角一键实时切换外录/内录，录音各段会自动无缝合并后送入大模型识别。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Tab 4: 智能整理

    private var processingModeHelp: String {
        switch prefs.processingMode {
        case "原文": return "不做任何处理，转写完成立即插入，速度最快。"
        case "纠错": return "只清理同音错字、口头禅和标点；需要配置下方语言模型。"
        default: return "按句子和「首先/其次/另外/最后」等话语标记分段，列举项逐行；未配置模型也能用本地规则完成。"
        }
    }

    var aiTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                cardSection(
                    title: "文本后处理模式",
                    subtitle: "选择转写完成后的处理方式",
                    icon: "wand.and.stars",
                    iconColor: .pink
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("输出模式", selection: $prefs.processingMode) {
                            Text("原文直出 (无延迟)").tag("原文")
                            Text("智能纠错").tag("纠错")
                            Text("结构化思维整理").tag("结构化")
                        }
                        .pickerStyle(.segmented)

                        Text(processingModeHelp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if prefs.processingMode == "结构化" {
                    cardSection(
                        title: "本地结构化效果",
                        subtitle: "未配置语言模型时，会按这个规则排版（不改写内容）",
                        icon: "text.alignleft",
                        iconColor: .mint
                    ) {
                        Text(StructuredTextFormatter.format("首先我们需要确定目标，然后拆分任务。第二要评估风险。第三要安排时间。另外记得同步给团队。最后我们复盘一下。"))
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .textSelection(.enabled)
                    }
                }

                if prefs.processingMode == "结构化" {
                    Text("未配置语言模型时，会自动使用本地规则：按句子与「首先/其次/另外/最后」等话语标记分段，列举项逐行，段落之间留空行。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                }

                if prefs.processingMode != "原文" {
                    cardSection(
                        title: "语言模型服务配置",
                        subtitle: prefs.processingMode == "结构化"
                            ? "可选：配置后使用模型做更强的结构化；未配置则用本地规则"
                            : "兼容 OpenAI / Ollama / LM Studio 等 Chat Completions 接口",
                        icon: "sparkles",
                        iconColor: .orange
                    ) {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Chat Completions 接口 URL")
                                    .font(.subheadline).fontWeight(.medium)
                                TextField("https://api.openai.com/v1/chat/completions", text: $prefs.llmURL)
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("模型名称")
                                    .font(.subheadline).fontWeight(.medium)
                                TextField("如 gpt-4o-mini 或本地 ollama 模型", text: $prefs.llmModel)
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("API Key")
                                    .font(.subheadline).fontWeight(.medium)
                                SecureField("本地 Ollama/LM Studio 可留空", text: $prefs.llmKey)
                                    .textFieldStyle(.roundedBorder)
                            }

                            HStack {
                                Text("提示：未配置 API Key 时将直接输出高质量原文，绝不卡顿或阻断输入。")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(savedNoticeText ?? "保存配置") {
                                    prefs.saveKeys()
                                    savedNoticeText = "已保存配置 ✓"
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                        savedNoticeText = nil
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Tab 5: 权限管理
    var privacyTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                permissionRow(
                    title: "辅助功能 (Accessibility)",
                    badgeText: "必需",
                    desc: "用于定位当前聚焦的输入框并自动模拟 ⌘V 粘贴文本",
                    icon: "accessibility",
                    isAuthorized: axTrusted,
                    paneURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                    permissionKind: .accessibility
                )

                permissionRow(
                    title: "麦克风权限 (Microphone)",
                    badgeText: "外录必需",
                    desc: "用于调用 MacBook Pro 内置高保真麦克风进行语音采集",
                    icon: "mic.fill",
                    isAuthorized: micAuthorized,
                    paneURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                    permissionKind: .microphone
                )

                permissionRow(
                    title: "屏幕与系统录音 (Screen Recording)",
                    badgeText: "内录可选",
                    desc: "用于 ScreenCaptureKit 回路采集 Mac 本机播放的声音（若仅外录则非必需）",
                    icon: "rectangle.inset.filled.and.cursorarrow",
                    isAuthorized: screenCaptureAuthorized,
                    paneURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                    permissionKind: .screenRecording
                )

                HStack {
                    Spacer()
                    Button("立即重新检查权限状态") {
                        refreshPermissions()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
                .padding(.top, 12)
            }
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
    }

    // MARK: - UI Helpers

    func cardSection<Content: View>(
        title: String,
        subtitle: String? = nil,
        icon: String,
        iconColor: Color = .accentColor,
        minHeight: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)
                    .background(iconColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(LocalizedStringKey(subtitle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: minHeight ?? 0, alignment: .topLeading)
            .padding(.top, 2)
            .fvContentCard(cornerRadius: 20)
        }
    }

    enum PermissionKind { case accessibility, microphone, screenRecording }

    func permissionRow(title: String, badgeText: String, desc: String, icon: String, isAuthorized: Bool, paneURL: String, permissionKind: PermissionKind) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 36, height: 36)
                .background((isAuthorized ? Color.green : Color.orange).opacity(0.12))
                .foregroundStyle(isAuthorized ? Color.green : Color.orange)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(title)).font(.body).fontWeight(.semibold)
                    Text(LocalizedStringKey(badgeText))
                        .font(.caption2).fontWeight(.bold)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text(LocalizedStringKey(desc)).font(.subheadline).foregroundStyle(.secondary)
            }

            Spacer()

            if isAuthorized {
                Text("● 已授权")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())
            } else {
                Button(isAuthorized ? "已授权" : "授权") {
                    requestPermission(permissionKind, paneURL: paneURL)
                }
                .fvGlassProminentButton()
                .controlSize(.regular)
            }
        }
        .padding(18)
        .fvContentCard(cornerRadius: 18)
    }

    private func startPermissionPolling() {
        refreshPermissions()
        permTimer?.invalidate()
        permTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in self.refreshPermissions() }
        }
    }

    private func stopPermissionPolling() {
        permTimer?.invalidate()
        permTimer = nil
    }

    private func requestPermission(_ kind: PermissionKind, paneURL: String) {
        switch kind {
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions([
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { refreshPermissions() }
        case .microphone:
            // 必须是 App 自己发起请求，系统才会弹出麦克风授权并把 App 加入列表；
            // 直接打开系统设置时 App 尚未注册，用户会看不到它。
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { refreshPermissions() }
            }
        case .screenRecording:
            CGRequestScreenCaptureAccess()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { refreshPermissions() }
        }
    }

    private func refreshPermissions() {
        axTrusted = AXIsProcessTrusted()
        micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screenCaptureAuthorized = CGPreflightScreenCaptureAccess()
    }
}

// MARK: - App Delegate

// MARK: - 设置窗口（窗口级毛玻璃，与浮层风格统一）

@MainActor enum SettingsWindowFactory {
    static func make(tab: Int = 0) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "FocusVoice 设置"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 620))
        window.contentMinSize = NSSize(width: 760, height: 620)
        window.contentMaxSize = NSSize(width: 760, height: 620)

        // 整窗毛玻璃：让设置界面与 HUD/胶囊保持同一套玻璃语言
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true

        let host = NSHostingView(rootView: PreferencesView(initialTab: tab))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        window.contentView = effect
        return window
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = Controller()
    private let hotkey = Hotkey()
    private let mouseWatcher = MouseHoldWatcher()
    private var item: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var settingsWindow: NSWindow?
    private var mainMenu: NSMenu?
    private var menuToggleTitle: String { "\(L10n.t("开始 / 结束录音"))  (\(Preferences.shared.hotkeyStyle))" }
    private var cancellables = Set<AnyCancellable>()
    private var pulseTimer: Timer?
    private var pulseOn = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Preferences.shared.$uiLanguage
            .dropFirst()
            .sink { [weak self] _ in self?.controller.refreshLanguage() }
            .store(in: &cancellables)
        Preferences.shared.$hotkeyStyle
            .dropFirst()
            .sink { [weak self] _ in self?.setupHotkey() }
            .store(in: &cancellables)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ""
        item.button?.image = Self.menuBarImage(active: false)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "FocusVoice"
        let menu = NSMenu()
        menu.delegate = self
        mainMenu = menu
        statusMenuItem = NSMenuItem(title: controller.status, action: nil, keyEquivalent: "")
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem(title: menuToggleTitle, action: #selector(toggle), keyEquivalent: ""))

        let sourceMenu = NSMenu(title: L10n.t("录音来源"))
        for s in AudioSource.allCases {
            let mi = NSMenuItem(title: L10n.t(s.rawValue), action: #selector(setSource(_:)), keyEquivalent: "")
            mi.representedObject = s.rawValue
            mi.target = self
            sourceMenu.addItem(mi)
        }
        sourceMenu.delegate = self
        sourceMenu.identifier = NSUserInterfaceItemIdentifier("source")
        let sourceItem = NSMenuItem(title: L10n.t("默认录音来源"), action: nil, keyEquivalent: "")
        sourceItem.submenu = sourceMenu
        menu.addItem(sourceItem)

        let modeMenu = NSMenu(title: L10n.t("输出模式"))
        for m in ["原文", "纠错", "结构化"] {
            let mi = NSMenuItem(title: L10n.t(m), action: #selector(setMode(_:)), keyEquivalent: "")
            mi.representedObject = m
            mi.target = self
            modeMenu.addItem(mi)
        }
        modeMenu.delegate = self
        modeMenu.identifier = NSUserInterfaceItemIdentifier("mode")
        let modeItem = NSMenuItem(title: L10n.t("输出模式"), action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let engineMenu = NSMenu(title: L10n.t("识别引擎"))
        for e in ["SenseVoice 本地", "腾讯云 ASR", "API"] {
            let mi = NSMenuItem(title: L10n.t(e), action: #selector(setEngine(_:)), keyEquivalent: "")
            mi.representedObject = e
            mi.target = self
            engineMenu.addItem(mi)
        }
        engineMenu.delegate = self
        engineMenu.identifier = NSUserInterfaceItemIdentifier("engine")
        let engineItem = NSMenuItem(title: L10n.t("识别引擎"), action: nil, keyEquivalent: "")
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)

        let historyMenu = NSMenu(title: L10n.t("最近转写"))
        historyMenu.identifier = NSUserInterfaceItemIdentifier("history")
        historyMenu.delegate = self
        historyMenu.autoenablesItems = false
        let historyItem = NSMenuItem(title: L10n.t("最近转写"), action: nil, keyEquivalent: "")
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.t("设置…"), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.t("退出 FocusVoice"), action: #selector(quit), keyEquivalent: "q"))
        for it in menu.items { if it.action != nil { it.target = self } }
        item.menu = menu

        mouseWatcher.onHold = { [weak self] point in self?.controller.start(at: point) }
        mouseWatcher.onOptionClick = { [weak self] point in self?.controller.start(at: point) }
        mouseWatcher.isPointInsideHUD = { [weak self] point in self?.controller.hudFrame?.contains(point) ?? false }
        mouseWatcher.refreshSettings()
        mouseWatcher.start()

        // 设置面板里改了触发参数后立刻生效（无需重启 App）
        Preferences.shared.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.mouseWatcher.refreshSettings() }
            }
            .store(in: &cancellables)

        setupHotkey()
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatus() }
        }

        controller.$status.combineLatest(controller.$recording)
            .sink { [weak self] value, recording in
                DispatchQueue.main.async {
                    self?.statusMenuItem.title = value
                    self?.setRecordingIndicator(recording)
                }
            }
            .store(in: &cancellables)

        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    /// 菜单栏模板图标：跟随系统明暗自动反色
    static func menuBarImage(active: Bool) -> NSImage? {
        if active { return menuBarRecordingImage(alpha: 1.0) }
        guard let resources = Bundle.main.resourceURL else { return nil }
        guard let image = NSImage(contentsOf: resources.appendingPathComponent("MenuBarIcon.png")) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 20, height: 20)
        return image
    }

    /// 录音中：模板色的圆环 + 红色录制点（红点不使用模板，保持醒目的红色）
    static func menuBarRecordingImage(alpha: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            let center = NSPoint(x: 10, y: 10)
            let heights: [CGFloat] = [0.62, 0.92, 0.72, 1.0, 0.68, 0.86, 0.60, 0.96, 0.78, 0.88]
            NSColor.labelColor.setStroke()
            for index in 0..<10 {
                let angle = Double(index) / 10 * 2 * .pi - .pi / 2
                let r0: CGFloat = 4.2
                let r1: CGFloat = r0 + (1.2 + 0.8 * heights[index])
                let path = NSBezierPath()
                path.move(to: NSPoint(x: center.x + CGFloat(cos(angle)) * r0,
                                      y: center.y + CGFloat(sin(angle)) * r0))
                path.line(to: NSPoint(x: center.x + CGFloat(cos(angle)) * r1,
                                      y: center.y + CGFloat(sin(angle)) * r1))
                path.lineWidth = 1.5
                path.lineCapStyle = .round
                path.stroke()
            }
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 1.7, y: center.y - 1.7, width: 3.4, height: 3.4))
            NSColor.systemRed.withAlphaComponent(alpha).setFill()
            dot.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func setRecordingIndicator(_ recording: Bool) {
        pulseTimer?.invalidate()
        pulseTimer = nil
        if recording {
            pulseOn = true
            item.button?.image = Self.menuBarRecordingImage(alpha: 1.0)
            let timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pulseOn.toggle()
                    self.item.button?.image = Self.menuBarRecordingImage(alpha: self.pulseOn ? 1.0 : 0.5)
                }
            }
            pulseTimer = timer
        } else {
            item.button?.image = Self.menuBarImage(active: false)
        }
    }

    private func setupHotkey() {
        hotkey.uninstall()
        hotkey.handler = { [weak self] in self?.controller.toggle() }
        _ = hotkey.install()
        updateStatus()
    }

    private func updateStatus() {
        if controller.recording || controller.busy { return }
        if AXIsProcessTrusted() {
            if controller.status.contains("需要辅助功能") {
                controller.status = "就绪 · 长按左键 0.6 秒，或按 \(Preferences.shared.hotkeyStyle)"
            }
        } else {
            controller.status = "需要辅助功能权限，请前往系统设置授权"
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        WhisperServer.shared.stop()
    }

    @objc private func toggle() { controller.toggle() }

    @objc private func setSource(_ sender: NSMenuItem) {
        Preferences.shared.audioSource = sender.title
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        Preferences.shared.processingMode = sender.title
    }

    @objc private func setEngine(_ sender: NSMenuItem) {
        Preferences.shared.speechEngine = sender.title
    }

    @objc private func copyTranscription(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func clearHistory() { controller.clearHistory() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let prefs = Preferences.shared

        // 每次打开菜单前同步当前语言（切换语言后不需要重启）
        if menu === mainMenu {
            for item in menu.items {
                if item.submenu?.identifier?.rawValue == "source" {
                    item.title = L10n.t("默认录音来源")
                } else if item.submenu?.identifier?.rawValue == "mode" {
                    item.title = L10n.t("输出模式")
                } else if item.submenu?.identifier?.rawValue == "engine" {
                    item.title = L10n.t("识别引擎")
                } else if item.submenu?.identifier?.rawValue == "history" {
                    item.title = L10n.t("最近转写")
                } else if item.action == #selector(toggle) {
                    item.title = self.menuToggleTitle
                } else if item.action == #selector(openSettings) {
                    item.title = L10n.t("设置…")
                } else if item.action == #selector(quit) {
                    item.title = L10n.t("退出 FocusVoice")
                }
            }
        }

        switch menu.identifier?.rawValue {
        case "source":
            for mi in menu.items {
                guard let raw = mi.representedObject as? String else { continue }
                mi.title = L10n.t(raw)
                mi.state = raw == prefs.audioSource ? .on : .off
            }
        case "mode":
            for mi in menu.items {
                guard let raw = mi.representedObject as? String else { continue }
                mi.title = L10n.t(raw)
                mi.state = raw == prefs.processingMode ? .on : .off
            }
        case "engine":
            for mi in menu.items {
                guard let raw = mi.representedObject as? String else { continue }
                mi.title = L10n.t(raw)
                mi.state = raw == prefs.speechEngine ? .on : .off
            }
        default:
            if menu.title == L10n.t("最近转写") || menu.identifier?.rawValue == "history" {
                menu.removeAllItems()
                let items = controller.historyItems
                if items.isEmpty {
                    let mi = NSMenuItem(title: L10n.t("暂无记录"), action: nil, keyEquivalent: "")
                    mi.isEnabled = false
                    menu.addItem(mi)
                } else {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm"
                    for h in items.prefix(10) {
                        let preview = h.text.replacingOccurrences(of: "\n", with: " ")
                        let trimmed = preview.count > 36 ? preview.prefix(36) + "…" : preview
                        let mi = NSMenuItem(title: "\(formatter.string(from: h.date)) \(h.app ?? "") · \(trimmed)", action: #selector(copyTranscription(_:)), keyEquivalent: "")
                        mi.target = self
                        mi.representedObject = h.text
                        mi.isEnabled = true
                        menu.addItem(mi)
                    }
                    menu.addItem(.separator())
                    let clear = NSMenuItem(title: L10n.t("清空历史"), action: #selector(clearHistory), keyEquivalent: "")
                    clear.target = self
                    menu.addItem(clear)
                }
            }
        }
        statusMenuItem.title = controller.status
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowFactory.make()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

var hudTestKeeper: RecordingHUD?
var ringDemoKeeper: HoldRingHUD?

// MARK: - Entry point

@main struct FocusVoiceMain {
    @MainActor static func main() {
        if let lidx = CommandLine.arguments.firstIndex(of: "--language"),
           lidx + 1 < CommandLine.arguments.count {
            UserDefaults.standard.set(CommandLine.arguments[lidx + 1], forKey: "uiLanguage")
        }
        if CommandLine.arguments.contains("--hud-test") {
            runHUDTest()
            return
        }
        if CommandLine.arguments.contains("--preview-test") {
            runPreviewTest()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--transcribe"), index + 1 < CommandLine.arguments.count {
            runTranscriptionTest(path: CommandLine.arguments[index + 1], useServer: !CommandLine.arguments.contains("--no-server"))
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--selftest-stt"), index + 1 < CommandLine.arguments.count {
            runSenseVoiceSelfTest(path: CommandLine.arguments[index + 1])
            return
        }
        if CommandLine.arguments.contains("--hud-live") {
            runHUDLiveTest()
            return
        }
        if CommandLine.arguments.contains("--download-model") {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                print("MODEL_DOWNLOAD: start")
                await SenseVoiceModelManager.shared.installAwait()
                if SenseVoiceModelManager.shared.state == .ready {
                    print("MODEL_DOWNLOAD: ready \(SenseVoiceModelManager.installDirectory.path)")
                    exit(0)
                } else {
                    print("MODEL_DOWNLOAD: failed \(SenseVoiceModelManager.shared.detail)")
                    exit(1)
                }
            }
            app.run()
            exit(0)
        }
        if CommandLine.arguments.contains("--selftest-sanitize") {
            runSanitizerSelfTest()
            return
        }
        if CommandLine.arguments.contains("--selftest-structure") {
            runStructureSelfTest()
            return
        }
        if CommandLine.arguments.contains("--ui-demo") {
            runUIDemo()
            return
        }
        if CommandLine.arguments.contains("--settings-preview") {
            runSettingsPreview()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--export-sounds"),
           index + 1 < CommandLine.arguments.count {
            runSoundExport(directory: CommandLine.arguments[index + 1])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--selftest-insert"), index + 1 < CommandLine.arguments.count {
            runInsertSelfTest(text: CommandLine.arguments[index + 1])
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private static func runTranscriptionTest(path: String, useServer: Bool) {
        let engine: String?
        if let idx = CommandLine.arguments.firstIndex(of: "--engine"), idx + 1 < CommandLine.arguments.count {
            engine = CommandLine.arguments[idx + 1]
        } else {
            engine = nil
        }
        Task { @MainActor in
            do {
                let text = try await Recognizer.recognize(
                    URL(fileURLWithPath: path),
                    preferences: Preferences.shared,
                    engineOverride: engine,
                    forceNoServer: !useServer
                )
                print(text)
                WhisperServer.shared.stop()
                exit(0)
            } catch {
                fputs("ERROR: \(error.localizedDescription)\n", stderr)
                WhisperServer.shared.stop()
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func runStructureSelfTest() {
        let samples = [
            "首先我们需要确定目标然后拆分任务。第二要评估风险。第三要安排时间。另外记得同步给团队。最后我们复盘一下。",
            "我觉得这个方向可以，但是有几个问题，第一成本太高，第二时间来不及，另外人手也不够。",
            "今天下午三点开会，记得带上项目文档。"
        ]
        for sample in samples {
            print("IN : \(sample)")
            print("OUT:\n\(StructuredTextFormatter.format(sample))\n---")
        }
        exit(0)
    }

    private static func runSanitizerSelfTest() {
        let samples = [
            "今天下午三点开会。yeah",
            "Okay. 我觉得可以。",
            "That's okay",
            "嗯。。。今天下午三点开会，。",
            "<|HAPPY|>你好呀",
            "yeah",
            "今天 下午 三点 开会",
            "这是测试 okay，",
            "没问题 OK！",
            "好的呀。yeah。",
            "。今天 ，下午  三点开会 ，，嗯",
            "我觉得，。这个方案，；可以！"
        ]
        for sample in samples {
            print("IN : \(sample)")
            print("OUT: '\(TranscriptSanitizer.sanitize(sample))'")
        }
        exit(0)
    }

    @MainActor private static func runSoundExport(directory: String) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sampleRate = 44_100.0
        print("name\tduration_s\tpeak")
        for preset in SoundPreset.all {
            guard case .synth(let key) = preset.kind else { continue }
            guard let samples = SoundFeedback.shared.debugSamples(key: key), !samples.isEmpty else {
                print("\(preset.name)\tERROR")
                continue
            }
            var peak: Float = 0
            for sample in samples { peak = max(peak, abs(sample)) }
            let duration = Double(samples.count) / sampleRate
            print(String(format: "%@\t%.2f\t%.3f", preset.name, duration, Double(peak)))
            writeWAV(samples, sampleRate: sampleRate, to: dir.appendingPathComponent("\(preset.name).wav"))
        }
        print("exported to \(dir.path)")
        exit(0)
    }

    private static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) {
        var data = Data()
        func appendUInt32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func appendUInt16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate) * 2)
        appendUInt16(2)
        appendUInt16(16)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(UInt32(samples.count * 2))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * 32767)
            value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        try? data.write(to: url)
    }

    @MainActor private static func runSettingsPreview() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let tabArg: Int
        if let index = CommandLine.arguments.firstIndex(of: "--settings-tab"),
           index + 1 < CommandLine.arguments.count {
            tabArg = Int(CommandLine.arguments[index + 1]) ?? 0
        } else {
            tabArg = 0
        }
        if let eidx = CommandLine.arguments.firstIndex(of: "--engine"),
           eidx + 1 < CommandLine.arguments.count {
            Preferences.shared.speechEngine = CommandLine.arguments[eidx + 1]
        }
        let window = SettingsWindowFactory.make(tab: tabArg)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { exit(0) }
        app.run()
    }

    @MainActor private static func runUIDemo() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        // 固定用主屏，避免演示窗口跑到副屏导致截图看不到
        let screen = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = CGPoint(x: screen.midX, y: screen.midY)
        print("UIDEMO anchor=\(anchor)")

        let styleArg: String
        if let index = CommandLine.arguments.firstIndex(of: "--ring-style"),
           index + 1 < CommandLine.arguments.count {
            styleArg = CommandLine.arguments[index + 1]
        } else {
            styleArg = Preferences.shared.ringStyle
        }
        print("UIDEMO ringStyle=\(styleArg)")

        DispatchQueue.main.async {
            let ring = HoldRingHUD()
            ring.show(at: anchor, duration: 1.4, style: styleArg)
            ringDemoKeeper = ring
            print("UIDEMO ring shown")

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.45) {
                ring.complete()
                print("UIDEMO ring burst")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                let hud = RecordingHUD()
                hud.setTarget("备忘录")
                hud.show(.recording(startedAt: Date()), near: anchor)
                hud.setLiveTranscript(confirmed: "今天下午三点开会，", partial: "记得带上项目文档")
                hudTestKeeper = hud
                print("UIDEMO hud shown")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                    hud.show(.inserted(title: L10n.t("已插入"), detail: L10n.t("⌘V 可再用")), near: anchor)
                    print("UIDEMO toast shown")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { print("UIDEMO exit"); exit(0) }
        app.run()
    }

    private static func runInsertSelfTest(text: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)   // 给用户时间切到目标输入框
            let target = await TextInsertion.capture(at: NSEvent.mouseLocation)
            print("INSERT_TARGET_APP: \(target.appName ?? "nil")")
            print("INSERT_EDITABLE: \(target.isEditableTarget)")
            do {
                try await target.insert(text)
                print("INSERT_OK")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { exit(0) }
            } catch {
                fputs("INSERT_ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func runSenseVoiceSelfTest(path: String) {
        Task { @MainActor in
            do {
                let start = Date()
                let available = SenseVoiceEngine.isAvailable
                let location = SenseVoiceEngine.locationDescription
                let text = try await SenseVoiceEngine.transcribeFile(URL(fileURLWithPath: path))
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                print("STT_AVAILABLE: \(available)")
                print("STT_LOCATION: \(location)")
                print("STT_MS: \(ms)")
                print("STT_TEXT: \(text)")
                exit(text.isEmpty ? 2 : 0)
            } catch {
                fputs("STT_ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        dispatchMain()
    }

    @MainActor private static func runHUDLiveTest() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let hud = RecordingHUD()
        hud.setTarget("备忘录")
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = CGPoint(x: screen.midX, y: screen.midY)
        hud.show(.recording(startedAt: Date()), near: anchor)
        hudTestKeeper = hud
        let script: [(Double, String, String)] = [
            (0.8, "", "今天下午"),
            (2.0, "今天下午三点", "开会，"),
            (3.4, "今天下午三点开会，", "记得带上项目文档"),
            (4.8, "今天下午三点开会，记得带上项目文档和笔记本。", ""),
        ]
        for (delay, confirmed, partial) in script {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { hud.setLiveTranscript(confirmed: confirmed, partial: partial) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(0) }
        app.run()
    }



    @MainActor private static func runHUDTest() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let hud = RecordingHUD()
        hud.onFinish = { print("HUD_FINISH"); exit(0) }
        hud.onCancel = { print("HUD_CANCEL"); exit(0) }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        hud.show(.recording(startedAt: Date()), near: CGPoint(x: screen.minX + 200, y: screen.maxY - 200))
        hudTestKeeper = hud
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(2) }
        app.run()
    }

    @MainActor private static func runPreviewTest() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        PreviewController.shared.present(
            text: "这是商业级 Apple 风格预览微调窗口测试。",
            targetName: "测试应用",
            onInsert: { print("PREVIEW_INSERT"); exit(0) },
            onRetry: { print("PREVIEW_RETRY"); exit(0) },
            onCancel: { print("PREVIEW_CANCEL"); exit(0) }
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(2) }
        app.run()
    }
}
