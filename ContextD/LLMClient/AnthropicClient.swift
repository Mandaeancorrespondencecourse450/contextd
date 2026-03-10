import Foundation

/// Anthropic Messages API client. Hand-rolled using URLSession.
/// Supports Claude models (Haiku, Sonnet, Opus) via the /v1/messages endpoint.
final class AnthropicClient: LLMClient, Sendable {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    private let logger = DualLogger(category: "AnthropicClient")

    /// Maximum number of retry attempts for transient errors.
    private let maxRetries = 3

    // MARK: - API Key (plain text file in Application Support)

    /// Path to the API key file: ~/Library/Application Support/ContextD/api_key
    static var apiKeyFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ContextD", isDirectory: true)
            .appendingPathComponent("api_key")
    }

    /// Read the API key from disk. Returns nil if the file doesn't exist or is empty.
    static func readAPIKey() -> String? {
        guard let raw = try? String(contentsOf: apiKeyFileURL, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Write the API key to disk.
    static func saveAPIKey(_ key: String) throws {
        let dir = apiKeyFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try key.trimmingCharacters(in: .whitespacesAndNewlines)
            .write(to: apiKeyFileURL, atomically: true, encoding: .utf8)
    }

    /// Check whether an API key file exists and is non-empty.
    static func hasAPIKey() -> Bool {
        readAPIKey() != nil
    }

    func complete(
        messages: [LLMMessage],
        model: String,
        maxTokens: Int,
        systemPrompt: String?,
        temperature: Double
    ) async throws -> String {
        guard let apiKey = Self.readAPIKey() else {
            throw LLMError.noAPIKey
        }

        let requestBody = buildRequestBody(
            messages: messages,
            model: model,
            maxTokens: maxTokens,
            systemPrompt: systemPrompt,
            temperature: temperature
        )

        var lastError: Error = LLMError.invalidResponse

        for attempt in 0..<maxRetries {
            do {
                let response = try await sendRequest(body: requestBody, apiKey: apiKey)
                return response
            } catch LLMError.rateLimited(let retryAfter) {
                let delay = retryAfter ?? Double(pow(2.0, Double(attempt))) // exponential backoff
                logger.warning("Rate limited, retrying in \(delay)s (attempt \(attempt + 1)/\(self.maxRetries))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                lastError = LLMError.rateLimited(retryAfter: retryAfter)
            } catch LLMError.httpError(let code, let body) where code >= 500 {
                let delay = Double(pow(2.0, Double(attempt)))
                logger.warning("Server error \(code), retrying in \(delay)s (attempt \(attempt + 1)/\(self.maxRetries))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                lastError = LLMError.httpError(statusCode: code, body: body)
            } catch {
                throw error
            }
        }

        throw lastError
    }

    // MARK: - Private

    private func buildRequestBody(
        messages: [LLMMessage],
        model: String,
        maxTokens: Int,
        systemPrompt: String?,
        temperature: Double
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]

        if let system = systemPrompt {
            body["system"] = system
        }

        return body
    }

    private func sendRequest(body: [String: Any], apiKey: String) async throws -> String {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        let responseBody = String(data: data, encoding: .utf8) ?? ""

        switch httpResponse.statusCode {
        case 200:
            return try parseResponse(data: data)
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after")
                .flatMap(TimeInterval.init)
            throw LLMError.rateLimited(retryAfter: retryAfter)
        default:
            throw LLMError.httpError(statusCode: httpResponse.statusCode, body: responseBody)
        }
    }

    private func parseResponse(data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw LLMError.invalidResponse
        }
        return text
    }
}
