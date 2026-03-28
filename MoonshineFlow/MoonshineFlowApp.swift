import AppKit
import SwiftUI

@main
struct MoonshineFlowApp: App {
    @StateObject private var controller = DictationController.makeDefault()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Moonshine Flow", systemImage: controller.menuBarIconName) {
            ContentView(controller: controller)
                .frame(width: 270)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: controller)
                .frame(width: 420, height: 320)
        }
    }
}
