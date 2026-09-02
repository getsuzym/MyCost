import Foundation

// (Filename kept for project stability; this holds the concrete
// AIClassificationProvider implementations and their shared response parser.)

/// Validates and canonicalizes the strict JSON both providers are asked to
/// return: `{ "normalizedMerchantName": string, "suggestedCategory": string|null,
/// "confidence": number 0..1, "reasoningSummary": string|null }`. Any structural
/// problem becomes ``AIClassificationError/invalidResponse(_:)``.
struct ClassificationResponseParser {
    func classification(
        fromContent content: String,
        availableCategoryNames: [String]
    ) throws -> MerchantClassification {
        guard
            let data = extractJSONObject(from: content).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AIClassificationError.invalidResponse("Model output was not a JSON object.")
        }

        let merchant = (object["normalizedMerchantName"] as? String
            ?? object["merchant"] as? String
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !merchant.isEmpty else {
            throw AIClassificationError.invalidResponse("Missing 'normalizedMerchantName'.")
        }

        guard
            let confidenceNumber = object["confidence"] as? NSNumber,
            !isBoolean(confidenceNumber)
        else {
            throw AIClassificationError.invalidResponse("Missing or non-numeric 'confidence'.")
        }
        let confidence = confidenceNumber.doubleValue
        guard confidence >= 0, confidence <= 1 else {
            throw AIClassificationError.invalidResponse("'confidence' must be between 0 and 1.")
        }

        let category = canonicalCategory(
            for: object["suggestedCategory"] as? String ?? object["category"] as? String,
            in: availableCategoryNames
        )
        let reasoning = (object["reasoningSummary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return MerchantClassification(
            normalizedMerchantName: merchant,
            suggestedCategory: category,
            confidence: confidence,
            reasoningSummary: (reasoning?.isEmpty ?? true) ? nil : reasoning
        )
    }

    private func canonicalCategory(for raw: String?, in available: [String]) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return nil }
        return available.first { $0.compare(trimmed, options: .caseInsensitive) == .orderedSame }
    }

    private func extractJSONObject(from content: String) -> String {
        guard
            let start = content.firstIndex(of: "{"),
            let end = content.lastIndex(of: "}"),
            start < end
        else { return content }
        return String(content[start...end])
    }

    private func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

/// Shared bits both concrete providers need.
enum AIClassificationPrompt {
    static func system(categories: [String]) -> String {
        let list = categories.isEmpty ? "a short label" : categories.joined(separator: ", ")
        return """
        You normalize one card/bank payment description and classify it.
        Reply with ONLY a JSON object, no prose:
        {"normalizedMerchantName": string, "suggestedCategory": string or null, "confidence": number between 0 and 1, "reasoningSummary": string or null}
        "suggestedCategory" must be exactly one of: \(list). Use null if none clearly fits.
        "confidence" is your certainty in the classification. Keep "reasoningSummary" to one short sentence or null.
        """
    }

    static func user(for request: MerchantClassificationRequest) -> String {
        var lines = ["Description: \(request.merchantDescription)"]
        if let amount = request.amount {
            lines.append("Amount: \(NSDecimalNumber(decimal: amount).stringValue)")
        }
        return lines.joined(separator: "\n")
    }
}

typealias AITransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// Real networking. Injected everywhere so tests can substitute a stub.
let defaultAITransport: AITransport = { try await URLSession.shared.data(for: $0) }

private func mapTransportError(_ error: Error) -> AIClassificationError {
    if error is CancellationError { return .cancelled }
    return .network(error.localizedDescription)
}

private func mapHTTPStatus(_ code: Int) -> AIClassificationError? {
    switch code {
    case 200..<300: return nil
    case 401, 403: return .credentialsExpired
    case 429: return .network("Rate limited (HTTP 429)")
    default: return .network("HTTP \(code)")
    }
}

// MARK: - OpenAI

struct OpenAIClassificationProvider: AIClassificationProvider {
    let kind: AIProviderKind = .openAI
    private let endpoint: URL
    private let model: String
    private let secretStore: AISecretStore
    private let transport: AITransport
    private let parser = ClassificationResponseParser()

    init(
        endpoint: URL = AIProviderKind.openAI.defaultEndpoint,
        model: String = AIProviderKind.openAI.defaultModel,
        secretStore: AISecretStore,
        transport: @escaping AITransport = defaultAITransport
    ) {
        self.endpoint = endpoint
        self.model = model
        self.secretStore = secretStore
        self.transport = transport
    }

    var isConfigured: Bool { secretStore.secret(for: kind.keychainAccount)?.isUsable == true }

    func validateConnection() async throws {
        _ = try await classify(MerchantClassificationRequest(merchantDescription: "TEST", availableCategoryNames: []))
    }

    func classify(_ request: MerchantClassificationRequest) async throws -> MerchantClassification {
        guard let key = secretStore.secret(for: kind.keychainAccount)?.apiKey, !key.isEmpty else {
            throw AIClassificationError.providerUnavailable
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": AIClassificationPrompt.system(categories: request.availableCategoryNames)],
                ["role": "user", "content": AIClassificationPrompt.user(for: request)]
            ]
        ], options: [.sortedKeys])

        let (data, response) = try await perform(urlRequest)
        if let http = response as? HTTPURLResponse, let error = mapHTTPStatus(http.statusCode) { throw error }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw AIClassificationError.invalidResponse("Unexpected Chat Completions envelope.")
        }
        return try parser.classification(fromContent: content, availableCategoryNames: request.availableCategoryNames)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await transport(request) } catch { throw mapTransportError(error) }
    }
}

// MARK: - Anthropic

struct AnthropicClassificationProvider: AIClassificationProvider {
    let kind: AIProviderKind = .anthropic
    private let endpoint: URL
    private let model: String
    private let secretStore: AISecretStore
    private let transport: AITransport
    private let parser = ClassificationResponseParser()

    init(
        endpoint: URL = AIProviderKind.anthropic.defaultEndpoint,
        model: String = AIProviderKind.anthropic.defaultModel,
        secretStore: AISecretStore,
        transport: @escaping AITransport = defaultAITransport
    ) {
        self.endpoint = endpoint
        self.model = model
        self.secretStore = secretStore
        self.transport = transport
    }

    var isConfigured: Bool { secretStore.secret(for: kind.keychainAccount)?.isUsable == true }

    func validateConnection() async throws {
        _ = try await classify(MerchantClassificationRequest(merchantDescription: "TEST", availableCategoryNames: []))
    }

    func classify(_ request: MerchantClassificationRequest) async throws -> MerchantClassification {
        guard let key = secretStore.secret(for: kind.keychainAccount)?.apiKey, !key.isEmpty else {
            throw AIClassificationError.providerUnavailable
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 300,
            "system": AIClassificationPrompt.system(categories: request.availableCategoryNames),
            "messages": [
                ["role": "user", "content": AIClassificationPrompt.user(for: request)]
            ]
        ], options: [.sortedKeys])

        let (data, response) = try await perform(urlRequest)
        if let http = response as? HTTPURLResponse, let error = mapHTTPStatus(http.statusCode) { throw error }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let contentBlocks = root["content"] as? [[String: Any]]
        else {
            throw AIClassificationError.invalidResponse("Unexpected Messages envelope.")
        }
        let text = contentBlocks.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else {
            throw AIClassificationError.invalidResponse("Messages response had no text content.")
        }
        return try parser.classification(fromContent: text, availableCategoryNames: request.availableCategoryNames)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await transport(request) } catch { throw mapTransportError(error) }
    }
}
