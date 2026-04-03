import Foundation
import MoonshineVoice

struct TranscriptionResult {
    let committedText: String
    let partialText: String
    let turns: [TranscriptionTurn]
}

struct TranscriptionTurn {
    let lineId: UInt64
    let order: Int
    let startTime: Float
    let text: String
    let isComplete: Bool
    let speakerLabel: Int?
    let source: AudioCaptureSource?
}

final class Transcriber {
    private struct SpeakerIdentity: Hashable {
        let speakerId: UInt64?
        let speakerIndex: UInt32

        static func == (lhs: SpeakerIdentity, rhs: SpeakerIdentity) -> Bool {
            switch (lhs.speakerId, rhs.speakerId) {
            case let (.some(lhsSpeakerId), .some(rhsSpeakerId)):
                return lhsSpeakerId == rhsSpeakerId
            case (.none, .none):
                return lhs.speakerIndex == rhs.speakerIndex
            default:
                return false
            }
        }

        func hash(into hasher: inout Hasher) {
            if let speakerId {
                hasher.combine(0)
                hasher.combine(speakerId)
            } else {
                hasher.combine(1)
                hasher.combine(speakerIndex)
            }
        }
    }

    private struct LineState {
        var lineId: UInt64
        var order: Int
        var startTime: Float
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
        guard let stream else {
            return TranscriptionResult(committedText: "", partialText: "", turns: [])
        }
        try stream.addAudio(chunk.samples, sampleRate: chunk.sampleRate)
        return snapshot(outputMode: outputMode)
    }

    func finalizeResult(outputMode: DictationOutputMode) -> TranscriptionResult {
        if let stream {
            try? stream.stop()
        }

        let finalResult = snapshot(includeIncomplete: true, outputMode: outputMode)
        closeStream()
        return finalResult
    }

    func finalize(outputMode: DictationOutputMode) -> String {
        finalizeResult(outputMode: outputMode).committedText
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
            lineId: line.lineId,
            order: nextOrder,
            startTime: line.startTime,
            text: "",
            isComplete: false,
            hasSpeakerId: false,
            speakerId: 0,
            speakerIndex: 0
        )
        if lines[line.lineId] == nil {
            nextOrder += 1
        }

        state.lineId = line.lineId
        state.startTime = line.startTime
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
        let orderedTurns = turns(from: orderedLines, outputMode: outputMode)
        let committedLines = includeIncomplete ? orderedLines : committedPrefix(from: orderedLines)
        let committedLineIds = Set(committedLines.map(\.lineId))
        let committedTurns = includeIncomplete
            ? orderedTurns
            : orderedTurns.filter { committedLineIds.contains($0.lineId) }
        let committed = render(turns: committedTurns, outputMode: outputMode)
        let partial: String
        if includeIncomplete {
            partial = ""
        } else {
            let fullText = render(turns: orderedTurns, outputMode: outputMode)
            if fullText.hasPrefix(committed) {
                partial = String(fullText.dropFirst(committed.count))
            } else {
                partial = fullText
            }
        }

        return TranscriptionResult(
            committedText: committed,
            partialText: partial,
            turns: orderedTurns
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

    private func turns(from lines: [LineState], outputMode: DictationOutputMode) -> [TranscriptionTurn] {
        let orderedNonEmptyLines = lines.filter { !$0.text.isEmpty }
        switch outputMode {
        case .singleSpeaker:
            return orderedNonEmptyLines.map { line in
                TranscriptionTurn(
                    lineId: line.lineId,
                    order: line.order,
                    startTime: line.startTime,
                    text: line.text,
                    isComplete: line.isComplete,
                    speakerLabel: nil,
                    source: nil
                )
            }
        case .multiSpeaker:
            var speakerLabels: [SpeakerIdentity: Int] = [:]
            var nextSpeakerLabel = 1
            var turns: [TranscriptionTurn] = []

            for line in orderedNonEmptyLines {
                let speakerLabel: Int?
                if let speakerIdentity = speakerIdentity(for: line) {
                    if let existingLabel = speakerLabels[speakerIdentity] {
                        speakerLabel = existingLabel
                    } else {
                        let assignedLabel = nextSpeakerLabel
                        speakerLabel = assignedLabel
                        speakerLabels[speakerIdentity] = assignedLabel
                        nextSpeakerLabel += 1
                    }
                } else {
                    speakerLabel = nil
                }
                turns.append(
                    TranscriptionTurn(
                        lineId: line.lineId,
                        order: line.order,
                        startTime: line.startTime,
                        text: line.text,
                        isComplete: line.isComplete,
                        speakerLabel: speakerLabel,
                        source: nil
                    )
                )
            }

            return turns
        }
    }

    private func render(turns: [TranscriptionTurn], outputMode: DictationOutputMode) -> String {
        guard !turns.isEmpty else { return "" }
        switch outputMode {
        case .singleSpeaker:
            return turns.map(\.text).joined(separator: " ")
        case .multiSpeaker:
            var blocks: [String] = []

            for turn in turns {
                if let speakerLabel = turn.speakerLabel {
                    let header = "Speaker \(speakerLabel):"
                    if let lastIndex = blocks.indices.last,
                       blocks[lastIndex].hasPrefix(header + "\n") {
                        blocks[lastIndex] += "\n" + turn.text
                    } else {
                        blocks.append(header + "\n" + turn.text)
                    }
                } else {
                    blocks.append(turn.text)
                }
            }

            return blocks.joined(separator: "\n\n")
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
