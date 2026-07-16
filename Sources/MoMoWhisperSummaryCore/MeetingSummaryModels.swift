import Foundation

public enum MeetingSummaryItemKind: String, Codable, CaseIterable, Sendable {
    case decision
    case requirement
    case action
    case openQuestion
    case risk
    case fact
    case note
}

public enum MeetingSummaryItemStatus: String, Codable, CaseIterable, Sendable {
    case confirmed
    case proposed
    case open
    case resolved
    case superseded
    case unknown
}

public enum MeetingSummarySource: String, Codable, CaseIterable, Sendable {
    case ai
    case localFallback
    case manual
    case legacy
}

public struct MeetingSummaryEvidence: Codable, Equatable, Sendable {
    public var segmentID: String?
    public var startOffset: Int?
    public var endOffset: Int?
    public var excerpt: String?

    public init(
        segmentID: String? = nil,
        startOffset: Int? = nil,
        endOffset: Int? = nil,
        excerpt: String? = nil
    ) {
        self.segmentID = segmentID
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.excerpt = excerpt
    }
}

public struct MeetingSummaryTopic: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var aliases: [String]
    public var order: Int

    public init(
        id: String,
        title: String,
        aliases: [String] = [],
        order: Int = 0
    ) {
        self.id = id
        self.title = title
        self.aliases = aliases
        self.order = order
    }
}

public struct MeetingSummaryItem: Codable, Equatable, Identifiable, Sendable {
    public typealias Kind = MeetingSummaryItemKind
    public typealias Status = MeetingSummaryItemStatus
    public typealias Source = MeetingSummarySource

    public var id: String
    public var topicID: String
    public var kind: Kind
    public var status: Status
    public var text: String
    public var owner: String?
    public var dueDate: String?
    public var source: Source
    public var lockedByUser: Bool
    public var order: Int
    public var evidence: [MeetingSummaryEvidence]
    public var fallbackScopeID: String?
    public var supersededByItemID: String?

    public init(
        id: String,
        topicID: String,
        kind: Kind,
        status: Status,
        text: String,
        owner: String? = nil,
        dueDate: String? = nil,
        source: Source,
        lockedByUser: Bool = false,
        order: Int = 0,
        evidence: [MeetingSummaryEvidence] = [],
        fallbackScopeID: String? = nil,
        supersededByItemID: String? = nil
    ) {
        self.id = id
        self.topicID = topicID
        self.kind = kind
        self.status = status
        self.text = text
        self.owner = owner
        self.dueDate = dueDate
        self.source = source
        self.lockedByUser = lockedByUser
        self.order = order
        self.evidence = evidence
        self.fallbackScopeID = fallbackScopeID
        self.supersededByItemID = supersededByItemID
    }
}

public struct MeetingSummaryProcessingState: Codable, Equatable, Sendable {
    public var totalUnits: Int
    public var processedUnits: Int
    public var aiUnits: Int
    public var fallbackUnits: Int
    public var pendingUnits: Int
    public var retryUnits: Int
    public var lastError: String?

    public init(
        totalUnits: Int = 0,
        processedUnits: Int = 0,
        aiUnits: Int = 0,
        fallbackUnits: Int = 0,
        pendingUnits: Int = 0,
        retryUnits: Int = 0,
        lastError: String? = nil
    ) {
        let boundedTotal = max(0, totalUnits)
        let boundedProcessed = min(max(0, processedUnits), boundedTotal)
        let boundedAI = min(max(0, aiUnits), boundedProcessed)
        let boundedFallback = min(max(0, fallbackUnits), boundedProcessed - boundedAI)
        let unprocessed = boundedTotal - boundedProcessed

        self.totalUnits = boundedTotal
        self.processedUnits = boundedProcessed
        self.aiUnits = boundedAI
        self.fallbackUnits = boundedFallback
        self.pendingUnits = min(max(0, pendingUnits), unprocessed)
        self.retryUnits = min(max(0, retryUnits), boundedFallback)
        self.lastError = lastError
    }

    public var processedRatio: Double {
        ratio(processedUnits)
    }

    public var aiRatio: Double {
        ratio(aiUnits)
    }

    public var fallbackRatio: Double {
        ratio(fallbackUnits)
    }

    public var isFullyAIProcessed: Bool {
        totalUnits > 0
            && aiUnits == totalUnits
            && fallbackUnits == 0
            && pendingUnits == 0
            && retryUnits == 0
    }

    private func ratio(_ value: Int) -> Double {
        guard totalUnits > 0 else {
            return 0
        }
        return Double(value) / Double(totalUnits)
    }

    private enum CodingKeys: String, CodingKey {
        case totalUnits
        case processedUnits
        case aiUnits
        case fallbackUnits
        case pendingUnits
        case retryUnits
        case lastError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            totalUnits: try container.decodeIfPresent(Int.self, forKey: .totalUnits) ?? 0,
            processedUnits: try container.decodeIfPresent(Int.self, forKey: .processedUnits) ?? 0,
            aiUnits: try container.decodeIfPresent(Int.self, forKey: .aiUnits) ?? 0,
            fallbackUnits: try container.decodeIfPresent(Int.self, forKey: .fallbackUnits) ?? 0,
            pendingUnits: try container.decodeIfPresent(Int.self, forKey: .pendingUnits) ?? 0,
            retryUnits: try container.decodeIfPresent(Int.self, forKey: .retryUnits) ?? 0,
            lastError: try container.decodeIfPresent(String.self, forKey: .lastError)
        )
    }
}

