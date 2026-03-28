import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: DictationController

    private var missingPermissions: [(title: String, action: () -> Void)] {
        var permissions: [(title: String, action: () -> Void)] = []

        if !controller.inputMonitoringAuthorized {
            permissions.append(("Hotkey", controller.openInputMonitoringSettings))
        }
        if !controller.accessibilityTrusted {
            permissions.append(("Text Pasting", controller.requestAccessibilityPermission))
        }
        if !controller.microphoneAuthorized {
            permissions.append(("Microphone", controller.requestMicrophonePermission))
        }

        return permissions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Moonshine Flow")
                .font(.headline)

            Label(controller.state.rawValue, systemImage: controller.menuBarIconName)
                .font(.subheadline)

            Text(controller.hotkeyDescription + " to start dictation. Tap once to stop.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !controller.lastError.isEmpty {
                Text(controller.lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !missingPermissions.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(missingPermissions.enumerated()), id: \.offset) { _, permission in
                        permissionRow(title: permission.title, actionTitle: "Grant") {
                            permission.action()
                        }
                    }
                }
            }
        }
        .padding(12)
        .onAppear {
            controller.refreshPermissions()
        }
    }

    private func permissionRow(
        title: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("Missing")
                .foregroundStyle(.orange)
            Button(actionTitle, action: action)
        }
        .font(.caption)
    }
}
