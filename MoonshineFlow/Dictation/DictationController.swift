@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Foundation

enum DictationOutputMode: String, CaseIterable, Identifiable {
    case singleSpeaker
    case multiSpeaker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singleSpeaker:
            return "Single"
        case .multiSpeaker:
            return "Multi"
        }
    }
}

enum SystemAudioAccessState {
    case unknown
    case available
    case unavailable

    var title: String {
        switch self {
        case .unknown:
            return "Will prompt on first use"
        case .available:
            return "Granted"
        case .unavailable:
            return "Missing"
        }
    }
}

final class DictationController: ObservableObject, @unchecked Sendable {
    enum State: String {
        case idle = "Idle"
        case listening = "Listening"
    }

    private static let outputModeDefaultsKey = "dictationOutputMode"

    @Published private(set) var state: State = .idle
    @Published private(set) var previewText = ""
    @Published private(set) var lastError = ""
    @Published private(set) var microphoneAuthorized = false
    @Published private(set) var systemAudioAccessState: SystemAudioAccessState = .unknown
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var inputMonitoringAuthorized = false
    @Published var outputMode: DictationOutputMode {
        didSet {
            UserDefaults.standard.set(outputMode.rawValue, forKey: Self.outputModeDefaultsKey)
        }
    }

    let hotkeyDescription: String

    var menuBarIconName: String {
        "moon.stars.fill"
    }

    private let modelURL: URL?
    private let audioEngine = AudioEngine()
    private let systemAudioCapture = SystemAudioCapture()
    private let chunkBuffer = MixedChunkBuffer()
    private let textStateManager = TextStateManager()
    private let textInjector = TextInjector()
    private let hotkeyManager: HotkeyManager
    private let processingQueue = DispatchQueue(label: "ai.moonshine.flow.dictation")
    private var transcriber: Transcriber?
    private var insertionMode: TextInjector.InsertionMode = .pasteboard
    private var streamingFailed = false
    private var sessionOutputMode: DictationOutputMode
    private let startSound = NSSound(named: "Blow")
    private let stopSound = NSSound(named: "Bottle")

    init(modelURL: URL?, hotkey: HotkeyManager.Hotkey = .rightOption) {
        self.modelURL = modelURL
        self.hotkeyManager = HotkeyManager(hotkey: hotkey)
        self.hotkeyDescription = hotkey.displayName
        let savedOutputMode = UserDefaults.standard.string(forKey: Self.outputModeDefaultsKey)
        let initialOutputMode = DictationOutputMode(rawValue: savedOutputMode ?? "")
            ?? .singleSpeaker
        self.outputMode = initialOutputMode
        self.sessionOutputMode = initialOutputMode

        audioEngine.onBuffer = { [weak self] buffer, hostTime in
            self?.handleAudioChunk(buffer, hostTime: hostTime, source: .microphone)
        }
        systemAudioCapture.onBuffer = { [weak self] buffer, hostTime in
            self?.handleAudioChunk(buffer, hostTime: hostTime, source: .systemAudio)
        }
        chunkBuffer.onChunkReady = { [weak self] chunk in
            self?.processChunkSynchronously(chunk)
        }
        hotkeyManager.onPressChanged = { [weak self] isPressed in
            if isPressed {
                self?.startSession()
            } else {
                self?.stopSession()
            }
        }
        hotkeyManager.onInstallFailure = { [weak self] message in
            self?.lastError = message
        }

        refreshPermissions()
        hotkeyManager.start()

        // Pre-initialize the transcriber so the first keypress isn't slow
        if let modelURL, FileManager.default.fileExists(atPath: modelURL.path) {
            processingQueue.async { [weak self] in
                self?.transcriber = Transcriber(modelPath: modelURL.path)
            }
        }
    }

    deinit {
        hotkeyManager.stop()
        audioEngine.stop()
        systemAudioCapture.stop()
        transcriber?.close()
    }

    static func makeDefault() -> DictationController {
        #if SWIFT_PACKAGE
        let resourceRoot = Bundle.module.resourceURL
        #else
        let resourceRoot = Bundle.main.resourceURL
        #endif
        let modelURL = resourceRoot?
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("medium-streaming-en", isDirectory: true)
        return DictationController(modelURL: modelURL)
    }

