import Foundation

struct LiveMeetingSummaryState: Codable, Equatable, Sendable {
    struct TopicSummary: Codable, Equatable, Sendable {
        var topic: String
        var conclusion: String
        var openItems: [String]

        enum CodingKeys: String, CodingKey {
            case topic
            case conclusion
            case openItems = "open_items"
        }
    }

    var topics: [TopicSummary]

    static let empty = LiveMeetingSummaryState(topics: [])

    var isEmpty: Bool {
        topics.isEmpty
    }

    func merged(with incoming: LiveMeetingSummaryState) -> LiveMeetingSummaryState {
        guard !topics.isEmpty else {
            return incoming
        }
        guard !incoming.topics.isEmpty else {
            return self
        }

        var mergedTopics = topics
        for incomingTopic in incoming.topics {
            let incomingName = incomingTopic.topic.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !incomingName.isEmpty else {
                continue
            }

            if let existingIndex = mergedTopics.firstIndex(where: { Self.normalizedTopic($0.topic) == Self.normalizedTopic(incomingName) }) {
                mergedTopics[existingIndex] = Self.mergedTopic(mergedTopics[existingIndex], with: incomingTopic)
            } else {
                mergedTopics.append(incomingTopic)
            }
        }

        return LiveMeetingSummaryState(topics: mergedTopics)
    }

    func markdown() -> String {
        """
        ## 議題主題

        \(Self.topicBullets(topics))

        ## 主題結論

        \(Self.conclusionBullets(topics))

        ## 主題未確認事項

        \(Self.openItemBullets(topics))
        """
    }

    private static func mergedTopic(_ existing: TopicSummary, with incoming: TopicSummary) -> TopicSummary {
        let incomingConclusion = incoming.conclusion.trimmingCharacters(in: .whitespacesAndNewlines)
        let conclusion = incomingConclusion.isEmpty ? existing.conclusion : incoming.conclusion
        let openItems = mergedOpenItems(existing.openItems, incoming.openItems)
        return TopicSummary(
            topic: existing.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? incoming.topic : existing.topic,
            conclusion: conclusion,
            openItems: openItems
        )
    }

