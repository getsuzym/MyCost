import Foundation

/// Parses the two layers of an OpenAI-compatible Chat Completions reply:
/// the transport envelope (`choices[0].message.content`) and the JSON object
/// the model was asked to put inside that content. Every structural problem
/// becomes `MerchantCategorizationError.invalidResponse` so callers can treat
/// a broken response the same as any other failure.
struct MerchantCategorizationResponseParser {
    func content(fromEnvelope data: Data) throws -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw MerchantCategorizationError.invalidResponse("Response was not a JSON object.")
        }

        guard
            let choices = root["choices"] as? [[String: Any]],
            let firstChoice = choices.first,
            let message = firstChoice["message"] as? [String: Any],
            let content = message["content"] as? String,
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MerchantCategorizationError.invalidResponse("Response had no message content.")
        }

        return content
    }

    func suggestion(
        fromContent content: String,
        availableCategoryNames: [String]
    ) throws -> MerchantCategorizationSuggestion {
        guard
            let data = extractJSONObject(from: content).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw MerchantCategorizationError.invalidResponse("Model output was not a JSON object.")
        }

        guard
            let merchant = (object["merchant"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !merchant.isEmpty
        else {
            throw MerchantCategorizationError.invalidResponse("Missing 'merchant' in model output.")
        }

        guard let confidenceValue = object["confidence"] as? NSNumber, !isBoolean(confidenceValue) else {
            throw MerchantCategorizationError.invalidResponse("Missing or non-numeric 'confidence'.")
        }
        let confidence = confidenceValue.doubleValue
        guard confidence >= 0, confidence <= 1 else {
            throw MerchantCategorizationError.invalidResponse("'confidence' must be between 0 and 1.")
        }

        let categoryName = canonicalCategory(
            for: object["category"] as? String,
            in: availableCategoryNames
        )

        return MerchantCategorizationSuggestion(
            normalizedMerchantName: merchant,
            categoryName: categoryName,
            confidence: confidence
        )
    }

    /// An unknown or empty category is dropped (returns `nil`) rather than
    /// failing the whole suggestion — a usable merchant name plus manual
    /// category selection is still better than nothing.
    private func canonicalCategory(for raw: String?, in available: [String]) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return nil }
        return available.first { $0.compare(trimmed, options: .caseInsensitive) == .orderedSame }
    }

    /// Tolerates models that wrap the JSON in prose or a ```json fence.
    private func extractJSONObject(from content: String) -> String {
        guard
            let start = content.firstIndex(of: "{"),
            let end = content.lastIndex(of: "}"),
            start < end
        else {
            return content
        }
        return String(content[start...end])
    }

    private func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

/// Concrete provider for any OpenAI-compatible Chat Completions endpoint,
/// authenticated with the end user's own key from ``AICredentialStoring``.
/// Networking is injected so it can be exercised without a live server.
struct RemoteMerchantCategorizationProvider: MerchantCategorizationProviding {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let credentialStore: AICredentialStoring
    private let transport: Transport
    private let parser = MerchantCategorizationResponseParser()

    init(
        credentialStore: AICredentialStoring,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
    }

    var isConfigured: Bool { credentialStore.loadConnection() != nil }

    func suggestCategorization(
        for request: MerchantCategorizationRequest
    ) async throws -> MerchantCategorizationSuggestion {
        guard let connection = credentialStore.loadConnection() else {
            throw MerchantCategorizationError.notConfigured
        }

        let urlRequest = try makeURLRequest(for: request, connection: connection)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(urlRequest)
        } catch is CancellationError {
            throw MerchantCategorizationError.cancelled
        } catch {
            throw MerchantCategorizationError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MerchantCategorizationError.network("HTTP \(http.statusCode)")
        }

        let content = try parser.content(fromEnvelope: data)
        return try parser.suggestion(
            fromContent: content,
            availableCategoryNames: request.availableCategoryNames
        )
    }

    /// Exposed for tests: builds the exact request body that would be sent so
    /// its payload can be asserted on (only merchant + amount + category list).
    func makeURLRequest(
        for request: MerchantCategorizationRequest,
        connection: AIProviderConnection
    ) throws -> URLRequest {
        var urlRequest = URLRequest(url: connection.endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(connection.apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": connection.model,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": Self.systemPrompt(categories: request.availableCategoryNames)],
                ["role": "user", "content": Self.userPrompt(for: request)]
            ]
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return urlRequest
    }

    static func systemPrompt(categories: [String]) -> String {
        let list = categories.isEmpty ? "any short label" : categories.joined(separator: ", ")
        return """
        You normalize a single card/bank payment description and classify it.
        Reply with ONLY a JSON object, no prose, of the exact shape:
        {"merchant": string, "category": string or null, "confidence": number between 0 and 1}
        "merchant" is a clean, human-readable merchant name.
        "category" must be exactly one of: \(list). Use null if none clearly fits.
        "confidence" is your certainty in the classification.
        """
    }

    static func userPrompt(for request: MerchantCategorizationRequest) -> String {
        var lines = ["Description: \(request.merchantDescription)"]
        if let amount = request.amount {
            lines.append("Amount: \(NSDecimalNumber(decimal: amount).stringValue)")
        }
        return lines.joined(separator: "\n")
    }
}
