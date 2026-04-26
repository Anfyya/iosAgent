import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SupportedTools {
    public static let schemas: [ToolCallSchema] = [
        ToolCallSchema(
            name: "list_files",
            description: "List files inside the current workspace.",
            parameters: [:],
            required: []
        ),
        ToolCallSchema(
            name: "read_file",
            description: "Read a text file in the current workspace and return its content plus hash.",
            parameters: ["path": .object(["type": .string("string")])],
            required: ["path"]
        ),
        ToolCallSchema(
            name: "search_in_files",
            description: "Search workspace text files.",
            parameters: ["query": .object(["type": .string("string")])],
            required: ["query"]
        ),
        ToolCallSchema(
            name: "web_search",
            description: "Search the web using Aliyun OpenSearch web search API and return compact search results. This tool returns titles, URLs, snippets, and source metadata. It does not fetch full page content.",
            parameters: [
                "query": .object(["type": .string("string")]),
                "top_k": .object(["type": .string("number")]),
                "query_rewrite": .object(["type": .string("boolean")]),
                "content_type": .object([
                    "type": .string("string"),
                    "enum": .array([.string("snippet"), .string("summary")])
                ])
            ],
            required: ["query"]
        ),
        ToolCallSchema(
            name: "web_fetch",
            description: "Fetch a specific web page URL through the configured Cloudflare Worker and return cleaned page text. Use this after web_search when the model needs full page content.",
            parameters: [
                "url": .object(["type": .string("string")]),
                "max_chars": .object(["type": .string("number")])
            ],
            required: ["url"]
        ),
        ToolCallSchema(
            name: "ask_question",
            description: "Ask the user a clarification question before taking action.",
            parameters: [
                "question": .object(["type": .string("string")]),
                "reason": .object(["type": .string("string")]),
                "options": .object(["type": .string("array")]),
                "blocking": .object(["type": .string("boolean")])
            ],
            required: ["question", "reason", "blocking"]
        ),
        ToolCallSchema(
            name: "propose_patch",
            description: "Submit a patch proposal for review instead of writing files directly.",
            parameters: [
                "title": .object(["type": .string("string")]),
                "reason": .object(["type": .string("string")]),
                "changes": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "path": .object(["type": .string("string")]),
                            "operation": .object([
                                "type": .string("string"),
                                "enum": .array([.string("modify"), .string("create"), .string("delete"), .string("rename")])
                            ]),
                            "diff": .object(["type": .string("string")]),
                            "newPath": .object(["type": .string("string")]),
                            "newContent": .object(["type": .string("string")])
                        ]),
                        "required": .array([.string("path"), .string("operation")])
                    ])
                ])
            ],
            required: ["title", "reason", "changes"]
        ),
        ToolCallSchema(
            name: "get_context_status",
            description: "Get prefix hash, repo snapshot hash, and cache status for the current workspace.",
            parameters: [:],
            required: []
        )
    ]
}

public enum ToolExecutionError: Error {
    case missingArgument(String)
    case unsupportedTool(String)
    case malformedPayload(String)
}

public struct WebToolConfiguration: Codable, Hashable, Sendable {
    public static let defaultAliyunOpenSearchHost = "https://default-77kc.platform-cn-shanghai.opensearch.aliyuncs.com"
    public static let defaultAliyunWorkspaceName = "default"
    public static let defaultAliyunServiceID = "ops-web-search-001"

    public var aliyunOpenSearchHost: String?
    public var aliyunOpenSearchAPIKey: String?
    public var aliyunWorkspaceName: String
    public var aliyunServiceID: String
    public var cloudflareFetchEndpoint: String?
    public var cloudflareFetchToken: String?

    public init(
        aliyunOpenSearchHost: String? = WebToolConfiguration.defaultAliyunOpenSearchHost,
        aliyunOpenSearchAPIKey: String? = nil,
        aliyunWorkspaceName: String = WebToolConfiguration.defaultAliyunWorkspaceName,
        aliyunServiceID: String = WebToolConfiguration.defaultAliyunServiceID,
        cloudflareFetchEndpoint: String? = nil,
        cloudflareFetchToken: String? = nil
    ) {
        self.aliyunOpenSearchHost = aliyunOpenSearchHost
        self.aliyunOpenSearchAPIKey = aliyunOpenSearchAPIKey
        self.aliyunWorkspaceName = aliyunWorkspaceName
        self.aliyunServiceID = aliyunServiceID
        self.cloudflareFetchEndpoint = cloudflareFetchEndpoint
        self.cloudflareFetchToken = cloudflareFetchToken
    }

