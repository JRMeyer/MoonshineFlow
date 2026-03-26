import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import Foundation

final class TextInjector: @unchecked Sendable {
    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

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

    private func insertViaAccessibility(_ text: String) -> Bool {
        guard let focusedElement = focusedElement(), !isSecureField(focusedElement) else {
            return false
        }

        guard
            let currentValue = copyStringAttribute(kAXValueAttribute, from: focusedElement),
            let selectedRange = copySelectedRange(from: focusedElement)
        else {
            return false
        }

        let nsValue = currentValue as NSString
        guard selectedRange.location != NSNotFound else { return false }
        guard selectedRange.location + selectedRange.length <= nsValue.length else { return false }

        let updatedValue = nsValue.replacingCharacters(in: selectedRange, with: text)
        let setValueResult = AXUIElementSetAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        )
        guard setValueResult == .success else {
            return false
        }

        var newRange = CFRange(location: selectedRange.location + (text as NSString).length, length: 0)
        guard let newRangeValue = AXValueCreate(.cfRange, &newRange) else {
            return true
        }

        _ = AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            newRangeValue
        )
        return true
    }

    private func insertViaPasteboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general

        // Save existing clipboard content
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return false
        }

        // Small delay to ensure modifier keys from hotkey release are cleared
        Thread.sleep(forTimeInterval: 0.1)

        guard simulateCommandV() else {
            return false
        }

        // Restore previous clipboard after a delay
        if let previousContents {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                pasteboard.clearContents()
                pasteboard.setString(previousContents, forType: .string)
            }
        }

        return true
    }

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
