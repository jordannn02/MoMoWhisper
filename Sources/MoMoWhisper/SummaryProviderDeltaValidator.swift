import Foundation
import MoMoWhisperSummaryCore

enum SummaryProviderDeltaValidationError: LocalizedError {
    case itemReferencesUnknownTopic(itemID: String, topicID: String)
    case providerAttemptedLocalOperation
    case tooManyOperations(actual: Int, maximum: Int)
    case invalidField(name: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .itemReferencesUnknownTopic(itemID, topicID):
            return "摘要 delta 順序無效：item \(itemID) 引用尚未建立的 topic \(topicID)。"
        case .providerAttemptedLocalOperation:
            return "摘要 provider 不可修改 processing、人工鎖定或本機備援狀態。"
        case let .tooManyOperations(actual, maximum):
            return "摘要 provider 回傳 \(actual) 個 operations，超過上限 \(maximum)。"
        case let .invalidField(name, reason):
            return "摘要 provider 欄位 \(name) 無效：\(reason)"
        }
    }
}

enum SummaryProviderDeltaValidator {
    private static let maximumOperations = 256
    private static let maximumIDCharacters = 128
    private static let maximumHeadlineCharacters = 1_000
    private static let maximumTitleCharacters = 240
    private static let maximumItemCharacters = 4_000
    private static let maximumOwnerCharacters = 200
    private static let maximumDueDateCharacters = 64
    private static let maximumAliases = 20

    static func validated(
        _ delta: MeetingSummaryDelta,
        existingTopicIDs: Set<String>
    ) throws -> MeetingSummaryDelta {
        try validateID(delta.id, field: "delta_id")
        guard delta.operations.count <= maximumOperations else {
            throw SummaryProviderDeltaValidationError.tooManyOperations(
                actual: delta.operations.count,
                maximum: maximumOperations
            )
        }
        let declaredTopicIDs = Set(delta.operations.compactMap { operation -> String? in
            if case let .upsertTopic(topic) = operation {
                return topic.id
            }
            return nil
        })
        let knownTopicIDs = existingTopicIDs.union(declaredTopicIDs)
        for operation in delta.operations {
            switch operation {
            case let .setHeadline(headline):
                try validateText(
                    headline,
                    field: "headline",
                    maximum: maximumHeadlineCharacters,
                    permitsNewlines: false
                )
            case let .upsertTopic(topic):
                try validateTopic(topic)
            case let .upsertItem(item):
                try validateItem(item)
                try requireKnownTopic(item.topicID, itemID: item.id, knownTopicIDs: knownTopicIDs)
            case let .supersedeItem(id, replacement, source):
                try validateID(id, field: "superseded id")
                try requireProviderSource(source)
                try validateItem(replacement)
                try requireKnownTopic(
                    replacement.topicID,
                    itemID: replacement.id,
                    knownTopicIDs: knownTopicIDs
                )
            case .updateProcessing, .replaceFallback, .setManualHeadline:
                throw SummaryProviderDeltaValidationError.providerAttemptedLocalOperation
            case let .resolveItem(id, source):
                try validateID(id, field: "resolved id")
                try requireProviderSource(source)
            }
        }
        return delta
    }

    private static func validateTopic(_ topic: MeetingSummaryTopic) throws {
        try validateID(topic.id, field: "topic.id")
        try validateText(
            topic.title,
            field: "topic.title",
            maximum: maximumTitleCharacters,
            permitsNewlines: false
        )
        guard topic.aliases.count <= maximumAliases else {
            throw SummaryProviderDeltaValidationError.invalidField(
                name: "topic.aliases",
                reason: "超過 \(maximumAliases) 個"
            )
        }
        for alias in topic.aliases {
            try validateText(
                alias,
                field: "topic.alias",
                maximum: maximumTitleCharacters,
                permitsNewlines: false
            )
        }
    }

    private static func validateItem(_ item: MeetingSummaryItem) throws {
        try validateID(item.id, field: "item.id")
        try validateID(item.topicID, field: "item.topic_id")
        try validateText(
            item.text,
            field: "item.text",
            maximum: maximumItemCharacters,
            permitsNewlines: true
        )
        try validateOptionalText(item.owner, field: "item.owner", maximum: maximumOwnerCharacters)
        try validateOptionalText(item.dueDate, field: "item.due_date", maximum: maximumDueDateCharacters)
        guard item.source == .ai,
              !item.lockedByUser,
              item.fallbackScopeID == nil else {
            throw SummaryProviderDeltaValidationError.providerAttemptedLocalOperation
        }
    }

    private static func validateID(_ value: String, field: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SummaryProviderDeltaValidationError.invalidField(name: field, reason: "不可空白")
        }
        guard value.count <= maximumIDCharacters else {
            throw SummaryProviderDeltaValidationError.invalidField(
                name: field,
                reason: "超過 \(maximumIDCharacters) 字元"
            )
        }
        guard !value.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) else {
            throw SummaryProviderDeltaValidationError.invalidField(name: field, reason: "不可含空白或控制字元")
        }
    }

    private static func validateText(
        _ value: String,
        field: String,
        maximum: Int,
        permitsNewlines: Bool
    ) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummaryProviderDeltaValidationError.invalidField(name: field, reason: "不可空白")
        }
        guard value.count <= maximum else {
            throw SummaryProviderDeltaValidationError.invalidField(name: field, reason: "超過 \(maximum) 字元")
        }
        let containsDisallowedControl = value.unicodeScalars.contains { scalar in
            guard CharacterSet.controlCharacters.contains(scalar) else { return false }
            if permitsNewlines, scalar == "\n" || scalar == "\t" { return false }
            return true
        }
        guard !containsDisallowedControl else {
            throw SummaryProviderDeltaValidationError.invalidField(name: field, reason: "含不允許的控制字元")
        }
    }

    private static func validateOptionalText(_ value: String?, field: String, maximum: Int) throws {
        guard let value, !value.isEmpty else { return }
        guard value.count <= maximum else {
            throw SummaryProviderDeltaValidationError.invalidField(name: field, reason: "超過 \(maximum) 字元")
        }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SummaryProviderDeltaValidationError.invalidField(name: field, reason: "含控制字元")
        }
    }

    private static func requireProviderSource(_ source: MeetingSummarySource) throws {
        guard source == .ai else {
            throw SummaryProviderDeltaValidationError.providerAttemptedLocalOperation
        }
    }

    private static func requireKnownTopic(
        _ topicID: String,
        itemID: String,
        knownTopicIDs: Set<String>
    ) throws {
        guard knownTopicIDs.contains(topicID) else {
            throw SummaryProviderDeltaValidationError.itemReferencesUnknownTopic(
                itemID: itemID,
                topicID: topicID
            )
        }
    }
}
