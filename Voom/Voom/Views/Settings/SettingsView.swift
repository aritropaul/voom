import SwiftUI
import Carbon.HIToolbox
import VoomCore
import VoomAI

struct SettingsView: View {
    @AppStorage("ShareWorkerBaseURL") private var workerBaseURL = ""
    @AppStorage("ShareAPISecret") private var apiSecret = ""
    @AppStorage("AutoTranscribe") private var autoTranscribe = true
    @AppStorage("GlobalHotkeyEnabled") private var globalHotkeyEnabled = true
    @AppStorage("ViewNotificationsEnabled") private var viewNotificationsEnabled = true
    @AppStorage("AIAPIKey") private var aiAPIKey = ""
    @AppStorage("AISelectedProvider") private var aiSelectedProvider = AIProvider.defaultProvider.rawValue
    @AppStorage("AISelectedModel") private var aiSelectedModel = AIProvider.defaultModel.id
    @State private var testStatus: TestStatus = .idle
    @State private var aiTestStatus: AITestStatus = .idle
    @State private var showingSelfHostSetup = false

    private enum TestStatus: Equatable {
        case idle
        case testing
        case success
        case failed(String)
    }

    private enum AITestStatus: Equatable {
        case idle, testing, success, failed(String)
    }

    var body: some View {
        TabView {
            generalSettings
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            sharingSettings
                .tabItem {
                    Label("Sharing", systemImage: "link")
                }
            aiSettings
                .tabItem {
                    Label("AI", systemImage: "brain")
                }
        }
        .frame(width: 480, height: 360)
    }

    // MARK: - General Tab

    @ViewBuilder
    private var generalSettings: some View {
        Form {
            Section {
                Toggle("Automatically transcribe recordings", isOn: $autoTranscribe)
            } header: {
                Text("Transcription")
            } footer: {
                Text("When enabled, recordings with audio are transcribed on-device after recording stops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Global keyboard shortcut", isOn: $globalHotkeyEnabled)
            } header: {
                Text("Keyboard")
            } footer: {
                Text("⌘⇧R to start/stop recording from anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("View notifications", isOn: $viewNotificationsEnabled)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Get notified when someone views your shared recordings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: globalHotkeyEnabled) { _, enabled in
            if enabled {
                GlobalHotkey.shared.register()
            } else {
                GlobalHotkey.shared.unregister()
            }
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
    }

    // MARK: - Sharing Tab

    @ViewBuilder
    private var sharingSettings: some View {
        Form {
            Section {
                TextField("Worker URL", text: $workerBaseURL, prompt: Text("https://voom-share.example.workers.dev"))
                    .textFieldStyle(.roundedBorder)

                SecureField("API Secret", text: $apiSecret, prompt: Text("Paste your API secret"))
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Cloudflare Worker")
            } footer: {
                Text("These connect Voom to your Cloudflare Worker for link sharing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Test Connection") {
                        testConnection()
                    }
                    .disabled(workerBaseURL.isEmpty || apiSecret.isEmpty || testStatus == .testing)

                    switch testStatus {
                    case .idle:
                        EmptyView()
                    case .testing:
                        ProgressView()
                            .controlSize(.small)
                    case .success:
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    case .failed(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
            }

            Section {
                Button("Set Up Self-Hosting...") {
                    showingSelfHostSetup = true
                }
            } footer: {
                Text("Deploy the sharing worker to your own Cloudflare account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showingSelfHostSetup) {
            SelfHostSetupView()
        }
    }

    // MARK: - AI Tab

    private var currentProvider: AIProviderKind {
        AIProviderKind(rawValue: aiSelectedProvider) ?? .anthropic
    }

    @ViewBuilder
    private var aiSettings: some View {
        Form {
            Section {
                Picker("Provider", selection: $aiSelectedProvider) {
                    ForEach(AIProviderKind.allCases) { provider in
                        Text(provider.rawValue).tag(provider.rawValue)
                    }
                }

                Picker("Model", selection: $aiSelectedModel) {
                    ForEach(AIProvider.models(for: currentProvider)) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }

                SecureField("API Key", text: $aiAPIKey, prompt: Text(currentProvider.keyPlaceholder))
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("AI Provider")
            } footer: {
                Text("Use your own API key for AI-powered titles, summaries, and chapters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Test Connection") {
                        testAIConnection()
                    }
                    .disabled(aiAPIKey.isEmpty || aiTestStatus == .testing)

                    switch aiTestStatus {
                    case .idle:
                        EmptyView()
                    case .testing:
                        ProgressView()
                            .controlSize(.small)
                    case .success:
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    case .failed(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }

                if !aiAPIKey.isEmpty {
                    Button("Clear API Key") {
                        aiAPIKey = ""
                        aiTestStatus = .idle
                        Task {
                            await TextAnalysisService.shared.setExternalProvider(nil)
                        }
                    }
                }
            } footer: {
                if aiAPIKey.isEmpty {
                    Text("Without an API key, Voom uses Apple's on-device model (macOS 26+).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: aiSelectedProvider) { _, newValue in
            // Reset model to provider default when switching providers
            let provider = AIProviderKind(rawValue: newValue) ?? .anthropic
            aiSelectedModel = AIProvider.defaultModel(for: provider).id
            aiTestStatus = .idle
        }
        .onChange(of: aiAPIKey) { _, newValue in
            // Auto-detect provider from key prefix
            if let detected = AIProviderKind.detect(from: newValue) {
                aiSelectedProvider = detected.rawValue
                aiSelectedModel = AIProvider.defaultModel(for: detected).id
            }
            Task {
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await TextAnalysisService.shared.setExternalProvider(nil)
                } else {
                    await TextAnalysisService.shared.setExternalProvider(AIService.shared)
                }
            }
        }
    }

    private func testAIConnection() {
        aiTestStatus = .testing
        Task {
            do {
                try await AIService.shared.testConnection()
                aiTestStatus = .success
            } catch {
                aiTestStatus = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Test

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

        URLSession.shared.dataTask(with: request) { data, response, error in
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
                    // Save trimmed values
                    workerBaseURL = urlString
                    apiSecret = secret
                } else {
                    testStatus = .failed("HTTP \(http.statusCode)")
                }
            }
        }.resume()
    }
}