    public static let defaultConfiguration = WebToolConfiguration()
}

public struct WebToolHTTPResponse: Sendable {
    public var statusCode: Int
    public var contentType: String?
    public var data: Data

    public init(statusCode: Int, contentType: String?, data: Data) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.data = data
    }
}

public protocol WebToolClient: Sendable {
    func postJSON(url: URL, headers: [String: String], body: [String: JSONValue]) async throws -> WebToolHTTPResponse
}

public struct URLSessionWebToolClient: WebToolClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func postJSON(url: URL, headers: [String: String], body: [String: JSONValue]) async throws -> WebToolHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body.mapValues(\.rawValue), options: [])
        let (data, response) = try await session.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        return WebToolHTTPResponse(
            statusCode: httpResponse?.statusCode ?? 0,
            contentType: httpResponse?.value(forHTTPHeaderField: "Content-Type"),
            data: data
        )
    }
}

public struct ToolExecutor: Sendable {
    public let workspaceFS: WorkspaceFS
    public let contextEngine: ContextEngine
    public let patchStore: PatchStore?
    public let webConfiguration: WebToolConfiguration
    public let webClient: any WebToolClient

    public init(
        workspaceFS: WorkspaceFS,
        contextEngine: ContextEngine,
        patchStore: PatchStore? = nil,
        webConfiguration: WebToolConfiguration = .defaultConfiguration,
        webClient: any WebToolClient = URLSessionWebToolClient()
    ) {
        self.workspaceFS = workspaceFS
        self.contextEngine = contextEngine
        self.patchStore = patchStore
        self.webConfiguration = webConfiguration
        self.webClient = webClient
    }

    public func execute(_ call: ToolCall, workspaceID: UUID? = nil, agentRunID: UUID? = nil, contextRequest: ContextBuildRequest? = nil) async throws -> ToolResult {
        switch call.name {
        case "list_files":
            let files = try workspaceFS.listFiles().map { entry in
                JSONValue.object([
                    "path": .string(entry.path),
                    "isDirectory": .bool(entry.isDirectory),
                    "size": .integer(Int(entry.size))
                ])
            }
            return ToolResult(name: call.name, payload: .array(files))

        case "read_file":
            let path = try stringArgument(named: "path", in: call.arguments)
            let file = try workspaceFS.readTextFile(path: path)
            return ToolResult(name: call.name, payload: .object([
                "path": .string(file.path),
                "content": .string(file.content),
                "hash": .string(file.hash)
            ]))

        case "search_in_files":
            let query = try stringArgument(named: "query", in: call.arguments)
            let matches = try workspaceFS.search(query: query).map { match in
                JSONValue.object([
                    "path": .string(match.path),
                    "lineNumber": .integer(match.lineNumber),
                    "line": .string(match.line)
                ])
            }
            return ToolResult(name: call.name, payload: .array(matches))

        case "web_search":
            return ToolResult(name: call.name, payload: await executeWebSearch(arguments: call.arguments))

        case "web_fetch":
            return ToolResult(name: call.name, payload: await executeWebFetch(arguments: call.arguments))

        case "ask_question":
            return ToolResult(name: call.name, payload: .object(call.arguments))

        case "propose_patch":
            let title = try stringArgument(named: "title", in: call.arguments)
            let reason = try stringArgument(named: "reason", in: call.arguments)
            let changes = try Self.decodePatchChanges(from: call.arguments["changes"])
            let impact = ToolImpactAnalyzer.estimate(call)
            let proposal = PatchProposal(
                workspaceID: workspaceID,
                agentRunID: agentRunID,
                title: title,
                changes: changes,
                reason: reason,
                status: .pendingReview,
                changedFiles: max(changes.count, impact.changedFiles),
                changedLines: impact.changedLines
            )
            try patchStore?.save(proposal)
            return ToolResult(name: call.name, payload: .object([
                "queued": .bool(true),
                "proposalId": .string(proposal.id.uuidString),
                "changeCount": .integer(proposal.changes.count),
                "changedFiles": .integer(proposal.changedFiles),
                "changedLines": .integer(proposal.changedLines)
            ]))

        case "get_context_status":
            guard let contextRequest else {
                throw ToolExecutionError.malformedPayload("Context request is required for context status.")
            }
            let snapshot = try contextEngine.buildContext(using: contextRequest, workspaceFS: workspaceFS)
            return ToolResult(name: call.name, payload: .object([
                "prefixHash": .string(snapshot.prefixHash),
                "repoSnapshotHash": .string(snapshot.repoSnapshotHash),
                "staticTokenCount": .integer(snapshot.staticTokenCount),
                "dynamicTokenCount": .integer(snapshot.dynamicTokenCount)
            ]))

        default:
            throw ToolExecutionError.unsupportedTool(call.name)
        }
    }

