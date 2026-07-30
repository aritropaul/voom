import Foundation

public enum AIProviderKind: String, Sendable, CaseIterable, Identifiable {
    case anthropic = "Anthropic"
    case openai = "OpenAI"
    case google = "Google"
    case xai = "xAI"

    public var id: String { rawValue }

    public var endpoint: URL {
        switch self {
        case .anthropic: URL(string: "https://api.anthropic.com/v1/messages")!
        case .openai: URL(string: "https://api.openai.com/v1/chat/completions")!
        case .google: URL(string: "https://generativelanguage.googleapis.com/v1beta")!
        case .xai: URL(string: "https://api.x.ai/v1/chat/completions")!
        }
    }

    /// OpenAI-compatible chat completions format (OpenAI, xAI)
    public var isOpenAICompatible: Bool {
        self == .openai || self == .xai
    }

    public var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-..."
        case .openai: "sk-..."
        case .google: "AIza..."
        case .xai: "xai-..."
        }
    }

    /// Detect provider from API key prefix.
    public static func detect(from apiKey: String) -> AIProviderKind? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("sk-ant-") { return .anthropic }
        if key.hasPrefix("xai-") { return .xai }
        if key.hasPrefix("AIza") { return .google }
        if key.hasPrefix("sk-") { return .openai }
        return nil
    }
}

public struct AIModel: Sendable, Identifiable, Hashable {
    public let id: String
    public let displayName: String
    public let provider: AIProviderKind

    public init(id: String, displayName: String, provider: AIProviderKind) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
    }
}

public enum AIProvider {
    /// Ordered flagship → cheapest within each provider; `defaultModel(for:)`
    /// returns the first entry, so the leading model is that provider's default.
    public static let allModels: [AIModel] = [
        // OpenAI
        AIModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", provider: .openai),
        AIModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", provider: .openai),
        AIModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", provider: .openai),

        // Anthropic
        AIModel(id: "claude-opus-5", displayName: "Claude Opus 5", provider: .anthropic),
        AIModel(id: "claude-sonnet-5", displayName: "Claude Sonnet 5", provider: .anthropic),
        AIModel(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5", provider: .anthropic),

        // Google
        AIModel(id: "gemini-3.1-pro-preview", displayName: "Gemini 3.1 Pro", provider: .google),
        AIModel(id: "gemini-3.6-flash", displayName: "Gemini 3.6 Flash", provider: .google),
        AIModel(id: "gemini-3.5-flash-lite", displayName: "Gemini 3.5 Flash Lite", provider: .google),

        // xAI
        AIModel(id: "grok-4.5", displayName: "Grok 4.5", provider: .xai),
        AIModel(id: "grok-4.3", displayName: "Grok 4.3", provider: .xai),
    ]

    /// Model IDs shipped by earlier Voom versions, mapped to the current model
    /// at the same tier. A saved selection that isn't in `allModels` would leave
    /// the Settings picker blank and keep sending a retired ID to the API, so
    /// `AIConfig.migrateSelectedModel()` rewrites it on launch. IDs missing from
    /// this table fall back to the provider default.
    public static let retiredModelIDs: [String: String] = [
        "gpt-5.4": "gpt-5.6-sol",
        "gpt-5-mini": "gpt-5.6-terra",
        "gpt-5-nano": "gpt-5.6-luna",
        "claude-opus-4-6": "claude-opus-5",
        "claude-sonnet-4-6": "claude-sonnet-5",
        "gemini-3-flash-preview": "gemini-3.6-flash",
        "gemini-3.1-flash-lite-preview": "gemini-3.5-flash-lite",
        "grok-4-1-fast": "grok-4.5",
        "grok-4-fast-reasoning": "grok-4.3",
    ]

    public static let defaultProvider = AIProviderKind.anthropic
    public static let defaultModel = model(for: "claude-sonnet-5") ?? allModels[0]

    public static func model(for id: String) -> AIModel? {
        allModels.first { $0.id == id }
    }

    public static func models(for provider: AIProviderKind) -> [AIModel] {
        allModels.filter { $0.provider == provider }
    }

    public static func defaultModel(for provider: AIProviderKind) -> AIModel {
        models(for: provider).first ?? defaultModel
    }
}
