import AppKit
import SwiftUI

@main
struct MoonshineFlowApp: App {
    @StateObject private var controller = DictationController.makeDefault()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(controller: controller)
                .frame(width: 320)
        } label: {
            MenuBarIconView(isListening: controller.state == .listening)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: controller)
                .frame(width: 420, height: 320)
        }
    }
}

private struct MenuBarIconView: View {
    let isListening: Bool

    var body: some View {
        Image(nsImage: MenuBarIconImage.make(isListening: isListening))
            .interpolation(.high)
            .accessibilityLabel(
                isListening ? "MoonshineFlow listening" : "MoonshineFlow idle"
            )
    }
}

private enum MenuBarIconImage {
    static func make(isListening: Bool) -> NSImage {
        let size = NSSize(width: 32, height: 22)
        let image = NSImage(size: size)
        image.isTemplate = false

        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high

        let bounds = NSRect(origin: .zero, size: size)
        NSColor.clear.setFill()
        bounds.fill()

        if isListening {
            let badgeRect = NSRect(x: 1, y: 0, width: 30, height: 22)
            let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 11, yRadius: 11)
            NSColor.systemOrange.setFill()
            badgePath.fill()
        }

        let symbolName = "moon.stars.fill"
        let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .bold)
        let baseSymbol = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        ) ?? NSImage()
        let symbolRect = NSRect(x: 6, y: 1, width: 20, height: 20)
        let tint = isListening ? NSColor.white : NSColor.labelColor
        let tintedConfiguration = configuration.applying(
            NSImage.SymbolConfiguration(hierarchicalColor: tint)
        )
        let symbol = baseSymbol.withSymbolConfiguration(tintedConfiguration) ?? baseSymbol
        symbol.isTemplate = false
        symbol.draw(in: symbolRect)

        return image
    }
}
