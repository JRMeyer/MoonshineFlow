@preconcurrency import AVFoundation
import AppKit
import Combine
import Foundation

final class DictationController: ObservableObject, @unchecked Sendable {
    enum State: String {
        case idle = "Idle"
        case listening = "Listening"
        case finalizing = "Finalizing"
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var previewText = ""
    @Published private(set) var lastInsertedText = ""
    @Published private(set) var lastError = ""
    @Published private(set) var microphoneAuthorized = false
    @Published private(set) var accessibilityTrusted = false

    let hotkeyDescription: String

    var menuBarIconName: String {
        switch state {
        case .idle:
            return "mic"
        case .listening:
            return "waveform.badge.mic"
        case .finalizing:
            return "hourglass"
        }
    }

    private let modelURL: URL?
    private let audioEngine = AudioEngine()
    private let chunkBuffer = ChunkBuffer()
    private let textStateManager = TextStateManager()
    private let textInjector = TextInjector()
    private let hotkeyManager: HotkeyManager
    private let processingQueue = DispatchQueue(label: "ai.moonshine.flow.dictation")
    private var transcriber: Transcriber?

    init(modelURL: URL?, hotkey: HotkeyManager.Hotkey = .fn) {
        self.modelURL = modelURL
        self.hotkeyManager = HotkeyManager(hotkey: hotkey)
        self.hotkeyDescription = hotkey.displayName

        audioEngine.onBuffer = { [weak self] buffer in
            self?.handleAudioChunk(buffer)
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
    }

    deinit {
        hotkeyManager.stop()
        audioEngine.stop()
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

        do {
            try ensureMicrophonePermission()

            guard let modelURL, FileManager.default.fileExists(atPath: modelURL.path) else {
                throw DictationError.modelMissing
            }

            if transcriber == nil {
                transcriber = Transcriber(modelPath: modelURL.path)
            }

            try transcriber?.reset()
            textStateManager.reset()
            chunkBuffer.reset()
            state = .listening
            try audioEngine.start()
        } catch {
            state = .idle
            lastError = error.localizedDescription
        }
    }

    func stopSession() {
        guard state == .listening else { return }

        state = .finalizing
        audioEngine.stop()

        processingQueue.async { [weak self] in
            guard let self else { return }

            if let finalChunk = self.chunkBuffer.flush() {
                self.processChunkSynchronously(finalChunk)
            }

            let finalText = self.transcriber?.finalize() ?? ""
            let textToInsert = self.textStateManager.flush(finalText: finalText)
            let didInsert = textToInsert.isEmpty || self.textInjector.insert(text: textToInsert)

            DispatchQueue.main.async {
                self.lastInsertedText = textToInsert
                self.previewText = finalText
                self.state = .idle

                if !didInsert {
                    self.lastError = "Text injection failed. Grant Accessibility access and try again."
                }
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

    func refreshPermissions() {
        accessibilityTrusted = textInjector.isAccessibilityTrusted
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func handleAudioChunk(_ buffer: AVAudioPCMBuffer) {
        processingQueue.async { [weak self] in
            self?.chunkBuffer.append(buffer)
        }
    }

    private func processChunkSynchronously(_ chunk: AudioChunk) {
        guard state != .idle else { return }

        do {
            guard let result = try transcriber?.process(chunk) else { return }
            _ = textStateManager.update(with: result)
            let combinedPreview = [result.committedText, result.partialText]
                .filter { !$0.isEmpty }
                .joined(separator: result.committedText.isEmpty ? "" : " ")

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
