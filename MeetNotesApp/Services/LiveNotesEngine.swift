import Foundation
import SwiftData

/// Engine that periodically sends accumulated transcript to the configured LLM
/// during a live recording, extracting topics, decisions, and action items incrementally.
///
/// Uses the same LLM provider infrastructure as `SummaryEngine` (LLMProvider protocol,
/// AppSettings.summaryProvider, KeychainService for API keys).
@MainActor @Observable
final class LiveNotesEngine {
    // MARK: - Published State

    private(set) var currentNotes: AINotes?
    private(set) var isProcessing = false
    private(set) var lastUpdateTime: Date?
    var error: String?

    // MARK: - Private

    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var lastProcessedTranscriptLength = 0
    @ObservationIgnored private var fullTranscriptText = ""

    private let pollingInterval: TimeInterval = 30.0

    // MARK: - Public API

    /// Start the live notes polling loop.
    ///
    /// - Parameters:
    ///   - transcriptProvider: Closure that returns the current transcript segments.
    ///   - settings: App settings for LLM provider selection.
    func start(
        transcriptProvider: @escaping @MainActor () -> [TranscriptSegment],
        settings: AppSettings
    ) {
        guard !isRunning else { return }
        isRunning = true
        currentNotes = nil
        lastUpdateTime = nil
        lastProcessedTranscriptLength = 0
        fullTranscriptText = ""
        error = nil

        pollingTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled && self.isRunning {
                try? await Task.sleep(for: .seconds(self.pollingInterval))

                guard !Task.isCancelled, self.isRunning else { break }

                let segments = transcriptProvider()
                await self.processTranscript(segments: segments, settings: settings)
            }
        }
    }

    /// Stop the polling loop and return the final accumulated notes.
    ///
    /// - Returns: The final `AINotes`, or nil if no notes were extracted.
    @discardableResult
    func stop() -> AINotes? {
        isRunning = false
        pollingTask?.cancel()
        pollingTask = nil
        return currentNotes
    }

    // MARK: - Transcript Processing

    private func processTranscript(
        segments: [TranscriptSegment],
        settings: AppSettings
    ) async {
        // Build full transcript text
        let transcriptText = segments.map { segment in
            "[\(segment.speaker)] \(segment.text)"
        }.joined(separator: "\n")

        // Skip if no new content since last processing
        guard transcriptText.count > lastProcessedTranscriptLength else { return }

        let newTranscript = String(transcriptText.dropFirst(lastProcessedTranscriptLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !newTranscript.isEmpty else { return }

        isProcessing = true
        defer { isProcessing = false }

        let provider = makeProvider(for: settings)
        let prompt = buildIncrementalPrompt(newTranscript: newTranscript)

        do {
            let rawResponse = try await provider.generateCompletion(prompt: prompt)
            let extracted = try parseIncrementalResponse(rawResponse)
            mergeNotes(extracted)
            lastProcessedTranscriptLength = transcriptText.count
            lastUpdateTime = Date()
            error = nil
        } catch {
            // Graceful degradation: keep last known state, log error
            self.error = "Live notes update failed: \(error.localizedDescription)"
        }
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

    // MARK: - Incremental Prompt

    private func buildIncrementalPrompt(newTranscript: String) -> String {
        let previousTopics = currentNotes.map { $0.topics.joined(separator: ", ") } ?? "none yet"
        let previousDecisions = currentNotes.map { $0.decisions.joined(separator: ", ") } ?? "none yet"
        let previousActions = currentNotes.map {
            $0.actionItems.map { item in
                let assignee = item.assignee ?? "unassigned"
                return "\(item.description) (\(assignee))"
            }.joined(separator: ", ")
        } ?? "none yet"

        return """
        You are extracting live meeting notes. Below is the transcript so far and previously extracted items.

        Previously extracted:
        Topics: \(previousTopics)
        Decisions: \(previousDecisions)
        Action items: \(previousActions)

        New transcript since last update:
        \(newTranscript)

        Extract ONLY NEW items not already in the previous lists. Return JSON:
        {
          "topics": ["[[Topic Name]]"],
          "decisions": ["Decision text"],
          "actionItems": [{"description": "Task", "assignee": "Person or null"}]
        }

        Return ONLY valid JSON, no markdown.
        """
    }

    // MARK: - Response Parsing

    private struct IncrementalResponse: Decodable {
        var topics: [String]?
        var decisions: [String]?
        var actionItems: [IncrementalActionItem]?
    }

    private struct IncrementalActionItem: Decodable {
        var description: String
        var assignee: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            description = try container.decode(String.self, forKey: .description)
            // Handle "null" string as nil
            if let raw = try? container.decode(String.self, forKey: .assignee) {
                assignee = (raw == "null" || raw.isEmpty) ? nil : raw
            } else {
                assignee = nil
            }
        }

        private enum CodingKeys: String, CodingKey {
            case description, assignee
        }
    }

    private func parseIncrementalResponse(_ rawText: String) throws -> IncrementalResponse {
        let cleaned = stripCodeFences(rawText).trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            throw LLMError.jsonParsingFailed(rawText: rawText)
        }

        do {
            return try JSONDecoder().decode(IncrementalResponse.self, from: data)
        } catch {
            throw LLMError.jsonParsingFailed(rawText: rawText)
        }
    }

    private func stripCodeFences(_ text: String) -> String {
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

    // MARK: - Merge Logic

    /// Merge newly extracted items into the accumulated notes, avoiding duplicates.
    private func mergeNotes(_ extracted: IncrementalResponse) {
        var topics = currentNotes?.topics ?? []
        var decisions = currentNotes?.decisions ?? []
        var actionItems = currentNotes?.actionItems ?? []

        // Merge topics (case-insensitive dedup)
        let existingTopicsLower = Set(topics.map { $0.lowercased() })
        for topic in extracted.topics ?? [] where !topic.isEmpty {
            if !existingTopicsLower.contains(topic.lowercased()) {
                topics.append(topic)
            }
        }

        // Merge decisions (case-insensitive dedup)
        let existingDecisionsLower = Set(decisions.map { $0.lowercased() })
        for decision in extracted.decisions ?? [] where !decision.isEmpty {
            if !existingDecisionsLower.contains(decision.lowercased()) {
                decisions.append(decision)
            }
        }

        // Merge action items (dedup by description, case-insensitive)
        let existingActionsLower = Set(actionItems.map { $0.description.lowercased() })
        for item in extracted.actionItems ?? [] where !item.description.isEmpty {
            if !existingActionsLower.contains(item.description.lowercased()) {
                actionItems.append(ActionItem(description: item.description, assignee: item.assignee))
            }
        }

        currentNotes = AINotes(
            topics: topics,
            decisions: decisions,
            actionItems: actionItems,
            lastUpdated: Date()
        )
    }
}
