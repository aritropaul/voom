import SwiftUI
import AVFoundation
import VoomCore

struct OnboardingView: View {
    @Environment(AppState.self) private var appState

    private struct PermissionItem {
        let icon: String
        let title: String
        let description: String
    }

    private let permissions: [PermissionItem] = [
        .init(icon: "rectangle.dashed.badge.record", title: "Screen Recording", description: "Voom needs access to your screen to capture recordings."),
        .init(icon: "camera.fill", title: "Camera", description: "Used for the picture-in-picture webcam overlay during recordings."),
        .init(icon: "mic.fill", title: "Microphone", description: "Capture your voice alongside your screen recording."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 32) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.red)

                VStack(spacing: 8) {
                    Text("Welcome to Voom")
                        .font(.system(size: 28, weight: .bold))
                    Text("Voom needs a few permissions to record your screen.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    ForEach(Array(permissions.enumerated()), id: \.offset) { _, item in
                        permissionRow(icon: item.icon, title: item.title, description: item.description)
                    }
                }
                .padding(.horizontal, 20)
            }

            Spacer()

            Button(action: finishOnboarding) {
                Text("Get Started")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .frame(width: 460, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func permissionRow(icon: String, title: String, description: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.green.opacity(0.7))
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func finishOnboarding() {
        appState.hasCompletedOnboarding = true
        NSApp.setActivationPolicy(.accessory)
        // Close all windows first
        for window in NSApp.windows {
            window.orderOut(nil)
            window.close()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            ControlPanelManager.shared.toggle(appState: appState)
        }
    }
}
