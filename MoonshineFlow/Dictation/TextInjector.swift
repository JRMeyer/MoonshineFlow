import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import Foundation
import os.log

private let axLog = Logger(subsystem: "ai.moonshine.flow", category: "TextInjector")

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
    private var streamedInsertionLength = 0
    private var cachedElement: AXUIElement?
    private var latchedAppPID: pid_t?

    func requestAccessibilityPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Session lifecycle

    func beginStreamingSession(focusLocked: Bool) {
        savedClipboard = NSPasteboard.general.string(forType: .string)
        partialInsertionLength = 0
        streamedInsertionLength = 0
        cachedElement = nil
        latchedAppPID = focusLocked
            ? NSWorkspace.shared.frontmostApplication?.processIdentifier
            : nil
    }

    /// End the streaming session. Returns `true` if `remainingText` was successfully
    /// inserted via the cached/latched element, `false` if the caller should fall back.
    @discardableResult
    func endStreamingSession(insertingRemainingText remainingText: String? = nil) -> Bool {
        // Resolve the element for cleanup and final insertion
        let element: AXUIElement? = cachedElement ?? {
            if let pid = latchedAppPID {
                return focusedElement(inApp: pid)
            }
            return nil
        }()

        // Remove any outstanding partial text
        if partialInsertionLength > 0, let element {
            removePartialText(from: element)
        }

        // Insert remaining text via the resolved element (needed for latched focus
        // where the frontmost app may no longer be the original target)
        var didInsertRemaining = true
        if let text = remainingText, !text.isEmpty {
            if let element {
                didInsertRemaining = appendViaAccessibility(text, element: element)
            } else {
                didInsertRemaining = false
            }
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
        streamedInsertionLength = 0
        cachedElement = nil
        latchedAppPID = nil
        savedClipboard = nil
        return didInsertRemaining
    }

    func detectInsertionMode() -> InsertionMode {
        if isFocusedAppTerminal() {
            axLog.info("detectInsertionMode: terminal app → pasteboard")
            return .pasteboard
        }

        guard let element = focusedElement(), !isSecureField(element) else {
            axLog.warning("detectInsertionMode: no focused element or secure field → pasteboard")
            return .pasteboard
        }

        // Check that the value attribute is settable (works even when the field is
        // empty and kAXValueAttribute reads as nil, e.g. empty Notes documents).
        var settable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )
        let hasSelectedRange = copySelectedRange(from: element) != nil
        guard settableResult == .success, settable.boolValue, hasSelectedRange
        else {
            axLog.warning("detectInsertionMode: AX probe failed (settable=\(settableResult == .success && settable.boolValue), range=\(hasSelectedRange)) → pasteboard")
            return .pasteboard
        }

        axLog.info("detectInsertionMode: AX value is settable → accessibility")
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
        axLog.debug("streamInsert: committedLen=\((delta.newCommittedSuffix as NSString).length) partialLen=\((delta.updatedPartial as NSString).length) prevPartialLen=\((delta.previousPartial as NSString).length) hasReplacement=\(delta.replacementText != nil)")

        guard let (element, currentValue, selectedRange) = resolveStreamingElement() else {
            axLog.error("streamInsert: resolveStreamingElement FAILED")
            return false
        }

        let nsValue = currentValue as NSString

        if let replacementText = delta.replacementText {
            let replaceLocation = selectedRange.location - streamedInsertionLength
            guard replaceLocation >= 0, replaceLocation + streamedInsertionLength <= nsValue.length else {
                axLog.error("streamInsert(replace): bounds check failed loc=\(replaceLocation) streamed=\(self.streamedInsertionLength) valLen=\(nsValue.length)")
                return false
            }

            let replaceRange = NSRange(location: replaceLocation, length: streamedInsertionLength)
            let updatedValue = nsValue.replacingCharacters(in: replaceRange, with: replacementText)
            let setResult = AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                updatedValue as CFTypeRef
            )
            guard setResult == .success else {
                axLog.error("streamInsert(replace): AXSetValue FAILED result=\(setResult.rawValue)")
                return false
            }

            let replacementLength = (replacementText as NSString).length
            let partialLength = (delta.updatedPartial as NSString).length
            let cursorPosition = replaceLocation + replacementLength
            streamedInsertionLength = replacementLength
            partialInsertionLength = partialLength

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

        // Calculate the range to replace: the previous partial text we inserted
        let replaceLocation = selectedRange.location - partialInsertionLength
        guard replaceLocation >= 0, replaceLocation + partialInsertionLength <= nsValue.length else {
            axLog.error("streamInsert: bounds check failed loc=\(replaceLocation) partial=\(self.partialInsertionLength) valLen=\(nsValue.length) selLoc=\(selectedRange.location)")
            return false
        }

        let replaceRange = NSRange(location: replaceLocation, length: partialInsertionLength)

        // Streaming deltas already include any required separators.
        var parts: [String] = []
        if !delta.newCommittedSuffix.isEmpty {
            parts.append(delta.newCommittedSuffix)
        }
        if !delta.updatedPartial.isEmpty {
            parts.append(delta.updatedPartial)
        }

        let insertText: String
        if !parts.isEmpty {
            insertText = parts.joined()
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
        guard setResult == .success else {
            axLog.error("streamInsert: AXSetValue FAILED result=\(setResult.rawValue)")
            return false
        }
        axLog.debug("streamInsert: OK, inserted length=\((insertText as NSString).length) at \(replaceLocation)")

        // Track how much of what we inserted is partial (replaceable next time)
        let partialLen = (delta.updatedPartial as NSString).length
        let totalInserted = (insertText as NSString).length
        let cursorPosition = replaceLocation + totalInserted

        streamedInsertionLength = streamedInsertionLength - partialInsertionLength + totalInserted
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
        guard containsVisibleContent(text) else { return true }

        guard
            let currentValue = copyValueString(from: element),
            let selectedRange = copySelectedRange(from: element)
        else {
            return false
        }

        let nsValue = currentValue as NSString
        guard selectedRange.location != NSNotFound,
              selectedRange.location + selectedRange.length <= nsValue.length else {
            return false
        }

        let updatedValue = nsValue.replacingCharacters(in: selectedRange, with: text)
        let setResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        )
        guard setResult == .success else { return false }

        let newCursor = selectedRange.location + (text as NSString).length
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
              let currentValue = copyValueString(from: element),
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

        streamedInsertionLength -= partialInsertionLength
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
        guard containsVisibleContent(text) else { return true }

        if !isFocusedAppTerminal(), insertViaAccessibility(text) {
            return true
        }

        return insertViaPasteboard(text)
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

    private func focusedElement(inApp pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
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

    /// Read the value attribute, handling empty fields (nil → "") and attributed strings.
    private func copyValueString(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        )
        // Empty field — treat as empty string (common in Notes for new documents)
        if result == .noValue { return "" }
        guard result == .success else { return nil }
        guard let value else { return "" }
        if let str = value as? String { return str }
        if let attrStr = value as? NSAttributedString { return attrStr.string }
        return nil
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

    /// Resolve a valid AX element for streaming, retrying with a fresh lookup if the cache is stale.
    /// When focus is latched, re-resolves within the original app rather than following system focus.
    private func resolveStreamingElement() -> (element: AXUIElement, value: String, selection: NSRange)? {
        if let cached = cachedElement, !isSecureField(cached),
           let val = copyValueString(from: cached),
           let range = copySelectedRange(from: cached) {
            axLog.debug("resolveStreamingElement: cached hit, val.len=\(val.count) range=\(range.location),\(range.length)")
            return (cached, val, range)
        }
        // Cached element is missing or stale — try a fresh lookup
        let hadCache = cachedElement != nil
        cachedElement = nil
        let fresh: AXUIElement?
        if let pid = latchedAppPID {
            fresh = focusedElement(inApp: pid)
            axLog.info("resolveStreamingElement: cache \(hadCache ? "stale" : "nil"), re-resolved via latched PID \(pid), got=\(fresh != nil)")
        } else {
            fresh = focusedElement()
            axLog.info("resolveStreamingElement: cache \(hadCache ? "stale" : "nil"), re-resolved via system focus, got=\(fresh != nil)")
        }
        guard let fresh, !isSecureField(fresh),
              let val = copyValueString(from: fresh),
              let range = copySelectedRange(from: fresh) else {
            axLog.error("resolveStreamingElement: fresh element failed AX probe")
            return nil
        }
        axLog.info("resolveStreamingElement: fresh element OK, val.len=\(val.count) range=\(range.location),\(range.length)")
        cachedElement = fresh
        return (fresh, val, range)
    }

    private func containsVisibleContent(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
