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

enum DictationCapitalizationMode: String, CaseIterable, Identifiable {
    case standard
    case lowercase

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:
            return "Standard"
        case .lowercase:
            return "Lowercase"
        }
    }
}

enum AudioSourceMode: String, CaseIterable, Identifiable {
    case microphone
    case system
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone:
            return "Mic"
        case .system:
            return "System"
        case .both:
            return "Both"
        }
    }

    var capturesMicrophone: Bool {
        self == .microphone || self == .both
    }

    var capturesSystemAudio: Bool {
        self == .system || self == .both
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
    private static let capitalizationModeDefaultsKey = "dictationCapitalizationMode"
    private static let audioSourceModeDefaultsKey = "sessionAudioSourceMode"

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
    @Published var capitalizationMode: DictationCapitalizationMode {
        didSet {
            UserDefaults.standard.set(
                capitalizationMode.rawValue,
                forKey: Self.capitalizationModeDefaultsKey
            )
        }
    }
    @Published var audioSourceMode: AudioSourceMode {
        didSet {
            UserDefaults.standard.set(audioSourceMode.rawValue, forKey: Self.audioSourceModeDefaultsKey)
        }
    }

    let hotkeyDescription: String

    var menuBarIconName: String {
        "moon.stars.fill"
    }

    private let modelURL: URL?
    private let audioEngine = AudioEngine()
    private let systemAudioCapture = SystemAudioCapture()
    private let micChunkBuffer = ChunkBuffer()
    private let systemChunkBuffer = ChunkBuffer()
    private let textStateManager = TextStateManager()
    private let textInjector = TextInjector()
    private let hotkeyManager: HotkeyManager
    private let processingQueue = DispatchQueue(label: "ai.moonshine.flow.dictation")
    private var micTranscriber: Transcriber?
    private var systemTranscriber: Transcriber?
    private var insertionMode: TextInjector.InsertionMode = .pasteboard
    private var streamingFailed = false
    private var sessionOutputMode: DictationOutputMode
    private var sessionCapitalizationMode: DictationCapitalizationMode
    private var sessionAudioSourceMode: AudioSourceMode
    private var micCommittedSoFar = ""
    private var systemCommittedSoFar = ""
    private var mergedCommitted = ""
    private var micPartial = ""
    private var systemPartial = ""
    private let startSound = NSSound(named: "Blow")
    private let stopSound = NSSound(named: "Bottle")

    private final class PermissionRequestState: @unchecked Sendable {
        var granted = false
    }

    init(modelURL: URL?, hotkey: HotkeyManager.Hotkey = .rightOption) {
        self.modelURL = modelURL
        self.hotkeyManager = HotkeyManager(hotkey: hotkey)
        self.hotkeyDescription = hotkey.displayName

        let savedOutputMode = UserDefaults.standard.string(forKey: Self.outputModeDefaultsKey)
        let initialOutputMode = DictationOutputMode(rawValue: savedOutputMode ?? "")
            ?? .singleSpeaker
        let savedCapitalizationMode = UserDefaults.standard.string(
            forKey: Self.capitalizationModeDefaultsKey
        )
        let initialCapitalizationMode = DictationCapitalizationMode(
            rawValue: savedCapitalizationMode ?? ""
        ) ?? .standard
        let savedAudioSourceMode = UserDefaults.standard.string(
            forKey: Self.audioSourceModeDefaultsKey
        )
        let initialAudioSourceMode = AudioSourceMode(rawValue: savedAudioSourceMode ?? "")
            ?? .microphone

        self.outputMode = initialOutputMode
        self.capitalizationMode = initialCapitalizationMode
        self.audioSourceMode = initialAudioSourceMode
        self.sessionOutputMode = initialOutputMode
        self.sessionCapitalizationMode = initialCapitalizationMode
        self.sessionAudioSourceMode = initialAudioSourceMode

        audioEngine.onBuffer = { [weak self] buffer, hostTime in
            self?.handleAudioChunk(buffer, hostTime: hostTime, source: .microphone)
        }
        systemAudioCapture.onBuffer = { [weak self] buffer, hostTime in
            self?.handleAudioChunk(buffer, hostTime: hostTime, source: .systemAudio)
        }
        micChunkBuffer.onChunkReady = { [weak self] chunk in
            self?.processChunkSynchronously(chunk, source: .microphone)
        }
        systemChunkBuffer.onChunkReady = { [weak self] chunk in
            self?.processChunkSynchronously(chunk, source: .systemAudio)
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
        systemAudioCapture.stop()
        micTranscriber?.close()
        systemTranscriber?.close()
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
        sessionCapitalizationMode = capitalizationMode
        sessionAudioSourceMode = audioSourceMode

        do {
            guard let modelURL, FileManager.default.fileExists(atPath: modelURL.path) else {
                throw DictationError.modelMissing
            }

            textInjector.beginStreamingSession()
            insertionMode = textInjector.detectInsertionMode()

            if sessionAudioSourceMode.capturesMicrophone {
                try ensureMicrophonePermission()
            }

            try prepareSessionTranscribers(modelPath: modelURL.path)
            textStateManager.reset()
            resetMergeState()
            micChunkBuffer.reset()
            systemChunkBuffer.reset()

            state = .listening
            startSound?.play()

            if sessionAudioSourceMode.capturesMicrophone {
                try audioEngine.start()
            }

            if sessionAudioSourceMode.capturesSystemAudio {
                do {
                    try systemAudioCapture.start()
                    DispatchQueue.main.async { [weak self] in
                        self?.systemAudioAccessState = .available
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.systemAudioAccessState = .unavailable
                    }
                    throw DictationError.systemAudioCaptureUnavailable(error.localizedDescription)
                }
            }
        } catch {
            audioEngine.stop()
            systemAudioCapture.stop()
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

            if self.sessionAudioSourceMode.capturesMicrophone,
               let finalChunk = self.micChunkBuffer.flush() {
                self.processChunkSynchronously(finalChunk, source: .microphone)
            }

            if self.sessionAudioSourceMode.capturesSystemAudio,
               let finalChunk = self.systemChunkBuffer.flush() {
                self.processChunkSynchronously(finalChunk, source: .systemAudio)
            }

            if self.sessionAudioSourceMode.capturesMicrophone {
                let finalMicText = self.micTranscriber?.finalize(outputMode: self.sessionOutputMode) ?? ""
                self.updateMergedState(
                    with: TranscriptionResult(committedText: finalMicText, partialText: ""),
                    for: .microphone
                )
            }

            if self.sessionAudioSourceMode.capturesSystemAudio {
                let finalSystemText = self.systemTranscriber?.finalize(outputMode: self.sessionOutputMode) ?? ""
                self.updateMergedState(
                    with: TranscriptionResult(committedText: finalSystemText, partialText: ""),
                    for: .systemAudio
                )
            }

            let finalText = self.applyCapitalization(
                to: self.mergedTranscription().committedText,
                mode: self.sessionCapitalizationMode
            )

            let remainingText: String
            if self.insertionMode == .accessibility {
                remainingText = self.textStateManager.flush(finalText: finalText)
            } else {
                remainingText = finalText
            }

            if self.insertionMode == .accessibility {
                self.textInjector.endStreamingSession()
                if !remainingText.isEmpty {
                    self.textInjector.insert(text: remainingText)
                }
            } else {
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
        hostTime _: UInt64,
        source: AudioCaptureSource
    ) {
        processingQueue.async { [weak self] in
            self?.chunkBuffer(for: source)?.append(buffer)
        }
    }

    private func processChunkSynchronously(_ chunk: AudioChunk, source: AudioCaptureSource) {
        guard state != .idle else { return }

        do {
            guard let transcriber = transcriber(for: source) else { return }

            let result = try transcriber.process(chunk, outputMode: sessionOutputMode)
            updateMergedState(with: result, for: source)

            let mergedResult = mergedTranscription()
            let formattedResult = TranscriptionResult(
                committedText: applyCapitalization(
                    to: mergedResult.committedText,
                    mode: sessionCapitalizationMode
                ),
                partialText: applyCapitalization(
                    to: mergedResult.partialText,
                    mode: sessionCapitalizationMode
                )
            )
            if insertionMode == .accessibility {
                let delta = textStateManager.update(with: formattedResult)

                if !streamingFailed {
                    let hasNewContent = !delta.newCommittedSuffix.isEmpty
                        || delta.updatedPartial != delta.previousPartial
                        || delta.replacementText != nil
                    if hasNewContent {
                        let ok = textInjector.streamInsert(delta: delta, mode: insertionMode)
                        if !ok {
                            streamingFailed = true
                        }
                    }
                }
            }

            let combinedPreview = formattedResult.committedText + formattedResult.partialText
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
            let requestState = PermissionRequestState()
            AVCaptureDevice.requestAccess(for: .audio) { access in
                requestState.granted = access
                semaphore.signal()
            }
            semaphore.wait()
            microphoneAuthorized = requestState.granted

            if !requestState.granted {
                throw DictationError.microphonePermissionDenied
            }
        default:
            microphoneAuthorized = false
            throw DictationError.microphonePermissionDenied
        }
    }

    private func prepareSessionTranscribers(modelPath: String) throws {
        if sessionAudioSourceMode.capturesMicrophone {
            if micTranscriber == nil {
                micTranscriber = Transcriber(modelPath: modelPath)
            }
            try micTranscriber?.reset()
        }

        if sessionAudioSourceMode.capturesSystemAudio {
            if systemTranscriber == nil {
                systemTranscriber = Transcriber(modelPath: modelPath)
            }
            try systemTranscriber?.reset()
        }
    }

    private func resetMergeState() {
        micCommittedSoFar = ""
        systemCommittedSoFar = ""
        mergedCommitted = ""
        micPartial = ""
        systemPartial = ""
    }

    private func chunkBuffer(for source: AudioCaptureSource) -> ChunkBuffer? {
        switch source {
        case .microphone:
            return sessionAudioSourceMode.capturesMicrophone ? micChunkBuffer : nil
        case .systemAudio:
            return sessionAudioSourceMode.capturesSystemAudio ? systemChunkBuffer : nil
        }
    }

    private func transcriber(for source: AudioCaptureSource) -> Transcriber? {
        switch source {
        case .microphone:
            return micTranscriber
        case .systemAudio:
            return systemTranscriber
        }
    }

    private func updateMergedState(
        with result: TranscriptionResult,
        for source: AudioCaptureSource
    ) {
        switch source {
        case .microphone:
            micCommittedSoFar = result.committedText
            micPartial = result.partialText
        case .systemAudio:
            systemCommittedSoFar = result.committedText
            systemPartial = result.partialText
        }

        recomputeMergedCommitted()
    }

    private func mergedTranscription() -> TranscriptionResult {
        let partials = [micPartial, systemPartial].filter { !$0.isEmpty }
        let partialText: String
        if partials.isEmpty {
            partialText = ""
        } else if mergedCommitted.isEmpty {
            partialText = partials.joined(separator: " ")
        } else {
            partialText = " " + partials.joined(separator: " ")
        }

        return TranscriptionResult(
            committedText: mergedCommitted,
            partialText: partialText
        )
    }

    private func recomputeMergedCommitted() {
        let committedParts = [micCommittedSoFar, systemCommittedSoFar].filter { !$0.isEmpty }
        mergedCommitted = committedParts.joined(separator: " ")
    }

    private func applyCapitalization(
        to text: String,
        mode: DictationCapitalizationMode
    ) -> String {
        switch mode {
        case .standard:
            return text
        case .lowercase:
            return text.lowercased()
        }
    }
}

private enum DictationError: LocalizedError {
    case modelMissing
    case microphonePermissionDenied
    case systemAudioCaptureUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "Moonshine model files are missing from the app bundle."
        case .microphonePermissionDenied:
            return "Microphone permission is required to start dictation."
        case let .systemAudioCaptureUnavailable(message):
            return "System audio capture unavailable. \(message)"
        }
    }
}
