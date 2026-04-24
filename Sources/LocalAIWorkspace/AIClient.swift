import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AIClientError: Error, LocalizedError {
    case unsupportedProvider
    case invalidBaseURL(String)
    case missingAPIKeyReference
    case streamingToolCallsUnsupported
    case server(statusCode: Int, message: String, payload: Data)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "The selected provider style is not supported yet."
        case let .invalidBaseURL(url):
            return "The provider base URL is invalid: \(url)"
        case .missingAPIKeyReference:
            return "The provider profile is missing an API key reference."
        case .streamingToolCallsUnsupported:
            return "Streaming tool calls are not supported yet."
        case let .server(statusCode, message, _):
            return "Provider request failed with status \(statusCode): \(message)"
        }
    }
}

public protocol AIClient: Sendable {
    func complete(profile: ProviderProfile, apiKey: String?, request: AIRequest) async throws -> AIResponse
}

public struct OpenAICompatibleAIClient: AIClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func complete(profile: ProviderProfile, apiKey: String?, request: AIRequest) async throws -> AIResponse {
        let urlRequest = try buildURLRequest(profile: profile, apiKey: apiKey, request: request)
        let startedAt = Date()
        let (data, response) = try await session.data(for: urlRequest)
        let latency = Int(Date().timeIntervalSince(startedAt) * 1000)

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(statusCode) else {
            let message = ProviderPayloadParser.errorMessage(from: data, profile: profile) ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
            throw AIClientError.server(statusCode: statusCode, message: message, payload: data)
        }

        let adapter = try ProviderAdapterFactory.makeAdapter(for: profile)
        var parsed = try adapter.parseResponse(profile: profile, data: data)
        if var usage = parsed.usage {
            usage.latencyMs = latency
            parsed.usage = usage
        } else {
            parsed.usage = AIUsage(latencyMs: latency)
        }
        return parsed
    }

    public func buildURLRequest(profile: ProviderProfile, apiKey: String?, request: AIRequest) throws -> URLRequest {
        if request.stream, let tools = request.tools, !tools.isEmpty {
            throw AIClientError.streamingToolCallsUnsupported
        }

        guard var components = URLComponents(string: profile.baseURL) else {
            throw AIClientError.invalidBaseURL(profile.baseURL)
        }

        let endpoint = profile.endpoint.hasPrefix("/") ? profile.endpoint : "/" + profile.endpoint
        let combinedPath = components.path.isEmpty ? endpoint : components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + endpoint
        components.path = combinedPath.hasPrefix("/") ? combinedPath : "/" + combinedPath

        switch profile.auth.type {
        case .query:
            guard let keyName = profile.auth.keyName, let apiKey else {
                throw AIClientError.missingAPIKeyReference
            }
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: keyName, value: apiKey))
            components.queryItems = items
        case .bearer, .header:
            if profile.auth.type != .none, apiKey == nil {
                throw AIClientError.missingAPIKeyReference
            }
        case .none:
            break
        }

        guard let url = components.url else {
            throw AIClientError.invalidBaseURL(profile.baseURL)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        if let apiKey {
            switch profile.auth.type {
            case .bearer:
                urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            case .header:
                urlRequest.setValue(apiKey, forHTTPHeaderField: profile.auth.keyName ?? "X-API-Key")
            case .query, .none:
                break
            }
        }

        for (key, value) in profile.extraHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let adapter = try ProviderAdapterFactory.makeAdapter(for: profile)
        urlRequest.httpBody = try adapter.buildRequestBody(profile: profile, request: request)
        return urlRequest
    }
}

public struct DefaultAIClient: AIClient {
    private let openAICompatibleClient: OpenAICompatibleAIClient

    public init(openAICompatibleClient: OpenAICompatibleAIClient = OpenAICompatibleAIClient()) {
        self.openAICompatibleClient = openAICompatibleClient
    }

    public func complete(profile: ProviderProfile, apiKey: String?, request: AIRequest) async throws -> AIResponse {
        switch profile.apiStyle {
        case .openAICompatible:
            return try await openAICompatibleClient.complete(profile: profile, apiKey: apiKey, request: request)
        default:
            throw AIClientError.unsupportedProvider
        }
    }
}
