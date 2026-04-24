import Foundation

public protocol ProviderAdapter: Sendable {
    func buildRequestBody(profile: ProviderProfile, request: AIRequest) throws -> Data
    func parseResponse(data: Data) throws -> AIResponse
}

public enum ProviderAdapterError: Error {
    case unsupportedStyle
    case invalidPayload
}

public struct ProviderAdapterFactory {
    public static func makeAdapter(for profile: ProviderProfile) throws -> any ProviderAdapter {
        switch profile.apiStyle {
        case .openAICompatible:
            return OpenAICompatibleAdapter()
        default:
            throw ProviderAdapterError.unsupportedStyle
        }
    }
}

public struct OpenAICompatibleAdapter: ProviderAdapter {
    public init() {}

    public func buildRequestBody(profile: ProviderProfile, request: AIRequest) throws -> Data {
        var body: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map { ["role": $0.role, "content": $0.content] },
            "stream": request.stream
        ]

        if let temperature = request.temperature {
            body[profile.requestFieldMapping["temperature"] ?? "temperature"] = temperature
        }
        if let maxTokens = request.maxTokens {
            body[profile.requestFieldMapping["maxTokens"] ?? "max_tokens"] = maxTokens
        }
        if let reasoning = request.reasoning,
           let modelProfile = profile.modelProfiles.first(where: { $0.id == request.model }),
           let mapping = modelProfile.reasoningMapping {
            set(value: reasoning.enabled, for: mapping.enabledField, in: &body)
            if let level = reasoning.level {
                set(value: level, for: mapping.depthField, in: &body)
            }
        }

        for (key, value) in request.extraParameters {
            body[key] = value.rawValue
        }
        for (key, value) in profile.extraBodyParameters {
            body[key] = value.rawValue
        }

        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    public func parseResponse(data: Data) throws -> AIResponse {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderAdapterError.invalidPayload
        }

        let choices = object["choices"] as? [[String: Any]]
        let firstMessage = choices?.first?["message"] as? [String: Any]
        let content = firstMessage?["content"] as? String
        let toolCalls = (firstMessage?["tool_calls"] as? [[String: Any]] ?? []).compactMap { item -> ToolCall? in
            guard let function = item["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }

            let argumentsData = (function["arguments"] as? String)?.data(using: .utf8)
            let argumentsJSON = (argumentsData.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
            return ToolCall(name: name, arguments: argumentsJSON.mapValues(JSONValue.convert(any:)))
        }

        let usageDict = object["usage"] as? [String: Any]
        let usage = AIUsage(
            inputTokens: usageDict?["prompt_tokens"] as? Int,
            outputTokens: usageDict?["completion_tokens"] as? Int,
            cachedInputTokens: usageDict?["cached_tokens"] as? Int,
            cacheMissInputTokens: usageDict?["prompt_cache_miss_tokens"] as? Int,
            totalTokens: usageDict?["total_tokens"] as? Int
        )

        return AIResponse(text: content, toolCalls: toolCalls, usage: usage, rawPayload: data)
    }

    private func set(value: Any, for dottedPath: String, in dictionary: inout [String: Any]) {
        let parts = dottedPath.split(separator: ".").map(String.init)
        guard let first = parts.first else { return }
        if parts.count == 1 {
            dictionary[first] = value
            return
        }

        var nested = dictionary[first] as? [String: Any] ?? [:]
        setNested(value: value, parts: Array(parts.dropFirst()), in: &nested)
        dictionary[first] = nested
    }

    private func setNested(value: Any, parts: [String], in dictionary: inout [String: Any]) {
        guard let first = parts.first else { return }
        if parts.count == 1 {
            dictionary[first] = value
            return
        }
        var nested = dictionary[first] as? [String: Any] ?? [:]
        setNested(value: value, parts: Array(parts.dropFirst()), in: &nested)
        dictionary[first] = nested
    }
}

private extension JSONValue {
    static func convert(any: Any) -> JSONValue {
        switch any {
        case let value as String:
            .string(value)
        case let value as Int:
            .integer(value)
        case let value as Double:
            .number(value)
        case let value as Bool:
            .bool(value)
        case let value as [String: Any]:
            .object(value.mapValues(convert(any:)))
        case let value as [Any]:
            .array(value.map(convert(any:)))
        default:
            .null
        }
    }
}