    private func stringArgument(named name: String, in arguments: [String: JSONValue]) throws -> String {
        guard case let .string(value)? = arguments[name] else {
            throw ToolExecutionError.missingArgument(name)
        }
        return value
    }

    private func optionalStringArgument(named name: String, in arguments: [String: JSONValue]) -> String? {
        guard case let .string(value)? = arguments[name] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func optionalIntArgument(named name: String, in arguments: [String: JSONValue], default defaultValue: Int, maximum: Int) -> Int {
        let value: Int?
        switch arguments[name] {
        case let .integer(number):
            value = number
        case let .number(number):
            value = Int(number)
        case let .string(text):
            value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            value = nil
        }
        return min(max(value ?? defaultValue, 1), maximum)
    }

    private func optionalBoolArgument(named name: String, in arguments: [String: JSONValue], default defaultValue: Bool) -> Bool {
        switch arguments[name] {
        case let .bool(value):
            return value
        case let .string(text):
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "yes", "1"].contains(normalized) { return true }
            if ["false", "no", "0"].contains(normalized) { return false }
            return defaultValue
        default:
            return defaultValue
        }
    }

    private func executeWebSearch(arguments: [String: JSONValue]) async -> JSONValue {
        guard let query = optionalStringArgument(named: "query", in: arguments) else {
            return webError(provider: "aliyun-opensearch", message: "query 不能为空。", status: 400)
        }
        guard let host = webConfiguration.aliyunOpenSearchHost, let apiKey = webConfiguration.aliyunOpenSearchAPIKey else {
            return webError(provider: "aliyun-opensearch", message: "阿里云 OpenSearch API Key 未配置。", status: 401)
        }
        guard let url = aliyunSearchURL(host: host) else {
            return webError(provider: "aliyun-opensearch", message: "阿里云 OpenSearch Host 不是有效 URL。", status: 400)
        }

        let topK = optionalIntArgument(named: "top_k", in: arguments, default: 5, maximum: 10)
        let queryRewrite = optionalBoolArgument(named: "query_rewrite", in: arguments, default: true)
        let requestedContentType = optionalStringArgument(named: "content_type", in: arguments) ?? "snippet"
        let contentType = ["snippet", "summary"].contains(requestedContentType) ? requestedContentType : "snippet"

        do {
            let response = try await webClient.postJSON(
                url: url,
                headers: ["Authorization": "Bearer \(apiKey)"],
                body: [
                    "query": .string(query),
                    "top_k": .integer(topK),
                    "query_rewrite": .bool(queryRewrite),
                    "content_type": .string(contentType)
                ]
            )
            guard (200 ..< 300).contains(response.statusCode) else {
                return webError(provider: "aliyun-opensearch", message: responseErrorMessage(from: response.data), status: response.statusCode)
            }
            return normalizeSearchResults(data: response.data, query: query, topK: topK)
        } catch {
            return webError(provider: "aliyun-opensearch", message: error.localizedDescription, status: 0)
        }
    }

