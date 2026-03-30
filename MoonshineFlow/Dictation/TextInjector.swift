import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import Foundation

final class TextInjector: @unchecked Sendable {
    enum InsertionMode {
        case accessibility
        case pasteboard
    }

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    private var savedClipboard: String?
    private var partialInsertionLength = 0
    private var cachedElement: AXUIElement?

    func requestAccessibilityPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Session lifecycle

    func beginStreamingSession() {
        savedClipboard = NSPasteboard.general.string(forType: .string)
        partialInsertionLength = 0
        cachedElement = nil
    }

    func endStreamingSession() {
        // Remove any outstanding partial text
        if partialInsertionLength > 0, let element = cachedElement {
            removePartialText(from: element)
        }

        // Restore clipboard after a delay so any pending Cmd+V paste completes first
        if let saved = savedClipboard {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(saved, forType: .string)
            }
        }

        partialInsertionLength = 0
        cachedElement = nil
        savedClipboard = nil
    }

    func detectInsertionMode() -> InsertionMode {
        if isFocusedAppTerminal() {
            return .pasteboard
        }

        // Probe whether AX insertion would work
        guard let element = focusedElement(), !isSecureField(element) else {
            return .pasteboard
        }

        guard
            copyStringAttribute(kAXValueAttribute, from: element) != nil,
            copySelectedRange(from: element) != nil
        else {
            return .pasteboard
        }

        cachedElement = element
        return .accessibility
    }

    // MARK: - Streaming insertion

    @discardableResult
    func streamInsert(delta: StreamingTextDelta, mode: InsertionMode) -> Bool {
        switch mode {
        case .accessibility:
            return streamInsertViaAccessibility(delta)
        case .pasteboard:
            return streamInsertViaPasteboard(delta)
        }
    }

    private func streamInsertViaAccessibility(_ delta: StreamingTextDelta) -> Bool {
        guard let element = cachedElement ?? focusedElement(),
              !isSecureField(element) else {
            return false
        }

        guard
            let currentValue = copyStringAttribute(kAXValueAttribute, from: element),
            let selectedRange = copySelectedRange(from: element)
        else {
            return false
        }

        let nsValue = currentValue as NSString

        // Calculate the range to replace: the previous partial text we inserted
        let replaceLocation = selectedRange.location - partialInsertionLength
        guard replaceLocation >= 0, replaceLocation + partialInsertionLength <= nsValue.length else {
            // Fallback: just append
            partialInsertionLength = 0
            return appendViaAccessibility(delta.newCommittedSuffix + " " + delta.updatedPartial, element: element)
        }

        let replaceRange = NSRange(location: replaceLocation, length: partialInsertionLength)

        // Build the replacement text: new committed suffix + space + updated partial
        var parts: [String] = []
        if !delta.newCommittedSuffix.isEmpty {
            parts.append(delta.newCommittedSuffix)
        }
        if !delta.updatedPartial.isEmpty {
            parts.append(delta.updatedPartial)
        }

        // If we had previous partial but there's also new committed text,
        // we need a leading space before committed text
        let insertText: String
        if !delta.newCommittedSuffix.isEmpty && partialInsertionLength > 0 {
            // Previous partial gets replaced by: committed + partial
            insertText = parts.joined(separator: " ")
        } else if !delta.updatedPartial.isEmpty {
            insertText = delta.updatedPartial
        } else if !delta.newCommittedSuffix.isEmpty {
            insertText = delta.newCommittedSuffix
        } else {
            return true
        }

        let updatedValue = nsValue.replacingCharacters(in: replaceRange, with: insertText)
        let setResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        )
        guard setResult == .success else { return false }

        // Track how much of what we inserted is partial (replaceable next time)
        let partialLen = (delta.updatedPartial as NSString).length
        let totalInserted = (insertText as NSString).length
        let cursorPosition = replaceLocation + totalInserted

        partialInsertionLength = partialLen

        // Move cursor to after all inserted text
        var newRange = CFRange(location: cursorPosition, length: 0)
        if let rangeValue = AXValueCreate(.cfRange, &newRange) {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
        }

        return true
    }

    private func appendViaAccessibility(_ text: String, element: AXUIElement) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        guard
            let currentValue = copyStringAttribute(kAXValueAttribute, from: element),
            let selectedRange = copySelectedRange(from: element)
        else {
            return false
        }

        let nsValue = currentValue as NSString
        guard selectedRange.location != NSNotFound,
              selectedRange.location + selectedRange.length <= nsValue.length else {
            return false
        }

        let updatedValue = nsValue.replacingCharacters(in: selectedRange, with: trimmed)
        let setResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        )
        guard setResult == .success else { return false }

        let newCursor = selectedRange.location + (trimmed as NSString).length
        var newRange = CFRange(location: newCursor, length: 0)
        if let rangeValue = AXValueCreate(.cfRange, &newRange) {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
        }

        return true
    }

    private func removePartialText(from element: AXUIElement) {
        guard partialInsertionLength > 0,
              let currentValue = copyStringAttribute(kAXValueAttribute, from: element),
              let selectedRange = copySelectedRange(from: element) else { return }

        let nsValue = currentValue as NSString
        let removeLocation = selectedRange.location - partialInsertionLength
        guard removeLocation >= 0, removeLocation + partialInsertionLength <= nsValue.length else { return }

        let removeRange = NSRange(location: removeLocation, length: partialInsertionLength)
        let updatedValue = nsValue.replacingCharacters(in: removeRange, with: "")

        let setResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        )

        if setResult == .success {
            var newRange = CFRange(location: removeLocation, length: 0)
            if let rangeValue = AXValueCreate(.cfRange, &newRange) {
                _ = AXUIElementSetAttributeValue(
                    element,
                    kAXSelectedTextRangeAttribute as CFString,
                    rangeValue
                )
            }
        }

        partialInsertionLength = 0
    }

    private func streamInsertViaPasteboard(_ delta: StreamingTextDelta) -> Bool {
        // For terminals: only insert committed text (partials can't be replaced)
        guard !delta.newCommittedSuffix.isEmpty else { return true }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(delta.newCommittedSuffix, forType: .string) else {
            return false
        }

        return simulateCommandV()
    }

    // MARK: - One-shot insertion (used at finalize)

    @discardableResult
    func insert(text: String) -> Bool {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return true }

        if !isFocusedAppTerminal(), insertViaAccessibility(normalizedText) {
            return true
        }

        return insertViaPasteboard(normalizedText)
    }

    private func isFocusedAppTerminal() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier else { return false }
        let terminalBundleIds = [
            "com.mitchellh.ghostty",
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "net.kovidgoyal.kitty",
            "co.zeit.hyper",
            "com.github.wez.wezterm",
        ]
        return terminalBundleIds.contains(bundleId)
    }

    // MARK: - One-shot AX insertion

    private func insertViaAccessibility(_ text: String) -> Bool {
        guard let element = focusedElement(), !isSecureField(element) else {
            return false
        }

        return appendViaAccessibility(text, element: element)
    }

    private func insertViaPasteboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let inSession = savedClipboard != nil

        // Only save clipboard if not in a streaming session (session manages its own save/restore)
        let previousContents = inSession ? nil : pasteboard.string(forType: .string)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return false
        }

        Thread.sleep(forTimeInterval: 0.1)

        guard simulateCommandV() else {
            return false
        }

        if let previousContents {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                pasteboard.clearContents()
                pasteboard.setString(previousContents, forType: .string)
            }
        }

        return true
    }

    // MARK: - Helpers

    private func simulateCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success, let focusedElement else {
            return nil
        }

        return (focusedElement as! AXUIElement)
    }

    private func isSecureField(_ element: AXUIElement) -> Bool {
        copyStringAttribute(kAXSubroleAttribute, from: element) == (kAXSecureTextFieldSubrole as String)
    }

    private func copyStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func copySelectedRange(from element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        )
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }

        let rangeValue = value as! AXValue
        var selectedRange = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &selectedRange) else {
            return nil
        }

        return NSRange(location: selectedRange.location, length: selectedRange.length)
    }
}
