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
    public static let allModels: [AIModel] = [
        // OpenAI
        AIModel(id: "gpt-5.4", displayName: "GPT-5.4", provider: .openai),
        AIModel(id: "gpt-5-mini", displayName: "GPT-5 Mini", provider: .openai),
        AIModel(id: "gpt-5-nano", displayName: "GPT-5 Nano", provider: .openai),

        // Anthropic
        AIModel(id: "claude-opus-4-6", displayName: "Claude Opus 4.6", provider: .anthropic),
        AIModel(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", provider: .anthropic),
        AIModel(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5", provider: .anthropic),

        // Google
        AIModel(id: "gemini-3.1-pro-preview", displayName: "Gemini 3.1 Pro", provider: .google),
        AIModel(id: "gemini-3-flash-preview", displayName: "Gemini 3 Flash", provider: .google),
        AIModel(id: "gemini-3.1-flash-lite-preview", displayName: "Gemini 3.1 Flash Lite", provider: .google),

        // xAI
        AIModel(id: "grok-4-1-fast", displayName: "Grok 4.1 Fast", provider: .xai),
        AIModel(id: "grok-4-fast-reasoning", displayName: "Grok 4 Fast", provider: .xai),
    ]

    public static let defaultProvider = AIProviderKind.anthropic
    public static let defaultModel = allModels[4] // Claude Sonnet 4.6

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
