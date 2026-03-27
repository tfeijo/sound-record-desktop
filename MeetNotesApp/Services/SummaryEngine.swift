import Foundation
import SwiftData

/// Provider-agnostic LLM summarization engine.
///
/// Selects the appropriate LLM provider based on `AppSettings.summaryProvider`,
/// sends the shared prompt template with the transcript, and parses the JSON
/// response into a `MeetingSummary`.
@Observable
final class SummaryEngine {
    private(set) var isProcessing = false
    var error: String?

    /// Summarize a transcript using the configured LLM provider.
    ///
    /// - Parameters:
    ///   - transcript: The full transcript text to summarize.
    ///   - settings: App settings containing the selected provider and Ollama model.
    /// - Returns: A parsed `MeetingSummary`.
    func summarize(transcript: String, settings: AppSettings) async throws -> MeetingSummary {
        guard !transcript.isEmpty else {
            throw LLMError.invalidResponse(provider: "SummaryEngine")
        }

        let provider = makeProvider(for: settings)
        let prompt = Self.buildPrompt(transcript: transcript)

        isProcessing = true
        error = nil
        defer { isProcessing = false }

        let rawResponse: String
        do {
            rawResponse = try await provider.generateCompletion(prompt: prompt)
        } catch let llmError as LLMError {
            error = llmError.errorDescription
            throw llmError
        } catch {
            let wrapped = LLMError.networkError(underlying: error)
            self.error = wrapped.errorDescription
            throw wrapped
        }

        let summary = try Self.parseResponse(rawResponse, providerName: provider.name)
        return summary
    }

    // MARK: - Provider Factory

    private func makeProvider(for settings: AppSettings) -> LLMProvider {
        switch settings.summaryProvider {
        case .claude:
            return ClaudeProvider()
        case .gemini:
            return GeminiProvider()
        case .local:
            let model = settings.ollamaModel ?? "llama3"
            return OllamaProvider(modelName: model)
        }
    }

    // MARK: - Prompt Template

    static func buildPrompt(transcript: String) -> String {
        """
        Analyze the following meeting transcript and return a JSON object with:
        - title: A concise title for the meeting (max 10 words)
        - summary: A 2-3 sentence summary of what was discussed
        - decisions: Array of key decisions made (strings)
        - actionItems: Array of {"description": string, "assignee": string} objects for tasks assigned
        - topics: Array of {"title": string, "summary": string} objects for main topics discussed

        Return ONLY valid JSON, no markdown code fences.

        Transcript:
        \(transcript)
        """
    }

    // MARK: - JSON Parsing

    /// Parse the raw LLM response text into a `MeetingSummary`.
    /// Handles common LLM quirks like markdown code fences wrapping the JSON.
    static func parseResponse(_ rawText: String, providerName: String) throws -> MeetingSummary {
        let cleaned = Self.stripCodeFences(rawText).trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            throw LLMError.jsonParsingFailed(rawText: rawText)
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(MeetingSummary.self, from: data)
        } catch {
            throw LLMError.jsonParsingFailed(rawText: rawText)
        }
    }

    /// Strip markdown code fences that LLMs sometimes add despite instructions.
    private static func stripCodeFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove opening fence (```json or ```)
        if result.hasPrefix("```") {
            if let newlineIndex = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: newlineIndex)...])
            }
        }

        // Remove closing fence
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
