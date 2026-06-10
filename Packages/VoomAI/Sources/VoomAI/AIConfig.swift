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
}