    private func executeWebFetch(arguments: [String: JSONValue]) async -> JSONValue {
        guard let urlText = optionalStringArgument(named: "url", in: arguments) else {
            return webError(provider: "cloudflare-worker", message: "url 不能为空。", status: 400)
        }
        guard let endpoint = webConfiguration.cloudflareFetchEndpoint, let token = webConfiguration.cloudflareFetchToken else {
            return webError(provider: "cloudflare-worker", message: "Cloudflare Worker 地址或 Token 未配置。", status: 401)
        }
        guard let targetURL = validatedPublicHTTPURL(urlText) else {
            return webError(provider: "cloudflare-worker", message: "URL must be public http/https and must not target localhost or private IP ranges.", status: 400)
        }
        guard let endpointURL = URL(string: endpoint),
              let endpointScheme = endpointURL.scheme?.lowercased(),
              ["http", "https"].contains(endpointScheme) else {
            return webError(provider: "cloudflare-worker", message: "Cloudflare Worker 地址不是有效 http/https URL。", status: 400)
        }

        let maxChars = optionalIntArgument(named: "max_chars", in: arguments, default: 12_000, maximum: 30_000)
        do {
            let response = try await webClient.postJSON(
                url: endpointURL,
                headers: ["Authorization": "Bearer \(token)"],
                body: ["url": .string(targetURL.absoluteString)]
            )
            guard (200 ..< 300).contains(response.statusCode) else {
                return webError(provider: "cloudflare-worker", message: responseErrorMessage(from: response.data), status: response.statusCode)
            }
            return normalizeFetchResult(data: response.data, response: response, requestedURL: targetURL.absoluteString, maxChars: maxChars)
        } catch {
            return webError(provider: "cloudflare-worker", message: error.localizedDescription, status: 0)
        }
    }

