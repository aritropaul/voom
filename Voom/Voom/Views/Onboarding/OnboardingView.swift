import SwiftUI
import AVFoundation
import ScreenCaptureKit

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var currentStep = 0
    @State private var screenPermission = CGPreflightScreenCaptureAccess()
    @State private var cameraPermission = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var micPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

    private let steps: [(icon: String, title: String, description: String, permissionType: PermissionType)] = [
        ("rectangle.dashed.badge.record", "Screen Recording", "Voom needs access to your screen to capture recordings.", .screen),
        ("camera.fill", "Camera", "Used for the picture-in-picture webcam overlay during recordings.", .camera),
        ("mic.fill", "Microphone", "Capture your voice alongside your screen recording.", .microphone),
    ]

    private enum PermissionType {
        case screen, camera, microphone
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 32) {
                // App icon area
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.red)

                VStack(spacing: 8) {
                    Text("Welcome to Voom")
                        .font(.system(size: 28, weight: .bold))
                    Text("A few permissions are needed to get started.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }

                // Permission cards
                VStack(spacing: 12) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        permissionRow(
                            icon: step.icon,
                            title: step.title,
                            description: step.description,
                            isGranted: isGranted(step.permissionType),
                            action: { requestPermission(step.permissionType) }
                        )
                    }
                }
                .padding(.horizontal, 20)
            }

            Spacer()

            // Continue button
            Button {
                appState.hasCompletedOnboarding = true
            } label: {
                Text("Get Started")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .frame(width: 460, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func permissionRow(icon: String, title: String, description: String, isGranted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(isGranted ? .green : .secondary)
                .frame(width: 36, height: 36)
                .background(isGranted ? Color.green.opacity(0.1) : Color.secondary.opacity(0.1))
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

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Allow") {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func isGranted(_ type: PermissionType) -> Bool {
        switch type {
        case .screen: return screenPermission
        case .camera: return cameraPermission
        case .microphone: return micPermission
        }
    }

    private func requestPermission(_ type: PermissionType) {
        switch type {
        case .screen:
            CGRequestScreenCaptureAccess()
            // Re-check after a short delay (system dialog is async)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                screenPermission = CGPreflightScreenCaptureAccess()
            }
        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { cameraPermission = granted }
            }
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { micPermission = granted }
            }
        }
    }
}
