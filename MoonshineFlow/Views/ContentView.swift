import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Moonshine Flow")
                .font(.headline)

            Label(controller.state.rawValue, systemImage: controller.menuBarIconName)
                .font(.subheadline)

            Text(controller.hotkeyDescription + " to dictate into the focused app.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !controller.previewText.isEmpty {
                GroupBox("Transcript Preview") {
                    Text(controller.previewText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }

            if !controller.lastInsertedText.isEmpty {
                GroupBox("Last Inserted") {
                    Text(controller.lastInsertedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }

            if !controller.lastError.isEmpty {
                Text(controller.lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(controller.state == .listening ? "Listening..." : "Start") {
                    controller.startSession()
                }
                .disabled(controller.state != .idle)

                Button("Stop") {
                    controller.stopSession()
                }
                .disabled(controller.state != .listening)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                permissionRow(
                    title: "Accessibility",
                    granted: controller.accessibilityTrusted,
                    actionTitle: "Grant"
                ) {
                    controller.requestAccessibilityPermission()
                }

                permissionRow(
                    title: "Microphone",
                    granted: controller.microphoneAuthorized,
                    actionTitle: "Grant"
                ) {
                    controller.requestMicrophonePermission()
                }
            }
        }
        .padding(14)
        .onAppear {
            controller.refreshPermissions()
        }
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(granted ? "Ready" : "Missing")
                .foregroundStyle(granted ? .green : .orange)
            if !granted {
                Button(actionTitle, action: action)
            }
        }
        .font(.caption)
    }
}
