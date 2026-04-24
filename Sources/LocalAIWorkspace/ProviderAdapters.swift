import Foundation

public protocol ProviderAdapter: Sendable {
    func buildRequestBody(profile: ProviderProfile, request: AIRequest) throws -> Data
    func parseResponse(profile: ProviderProfile, data: Data) throws -> AIResponse
}

public enum ProviderAdapterError: Error, LocalizedError {
    case unsupportedStyle
    case invalidPayload
    case invalidToolArguments(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedStyle:
            return "The selected provider style is not supported yet."
        case .invalidPayload:
            return "The provider returned an invalid JSON payload."
        case let .invalidToolArguments(value):
            return "Tool call arguments were not valid JSON: \(value)"
        }
    }
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
        var body: [String: Any] = [:]
        set(value: request.model, for: requestField("model", default: "model", profile: profile), in: &body)
        set(
            value: request.messages.map { ["role": $0.role, "content": $0.content] },
            for: requestField("messages", default: "messages", profile: profile),
            in: &body
        )
        set(value: request.stream, for: requestField("stream", default: "stream", profile: profile), in: &body)

        if let temperature = request.temperature {
            set(value: temperature, for: requestField("temperature", default: "temperature", profile: profile), in: &body)
        }
        if let maxTokens = request.maxTokens {
            set(value: maxTokens, for: requestField("maxTokens", default: "max_tokens", profile: profile), in: &body)
        }
        if let tools = request.tools, !tools.isEmpty {
            set(
                value: tools.map(makeToolDescriptor),
                for: requestField("tools", default: "tools", profile: profile),
                in: &body
            )
            set(
                value: request.toolChoice ?? "auto",
                for: requestField("toolChoice", default: "tool_choice", profile: profile),
                in: &body
            )
        }
        if let reasoning = request.reasoning,
           let modelProfile = profile.modelProfiles.first(where: { $0.id == request.model }),
           let mapping = modelProfile.reasoningMapping {
            set(value: reasoning.enabled, for: mapping.enabledField, in: &body)
            if let level = reasoning.level {
                set(value: level, for: mapping.depthField, in: &body)
            }
        }
        if let webSearch = request.webSearch,
           let mapping = profile.requestFieldMapping["webSearch"] {
            set(value: webSearch.rawValue, for: mapping, in: &body)
        }

        for (key, value) in profile.extraBodyParameters {
            set(value: value.rawValue, for: key, in: &body)
        }
        for (key, value) in request.extraParameters {
            set(value: value.rawValue, for: key, in: &body)
        }

        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    public func parseResponse(profile: ProviderProfile, data: Data) throws -> AIResponse {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderAdapterError.invalidPayload
        }

        let content = firstString(
            in: object,
            preferredPath: profile.responseFieldMapping["text"],
            fallbacks: [
                "choices.0.message.content",
                "choices.0.message.content.0.text",
                "choices.0.text"
            ]
        )
        let reasoningContent = firstString(
            in: object,
            preferredPath: profile.responseFieldMapping["reasoningContent"],
            fallbacks: [
                "choices.0.message.reasoning_content",
                "choices.0.message.reasoning",
                "choices.0.delta.reasoning_content"
            ]
        )
        let toolCalls = try parseToolCalls(
            in: object,
            preferredPath: profile.responseFieldMapping["toolCalls"],
            fallbacks: [
                "choices.0.message.tool_calls",
                "choices.0.delta.tool_calls"
            ]
        )
        let usage = parseUsage(from: object, profile: profile)

        return AIResponse(
            text: content,
            toolCalls: toolCalls,
            reasoningContent: reasoningContent,
            usage: usage,
            rawPayload: data
        )
    }

    private func requestField(_ logicalName: String, default defaultValue: String, profile: ProviderProfile) -> String {
        profile.requestFieldMapping[logicalName] ?? defaultValue
    }

    private func makeToolDescriptor(_ schema: ToolCallSchema) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": schema.name,
                "description": schema.description,
                "parameters": [
                    "type": "object",
                    "properties": schema.parameters.mapValues(\.rawValue),
                    "required": schema.required
                ]
            ]
        ]
    }

    private func parseUsage(from object: [String: Any], profile: ProviderProfile) -> AIUsage? {
        guard value(at: "usage", in: object) != nil || !profile.usageFieldMapping.isEmpty else {
            return nil
        }

        let inputTokens = firstInt(
            in: object,
            preferredPath: profile.usageFieldMapping["promptTokens"],
            fallbacks: ["usage.prompt_tokens"]
        )
        let outputTokens = firstInt(
            in: object,
            preferredPath: profile.usageFieldMapping["completionTokens"],
            fallbacks: ["usage.completion_tokens"]
        )
        let totalTokens = firstInt(
            in: object,
            preferredPath: profile.usageFieldMapping["totalTokens"],
            fallbacks: ["usage.total_tokens"]
        )
        let cachedTokens = firstInt(
            in: object,
            preferredPath: profile.usageFieldMapping["cachedTokens"],
            fallbacks: [
                "usage.prompt_tokens_details.cached_tokens",
                "usage.cached_tokens",
                "usage.prompt_cache_hit_tokens"
            ]
        )
        let cacheMissTokens = firstInt(
            in: object,
            preferredPath: profile.usageFieldMapping["cacheMissTokens"],
            fallbacks: [
                "usage.prompt_cache_miss_tokens"
            ]
        )

        return AIUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: cachedTokens,
            cacheMissInputTokens: cacheMissTokens,
            totalTokens: totalTokens
        )
    }

    private func parseToolCalls(in object: [String: Any], preferredPath: String?, fallbacks: [String]) throws -> [ToolCall] {
        guard let rawToolCalls = firstArray(in: object, preferredPath: preferredPath, fallbacks: fallbacks) else {
            return []
        }

        return try rawToolCalls.compactMap { item -> ToolCall? in
            guard let dictionary = item as? [String: Any] else { return nil }
            let function = (dictionary["function"] as? [String: Any]) ?? dictionary
            guard let name = function["name"] as? String else { return nil }
            let argumentsValue = function["arguments"]

            if let argumentString = argumentsValue as? String {
                guard let data = argumentString.data(using: .utf8) else {
                    throw ProviderAdapterError.invalidToolArguments(argumentString)
                }
                let object = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                return ToolCall(name: name, arguments: object.mapValues(JSONValue.convert(any:)))
            }
            if let argumentObject = argumentsValue as? [String: Any] {
                return ToolCall(name: name, arguments: argumentObject.mapValues(JSONValue.convert(any:)))
            }
            return ToolCall(name: name, arguments: [:])
        }
    }
}

