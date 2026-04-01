import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        Form {
            Section("Dictation") {
                LabeledContent("Hotkey", value: controller.hotkeyDescription)
                LabeledContent("Mode", value: "Hold to dictate, insert on release")
                LabeledContent("Model", value: "medium-streaming-en")
                Picker("Speaker Output", selection: $controller.outputMode) {
                    ForEach(DictationOutputMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Capitalization", selection: $controller.capitalizationMode) {
                    ForEach(DictationCapitalizationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            Section("Permissions") {
                HStack {
                    Text("Hotkey")
                    Spacer()
                    Text(controller.inputMonitoringAuthorized ? "Granted" : "Missing")
                    if !controller.inputMonitoringAuthorized {
                        Button("Open Settings") {
                            controller.openInputMonitoringSettings()
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

                HStack {
                    Text("System Audio")
                    Spacer()
                    Text(controller.systemAudioAccessState.title)
                    if controller.systemAudioAccessState == .unavailable {
                        Button("Open Settings") {
                            controller.openSystemAudioSettings()
                        }
                    }
                }

                HStack {
                    Text("Text Pasting")
                    Spacer()
                    Text(controller.accessibilityTrusted ? "Granted" : "Missing")
                    if !controller.accessibilityTrusted {
                        Button("Open Settings") {
                            controller.openAccessibilitySettings()
                        }
                    }
                }
            }

            Section("Notes") {
                Text("MoonshineFlow transcribes locally with Moonshine and inserts text into the focused app.")
                Text("System audio recording permission is requested automatically the first time a dictation session starts.")
                Text("If direct Accessibility insertion fails for a target app, the injector falls back to clipboard paste.")
            }
        }
        .padding()
        .onAppear {
            controller.refreshPermissions()
        }
    }
}
