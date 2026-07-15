import Foundation

public enum TranscriptSource: String, Codable, CaseIterable, Equatable, Sendable {
    case microphone
    case systemAudio
    case mixed
    case unknown

    public var displayName: String {
        switch self {
        case .microphone:
            return "麥克風"
        case .systemAudio:
            return "系統音訊"
        case .mixed:
            return "混合來源"
        case .unknown:
            return "來源未知"
        }
    }

    public var shortLabel: String {
        switch self {
        case .microphone:
            return "MIC"
        case .systemAudio:
            return "SYS"
        case .mixed:
            return "MIX"
        case .unknown:
            return "UNK"
        }
    }
}

public struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var timestamp: Date
    public var relativeTime: TimeInterval
    public var source: TranscriptSource

    public init(
        id: UUID,
        text: String,
        timestamp: Date,
        relativeTime: TimeInterval,
        source: TranscriptSource
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.relativeTime = relativeTime
        self.source = source
    }

    public func markdownLine(timestampText: String) -> String {
        "[\(timestampText)] [\(source.shortLabel)] \(text)"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case timestamp
        case relativeTime
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        relativeTime = try container.decode(TimeInterval.self, forKey: .relativeTime)
        source = try container.decodeIfPresent(TranscriptSource.self, forKey: .source) ?? .unknown
    }
}
