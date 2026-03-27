import Foundation

/// LLM provider for local Ollama instance.
struct OllamaProvider: LLMProvider {
    let name = "Ollama"

    private let baseURL = URL(string: "http://localhost:11434")!
    let modelName: String

    init(modelName: String = "llama3") {
        self.modelName = modelName
    }

    func generateCompletion(prompt: String) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("api/generate")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Longer timeout for local models which can be slow
        request.timeoutInterval = 300

        let body: [String: Any] = [
            "model": modelName,
            "prompt": prompt,
            "stream": false,
            "format": "json"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse(provider: name)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw LLMError.providerUnavailable(
                provider: name,
                reason: "HTTP \(httpResponse.statusCode): \(body)"
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            throw LLMError.invalidResponse(provider: name)
        }

        return text
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .timedOut {
            throw LLMError.providerUnavailable(
                provider: name,
                reason: "Cannot connect to Ollama at localhost:11434. Is Ollama running?"
            )
        } catch {
            throw LLMError.networkError(underlying: error)
        }
    }
}