    private static func mergedOpenItems(_ existing: [String], _ incoming: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in existing + incoming {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            let key = normalizedTopic(trimmed)
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    private static func normalizedTopic(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    private static func topicBullets(_ topics: [TopicSummary]) -> String {
        let topicNames = topics
            .map { $0.topic.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !topicNames.isEmpty else {
            return "- 尚無明確議題"
        }

        return topicNames.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func conclusionBullets(_ topics: [TopicSummary]) -> String {
        let lines = topics.compactMap { topic -> String? in
            let topicName = topic.topic.trimmingCharacters(in: .whitespacesAndNewlines)
            let conclusion = topic.conclusion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !topicName.isEmpty else {
                return nil
            }
            let compactConclusion = compactBulletText(
                conclusion,
                fallback: "尚無明確結論",
                characterLimit: 72
            )
            return "- \(topicName)：\(compactConclusion)"
        }

        guard !lines.isEmpty else {
            return "- 尚無明確結論"
        }

        return lines.joined(separator: "\n")
    }

    private static func openItemBullets(_ topics: [TopicSummary]) -> String {
        let lines = topics.flatMap { topic -> [String] in
            let topicName = topic.topic.trimmingCharacters(in: .whitespacesAndNewlines)
            let items = topic.openItems
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard !topicName.isEmpty else {
                return []
            }

        if items.isEmpty {
            return ["- \(topicName)：尚無"]
        }

        return items.map {
            "- \(topicName)：\(compactBulletText($0, fallback: "尚無", characterLimit: 72))"
        }
    }

    guard !lines.isEmpty else {
        return "- 尚無"
    }

    return lines.joined(separator: "\n")
    }

    private static func compactBulletText(
        _ value: String,
        fallback: String,
        characterLimit: Int
    ) -> String {
        let compact = value
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else {
            return fallback
        }
        guard compact.count > characterLimit else {
            return compact
        }
        let endIndex = compact.index(compact.startIndex, offsetBy: characterLimit)
        return String(compact[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

final class DeepSeekMeetingSummarizer: @unchecked Sendable {
    struct Configuration: Sendable {
        var baseURL: URL
        var apiKey: String
        var model: String
    }

    private let configuration: Configuration
    private(set) var lastDiagnostics: DeepSeekMeetingDiagnostics?
    private static let requestTimeoutSeconds: TimeInterval = 45
    private static let liveSummaryMaxTokens = 1_600
    private static let finalSummaryMaxTokens = 2_800
    private static let maxRequestAttempts = 3

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func summarize(
        newTranscript: String,
        recentTranscript: String,
        currentState: LiveMeetingSummaryState,
        isFinal: Bool
    ) async throws -> LiveMeetingSummaryState {
        let currentStateData = try JSONEncoder().encode(currentState)
        let currentStateJSON = String(data: currentStateData, encoding: .utf8) ?? #"{"topics":[]}"#
        let modeInstruction = isFinal
            ? "這是停止錄音後的最後梳理。請重新壓縮目前 JSON 狀態，新增逐字稿只代表尚未吸收的尾段，不要把最近上下文重複寫成新議題。"
            : "這是錄音中的分段增量更新。請只吸收新增逐字稿中的新資訊，保留既有重點，不要重複議題。"

        let userContent = """
        目前會議狀態 JSON：
        \(currentStateJSON)

        \(modeInstruction)

        新增逐字稿：
        \(newTranscript)

        最近上下文：
        \(recentTranscript)
        """

        let requestBody = DeepSeekChatRequest(
            model: configuration.model,
            messages: [
                .init(role: "system", content: Self.systemPrompt),
                .init(role: "user", content: userContent)
            ],
            responseFormat: .init(type: "json_object"),
            thinking: .init(type: "disabled"),
            temperature: 0.1,
            maxTokens: isFinal ? Self.finalSummaryMaxTokens : Self.liveSummaryMaxTokens,
            stream: false
        )

        return try await performSummaryRequest(requestBody)
    }

    private func performSummaryRequest(_ requestBody: DeepSeekChatRequest) async throws -> LiveMeetingSummaryState {
        var lastError: Error?
        var requestBody = requestBody

        for attempt in 1...Self.maxRequestAttempts {
            do {
                return try await performSingleSummaryRequest(requestBody)
            } catch {
                lastError = error

                guard attempt < Self.maxRequestAttempts, Self.shouldRetry(error) else {
                    throw error
                }

                if case DeepSeekMeetingError.truncatedResponse = error {
                    requestBody.maxTokens = min(requestBody.maxTokens * 2, 4_096)
                }

                let delay = UInt64(attempt * attempt) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }

        throw lastError ?? DeepSeekMeetingError.emptyResponse(finishReason: nil, reasoningContent: nil)
    }

    private func performSingleSummaryRequest(_ requestBody: DeepSeekChatRequest) async throws -> LiveMeetingSummaryState {
        var request = URLRequest(url: Self.chatCompletionsURL(from: configuration.baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepSeekMeetingError.invalidResponse("DeepSeek 沒有回傳 HTTP 狀態。")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DeepSeekMeetingError.httpStatus(httpResponse.statusCode, Self.errorMessage(from: data))
        }

        lastDiagnostics = try? DeepSeekMeetingResponseParser.diagnostics(from: data)
        return try DeepSeekMeetingResponseParser.parseState(from: data)
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        switch error {
        case DeepSeekMeetingError.emptyResponse,
             DeepSeekMeetingError.truncatedResponse,
             DeepSeekMeetingError.invalidResponse:
            return true
        case DeepSeekMeetingError.httpStatus(let status, _):
            return [408, 409, 429, 500, 502, 503, 504].contains(status)
        default:
            return false
        }
    }

    private static let systemPrompt = """
    你是即時會議重點整理器。請只整理三種資訊：
    1. 議題主題
    2. 主題結論
    3. 主題未確認事項

    輸出要非常精簡，像會議旁聽筆記，不要寫摘要作文：
    - topic：短名詞，最多 16 個中文字。
    - conclusion：一個短句或用頓號分隔的短列點，最多 40 個中文字。
    - open_items：每項最多 30 個中文字。
    - 只記決議、狀態、待辦、風險、卡點；不要補背景，不要解釋脈絡。
    - 沒有明確結論時，conclusion 留空字串，不要硬湊。

    請合併目前 JSON 狀態與新增逐字稿，不要重複議題，不要捏造逐字稿沒有說的內容。
    如果目前 JSON 狀態已經有 topics，即使新增逐字稿沒有新的明確資訊，也必須保留既有 topics，不可回覆空陣列。
回覆必須是 JSON，格式如下：
{"topics":[{"topic":"...","conclusion":"...","open_items":["..."]}]}
只有在目前 JSON 狀態與新增逐字稿都尚無資訊時，才回覆 {"topics":[]}
"""

    private static func decodeMeetingState(from content: String) throws -> LiveMeetingSummaryState {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let state = try? JSONDecoder().decode(LiveMeetingSummaryState.self, from: data) {
            return state
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end else {
            throw DeepSeekMeetingError.invalidResponse(content)
        }

        let jsonSlice = String(trimmed[start...end])
        guard let data = jsonSlice.data(using: .utf8) else {
            throw DeepSeekMeetingError.invalidResponse(content)
        }

        return try JSONDecoder().decode(LiveMeetingSummaryState.self, from: data)
    }

    private static func chatCompletionsURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        let normalizedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.hasSuffix("chat/completions") {
            return url
        }

        if components.path.isEmpty || components.path == "/" {
            components.path = "/chat/completions"
        } else {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = "/" + components.path + "/chat/completions"
        }

        return components.url ?? url
    }

    private static func errorMessage(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(DeepSeekErrorResponse.self, from: data) {
            return decoded.error.message
        }

        return String(data: data.prefix(600), encoding: .utf8) ?? "無法讀取錯誤內容。"
    }
}

private struct DeepSeekChatRequest: Encodable {
    struct Message: Encodable {
        var role: String
        var content: String
    }

    struct ResponseFormat: Encodable {
        var type: String
    }

    struct Thinking: Encodable {
        var type: String
    }

    var model: String
    var messages: [Message]
    var responseFormat: ResponseFormat
    var thinking: Thinking?
    var temperature: Double
    var maxTokens: Int
    var stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
        case thinking
        case temperature
        case maxTokens = "max_tokens"
        case stream
    }
}

private struct DeepSeekChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var content: String?
            var reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
            }
        }

        var finishReason: String?
        var message: Message

        enum CodingKeys: String, CodingKey {
            case finishReason = "finish_reason"
            case message
        }
    }

    var choices: [Choice]
    var usage: Usage?

    struct Usage: Decodable {
        var promptCacheHitTokens: Int?
        var promptCacheMissTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptCacheHitTokens = "prompt_cache_hit_tokens"
            case promptCacheMissTokens = "prompt_cache_miss_tokens"
        }
    }
}

struct DeepSeekMeetingDiagnostics: Equatable, Sendable {
    var finishReason: String?
    var promptCacheHitTokens: Int
    var promptCacheMissTokens: Int

    var cacheHitRate: Double {
        let total = promptCacheHitTokens + promptCacheMissTokens
        guard total > 0 else {
            return 0
        }

        return Double(promptCacheHitTokens) / Double(total)
    }
}

enum DeepSeekMeetingResponseParser {
    static func parseState(from data: Data) throws -> LiveMeetingSummaryState {
        let decoded = try JSONDecoder().decode(DeepSeekChatResponse.self, from: data)
        guard let firstChoice = decoded.choices.first else {
            throw DeepSeekMeetingError.emptyResponse(finishReason: nil, reasoningContent: nil)
        }

        if firstChoice.finishReason == "length" {
            throw DeepSeekMeetingError.truncatedResponse
        }

        guard let content = firstChoice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw DeepSeekMeetingError.emptyResponse(
                finishReason: firstChoice.finishReason,
                reasoningContent: firstChoice.message.reasoningContent
            )
        }

        return try decodeMeetingState(from: content)
    }

    static func diagnostics(from data: Data) throws -> DeepSeekMeetingDiagnostics {
        let decoded = try JSONDecoder().decode(DeepSeekChatResponse.self, from: data)
        let firstChoice = decoded.choices.first

        return DeepSeekMeetingDiagnostics(
            finishReason: firstChoice?.finishReason,
            promptCacheHitTokens: decoded.usage?.promptCacheHitTokens ?? 0,
            promptCacheMissTokens: decoded.usage?.promptCacheMissTokens ?? 0
        )
    }

    private static func decodeMeetingState(from content: String) throws -> LiveMeetingSummaryState {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let state = try? JSONDecoder().decode(LiveMeetingSummaryState.self, from: data) {
            return state
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end else {
            throw DeepSeekMeetingError.invalidResponse(content)
        }

        let jsonSlice = String(trimmed[start...end])
        guard let data = jsonSlice.data(using: .utf8) else {
            throw DeepSeekMeetingError.invalidResponse(content)
        }

        do {
            return try JSONDecoder().decode(LiveMeetingSummaryState.self, from: data)
        } catch {
            throw DeepSeekMeetingError.invalidResponse(content)
        }
    }
}

private struct DeepSeekErrorResponse: Decodable {
    struct APIError: Decodable {
        var message: String
    }

    var error: APIError
}

enum DeepSeekMeetingError: LocalizedError {
    case missingAPIKey
    case emptyResponse(finishReason: String?, reasoningContent: String?)
    case truncatedResponse
    case invalidResponse(String)
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "找不到 DeepSeek API key，會議重點可改用 Gemma 備援。"
        case .emptyResponse(let finishReason, let reasoningContent):
            let suffix = finishReason.map { "（finish_reason=\($0)）" } ?? ""
            if let reasoningContent,
               !reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "DeepSeek 回傳了思考內容但沒有最終整理\(suffix)。已切換為非思考模式，請再手動更新一次重點。"
            }
            return "DeepSeek 沒有回傳可用內容\(suffix)。"
        case .truncatedResponse:
            return "DeepSeek 回傳被 max_tokens 截斷，已自動加大輸出上限並重試。"
        case .invalidResponse(let message):
            return "DeepSeek 回傳格式無法解析：\(message)"
        case .httpStatus(let status, let message):
            return "DeepSeek HTTP \(status)：\(message)"
        }
    }
}
