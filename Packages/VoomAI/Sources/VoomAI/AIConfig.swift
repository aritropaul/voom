import Foundation

/// UserDefaults-backed configuration for AI provider integration.
public enum AIConfig {
    private static let apiKeyKey = "AIAPIKey"
    private static let selectedModelKey = "AISelectedModel"
    private static let selectedProviderKey = "AISelectedProvider"

    public static var apiKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: apiKeyKey) }
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
