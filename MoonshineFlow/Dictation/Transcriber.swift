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
        var hasSpeakerId: Bool
        var speakerIndex: UInt32
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
        stream.addListener { [weak self] event in
            self?.handle(event)
        }
        try stream.start()
        self.stream = stream
    }

    func process(_ chunk: AudioChunk, outputMode: DictationOutputMode) throws -> TranscriptionResult {
        guard let stream else { return TranscriptionResult(committedText: "", partialText: "") }
        try stream.addAudio(chunk.samples, sampleRate: chunk.sampleRate)
        return snapshot(outputMode: outputMode)
    }

    func finalize(outputMode: DictationOutputMode) -> String {
        if let stream {
            try? stream.stop()
        }

        let finalText = snapshot(includeIncomplete: true, outputMode: outputMode).committedText
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

        var state = lines[line.lineId] ?? LineState(
            order: nextOrder,
            text: "",
            isComplete: false,
            hasSpeakerId: false,
            speakerIndex: 0
        )
        if lines[line.lineId] == nil {
            nextOrder += 1
        }

        state.hasSpeakerId = line.hasSpeakerId
        state.speakerIndex = line.speakerIndex

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
        case let transcriptError as TranscriptError:
            NSLog("MoonshineFlow: transcript error on line %llu: %@", line.lineId, transcriptError.error.localizedDescription)
        default:
            break
        }

        lines[line.lineId] = state
    }

    private func snapshot(
        includeIncomplete: Bool = false,
        outputMode: DictationOutputMode
    ) -> TranscriptionResult {
        lock.lock()
        defer { lock.unlock() }

        let orderedLines = lines.values.sorted { $0.order < $1.order }
        let committedLines = orderedLines.filter { includeIncomplete || $0.isComplete }
        let committed = format(lines: committedLines, outputMode: outputMode)
        let partial: String
        if includeIncomplete {
            partial = ""
        } else {
            let fullText = format(lines: orderedLines, outputMode: outputMode)
            if fullText.hasPrefix(committed) {
                partial = String(fullText.dropFirst(committed.count))
            } else {
                partial = fullText
            }
        }

        return TranscriptionResult(
            committedText: committed,
            partialText: partial
        )
    }

    private func format(lines: [LineState], outputMode: DictationOutputMode) -> String {
        let orderedNonEmptyLines = lines.filter { !$0.text.isEmpty }
        switch outputMode {
        case .singleSpeaker:
            return orderedNonEmptyLines.map(\.text).joined(separator: " ")
        case .multiSpeaker:
            var formatted = ""
            var previousSpeakerIndex: UInt32?

            for line in orderedNonEmptyLines {
                let needsSpeakerHeader = line.hasSpeakerId && previousSpeakerIndex != line.speakerIndex

                if !formatted.isEmpty {
                    formatted += needsSpeakerHeader ? "\n\n" : " "
                }

                if needsSpeakerHeader {
                    formatted += "Speaker \(line.speakerIndex + 1):\n"
                }

                formatted += line.text

                if line.hasSpeakerId {
                    previousSpeakerIndex = line.speakerIndex
                }
            }

            return formatted
        }
    }

    private func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
