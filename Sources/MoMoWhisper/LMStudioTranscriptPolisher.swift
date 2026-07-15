import Foundation

final class LMStudioTranscriptPolisher: @unchecked Sendable {
    struct Configuration: Sendable {
        let baseURL: URL
        let apiToken: String
        let model: String
    }

    private let configuration: Configuration
    private static let requestTimeoutSeconds: TimeInterval = 45
    private static let inputLimit = 18_000

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func summarizeMeeting(_ transcript: String) async throws -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        let input = trimmed.count > Self.inputLimit ? String(trimmed.suffix(Self.inputLimit)) : trimmed
        if configuration.baseURL.path.contains("chat/completions") {
            return try await summarizeWithOpenAICompatibleRequest(input)
        }

        return try await summarizeWithPublicChatRequest(input)
    }

    private func summarizeWithPublicChatRequest(_ input: String) async throws -> String {
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
        guard let content = decoded.bestContent?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw LMStudioPolishError.emptyResponse
        }

        return content
    }

    private func summarizeWithOpenAICompatibleRequest(_ input: String) async throws -> String {
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
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw LMStudioPolishError.emptyResponse
        }

        return content
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
    請把會議逐字稿整理成繁體中文，且只保留三個區塊：
    ## 議題主題
    ## 主題結論
    ## 主題未確認事項
    不要加入逐字稿沒有出現的資訊。
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
    struct OutputItem: Decodable {
        let type: String?
        let content: String?
    }

    let output: [OutputItem]?
    let content: String?

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
    }

    var choices: [Choice]
}

enum LMStudioPolishError: LocalizedError {
    case invalidConfiguration(String)
    case invalidResponse(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .invalidResponse(let message):
            return "LM Studio 回傳格式無法解析：\(message)"
        case .emptyResponse:
            return "LM Studio 沒有回傳可用內容。"
        }
    }
}
