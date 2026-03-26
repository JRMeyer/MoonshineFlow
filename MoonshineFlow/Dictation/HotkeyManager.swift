import CoreGraphics
import Foundation

final class HotkeyManager {
    enum Hotkey {
        case fn
        case capsLock
        case rightOption

        var keyCode: CGKeyCode {
            switch self {
            case .fn:
                return 63
            case .capsLock:
                return 57
            case .rightOption:
                return 61
            }
        }

        var displayName: String {
            switch self {
            case .fn:
                return "Double-tap fn"
            case .capsLock:
                return "Double-tap Caps Lock"
            case .rightOption:
                return "Double-tap right ⌥"
            }
        }
    }

    var onPressChanged: ((Bool) -> Void)?
    var onInstallFailure: ((String) -> Void)?

    private let hotkey: Hotkey
    private let doubleTapInterval: TimeInterval = 0.4
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isKeyDown = false
    private var isActive = false
    private var lastReleaseTime: TimeInterval = 0

    init(hotkey: Hotkey = .fn) {
        self.hotkey = hotkey
    }

    deinit {
        stop()
    }

    func start() {
        guard eventTap == nil else { return }

        let eventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            manager.handleEvent(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            onInstallFailure?("Global hotkey registration failed. Enable Accessibility or Input Monitoring and relaunch.")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source

        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        runLoopSource = nil
        eventTap = nil
        isKeyDown = false
        isActive = false
    }

    private func handleEvent(type: CGEventType, event: CGEvent) {
        if type.rawValue == UInt32(CGEventType.tapDisabledByTimeout.rawValue) {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(hotkey.keyCode) else {
            return
        }

        let pressed: Bool
        switch type {
        case .keyDown:
            pressed = true
        case .keyUp:
            pressed = false
        case .flagsChanged:
            pressed = isHotkeyPressed(flags: event.flags)
        default:
            return
        }

        guard pressed != isKeyDown else { return }
        isKeyDown = pressed

        if !pressed {
            // Key was released — check for double-tap or deactivation
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - lastReleaseTime
            lastReleaseTime = now

            if isActive {
                // Currently dictating — single tap stops
                isActive = false
                onPressChanged?(false)
            } else if elapsed < doubleTapInterval {
                // Double-tap detected — start dictating
                isActive = true
                onPressChanged?(true)
            }
        }
    }

    private func isHotkeyPressed(flags: CGEventFlags) -> Bool {
        switch hotkey {
        case .fn:
            return flags.contains(.maskSecondaryFn)
        case .capsLock:
            return flags.contains(.maskAlphaShift)
        case .rightOption:
            return flags.contains(.maskAlternate)
        }
    }
}
