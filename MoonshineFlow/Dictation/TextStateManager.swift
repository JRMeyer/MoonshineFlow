import Foundation

struct StreamingTextDelta {
    let newCommittedSuffix: String
    let updatedPartial: String
    let previousPartial: String
}

final class TextStateManager {
    private var lastEmittedCommitted = ""
    private var lastEmittedPartial = ""

    func reset() {
        lastEmittedCommitted = ""
        lastEmittedPartial = ""
    }

    func update(with result: TranscriptionResult) -> StreamingTextDelta {
        let committed = result.committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let partial = result.partialText.trimmingCharacters(in: .whitespacesAndNewlines)

        var newCommittedSuffix: String
        if committed.hasPrefix(lastEmittedCommitted) {
            newCommittedSuffix = String(committed.dropFirst(lastEmittedCommitted.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if !committed.isEmpty {
            newCommittedSuffix = committed
        } else {
            newCommittedSuffix = ""
        }

        // Ensure space between previously inserted text and new committed text
        let hasExistingText = !lastEmittedCommitted.isEmpty || !lastEmittedPartial.isEmpty
        if !newCommittedSuffix.isEmpty && hasExistingText {
            newCommittedSuffix = " " + newCommittedSuffix
        }

        let previousPartial = lastEmittedPartial

        // Ensure space before partial when there's committed text before it
        let spacedPartial: String
        if !partial.isEmpty && !committed.isEmpty {
            spacedPartial = " " + partial
        } else {
            spacedPartial = partial
        }

        let spacedPreviousPartial: String
        if !previousPartial.isEmpty && !lastEmittedCommitted.isEmpty {
            spacedPreviousPartial = " " + previousPartial
        } else {
            spacedPreviousPartial = previousPartial
        }

        lastEmittedCommitted = committed
        lastEmittedPartial = partial

        return StreamingTextDelta(
            newCommittedSuffix: newCommittedSuffix,
            updatedPartial: spacedPartial,
            previousPartial: spacedPreviousPartial
        )
    }

    func flush(finalText: String) -> String {
        let normalized = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Return only what hasn't been inserted yet
        let alreadyInserted = lastEmittedCommitted
        var remaining: String
        if normalized.hasPrefix(alreadyInserted) {
            remaining = String(normalized.dropFirst(alreadyInserted.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            remaining = normalized
        }

        // Add leading space if there's already text in the field
        if !remaining.isEmpty && !alreadyInserted.isEmpty {
            remaining = " " + remaining
        }

        lastEmittedCommitted = normalized
        lastEmittedPartial = ""
        return remaining
    }
}