enum ProviderPayloadParser {
    static func errorMessage(from data: Data, profile: ProviderProfile) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return firstString(
            in: object,
            preferredPath: profile.responseFieldMapping["errorMessage"],
            fallbacks: [
                "error.message",
                "message",
                "detail"
            ]
        )
    }
}

private func value(at dottedPath: String, in root: [String: Any]) -> Any? {
    var current: Any = root
    for part in dottedPath.split(separator: ".").map(String.init) {
        if let index = Int(part), let array = current as? [Any], array.indices.contains(index) {
            current = array[index]
        } else if let dictionary = current as? [String: Any], let next = dictionary[part] {
            current = next
        } else {
            return nil
        }
    }
    return current
}

private func firstString(in object: [String: Any], preferredPath: String?, fallbacks: [String]) -> String? {
    for path in [preferredPath].compactMap({ $0 }) + fallbacks {
        if let string = value(at: path, in: object) as? String, !string.isEmpty {
            return string
        }
        if let array = value(at: path, in: object) as? [Any] {
            let segments = array.compactMap { item -> String? in
                if let text = item as? String {
                    return text
                }
                if let dictionary = item as? [String: Any] {
                    return dictionary["text"] as? String
                }
                return nil
            }
            if !segments.isEmpty {
                return segments.joined()
            }
        }
    }
    return nil
}

private func firstInt(in object: [String: Any], preferredPath: String?, fallbacks: [String]) -> Int? {
    for path in [preferredPath].compactMap({ $0 }) + fallbacks {
        if let value = value(at: path, in: object) as? Int {
            return value
        }
        if let string = value(at: path, in: object) as? String, let value = Int(string) {
            return value
        }
        if let double = value(at: path, in: object) as? Double {
            return Int(double.rounded())
        }
    }
    return nil
}

private func firstArray(in object: [String: Any], preferredPath: String?, fallbacks: [String]) -> [Any]? {
    for path in [preferredPath].compactMap({ $0 }) + fallbacks {
        if let array = value(at: path, in: object) as? [Any] {
            return array
        }
    }
    return nil
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
