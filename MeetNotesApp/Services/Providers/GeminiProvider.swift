import Foundation

/// LLM provider for Google's Gemini API.
struct GeminiProvider: LLMProvider {
    let name = "Gemini"

    private let model = "gemini-2.0-flash"

    private func endpoint(apiKey: String) -> URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
    }

    func generateCompletion(prompt: String) async throws -> String {
        guard let apiKey = KeychainService.read(key: .googleApiKey), !apiKey.isEmpty else {
            throw LLMError.missingAPIKey(provider: name)
        }

        var request = URLRequest(url: endpoint(apiKey: apiKey))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.3
            ]
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
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw LLMError.invalidResponse(provider: name)
        }

        return text
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw LLMError.networkError(underlying: error)
        }
    }
}
