import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        Form {
            Section("Dictation") {
                LabeledContent("Hotkey", value: controller.hotkeyDescription)
                LabeledContent("Mode", value: "Hold to dictate, insert on release")
                LabeledContent("Model", value: "medium-streaming-en")
            }

            Section("Permissions") {
                HStack {
                    Text("Accessibility")
                    Spacer()
                    Text(controller.accessibilityTrusted ? "Granted" : "Missing")
                    if !controller.accessibilityTrusted {
                        Button("Open Settings") {
                            controller.openAccessibilitySettings()
                        }
                    }
                }

                HStack {
                    Text("Microphone")
                    Spacer()
                    Text(controller.microphoneAuthorized ? "Granted" : "Missing")
                    if !controller.microphoneAuthorized {
                        Button("Open Settings") {
                            controller.openMicrophoneSettings()
                        }
                    }
                }
            }

            Section("Notes") {
                Text("Moonshine Flow transcribes locally with Moonshine and inserts text into the focused app.")
                Text("If direct Accessibility insertion fails for a target app, the injector falls back to clipboard paste.")
            }
        }
        .padding()
        .onAppear {
            controller.refreshPermissions()
        }
    }
}

extension Color {
    func toData() -> Data {
        let nsColor = NSColor(self)
        return (try? NSKeyedArchiver.archivedData(withRootObject: nsColor, requiringSecureCoding: false))
            ?? Data()
    }

    static func fromData(_ data: Data) -> Color? {
        guard let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else {
            return nil
        }
        return Color(nsColor)
    }

    func toNSColor() -> NSColor {
        NSColor(self)
    }
}