public struct MeetingSummaryDocument: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 2
    public static let appliedDeltaHistoryLimit = 512

    public var schemaVersion: Int
    public var id: String
    public var title: String
    public var headline: String
    /// Optional for backward-compatible decoding of early V2 documents.
    /// `nil` and `false` both mean the AI may update the headline.
    public var headlineLockedByUser: Bool?
    public var topics: [MeetingSummaryTopic]
    public var items: [MeetingSummaryItem]
    public var processing: MeetingSummaryProcessingState
    public var appliedDeltaIDs: [String]
    public var revision: Int

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: String,
        title: String,
        headline: String = "",
        headlineLockedByUser: Bool? = false,
        topics: [MeetingSummaryTopic] = [],
        items: [MeetingSummaryItem] = [],
        processing: MeetingSummaryProcessingState = .init(),
        appliedDeltaIDs: [String] = [],
        revision: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.headline = headline
        self.headlineLockedByUser = headlineLockedByUser
        self.topics = topics
        self.items = items
        self.processing = processing
        self.appliedDeltaIDs = Array(appliedDeltaIDs.suffix(Self.appliedDeltaHistoryLimit))
        self.revision = max(0, revision)
    }

    public static func empty(id: String, title: String) -> MeetingSummaryDocument {
        MeetingSummaryDocument(id: id, title: title)
    }
}

public struct MeetingSummaryDelta: Codable, Equatable, Sendable {
    public var id: String
    public var operations: [MeetingSummaryDeltaOperation]

    public init(id: String, operations: [MeetingSummaryDeltaOperation]) {
        self.id = id
        self.operations = operations
    }
}

public enum MeetingSummaryDeltaOperation: Equatable, Sendable {
    case setHeadline(String)
    case setManualHeadline(String)
    case upsertTopic(MeetingSummaryTopic)
    case upsertItem(MeetingSummaryItem)
    case updateProcessing(MeetingSummaryProcessingState)
    case resolveItem(id: String, source: MeetingSummarySource)
    case supersedeItem(id: String, replacement: MeetingSummaryItem, source: MeetingSummarySource)
    case replaceFallback(scopeID: String, topic: MeetingSummaryTopic, items: [MeetingSummaryItem])
}

extension MeetingSummaryDeltaOperation: Codable {
    private enum OperationType: String, Codable {
        case setHeadline
        case setManualHeadline
        case upsertTopic
        case upsertItem
        case updateProcessing
        case resolveItem
        case supersedeItem
        case replaceFallback
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case headline
        case topic
        case item
        case processing
        case id
        case source
        case replacement
        case scopeID
        case items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(OperationType.self, forKey: .type) {
        case .setHeadline:
            self = .setHeadline(try container.decode(String.self, forKey: .headline))
        case .setManualHeadline:
            self = .setManualHeadline(try container.decode(String.self, forKey: .headline))
        case .upsertTopic:
            self = .upsertTopic(try container.decode(MeetingSummaryTopic.self, forKey: .topic))
        case .upsertItem:
            self = .upsertItem(try container.decode(MeetingSummaryItem.self, forKey: .item))
        case .updateProcessing:
            self = .updateProcessing(try container.decode(MeetingSummaryProcessingState.self, forKey: .processing))
        case .resolveItem:
            self = .resolveItem(
                id: try container.decode(String.self, forKey: .id),
                source: try container.decode(MeetingSummarySource.self, forKey: .source)
            )
        case .supersedeItem:
            self = .supersedeItem(
                id: try container.decode(String.self, forKey: .id),
                replacement: try container.decode(MeetingSummaryItem.self, forKey: .replacement),
                source: try container.decode(MeetingSummarySource.self, forKey: .source)
            )
        case .replaceFallback:
            self = .replaceFallback(
                scopeID: try container.decode(String.self, forKey: .scopeID),
                topic: try container.decode(MeetingSummaryTopic.self, forKey: .topic),
                items: try container.decode([MeetingSummaryItem].self, forKey: .items)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .setHeadline(headline):
            try container.encode(OperationType.setHeadline, forKey: .type)
            try container.encode(headline, forKey: .headline)
        case let .setManualHeadline(headline):
            try container.encode(OperationType.setManualHeadline, forKey: .type)
            try container.encode(headline, forKey: .headline)
        case let .upsertTopic(topic):
            try container.encode(OperationType.upsertTopic, forKey: .type)
            try container.encode(topic, forKey: .topic)
        case let .upsertItem(item):
            try container.encode(OperationType.upsertItem, forKey: .type)
            try container.encode(item, forKey: .item)
        case let .updateProcessing(processing):
            try container.encode(OperationType.updateProcessing, forKey: .type)
            try container.encode(processing, forKey: .processing)
        case let .resolveItem(id, source):
            try container.encode(OperationType.resolveItem, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(source, forKey: .source)
        case let .supersedeItem(id, replacement, source):
            try container.encode(OperationType.supersedeItem, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(replacement, forKey: .replacement)
            try container.encode(source, forKey: .source)
        case let .replaceFallback(scopeID, topic, items):
            try container.encode(OperationType.replaceFallback, forKey: .type)
            try container.encode(scopeID, forKey: .scopeID)
            try container.encode(topic, forKey: .topic)
            try container.encode(items, forKey: .items)
        }
    }
}

public typealias Topic = MeetingSummaryTopic
public typealias Item = MeetingSummaryItem
public typealias ProcessingState = MeetingSummaryProcessingState
public typealias Delta = MeetingSummaryDelta
public typealias DeltaOperation = MeetingSummaryDeltaOperation
public typealias MeetingSummaryItemSource = MeetingSummarySource