    private func aliyunSearchURL(host: String) -> URL? {
        let trimmedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
        guard var components = URLComponents(string: trimmedHost) else { return nil }
        guard let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false else {
            return nil
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathParts = [
            basePath,
            "v3/openapi/workspaces",
            webConfiguration.aliyunWorkspaceName,
            "web-search",
            webConfiguration.aliyunServiceID
        ].filter { $0.isEmpty == false }
        components.path = "/" + pathParts.joined(separator: "/")
        return components.url
    }

    private func validatedPublicHTTPURL(_ text: String) -> URL? {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              host.isEmpty == false else {
            return nil
        }
        if host == "localhost" || host.hasSuffix(".localhost") { return nil }
        let ipv6Host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ipv6Host.contains(":"),
           ipv6Host == "::1" || ipv6Host.hasPrefix("fc") || ipv6Host.hasPrefix("fd") || ipv6Host.hasPrefix("fe80") {
            return nil
        }
        if let octets = ipv4Octets(from: host), isPrivateOrLocalIPv4(octets) { return nil }
        return components.url
    }

    private func ipv4Octets(from host: String) -> [Int]? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0 ... 255).contains($0) }) else { return nil }
        return octets
    }

    private func isPrivateOrLocalIPv4(_ octets: [Int]) -> Bool {
        guard octets.count == 4 else { return true }
        if octets[0] == 0 || octets[0] == 10 || octets[0] == 127 { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        if octets[0] == 172 && (16 ... 31).contains(octets[1]) { return true }
        if octets[0] == 169 && octets[1] == 254 { return true }
        return false
    }

    private func normalizeSearchResults(data: Data, query: String, topK: Int) -> JSONValue {
        let object = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        let rows = firstObjectArray(in: object, paths: [
            ["results"],
            ["items"],
            ["search_results"],
            ["web_search_result"],
            ["result", "results"],
            ["result", "items"],
            ["result", "search_results"],
            ["result", "search_result"],
            ["data", "results"],
            ["data", "items"],
            ["data", "search_results"],
            ["data", "webPages", "value"]
        ])
        let results = rows.prefix(topK).enumerated().map { index, row in
            JSONValue.object([
                "title": .string(firstString(in: row, keys: ["title", "name", "pageTitle", "displayTitle"]) ?? ""),
                "url": .string(firstString(in: row, keys: ["url", "link", "href", "sourceUrl", "pageUrl"]) ?? ""),
                "snippet": .string(firstString(in: row, keys: ["snippet", "summary", "content", "description", "abstract"]) ?? ""),
                "source": .string(firstString(in: row, keys: ["source", "site", "siteName", "hostname", "provider", "media"]) ?? ""),
                "publishedAt": .string(firstString(in: row, keys: ["publishedAt", "published_at", "date", "time", "published_time"]) ?? ""),
                "position": .integer(index + 1)
            ])
        }
        return .object([
            "query": .string(query),
            "provider": .string("aliyun-opensearch"),
            "results": .array(results)
        ])
    }

    private func normalizeFetchResult(data: Data, response: WebToolHTTPResponse, requestedURL: String, maxChars: Int) -> JSONValue {
        let object = try? JSONSerialization.jsonObject(with: data)
        let dictionary = object as? [String: Any]
        if let error = dictionary?["error"] as? Bool, error {
            return webError(
                provider: "cloudflare-worker",
                message: firstString(in: dictionary ?? [:], keys: ["message", "error", "detail"]) ?? "Worker returned an error.",
                status: firstInt(in: dictionary ?? [:], keys: ["status", "statusCode", "status_code"]) ?? response.statusCode
            )
        }

        let rawContent = dictionary.flatMap { firstString(in: $0, keys: ["content", "text", "body", "markdown", "cleanedText", "cleaned_text"]) }
            ?? String(data: data, encoding: .utf8)
            ?? ""
        let originalLength = rawContent.count
        let truncated = originalLength > maxChars
        let content = truncated ? String(rawContent.prefix(maxChars)) : rawContent
        let status = dictionary.flatMap { firstInt(in: $0, keys: ["status", "statusCode", "status_code"]) } ?? response.statusCode
        let contentType = dictionary.flatMap { firstString(in: $0, keys: ["contentType", "content_type", "mime"]) } ?? response.contentType ?? ""
        let finalURL = dictionary.flatMap { firstString(in: $0, keys: ["finalUrl", "final_url", "url"]) } ?? requestedURL
        let ok = dictionary.flatMap { firstBool(in: $0, keys: ["ok", "success"]) } ?? (200 ..< 300).contains(status)

        return .object([
            "url": .string(requestedURL),
            "finalUrl": .string(finalURL),
            "status": .integer(status),
            "ok": .bool(ok),
            "contentType": .string(contentType),
            "title": .string(dictionary.flatMap { firstString(in: $0, keys: ["title"]) } ?? ""),
            "content": .string(content),
            "truncated": .bool(truncated),
            "length": .integer(originalLength)
        ])
    }

    private func webError(provider: String, message: String, status: Int) -> JSONValue {
        .object([
            "error": .bool(true),
            "provider": .string(provider),
            "message": .string(message),
            "status": .integer(status)
        ])
    }

    private func responseErrorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = firstString(in: object, keys: ["message", "error", "errorMessage", "msg", "detail"]) {
            return message
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return String(text.prefix(500))
    }

    private func firstObjectArray(in object: Any, paths: [[String]]) -> [[String: Any]] {
        if let rows = object as? [[String: Any]] { return rows }
        for path in paths {
            if let rows = value(at: path, in: object) as? [[String: Any]] {
                return rows
            }
        }
        return []
    }

    private func value(at path: [String], in object: Any) -> Any? {
        var current: Any? = object
        for part in path {
            if let dictionary = current as? [String: Any] {
                current = dictionary[part]
            } else {
                return nil
            }
        }
        return current
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false { return trimmed }
            } else if let number = value as? NSNumber {
                return number.stringValue
            } else if let nested = value as? [String: Any],
                      let string = firstString(in: nested, keys: ["name", "title", "url", "host"]) {
                return string
            }
        }
        return nil
    }

    private func firstInt(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let int = object[key] as? Int { return int }
            if let number = object[key] as? NSNumber { return number.intValue }
            if let string = object[key] as? String, let int = Int(string) { return int }
        }
        return nil
    }

    private func firstBool(in object: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let bool = object[key] as? Bool { return bool }
            if let number = object[key] as? NSNumber { return number.boolValue }
            if let string = object[key] as? String {
                let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["true", "yes", "1"].contains(normalized) { return true }
                if ["false", "no", "0"].contains(normalized) { return false }
            }
        }
        return nil
    }

    public static func decodePatchChanges(from value: JSONValue?) throws -> [PatchChange] {
        guard case let .array(items)? = value else {
            throw ToolExecutionError.malformedPayload("changes must be an array")
        }

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        return try items.map { item in
            let data = try encoder.encode(item)
            return try decoder.decode(PatchChange.self, from: data)
        }
    }

}
