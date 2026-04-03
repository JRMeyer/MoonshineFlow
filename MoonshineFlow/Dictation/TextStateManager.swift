import Foundation

struct StreamingTextDelta {
    let newCommittedSuffix: String
    let updatedPartial: String
    let previousPartial: String
    let replacementText: String?
}

final class TextStateManager {
    private var lastEmittedCommitted = ""
    private var lastEmittedPartial = ""
    private var previousCommitted = ""
    private var previousPartial = ""

    func reset() {
        lastEmittedCommitted = ""
        lastEmittedPartial = ""
        previousCommitted = ""
        previousPartial = ""
    }

    func update(with result: TranscriptionResult) -> StreamingTextDelta {
        let committed = result.committedText
        let partial = result.partialText

        previousCommitted = lastEmittedCommitted
        previousPartial = lastEmittedPartial

        var newCommittedSuffix: String
        var replacementText: String?
        if committed.hasPrefix(lastEmittedCommitted) {
            newCommittedSuffix = String(committed.dropFirst(lastEmittedCommitted.count))
        } else if !committed.isEmpty {
            newCommittedSuffix = ""
            replacementText = committed + partial
        } else {
            newCommittedSuffix = ""
        }

        let previousPartial = lastEmittedPartial

        lastEmittedCommitted = committed
        lastEmittedPartial = partial

        return StreamingTextDelta(
            newCommittedSuffix: newCommittedSuffix,
            updatedPartial: partial,
            previousPartial: previousPartial,
            replacementText: replacementText
        )
    }

    func rollbackLastUpdate() {
        lastEmittedCommitted = previousCommitted
        lastEmittedPartial = previousPartial
    }

    func flush(finalText: String) -> String {
        let normalized = finalText

        // Return only what hasn't been inserted yet
        let alreadyInserted = lastEmittedCommitted
        var remaining: String
        if normalized.hasPrefix(alreadyInserted) {
            remaining = String(normalized.dropFirst(alreadyInserted.count))
        } else {
            remaining = normalized
        }

        lastEmittedCommitted = normalized
        lastEmittedPartial = ""
        previousCommitted = normalized
        previousPartial = ""
        return remaining
    }
}
