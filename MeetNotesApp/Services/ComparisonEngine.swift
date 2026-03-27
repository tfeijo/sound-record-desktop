import Foundation
import SwiftData

/// Provider-agnostic LLM engine for comparing user personal notes against AI-generated notes.
///
/// After a meeting ends and summarization completes, this engine sends both the user's
/// personal notes and the AI notes to the configured LLM provider, which categorizes
/// observations into aligned, user-only, AI-only, and conflicting items.
@Observable
final class ComparisonEngine {
    private(set) var isProcessing = false
    var error: String?

    /// Compare personal notes against AI notes using the configured LLM provider.
    func compare(
        personalNotes: [PersonalNote],
        aiNotes: AINotes?,
        transcript: [TranscriptSegment],
        settings: AppSettings
    ) async throws -> NoteComparison {
        guard !personalNotes.isEmpty else {
            throw LLMError.invalidResponse(provider: "ComparisonEngine")
        }

        let provider = makeProvider(for: settings)
        let prompt = Self.buildPrompt(
            personalNotes: personalNotes,
            aiNotes: aiNotes,
            transcript: transcript
        )

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

        return try Self.parseResponse(rawResponse)
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

    // MARK: - Prompt

    static func buildPrompt(
        personalNotes: [PersonalNote],
        aiNotes: AINotes?,
        transcript: [TranscriptSegment]
    ) -> String {
        let userNotesText = personalNotes.map { note in
            let mins = Int(note.timestamp) / 60
            let secs = Int(note.timestamp) % 60
            return "[\(String(format: "%02d:%02d", mins, secs))] \(note.text)"
        }.joined(separator: "\n")

        var aiNotesText = ""
        if let ai = aiNotes {
            if !ai.topics.isEmpty {
                aiNotesText += "Topics: \(ai.topics.joined(separator: ", "))\n"
            }
            if !ai.decisions.isEmpty {
                aiNotesText += "Decisions: \(ai.decisions.joined(separator: "; "))\n"
            }
            if !ai.actionItems.isEmpty {
                let items = ai.actionItems.map { item in
                    if let assignee = item.assignee {
                        return "\(item.description) (@\(assignee))"
                    }
                    return item.description
                }
                aiNotesText += "Action Items: \(items.joined(separator: "; "))\n"
            }
        }

        let transcriptText = transcript.prefix(50).map { segment in
            "[\(segment.speaker)] \(segment.text)"
        }.joined(separator: "\n")

        return """
        Compare the user's personal meeting notes against the AI-generated notes from the same meeting.
        Categorize each observation into one of four categories and return a JSON object.

        ## User's Personal Notes
        \(userNotesText)

        ## AI-Generated Notes
        \(aiNotesText.isEmpty ? "(none)" : aiNotesText)

        ## Meeting Transcript (for context)
        \(transcriptText)

        ## Instructions
        Return a JSON object with these four arrays:
        - "aligned": Items where user and AI agree. Each has {"description": string, "userNote": string, "aiNote": string}
        - "userOnly": Observations the user captured that the AI missed. Each has {"description": string, "userNote": string}
        - "aiOnly": Insights the AI captured that the user missed. Each has {"description": string, "aiNote": string}
        - "conflicts": Points where user and AI disagree. Each has {"description": string, "userNote": string, "aiNote": string}

        Return ONLY valid JSON, no markdown code fences.
        """
    }

    // MARK: - Parsing

    static func parseResponse(_ rawText: String) throws -> NoteComparison {
        let cleaned = stripCodeFences(rawText).trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            throw LLMError.jsonParsingFailed(rawText: rawText)
        }

        do {
            return try JSONDecoder().decode(NoteComparison.self, from: data)
        } catch {
            throw LLMError.jsonParsingFailed(rawText: rawText)
        }
    }

    private static func stripCodeFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            if let newlineIndex = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: newlineIndex)...])
            }
        }
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
