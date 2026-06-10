import SwiftUI
import VoomCore

struct SelfHostSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ShareWorkerBaseURL") private var workerBaseURL = ""

    // Primary: Deploy to Cloudflare → connect with worker URL + API secret
    @State private var workerURLInput = ""
    @State private var apiSecretInput = ""
    @State private var isConnecting = false
    @State private var connectError: String?
    @State private var didConnect = false

    // Advanced: API-token auto-provision
    @State private var showAdvanced = false
    @State private var apiToken = ""
    @State private var progress = DeployProgress()

    private let deployURL = "https://deploy.workers.cloudflare.com/?url=https://github.com/aritropaul/voom/tree/main/voom-share"

    private enum TokenPhase { case input, deploying, failed }
    private var tokenPhase: TokenPhase {
        if progress.hasFailed { return .failed }
        if progress.isDeploying { return .deploying }
        return .input
    }

    private var isBusy: Bool { isConnecting || progress.isDeploying }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().foregroundStyle(VoomTheme.borderSubtle)
            ScrollView {
                content.padding(VoomTheme.spacingLG)
            }
        }
        .frame(width: 440)
        .frame(maxHeight: 580)
        .background(VoomTheme.backgroundPrimary)
        .interactiveDismissDisabled(isBusy)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Self-Host Setup")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoomTheme.textPrimary)
                Text("Run sharing on your own Cloudflare account")
                    .font(VoomTheme.fontCaption())
                    .foregroundStyle(VoomTheme.textTertiary)
            }
            Spacer()
            if !isBusy {
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
        if didConnect {
            successView
        } else if showAdvanced {
            advancedFlow
        } else {
            primaryFlow
        }
    }

    // MARK: - Primary: Deploy to Cloudflare

    private var primaryFlow: some View {
        VStack(alignment: .leading, spacing: VoomTheme.spacingLG) {
            Text("Voom's sharing backend is a single Cloudflare Worker. Deploy it to your account in one click — it's always free and you own the data.")
                .font(.system(size: 11))
                .foregroundStyle(VoomTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Step 1 — deploy
            stepBlock(1, "Deploy the worker") {
                Text("Provisions a fresh database and storage bucket in your account.")
                    .font(.system(size: 10))
                    .foregroundStyle(VoomTheme.textTertiary)
                Link(destination: URL(string: deployURL)!) {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill").font(.system(size: 9, weight: .semibold))
                        Text("Deploy to Cloudflare").font(.system(size: 11, weight: .medium))
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }

            // Step 2 — secret
            stepBlock(2, "Set an API secret") {
                Text("When prompted during deploy, set a Secret named ")
                    .font(.system(size: 10)).foregroundStyle(VoomTheme.textTertiary)
                + Text("API_SECRET").font(.system(size: 10, design: .monospaced)).foregroundStyle(VoomTheme.textSecondary)
                + Text(". Generate one with:").font(.system(size: 10)).foregroundStyle(VoomTheme.textTertiary)
                Text("openssl rand -hex 32")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(VoomTheme.textSecondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, VoomTheme.spacingSM)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VoomTheme.backgroundTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: VoomTheme.radiusSmall))
            }

            // Step 3 — connect
            stepBlock(3, "Connect Voom") {
                Text("Paste your worker URL and the secret you set.")
                    .font(.system(size: 10))
                    .foregroundStyle(VoomTheme.textTertiary)
                TextField("https://voom-share.<you>.workers.dev", text: $workerURLInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disableAutocorrection(true)
                SecureField("API_SECRET", text: $apiSecretInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            if let connectError {
                errorBanner(connectError)
            }

            HStack {
                Button("Advanced: use an API token") { showAdvanced = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(VoomTheme.textTertiary)
                Spacer()
                Button {
                    connect()
                } label: {
                    if isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isConnecting
                          || workerURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || apiSecretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Advanced: API-token auto-provision

    @ViewBuilder
    private var advancedFlow: some View {
        switch tokenPhase {
        case .input: tokenInput
        case .deploying: tokenProgress
        case .failed: tokenFailed
        }
    }

    private var tokenInput: some View {
        VStack(alignment: .leading, spacing: VoomTheme.spacingLG) {
            Button {
                showAdvanced = false
                connectError = nil
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                    Text("Back").font(.system(size: 10))
                }
                .foregroundStyle(VoomTheme.textTertiary)
            }
            .buttonStyle(.plain)

            Text("Provision everything automatically with a scoped API token.")
                .font(.system(size: 11))
                .foregroundStyle(VoomTheme.textSecondary)

            stepBlock(1, "Create an API token on Cloudflare") {
                Text("Required permissions:")
                    .font(.system(size: 10)).foregroundStyle(VoomTheme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    permissionRow("Account — Read")
                    permissionRow("Workers Scripts — Edit")
                    permissionRow("D1 — Edit")
                    permissionRow("R2 Storage — Edit")
                }
                Button {
                    NSWorkspace.shared.open(URL(string: "https://dash.cloudflare.com/profile/api-tokens")!)
                } label: {
                    HStack(spacing: 4) {
                        Text("Open Cloudflare Dashboard").font(.system(size: 11, weight: .medium))
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }

            stepBlock(2, "Paste your API token") {
                SecureField("Paste token here", text: $apiToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Text("Not stored — used for this deployment only.")
                    .font(.system(size: 10))
                    .foregroundStyle(VoomTheme.textTertiary)
            }

            HStack {
                Spacer()
                Button("Deploy") { startTokenDeploy() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var tokenProgress: some View {
        VStack(alignment: .leading, spacing: VoomTheme.spacingSM) {
            ForEach(progress.steps) { step in stepRow(step) }
        }
    }

    private var tokenFailed: some View {
        VStack(alignment: .leading, spacing: VoomTheme.spacingLG) {
            VStack(alignment: .leading, spacing: VoomTheme.spacingSM) {
                ForEach(progress.steps) { step in stepRow(step) }
            }
            if let error = progress.errorMessage { errorBanner(error) }
            HStack {
                Button("Back") { progress.reset(); showAdvanced = false }
                Spacer()
                Button("Retry") { progress.reset(); startTokenDeploy() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Success

    private var successView: some View {
        VStack(spacing: VoomTheme.spacingLG) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(VoomTheme.accentGreen)
            VStack(spacing: 6) {
                Text("Connected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoomTheme.textPrimary)
                if !workerBaseURL.isEmpty {
                    Text(workerBaseURL)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(VoomTheme.textSecondary)
                        .textSelection(.enabled)
                }
            }
            Text("Your shares will be hosted on this worker.")
                .font(VoomTheme.fontCaption())
                .foregroundStyle(VoomTheme.textTertiary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, VoomTheme.spacingLG)
    }

    // MARK: - Reusable bits

    @ViewBuilder
    private func stepBlock<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                stepBadge(number)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VoomTheme.textPrimary)
            }
            VStack(alignment: .leading, spacing: 4) { content() }
        }
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

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(VoomTheme.accentRed)
            .padding(VoomTheme.spacingSM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VoomTheme.accentRed.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: VoomTheme.radiusSmall))
    }

    private func stepRow(_ step: DeployStep) -> some View {
        HStack(spacing: VoomTheme.spacingSM) {
            Group {
                switch step.status {
                case .pending:
                    Image(systemName: "circle").foregroundStyle(VoomTheme.textQuaternary)
                case .inProgress:
                    ProgressView().controlSize(.small)
                case .completed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(VoomTheme.accentGreen)
                case .skipped:
                    Image(systemName: "arrow.right.circle.fill").foregroundStyle(VoomTheme.accentOrange)
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(VoomTheme.accentRed)
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

    private func connect() {
        let url = workerURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = apiSecretInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !secret.isEmpty else { return }
        isConnecting = true
        connectError = nil
        Task {
            do {
                try await CloudflareDeployService.shared.verifyConnection(workerURL: url, apiSecret: secret)
                let normalized = url.hasSuffix("/") ? String(url.dropLast()) : url
                workerBaseURL = normalized
                ShareConfig.apiSecret = secret
                isConnecting = false
                didConnect = true
            } catch {
                isConnecting = false
                connectError = error.localizedDescription
            }
        }
    }

    private func startTokenDeploy() {
        Task {
            do {
                let result = try await CloudflareDeployService.shared.deploy(
                    apiToken: apiToken,
                    progress: progress
                )
                workerBaseURL = result.workerURL
                ShareConfig.apiSecret = result.apiSecret
                didConnect = true
            } catch {
                // Error state is set on `progress` by the service.
            }
        }
    }
}
