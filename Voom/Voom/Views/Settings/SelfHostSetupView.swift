import SwiftUI

struct SelfHostSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ShareWorkerBaseURL") private var workerBaseURL = ""
    @AppStorage("ShareAPISecret") private var apiSecret = ""

    @State private var apiToken = ""
    @State private var progress = DeployProgress()

    private enum Phase {
        case input, deploying, success, failed
    }

    private var phase: Phase {
        if progress.isComplete { return .success }
        if progress.hasFailed { return .failed }
        if progress.isDeploying { return .deploying }
        return .input
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().foregroundStyle(VoomTheme.borderSubtle)
            content
        }
        .frame(width: 420)
        .background(VoomTheme.backgroundPrimary)
        .interactiveDismissDisabled(phase == .deploying)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Self-Host Setup")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoomTheme.textPrimary)
                Text("Deploy to your Cloudflare account")
                    .font(VoomTheme.fontCaption())
                    .foregroundStyle(VoomTheme.textTertiary)
            }
            Spacer()
            if phase != .deploying {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(VoomTheme.textTertiary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(VoomTheme.spacingLG)
    }

    // MARK: - Content Router

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .input:
            inputPhase
        case .deploying:
            deployPhase
        case .success:
            successPhase
        case .failed:
            failedPhase
        }
    }

    // MARK: - Input Phase

    private var inputPhase: some View {
        VStack(alignment: .leading, spacing: VoomTheme.spacingLG) {
            // Step 1 instruction
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    stepBadge(1)
                    Text("Create an API token on Cloudflare")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(VoomTheme.textPrimary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Required permissions:")
                        .font(.system(size: 10))
                        .foregroundStyle(VoomTheme.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        permissionRow("Account — Read")
                        permissionRow("Workers Scripts — Edit")
                        permissionRow("D1 — Edit")
                        permissionRow("R2 Storage — Edit")
                    }
                }

                Button {
                    NSWorkspace.shared.open(URL(string: "https://dash.cloudflare.com/profile/api-tokens")!)
                } label: {
                    HStack(spacing: 4) {
                        Text("Open Cloudflare Dashboard")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }

            // Step 2: paste token
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    stepBadge(2)
                    Text("Paste your API token")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(VoomTheme.textPrimary)
                }
                SecureField("Paste token here", text: $apiToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Text("Not stored — used for this deployment only.")
                    .font(.system(size: 10))
                    .foregroundStyle(VoomTheme.textTertiary)
            }

            HStack {
                Spacer()
                Button("Deploy") {
                    startDeploy()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(VoomTheme.spacingLG)
    }

    private func stepBadge(_ number: Int) -> some View {
        Text("\(number)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(VoomTheme.textPrimary)
            .frame(width: 16, height: 16)
            .background(VoomTheme.backgroundTertiary)
            .clipShape(Circle())
    }

    private func permissionRow(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(VoomTheme.textQuaternary)
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(VoomTheme.textTertiary)
        }
    }

    // MARK: - Deploy Phase

    private var deployPhase: some View {
        VStack(alignment: .leading, spacing: VoomTheme.spacingSM) {
            ForEach(progress.steps) { step in
                stepRow(step)
            }
        }
        .padding(VoomTheme.spacingLG)
    }

    // MARK: - Success Phase

    private var successPhase: some View {
        VStack(spacing: VoomTheme.spacingLG) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(VoomTheme.accentGreen)

            VStack(spacing: 6) {
                Text("Deployment Complete")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoomTheme.textPrimary)

                if let url = progress.workerURL {
                    Text(url)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(VoomTheme.textSecondary)
                        .textSelection(.enabled)
                }
            }

            Text("Worker URL and API secret have been saved to your settings.")
                .font(VoomTheme.fontCaption())
                .foregroundStyle(VoomTheme.textTertiary)
                .multilineTextAlignment(.center)

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(VoomTheme.spacingXL)
    }

    // MARK: - Failed Phase

    private var failedPhase: some View {
        VStack(alignment: .leading, spacing: VoomTheme.spacingLG) {
            VStack(alignment: .leading, spacing: VoomTheme.spacingSM) {
                ForEach(progress.steps) { step in
                    stepRow(step)
                }
            }

            if let error = progress.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(VoomTheme.accentRed)
                    .padding(VoomTheme.spacingSM)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VoomTheme.accentRed.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: VoomTheme.radiusSmall))
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                Spacer()
                Button("Retry") {
                    progress.reset()
                    startDeploy()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(VoomTheme.spacingLG)
    }

    // MARK: - Step Row

    private func stepRow(_ step: DeployStep) -> some View {
        HStack(spacing: VoomTheme.spacingSM) {
            Group {
                switch step.status {
                case .pending:
                    Image(systemName: "circle")
                        .foregroundStyle(VoomTheme.textQuaternary)
                case .inProgress:
                    ProgressView()
                        .controlSize(.small)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(VoomTheme.accentGreen)
                case .skipped:
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(VoomTheme.accentOrange)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(VoomTheme.accentRed)
                }
            }
            .font(.system(size: 12))
            .frame(width: 16, height: 16)

            Text(step.label)
                .font(.system(size: 11))
                .foregroundStyle(stepTextColor(step.status))

            if case .skipped(let reason) = step.status {
                Text("— \(reason)")
                    .font(.system(size: 10))
                    .foregroundStyle(VoomTheme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private func stepTextColor(_ status: DeployStepStatus) -> Color {
        switch status {
        case .pending: return VoomTheme.textTertiary
        case .inProgress: return VoomTheme.textPrimary
        case .completed: return VoomTheme.textSecondary
        case .skipped: return VoomTheme.textTertiary
        case .failed: return VoomTheme.accentRed
        }
    }

    // MARK: - Actions

    private func startDeploy() {
        Task {
            do {
                let result = try await CloudflareDeployService.shared.deploy(
                    apiToken: apiToken,
                    progress: progress
                )
                workerBaseURL = result.workerURL
                apiSecret = result.apiSecret
            } catch {
                // Error state is already set by the service via progress
            }
        }
    }
}
