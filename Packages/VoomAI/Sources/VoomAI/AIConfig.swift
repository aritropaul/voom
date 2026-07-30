import Foundation
import VoomCore

/// Configuration for AI provider integration. The API key lives in the
/// Keychain; non-secret preferences stay in UserDefaults.
public enum AIConfig {
    private static let apiKeyKey = "AIAPIKey"
    private static let selectedModelKey = "AISelectedModel"
    private static let selectedProviderKey = "AISelectedProvider"

    public static var apiKey: String {
        get { KeychainStore.migratingFromDefaults(apiKeyKey) }
        set { KeychainStore.set(newValue, for: apiKeyKey) }
    }

    public static var selectedModel: String {
        get { UserDefaults.standard.string(forKey: selectedModelKey) ?? AIProvider.defaultModel.id }
        set { UserDefaults.standard.set(newValue, forKey: selectedModelKey) }
    }

    public static var selectedProvider: AIProviderKind {
        get {
            guard let raw = UserDefaults.standard.string(forKey: selectedProviderKey),
                  let provider = AIProviderKind(rawValue: raw) else {
                return AIProvider.defaultProvider
            }
            return provider
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: selectedProviderKey) }
    }

    public static var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Rewrite a saved model ID that no longer exists in the catalog — either to
    /// its same-tier successor or, failing that, to the provider default. Without
    /// this the Settings picker renders an empty selection (no row matches the
    /// tag) while requests keep going out under the retired ID. Call on launch.
    public static func migrateSelectedModel() {
        guard let stored = UserDefaults.standard.string(forKey: selectedModelKey),
              AIProvider.model(for: stored) == nil else { return }
        let replacement = AIProvider.retiredModelIDs[stored]
            ?? AIProvider.defaultModel(for: selectedProvider).id
        selectedModel = replacement
    }
}
