import Foundation
import MoMoWhisperSummaryCore

final class LMStudioTranscriptPolisher: @unchecked Sendable {
    struct Configuration: Sendable {
        let baseURL: URL
        let apiToken: String
        let model: String
    }

    private let configuration: Configuration
    private(set) var lastDiagnostics: LMStudioSummaryDiagnostics?
    private static let requestTimeoutSeconds: TimeInterval = 45
    private static let inputLimit = 18_000

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func summarizeMeeting(
        _ transcript: String,
        currentCatalog: String,
        isFinal: Bool
    ) async throws -> MeetingSummaryDelta {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MeetingSummaryDelta(id: "lmstudio-empty", operations: [])
        }

        let input = trimmed.count > Self.inputLimit ? String(trimmed.suffix(Self.inputLimit)) : trimmed
        let requestInput = """
        目前摘要索引（只供去重，不可回傳完整狀態）：
        \(currentCatalog)

        模式：\(isFinal ? "最後梳理；可 resolve/supersede" : "即時增量；只新增真正的新資訊")

        新增逐字稿：
        \(input)
        """
        if configuration.baseURL.path.contains("chat/completions") {
            return try await summarizeWithOpenAICompatibleRequest(requestInput)
        }

        return try await summarizeWithPublicChatRequest(requestInput)
    }

    private func summarizeWithPublicChatRequest(_ input: String) async throws -> MeetingSummaryDelta {
        let requestBody = LMStudioPublicChatRequest(
            model: configuration.model,
            systemPrompt: Self.summaryPrompt,
            input: input,
            temperature: 0.1,
            maxOutputTokens: 1_500,
            reasoning: "off",
            store: false
        )

        let data = try await sendJSONRequest(requestBody)
        let decoded = try JSONDecoder().decode(LMStudioPublicChatResponse.self, from: data)
        if decoded.finishReason == "length" {
            throw LMStudioPolishError.truncatedResponse
        }
        guard let content = decoded.bestContent?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw LMStudioPolishError.emptyResponse
        }

        let delta = try DeepSeekMeetingResponseParser.parseDeltaContent(content)
        lastDiagnostics = LMStudioSummaryDiagnostics(
            finishReason: decoded.finishReason,
            inputTokens: decoded.usage?.inputTokens ?? 0,
            outputTokens: decoded.usage?.outputTokens ?? 0,
            operationCount: delta.operations.count
        )
        return delta
    }

    private func summarizeWithOpenAICompatibleRequest(_ input: String) async throws -> MeetingSummaryDelta {
        let requestBody = LMStudioChatRequest(
            model: configuration.model,
            messages: [
                .init(role: "system", content: Self.summaryPrompt),
                .init(role: "user", content: input)
            ],
            temperature: 0.1,
            maxTokens: 1_500,
            stream: false
        )

        let data = try await sendJSONRequest(requestBody)
        let decoded = try JSONDecoder().decode(LMStudioChatResponse.self, from: data)
        guard let firstChoice = decoded.choices.first else {
            throw LMStudioPolishError.emptyResponse
        }
        if firstChoice.finishReason == "length" {
            throw LMStudioPolishError.truncatedResponse
        }
        let content = firstChoice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw LMStudioPolishError.emptyResponse
        }

        let delta = try DeepSeekMeetingResponseParser.parseDeltaContent(content)
        lastDiagnostics = LMStudioSummaryDiagnostics(
            finishReason: firstChoice.finishReason,
            inputTokens: decoded.usage?.promptTokens ?? 0,
            outputTokens: decoded.usage?.completionTokens ?? 0,
            operationCount: delta.operations.count
        )
        return delta
    }

    private func sendJSONRequest<T: Encodable>(_ body: T) async throws -> Data {
        var request = URLRequest(url: configuration.baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw LMStudioPolishError.invalidResponse(Self.responsePreview(from: data))
        }

        return data
    }

    private static let summaryPrompt = """
    你是會議重點增量整理器。本機 reducer 是狀態唯一擁有者；只回傳 delta，不可回傳完整摘要或 Markdown。
    topic 最多 16 個中文字；每個 item 是一項原子資訊，最多 48 個中文字。不得捏造負責人、期限或確認狀態。
    kind 只能是 decision、requirement、action、open_question、risk、fact、note。
    status 只能是 confirmed、proposed、open、resolved、superseded、unknown。
    回傳：{"delta_id":"唯一值","operations":[{"op":"upsert_topic","id":"topic-id","title":"主題"},{"op":"upsert_item","id":"item-id","topic_id":"topic-id","kind":"note","status":"unknown","text":"重點"}]}
    最後梳理才可依摘要索引使用 resolve_item 或 supersede_item；無新增資訊時 operations 為空陣列。
    """

    private static func responsePreview(from data: Data) -> String {
        String(data: data.prefix(600), encoding: .utf8) ?? "無法讀取回應。"
    }
}

private struct LMStudioPublicChatRequest: Encodable {
    let model: String
    let systemPrompt: String
    let input: String
    let temperature: Double
    let maxOutputTokens: Int
    let reasoning: String
    let store: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case systemPrompt = "system_prompt"
        case input
        case temperature
        case maxOutputTokens = "max_output_tokens"
        case reasoning
        case store
    }
}

private struct LMStudioPublicChatResponse: Decodable {
    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    struct OutputItem: Decodable {
        let type: String?
        let content: String?
    }

    let output: [OutputItem]?
    let content: String?
    let finishReason: String?
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case output
        case content
        case finishReason = "finish_reason"
        case usage
    }

    var bestContent: String? {
        output?.compactMap(\.content).first(where: { !$0.isEmpty }) ?? content
    }
}

private struct LMStudioChatRequest: Encodable {
    struct Message: Encodable {
        var role: String
        var content: String
    }

    var model: String
    var messages: [Message]
    var temperature: Double
    var maxTokens: Int
    var stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case stream
    }
}

private struct LMStudioChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var content: String
        }

        var message: Message
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    var choices: [Choice]
    var usage: Usage?

    struct Usage: Decodable {
        var promptTokens: Int?
        var completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
}

struct LMStudioSummaryDiagnostics: Equatable, Sendable {
    var finishReason: String?
    var inputTokens: Int
    var outputTokens: Int
    var operationCount: Int
}

enum LMStudioPolishError: LocalizedError {
    case invalidConfiguration(String)
    case invalidResponse(String)
    case emptyResponse
    case truncatedResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .invalidResponse(let message):
            return "LM Studio 回傳格式無法解析：\(message)"
        case .emptyResponse:
            return "LM Studio 沒有回傳可用內容。"
        case .truncatedResponse:
            return "LM Studio delta 回覆遭輸出上限截斷。"
        }
    }
}