    func startSession() {
        guard state == .idle else { return }

        refreshPermissions()
        lastError = ""
        previewText = ""
        streamingFailed = false
        sessionOutputMode = outputMode

        do {
            try ensureMicrophonePermission()

            guard let modelURL, FileManager.default.fileExists(atPath: modelURL.path) else {
                throw DictationError.modelMissing
            }

            if transcriber == nil {
                transcriber = Transcriber(modelPath: modelURL.path)
            }

            // Detect insertion mode and begin streaming session before starting audio
            textInjector.beginStreamingSession()
            insertionMode = textInjector.detectInsertionMode()

            try transcriber?.reset()
            textStateManager.reset()
            chunkBuffer.reset()
            state = .listening
            startSound?.play()
            try audioEngine.start()
            do {
                try systemAudioCapture.start()
                DispatchQueue.main.async { [weak self] in
                    self?.systemAudioAccessState = .available
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.systemAudioAccessState = .unavailable
                    self?.lastError = "System audio capture unavailable. \(error.localizedDescription)"
                }
            }
        } catch {
            textInjector.endStreamingSession()
            state = .idle
            lastError = error.localizedDescription
        }
    }

    func stopSession() {
        guard state == .listening else { return }

        audioEngine.stop()
        systemAudioCapture.stop()

        processingQueue.async { [weak self] in
            guard let self else { return }

            if let finalChunk = self.chunkBuffer.flush() {
                self.processChunkSynchronously(finalChunk)
            }

            let finalText = self.transcriber?.finalize(outputMode: self.sessionOutputMode) ?? ""

            // flush returns only what hasn't been streamed yet
            let remainingText = self.textStateManager.flush(finalText: finalText)

            // For AX mode: end streaming session first (removes partial text),
            // then insert whatever remains
            if self.insertionMode == .accessibility {
                self.textInjector.endStreamingSession()
                if !remainingText.isEmpty {
                    self.textInjector.insert(text: remainingText)
                }
            } else {
                // For pasteboard mode: insert remaining text, then end session
                if !remainingText.isEmpty {
                    self.textInjector.insert(text: remainingText)
                }
                self.textInjector.endStreamingSession()
            }

            DispatchQueue.main.async {
                self.stopSound?.play()
                self.previewText = finalText
                self.state = .idle
            }
        }
    }

    func requestAccessibilityPermission() {
        textInjector.requestAccessibilityPrompt()
        refreshPermissions()
    }

    func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneAuthorized = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.microphoneAuthorized = granted
                }
            }
        default:
            microphoneAuthorized = false
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openSystemAudioSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func refreshPermissions() {
        accessibilityTrusted = textInjector.isAccessibilityTrusted
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        inputMonitoringAuthorized = CGPreflightListenEventAccess()
    }

    private func handleAudioChunk(
        _ buffer: AVAudioPCMBuffer,
        hostTime: UInt64,
        source: AudioCaptureSource
    ) {
        processingQueue.async { [weak self] in
            self?.chunkBuffer.append(buffer, hostTime: hostTime, source: source)
        }
    }

    private func processChunkSynchronously(_ chunk: AudioChunk) {
        guard state != .idle else { return }

        do {
            guard let result = try transcriber?.process(chunk, outputMode: sessionOutputMode) else { return }
            let delta = textStateManager.update(with: result)

            // Stream text into the focused app
            if !streamingFailed {
                let hasNewContent = !delta.newCommittedSuffix.isEmpty
                    || delta.updatedPartial != delta.previousPartial
                if hasNewContent {
                    let ok = textInjector.streamInsert(delta: delta, mode: insertionMode)
                    if !ok {
                        streamingFailed = true
                    }
                }
            }

            // Update preview in menu bar popover
            let combinedPreview = result.committedText + result.partialText

            DispatchQueue.main.async { [weak self] in
                self?.previewText = combinedPreview
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = error.localizedDescription
            }
        }
    }

    private func ensureMicrophonePermission() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneAuthorized = true
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { access in
                granted = access
                semaphore.signal()
            }
            semaphore.wait()
            microphoneAuthorized = granted

            if !granted {
                throw DictationError.microphonePermissionDenied
            }
        default:
            microphoneAuthorized = false
            throw DictationError.microphonePermissionDenied
        }
    }
}

private enum DictationError: LocalizedError {
    case modelMissing
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "Moonshine model files are missing from the app bundle."
        case .microphonePermissionDenied:
            return "Microphone permission is required to start dictation."
        }
    }
}
