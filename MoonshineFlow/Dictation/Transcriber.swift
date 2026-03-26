import Foundation
import MoonshineVoice

struct TranscriptionResult {
    let committedText: String
    let partialText: String
}

final class Transcriber {
    private struct LineState {
        var order: Int
        var text: String
        var isComplete: Bool
    }

    private let modelPath: String
    private let modelArch: ModelArch
    private let updateInterval: TimeInterval
    private let options: [TranscriberOption]
    private let lock = NSLock()

    private var moonshineTranscriber: MoonshineVoice.Transcriber?
    private var stream: MoonshineVoice.Stream?
    private var lines: [UInt64: LineState] = [:]
    private var nextOrder = 0

    init(
        modelPath: String,
        modelArch: ModelArch = .mediumStreaming,
        updateInterval: TimeInterval = 0.35,
        options: [TranscriberOption] = []
    ) {
        self.modelPath = modelPath
        self.modelArch = modelArch
        self.updateInterval = updateInterval
        self.options = options
    }

    deinit {
        close()
    }

    func reset() throws {
        if moonshineTranscriber == nil {
            moonshineTranscriber = try MoonshineVoice.Transcriber(
                modelPath: modelPath,
                modelArch: modelArch,
                options: options
            )
        }

        closeStream()
        lines.removeAll()
        nextOrder = 0

        guard let moonshineTranscriber else { return }

        let stream = try moonshineTranscriber.createStream(updateInterval: updateInterval)
        try stream.addListener { [weak self] event in
            self?.handle(event)
        }
        try stream.start()
        self.stream = stream
    }

    func process(_ chunk: AudioChunk) throws -> TranscriptionResult {
        guard let stream else { return TranscriptionResult(committedText: "", partialText: "") }
        try stream.addAudio(chunk.samples, sampleRate: chunk.sampleRate)
        return snapshot()
    }

    func finalize() -> String {
        if let stream {
            try? stream.stop()
        }

        let finalText = snapshot(includeIncomplete: true).committedText
        closeStream()
        return finalText
    }

    func close() {
        closeStream()
        moonshineTranscriber?.close()
        moonshineTranscriber = nil
    }

    private func closeStream() {
        stream?.close()
        stream = nil
    }

    private func handle(_ event: TranscriptEvent) {
        let line = event.line
        let normalizedText = normalize(line.text)

        lock.lock()
        defer { lock.unlock() }

        var state = lines[line.lineId] ?? LineState(order: nextOrder, text: "", isComplete: false)
        if lines[line.lineId] == nil {
            nextOrder += 1
        }

        switch event {
        case is LineStarted:
            state.text = normalizedText
            state.isComplete = line.isComplete
        case is LineTextChanged, is LineUpdated:
            state.text = normalizedText
            state.isComplete = line.isComplete
        case is LineCompleted:
            state.text = normalizedText
            state.isComplete = true
        case is TranscriptError:
            break
        default:
            break
        }

        lines[line.lineId] = state
    }

    private func snapshot(includeIncomplete: Bool = false) -> TranscriptionResult {
        lock.lock()
        defer { lock.unlock() }

        let orderedLines = lines.values.sorted { $0.order < $1.order }
        let committed = orderedLines
            .filter { includeIncomplete || $0.isComplete }
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let partial = orderedLines
            .filter { !$0.isComplete }
            .map(\.text)
            .last ?? ""

        return TranscriptionResult(
            committedText: committed,
            partialText: includeIncomplete ? "" : partial
        )
    }

    private func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
