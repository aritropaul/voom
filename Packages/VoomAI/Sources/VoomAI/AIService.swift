import Foundation
import os
import VoomCore

private let logger = Logger(subsystem: "com.voom.app", category: "AIService")

public actor AIService: AIGenerationProvider {
    public static let shared = AIService()
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - AIGenerationProvider

    public func generate(systemPrompt: String, userPrompt: String) async -> String? {
        let apiKey = AIConfig.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return nil }

        let provider = AIConfig.selectedProvider
        let modelId = AIConfig.selectedModel

        do {
            switch provider {
            case .anthropic:
                return try await callAnthropic(apiKey: apiKey, model: modelId, system: systemPrompt, user: userPrompt)
            case .openai, .xai:
                return try await callOpenAICompatible(endpoint: provider.endpoint, apiKey: apiKey, model: modelId, system: systemPrompt, user: userPrompt)
            case .google:
                return try await callGemini(apiKey: apiKey, model: modelId, system: systemPrompt, user: userPrompt)
            }
        } catch {
            logger.error("[Voom] \(provider.rawValue) request failed: \(error)")
            return nil
        }
    }

    // MARK: - Test Connection

    public func testConnection() async throws {
        let apiKey = AIConfig.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw AIServiceError.noAPIKey
        }

        let provider = AIConfig.selectedProvider
        let modelId = AIConfig.selectedModel

        switch provider {
        case .anthropic:
            _ = try await callAnthropic(apiKey: apiKey, model: modelId, system: "Respond briefly.", user: "Say OK")
        case .openai, .xai:
            _ = try await callOpenAICompatible(endpoint: provider.endpoint, apiKey: apiKey, model: modelId, system: "Respond briefly.", user: "Say OK")
        case .google:
            _ = try await callGemini(apiKey: apiKey, model: modelId, system: "Respond briefly.", user: "Say OK")
        }
    }

    // MARK: - OpenAI-Compatible (OpenAI, xAI)

    private func callOpenAICompatible(endpoint: URL, apiKey: String, model: String, system: String, user: String) async throws -> String? {
        struct Request: Encodable {
            let model: String
            let messages: [Message]
            struct Message: Encodable { let role: String; let content: String }
        }
        struct Response: Decodable {
            let choices: [Choice]?
            let error: APIError?
            struct Choice: Decodable { let message: Msg }
            struct Msg: Decodable { let content: String }
            struct APIError: Decodable { let message: String }
        }

        let body = Request(model: model, messages: [
            .init(role: "system", content: system),
            .init(role: "user", content: user),
        ])

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: req)
        try checkHTTPStatus(response, data: data)

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        if let error = decoded.error { throw AIServiceError.apiError(error.message) }
        let content = decoded.choices?.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return (content?.isEmpty ?? true) ? nil : content
    }

    // MARK: - Anthropic Messages API

    private func callAnthropic(apiKey: String, model: String, system: String, user: String) async throws -> String? {
        struct Request: Encodable {
            let model: String
            let max_tokens: Int
            let system: String
            let messages: [Message]
            struct Message: Encodable { let role: String; let content: String }
        }
        struct Response: Decodable {
            let content: [ContentBlock]?
            let error: APIError?
            struct ContentBlock: Decodable { let text: String? }
            struct APIError: Decodable { let message: String }
        }

        let body = Request(model: model, max_tokens: 1024, system: system, messages: [
            .init(role: "user", content: user),
        ])

        var req = URLRequest(url: AIProviderKind.anthropic.endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: req)
        try checkHTTPStatus(response, data: data)

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        if let error = decoded.error { throw AIServiceError.apiError(error.message) }
        let text = decoded.content?.compactMap(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    // MARK: - Google Gemini API

    private func callGemini(apiKey: String, model: String, system: String, user: String) async throws -> String? {
        struct Request: Encodable {
            let system_instruction: SystemInstruction?
            let contents: [Content]
            struct SystemInstruction: Encodable { let parts: [Part] }
            struct Content: Encodable { let parts: [Part] }
            struct Part: Encodable { let text: String }
        }
        struct Response: Decodable {
            let candidates: [Candidate]?
            let error: APIError?
            struct Candidate: Decodable { let content: Content }
            struct Content: Decodable { let parts: [Part] }
            struct Part: Decodable { let text: String? }
            struct APIError: Decodable { let message: String }
        }

        let body = Request(
            system_instruction: .init(parts: [.init(text: system)]),
            contents: [.init(parts: [.init(text: user)])]
        )

        let url = AIProviderKind.google.endpoint
            .appendingPathComponent("models/\(model):generateContent")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Gemini uses query param for key
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        req.url = components.url
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: req)
        try checkHTTPStatus(response, data: data)

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        if let error = decoded.error { throw AIServiceError.apiError(error.message) }
        let text = decoded.candidates?.first?.content.parts.compactMap(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    // MARK: - Helpers

    private func checkHTTPStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.noResponse
        }
        if !(200...299).contains(http.statusCode) {
            // Try to extract error message from response body
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw AIServiceError.apiError(message)
            }
            throw AIServiceError.httpError(http.statusCode)
        }
    }
}

// MARK: - Error

public enum AIServiceError: LocalizedError {
    case noAPIKey
    case noResponse
    case httpError(Int)
    case apiError(String)

    public var errorDescription: String? {
        switch self {
        case .noAPIKey: "No API key configured"
        case .noResponse: "No response from server"
        case .httpError(let code): "HTTP \(code)"
        case .apiError(let msg): msg
        }
    }
}
