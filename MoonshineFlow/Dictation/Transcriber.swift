import Foundation
import MoonshineVoice

struct TranscriptionResult {
    let committedText: String
    let partialText: String
}

final class Transcriber {
    private struct SpeakerIdentity: Hashable {
        let speakerId: UInt64?
        let speakerIndex: UInt32
    }

    private struct LineState {
        var order: Int
        var text: String
        var isComplete: Bool
        var hasSpeakerId: Bool
        var speakerId: UInt64
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
            speakerId: 0,
            speakerIndex: 0
        )
        if lines[line.lineId] == nil {
            nextOrder += 1
        }

        state.hasSpeakerId = line.hasSpeakerId
        state.speakerId = line.speakerId
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
        let committedLines = includeIncomplete ? orderedLines : committedPrefix(from: orderedLines)
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

    private func committedPrefix(from orderedLines: [LineState]) -> [LineState] {
        var committedLines: [LineState] = []

        for line in orderedLines {
            guard line.isComplete else { break }
            committedLines.append(line)
        }

        return committedLines
    }

    private func format(lines: [LineState], outputMode: DictationOutputMode) -> String {
        let orderedNonEmptyLines = lines.filter { !$0.text.isEmpty }
        switch outputMode {
        case .singleSpeaker:
            return orderedNonEmptyLines.map(\.text).joined(separator: " ")
        case .multiSpeaker:
            var formatted = ""
            var speakerLabels: [SpeakerIdentity: Int] = [:]
            var nextSpeakerLabel = 1

            for line in orderedNonEmptyLines {
                if !formatted.isEmpty {
                    formatted += "\n\n"
                }

                if let speakerIdentity = speakerIdentity(for: line) {
                    let speakerLabel: Int
                    if let existingLabel = speakerLabels[speakerIdentity] {
                        speakerLabel = existingLabel
                    } else {
                        speakerLabel = nextSpeakerLabel
                        speakerLabels[speakerIdentity] = speakerLabel
                        nextSpeakerLabel += 1
                    }

                    formatted += "Speaker \(speakerLabel):\n"
                }

                formatted += line.text
            }

            return formatted
        }
    }

    private func speakerIdentity(for line: LineState) -> SpeakerIdentity? {
        guard line.hasSpeakerId else { return nil }
        let speakerId = line.speakerId == 0 ? nil : line.speakerId
        return SpeakerIdentity(speakerId: speakerId, speakerIndex: line.speakerIndex)
    }

    private func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
