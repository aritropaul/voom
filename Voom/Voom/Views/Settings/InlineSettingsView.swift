import SwiftUI
import ServiceManagement
import Sparkle

struct InlineSettingsView: View {
    @AppStorage("ShareWorkerBaseURL") private var workerBaseURL = ""
    @AppStorage("ShareAPISecret") private var apiSecret = ""
    @AppStorage("AutoTranscribe") private var autoTranscribe = true
    @AppStorage("GlobalHotkeyEnabled") private var globalHotkeyEnabled = true
    @AppStorage("ViewNotificationsEnabled") private var viewNotificationsEnabled = true
    @AppStorage("RecordingDirectory") private var recordingDirectory = ""
    @AppStorage("LaunchAtLogin") private var launchAtLogin = false
    @State private var testStatus: TestStatus = .idle

    private enum TestStatus: Equatable {
        case idle, testing, success, failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoomTheme.spacingXL) {
                // General
                settingsCard(icon: "gear", title: "General") {
                    generalContent
                }
                .staggeredAppear(0)

                // Recording
                settingsCard(icon: "record.circle", title: "Recording") {
                    recordingContent
                }
                .staggeredAppear(1)

                // Sharing
                settingsCard(icon: "link", title: "Cloud Sharing") {
                    sharingContent
                }
                .staggeredAppear(2)

                // About
                settingsCard(icon: "info.circle", title: "About") {
                    aboutContent
                }
                .staggeredAppear(3)
            }
            .padding(VoomTheme.spacingXL)
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoomTheme.backgroundPrimary)
        .animation(.smooth(duration: 0.3), value: testStatus)
        .onChange(of: globalHotkeyEnabled) { _, enabled in
            if enabled { GlobalHotkey.shared.register() } else { GlobalHotkey.shared.unregister() }
        }
        .onChange(of: viewNotificationsEnabled) { _, enabled in
            Task {
                if enabled {
                    await ViewNotificationService.shared.requestNotificationPermission()
                    await ViewNotificationService.shared.startPolling()
                } else {
                    await ViewNotificationService.shared.stopPolling()
                }
            }
        }
        .onChange(of: launchAtLogin) { _, enabled in
            try? SMAppService.mainApp.register()
        }
    }

    // MARK: - Card Builder

    @ViewBuilder
    private func settingsCard<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: VoomTheme.spacingMD) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VoomTheme.textTertiary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoomTheme.textPrimary)
            }

            content()
        }
        .padding(VoomTheme.spacingLG)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                .fill(VoomTheme.backgroundCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - General

    @ViewBuilder
    private var generalContent: some View {
        settingsRow(title: "Launch at Login", subtitle: "Start Voom when you log in.") {
            Toggle("", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .controlSize(.small)
        }

        Divider().foregroundStyle(VoomTheme.borderSubtle)

        settingsRow(title: "Global Hotkey", subtitle: "Use Command+Shift+R to start/stop recording.") {
            Toggle("", isOn: $globalHotkeyEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        }

        Divider().foregroundStyle(VoomTheme.borderSubtle)

        settingsRow(title: "View Notifications", subtitle: "Notify when someone views a shared recording.") {
            Toggle("", isOn: $viewNotificationsEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        }

        Divider().foregroundStyle(VoomTheme.borderSubtle)

        settingsRow(title: "Automatic Updates", subtitle: "Check for updates automatically.") {
            Toggle("", isOn: Binding(
                get: { (AppDelegate.shared)?.updaterController.updater.automaticallyChecksForUpdates ?? true },
                set: { (AppDelegate.shared)?.updaterController.updater.automaticallyChecksForUpdates = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    // MARK: - Recording

    @ViewBuilder
    private var recordingContent: some View {
        settingsRow(title: "Auto-Transcribe", subtitle: "Transcribe recordings on-device after recording stops.") {
            Toggle("", isOn: $autoTranscribe)
                .toggleStyle(.switch)
                .controlSize(.small)
        }

        Divider().foregroundStyle(VoomTheme.borderSubtle)

        VStack(alignment: .leading, spacing: 6) {
            Text("Recording Directory")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VoomTheme.textPrimary)

            HStack {
                Text(recordingDirectoryDisplay)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(VoomTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change...") {
                    pickRecordingDirectory()
                }
                .controlSize(.small)
            }

            Text("Where Voom saves recorded videos.")
                .font(VoomTheme.fontCaption())
                .foregroundStyle(VoomTheme.textTertiary)
        }
    }

    // MARK: - Sharing

    @ViewBuilder
    private var sharingContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Worker URL")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VoomTheme.textPrimary)
            TextField("https://voom-share.example.workers.dev", text: $workerBaseURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("API Secret")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VoomTheme.textPrimary)
            SecureField("Paste your API secret", text: $apiSecret)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }

        HStack(spacing: VoomTheme.spacingSM) {
            Button("Test Connection") {
                testConnection()
            }
            .disabled(workerBaseURL.isEmpty || apiSecret.isEmpty || testStatus == .testing)
            .controlSize(.small)

            switch testStatus {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView().controlSize(.small)
            case .success:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(VoomTheme.accentGreen)
                    .font(VoomTheme.fontCaption())
            case .failed(let msg):
                Label(msg, systemImage: "xmark.circle.fill")
                    .foregroundStyle(VoomTheme.accentRed)
                    .font(VoomTheme.fontCaption())
                    .lineLimit(1)
            }
        }

        Text("Connect to your Cloudflare Worker for shareable links.")
            .font(VoomTheme.fontCaption())
            .foregroundStyle(VoomTheme.textTertiary)
    }

    // MARK: - About

    @ViewBuilder
    private var aboutContent: some View {
        HStack(spacing: VoomTheme.spacingMD) {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Voom")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VoomTheme.textPrimary)
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("Version \(version)")
                        .font(VoomTheme.fontCaption())
                        .foregroundStyle(VoomTheme.textTertiary)
                }
            }
        }

        Button("Check for Updates...") {
            if let delegate = AppDelegate.shared {
                delegate.updaterController.checkForUpdates(nil)
            }
        }
        .controlSize(.small)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func settingsRow<Accessory: View>(title: String, subtitle: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VoomTheme.textPrimary)
                Text(subtitle)
                    .font(VoomTheme.fontCaption())
                    .foregroundStyle(VoomTheme.textTertiary)
            }
            Spacer()
            accessory()
        }
    }

    private var recordingDirectoryDisplay: String {
        if recordingDirectory.isEmpty {
            return "~/Movies/Voom (default)"
        }
        return recordingDirectory.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func pickRecordingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select a directory for recordings"
        if panel.runModal() == .OK, let url = panel.url {
            recordingDirectory = url.path
        }
    }

    private func testConnection() {
        testStatus = .testing
        let urlString = workerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: urlString) else {
            testStatus = .failed("Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error {
                    testStatus = .failed(error.localizedDescription)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    testStatus = .failed("No response")
                    return
                }
                if (200...299).contains(http.statusCode) {
                    testStatus = .success
                    workerBaseURL = urlString
                    apiSecret = secret
                } else {
                    testStatus = .failed("HTTP \(http.statusCode)")
                }
            }
        }.resume()
    }
}
