import Foundation

/// Errors that can occur during LLM operations.
enum LLMError: LocalizedError {
    case missingAPIKey(provider: String)
    case providerUnavailable(provider: String, reason: String)
    case invalidResponse(provider: String)
    case jsonParsingFailed(rawText: String)
    case networkError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "API key not configured for \(provider). Please add it in Settings."
        case .providerUnavailable(let provider, let reason):
            return "\(provider) is unreachable: \(reason)"
        case .invalidResponse(let provider):
            return "Invalid response received from \(provider)."
        case .jsonParsingFailed(let rawText):
            let preview = String(rawText.prefix(200))
            return "Failed to parse LLM JSON response: \(preview)"
        case .networkError(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        }
    }
}

/// Protocol for LLM providers that can generate text completions.
protocol LLMProvider {
    /// Human-readable name for this provider (e.g. "Claude", "Gemini", "Ollama").
    var name: String { get }

    /// Send a prompt and receive a text completion.
    func generateCompletion(prompt: String) async throws -> String
}
