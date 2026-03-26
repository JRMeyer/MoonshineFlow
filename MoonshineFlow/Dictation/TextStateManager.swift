import Foundation

final class TextStateManager {
    private var lastEmittedText = ""

    func reset() {
        lastEmittedText = ""
    }

    func update(with result: TranscriptionResult) -> String {
        incrementalSuffix(for: result.committedText)
    }

    func flush(finalText: String) -> String {
        incrementalSuffix(for: finalText)
    }

    private func incrementalSuffix(for candidate: String) -> String {
        let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }

        if normalized.hasPrefix(lastEmittedText) {
            let suffix = String(normalized.dropFirst(lastEmittedText.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lastEmittedText = normalized
            return suffix
        }

        lastEmittedText = normalized
        return normalized
    }
}
