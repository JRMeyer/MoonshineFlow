import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: DictationController

    private var stateTint: Color {
        switch controller.state {
        case .idle:
            return .secondary
        case .listening:
            return .red
        }
    }

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
        if controller.systemAudioAccessState == .unavailable {
            permissions.append(("System Audio", controller.openSystemAudioSettings))
        }

        return permissions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MoonshineFlow")
                        .font(.title3.weight(.semibold))

                    Text("Local dictation in the focused app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                statusBadge
            }

            infoCard(
                title: controller.state == .listening ? "Listening now" : "Ready",
                message: controller.hotkeyDescription + " starts dictation with microphone and system audio. Tap once to stop.",
                systemImage: controller.menuBarIconName
            )

            Picker("Speaker Output", selection: $controller.outputMode) {
                Text("Single Speaker").tag(DictationOutputMode.singleSpeaker)
                Text("Multi Speaker").tag(DictationOutputMode.multiSpeaker)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(controller.state == .listening)
            .padding(12)
            .background(panelBackground)

            Picker("Capitalization", selection: $controller.capitalizationMode) {
                Text("Standard").tag(DictationCapitalizationMode.standard)
                Text("Lowercase").tag(DictationCapitalizationMode.lowercase)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(controller.state == .listening)
            .padding(12)
            .background(panelBackground)

            if !controller.lastError.isEmpty {
                Label(controller.lastError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(panelBackground)
            }

            if !missingPermissions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Permissions")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(Array(missingPermissions.enumerated()), id: \.offset) { _, permission in
                        permissionRow(title: permission.title, actionTitle: "Grant access") {
                            permission.action()
                        }
                    }
                }
                .padding(12)
                .background(panelBackground)
            }
        }
        .padding(14)
        .onAppear {
            controller.refreshPermissions()
        }
    }

    private var statusBadge: some View {
        Label(controller.state.rawValue, systemImage: controller.menuBarIconName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(stateTint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(stateTint.opacity(0.14), in: Capsule())
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.quaternary.opacity(0.45))
    }

    private func infoCard(title: String, message: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(stateTint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(panelBackground)
    }

    private func permissionRow(
        title: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("Required")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            Spacer()

            Text("Missing")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}
