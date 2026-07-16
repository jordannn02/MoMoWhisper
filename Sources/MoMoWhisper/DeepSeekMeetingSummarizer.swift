import Foundation
import MoMoWhisperSummaryCore

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

extension LiveMeetingSummaryState {
    var legacySummaryState: LegacyMeetingSummaryState {
        LegacyMeetingSummaryState(
            topics: topics.map {
                .init(topic: $0.topic, conclusion: $0.conclusion, openItems: $0.openItems)
            }
        )
    }
}

final class DeepSeekMeetingSummarizer: @unchecked Sendable {
    struct Configuration: Sendable {
        var baseURL: URL
        var apiKey: String
        var model: String
    }

    private let configuration: Configuration
    private let session: URLSession
    private(set) var lastDiagnostics: DeepSeekMeetingDiagnostics?
    private static let requestTimeoutSeconds: TimeInterval = 45
    private static let liveSummaryMaxTokens = 1_600
    private static let finalSummaryMaxTokens = 2_800
    private static let maxRequestAttempts = 3

    init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func summarize(
        newTranscript: String,
        recentTranscript: String,
        currentCatalog: String,
        isFinal: Bool
    ) async throws -> MeetingSummaryDelta {
        let modeInstruction = isFinal
            ? "這是停止錄音後的最後梳理。可用 resolve_item 或 supersede_item 收斂既有項目；不要重送未變更的項目。"
            : "這是錄音中的分段增量更新。只輸出新增或需要更新的操作；不要重送完整摘要。"

        let userContent = """
        目前摘要索引（僅供去重與最後收斂，不可原樣回傳）：
        \(currentCatalog)

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

    private func performSummaryRequest(_ requestBody: DeepSeekChatRequest) async throws -> MeetingSummaryDelta {
        var lastError: Error?
        var requestBody = requestBody

        for attempt in 1...Self.maxRequestAttempts {
            try Task.checkCancellation()

            do {
                return try await performSingleSummaryRequest(requestBody)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error

                guard attempt < Self.maxRequestAttempts, Self.shouldRetry(error) else {
                    throw error
                }

                if case DeepSeekMeetingError.truncatedResponse = error {
                    requestBody.maxTokens = min(requestBody.maxTokens * 2, 4_096)
                }

                let delay = UInt64(attempt * attempt) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
            }
        }

        throw lastError ?? DeepSeekMeetingError.emptyResponse(finishReason: nil, reasoningContent: nil)
    }

    private func performSingleSummaryRequest(_ requestBody: DeepSeekChatRequest) async throws -> MeetingSummaryDelta {
        var request = URLRequest(url: Self.chatCompletionsURL(from: configuration.baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepSeekMeetingError.invalidResponse("DeepSeek 沒有回傳 HTTP 狀態。")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DeepSeekMeetingError.httpStatus(httpResponse.statusCode, Self.errorMessage(from: data))
        }

        lastDiagnostics = try? DeepSeekMeetingResponseParser.diagnostics(from: data)
        return try DeepSeekMeetingResponseParser.parseDelta(from: data)
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
    你是即時會議重點的增量整理器。應用程式本機是摘要狀態的唯一擁有者；你只能回傳 delta operations，絕對不要回傳或覆誦完整摘要狀態。

    規則：
    - topic 標題最多 16 個中文字；item 每項一個原子資訊，最多 48 個中文字。
    - item kind 只能是 decision、requirement、action、open_question、risk、fact、note。
    - status 只能是 confirmed、proposed、open、resolved、superseded、unknown。
    - 沒有逐字稿證據時不得新增；不得推測負責人、期限或確認狀態。
    - 未明確確認的內容用 proposed 或 unknown；問題與待辦通常用 open。
    - 即時更新只新增或更新真正改變的項目；無新增資訊時 operations 回空陣列。
    - 最後梳理可使用 resolve_item；若新項目取代舊項目，使用 supersede_item 並提供 replacement。
    - id 必須簡短、穩定且在目前回應中唯一。重用摘要索引內既有項目時必須沿用其 id。

    僅回傳 JSON：
    {"delta_id":"batch-唯一值","operations":[
      {"op":"set_headline","headline":"一句話摘要"},
      {"op":"upsert_topic","id":"topic-id","title":"主題","aliases":[],"order":0},
      {"op":"upsert_item","id":"item-id","topic_id":"topic-id","kind":"decision","status":"confirmed","text":"原子重點","owner":null,"due_date":null,"order":0},
      {"op":"resolve_item","id":"既有-item-id"},
      {"op":"supersede_item","id":"既有-item-id","replacement":{"id":"新-item-id","topic_id":"topic-id","kind":"decision","status":"confirmed","text":"取代內容","owner":null,"due_date":null,"order":0}}
    ]}
    不可輸出 Markdown、程式碼圍欄、目前摘要全文或 processing 數字。
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
        var promptTokens: Int?
        var completionTokens: Int?
        var totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptCacheHitTokens = "prompt_cache_hit_tokens"
            case promptCacheMissTokens = "prompt_cache_miss_tokens"
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

struct DeepSeekMeetingDiagnostics: Equatable, Sendable {
    var finishReason: String?
    var promptCacheHitTokens: Int
    var promptCacheMissTokens: Int
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int

    var cacheHitRate: Double {
        let total = promptCacheHitTokens + promptCacheMissTokens
        guard total > 0 else {
            return 0
        }

        return Double(promptCacheHitTokens) / Double(total)
    }
}

enum DeepSeekMeetingResponseParser {
    static func parseDeltaContent(_ content: String) throws -> MeetingSummaryDelta {
        try decodeMeetingDelta(from: content)
    }

    static func parseDelta(from data: Data) throws -> MeetingSummaryDelta {
        let decoded = try JSONDecoder().decode(DeepSeekChatResponse.self, from: data)
        let content = try responseContent(from: decoded)
        return try decodeMeetingDelta(from: content)
    }

    static func parseState(from data: Data) throws -> LiveMeetingSummaryState {
        let decoded = try JSONDecoder().decode(DeepSeekChatResponse.self, from: data)
        let content = try responseContent(from: decoded)
        return try decodeMeetingState(from: content)
    }

    static func diagnostics(from data: Data) throws -> DeepSeekMeetingDiagnostics {
        let decoded = try JSONDecoder().decode(DeepSeekChatResponse.self, from: data)
        let firstChoice = decoded.choices.first

        return DeepSeekMeetingDiagnostics(
            finishReason: firstChoice?.finishReason,
            promptCacheHitTokens: decoded.usage?.promptCacheHitTokens ?? 0,
            promptCacheMissTokens: decoded.usage?.promptCacheMissTokens ?? 0,
            promptTokens: decoded.usage?.promptTokens ?? 0,
            completionTokens: decoded.usage?.completionTokens ?? 0,
            totalTokens: decoded.usage?.totalTokens ?? 0
        )
    }

    private static func responseContent(from response: DeepSeekChatResponse) throws -> String {
        guard let firstChoice = response.choices.first else {
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
        return content
    }

    private static func decodeMeetingDelta(from content: String) throws -> MeetingSummaryDelta {
        guard content.utf8.count <= 1_000_000 else {
            throw DeepSeekMeetingError.invalidResponse("delta JSON 超過 1 MB 安全上限。")
        }
        let data = try extractedJSONObjectData(from: content)
        do {
            let wire = try JSONDecoder().decode(MeetingSummaryDeltaWire.self, from: data)
            let deltaID = wire.deltaID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !deltaID.isEmpty else {
                throw DeepSeekMeetingError.invalidResponse("delta_id 不可空白。")
            }
            return MeetingSummaryDelta(
                id: deltaID,
                operations: try wire.operations.map(makeOperation)
            )
        } catch let error as DeepSeekMeetingError {
            throw error
        } catch {
            throw DeepSeekMeetingError.invalidResponse("delta JSON schema 不符：\(error.localizedDescription)")
        }
    }

    private static func makeOperation(_ wire: MeetingSummaryDeltaWire.Operation) throws -> MeetingSummaryDeltaOperation {
        switch wire.op {
        case "set_headline":
            return .setHeadline(try required(wire.headline, field: "headline"))
        case "upsert_topic":
            return .upsertTopic(try makeTopic(wire))
        case "upsert_item":
            return .upsertItem(try makeItem(wire))
        case "resolve_item":
            return .resolveItem(id: try required(wire.id, field: "id"), source: .ai)
        case "supersede_item":
            guard let replacement = wire.replacement else {
                throw DeepSeekMeetingError.invalidResponse("supersede_item 缺少 replacement。")
            }
            return .supersedeItem(
                id: try required(wire.id, field: "id"),
                replacement: try makeItem(replacement),
                source: .ai
            )
        default:
            throw DeepSeekMeetingError.invalidResponse("不支援的 delta op：\(wire.op)")
        }
    }

    private static func makeTopic(_ wire: MeetingSummaryDeltaWire.Operation) throws -> MeetingSummaryTopic {
        MeetingSummaryTopic(
            id: try required(wire.id, field: "id"),
            title: try required(wire.title, field: "title"),
            aliases: wire.aliases ?? [],
            order: max(0, wire.order ?? 0)
        )
    }

    private static func makeItem(_ wire: MeetingSummaryDeltaWire.Operation) throws -> MeetingSummaryItem {
        MeetingSummaryItem(
            id: try required(wire.id, field: "id"),
            topicID: try required(wire.topicID, field: "topic_id"),
            kind: try itemKind(wire.kind),
            status: try itemStatus(wire.status),
            text: try required(wire.text, field: "text"),
            owner: wire.owner,
            dueDate: wire.dueDate,
            source: .ai,
            order: max(0, wire.order ?? 0)
        )
    }

    private static func makeItem(_ wire: MeetingSummaryDeltaWire.Item) throws -> MeetingSummaryItem {
        MeetingSummaryItem(
            id: try required(wire.id, field: "replacement.id"),
            topicID: try required(wire.topicID, field: "replacement.topic_id"),
            kind: try itemKind(wire.kind),
            status: try itemStatus(wire.status),
            text: try required(wire.text, field: "replacement.text"),
            owner: wire.owner,
            dueDate: wire.dueDate,
            source: .ai,
            order: max(0, wire.order ?? 0)
        )
    }

    private static func itemKind(_ value: String?) throws -> MeetingSummaryItem.Kind {
        switch value {
        case "decision": return .decision
        case "requirement": return .requirement
        case "action": return .action
        case "open_question": return .openQuestion
        case "risk": return .risk
        case "fact": return .fact
        case "note": return .note
        default: throw DeepSeekMeetingError.invalidResponse("不支援的 item kind：\(value ?? "nil")")
        }
    }

    private static func itemStatus(_ value: String?) throws -> MeetingSummaryItem.Status {
        switch value {
        case "confirmed": return .confirmed
        case "proposed": return .proposed
        case "open": return .open
        case "resolved": return .resolved
        case "superseded": return .superseded
        case "unknown": return .unknown
        default: throw DeepSeekMeetingError.invalidResponse("不支援的 item status：\(value ?? "nil")")
        }
    }

    private static func required(_ value: String?, field: String) throws -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            throw DeepSeekMeetingError.invalidResponse("delta 欄位 \(field) 不可空白。")
        }
        return trimmed
    }

    private static func extractedJSONObjectData(from content: String) throws -> Data {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end,
              let data = String(trimmed[start...end]).data(using: .utf8) else {
            throw DeepSeekMeetingError.invalidResponse("找不到 delta JSON object。")
        }
        return data
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

private struct MeetingSummaryDeltaWire: Decodable {
    struct Item: Decodable {
        var id: String?
        var topicID: String?
        var kind: String?
        var status: String?
        var text: String?
        var owner: String?
        var dueDate: String?
        var order: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case topicID = "topic_id"
            case kind
            case status
            case text
            case owner
            case dueDate = "due_date"
            case order
        }
    }

    struct Operation: Decodable {
        var op: String
        var id: String?
        var headline: String?
        var title: String?
        var aliases: [String]?
        var topicID: String?
        var kind: String?
        var status: String?
        var text: String?
        var owner: String?
        var dueDate: String?
        var order: Int?
        var replacement: Item?

        enum CodingKeys: String, CodingKey {
            case op
            case id
            case headline
            case title
            case aliases
            case topicID = "topic_id"
            case kind
            case status
            case text
            case owner
            case dueDate = "due_date"
            case order
            case replacement
        }
    }

    var deltaID: String
    var operations: [Operation]

    enum CodingKeys: String, CodingKey {
        case deltaID = "delta_id"
        case operations
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
