import Foundation

public enum MeetingSummaryReducer {
    public static func applying(
        _ delta: MeetingSummaryDelta,
        to original: MeetingSummaryDocument
    ) -> MeetingSummaryDocument {
        var document = original
        let effectiveDeltaID = deltaID(delta)
        guard !document.appliedDeltaIDs.contains(effectiveDeltaID) else {
            return document
        }

        var topicAliases: [String: String] = [:]
        for topic in document.topics where topicAliases[topic.id] == nil {
            topicAliases[topic.id] = topic.id
        }
        var itemAliases: [String: String] = [:]
        for item in document.items where itemAliases[item.id] == nil {
            itemAliases[item.id] = item.id
        }

        // Providers are asked to emit topics before items, but the reducer is the
        // trust boundary. Resolve every topic operation up front so an out-of-order
        // item in the same delta cannot become permanently ungrouped.
        for operation in delta.operations {
            let incomingTopic: MeetingSummaryTopic?
            switch operation {
            case let .upsertTopic(topic):
                incomingTopic = topic
            case let .replaceFallback(_, topic, _):
                incomingTopic = topic
            default:
                incomingTopic = nil
            }

            if let incomingTopic {
                topicAliases[incomingTopic.id] = upsertTopic(incomingTopic, in: &document)
            }
        }

        for operation in delta.operations {
            switch operation {
            case let .setHeadline(headline):
                if document.headlineLockedByUser != true {
                    document.headline = headline.trimmingCharacters(in: .whitespacesAndNewlines)
                }

            case let .setManualHeadline(headline):
                document.headline = headline.trimmingCharacters(in: .whitespacesAndNewlines)
                document.headlineLockedByUser = true

            case let .upsertTopic(topic):
                let canonicalID = upsertTopic(topic, in: &document)
                topicAliases[topic.id] = canonicalID

            case let .upsertItem(item):
                let canonicalTopicID = topicAliases[item.topicID] ?? canonicalTopicID(item.topicID, in: document)
                var remapped = item
                remapped.topicID = canonicalTopicID
                let canonicalItemID = upsertItem(remapped, in: &document)
                itemAliases[item.id] = canonicalItemID

            case let .updateProcessing(processing):
                document.processing = processing

            case let .resolveItem(id, source):
                let canonicalID = itemAliases[id] ?? id
                guard let index = document.items.firstIndex(where: { $0.id == canonicalID }) else {
                    continue
                }
                guard !document.items[index].lockedByUser || source == .manual else {
                    continue
                }
                document.items[index].status = .resolved
                if source == .manual {
                    document.items[index].source = .manual
                    document.items[index].lockedByUser = true
                }

            case let .supersedeItem(id, replacement, source):
                let canonicalID = itemAliases[id] ?? id
                guard let index = document.items.firstIndex(where: { $0.id == canonicalID }),
                      !document.items[index].lockedByUser || source == .manual,
                      replacement.id != canonicalID else {
                    continue
                }
                var remapped = replacement
                remapped.topicID = topicAliases[replacement.topicID] ?? canonicalTopicID(replacement.topicID, in: document)
                let replacementCanonicalID = upsertItem(remapped, in: &document)
                guard replacementCanonicalID != canonicalID else {
                    continue
                }
                document.items[index].status = .superseded
                document.items[index].supersededByItemID = replacementCanonicalID

            case let .replaceFallback(scopeID, topic, items):
                let canonicalID = upsertTopic(topic, in: &document)
                topicAliases[topic.id] = canonicalID
                document.items.removeAll {
                    $0.fallbackScopeID == scopeID && !$0.lockedByUser
                }
                for item in items {
                    var fallback = item
                    fallback.topicID = canonicalID
                    fallback.source = .localFallback
                    fallback.fallbackScopeID = scopeID
                    _ = upsertItem(fallback, in: &document)
                }
            }
        }

        sort(&document)
        document.schemaVersion = MeetingSummaryDocument.currentSchemaVersion
        document.revision += 1
        document.appliedDeltaIDs.append(effectiveDeltaID)
        document.appliedDeltaIDs = Array(
            document.appliedDeltaIDs.suffix(MeetingSummaryDocument.appliedDeltaHistoryLimit)
        )
        return document
    }

    private static func deltaID(_ delta: MeetingSummaryDelta) -> String {
        let trimmed = delta.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else {
            return trimmed
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(delta.operations)) ?? Data()
        return "anonymous-\(MeetingSummaryFingerprint.make(String(decoding: data, as: UTF8.self)))"
    }

    @discardableResult
    private static func upsertTopic(
        _ incoming: MeetingSummaryTopic,
        in document: inout MeetingSummaryDocument
    ) -> String {
        let title = incoming.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return incoming.id
        }
        let incomingID = incoming.id.isEmpty
            ? "topic-\(MeetingSummaryFingerprint.make(title))"
            : incoming.id
        let normalized = MeetingSummaryNormalization.normalizedText(title)

        if let index = document.topics.firstIndex(where: { $0.id == incomingID }) {
            var updated = incoming
            updated.id = incomingID
            updated.title = title
            updated.aliases = normalizedAliases(existing: document.topics[index].aliases, incoming: incoming.aliases)
            document.topics[index] = updated
            return incomingID
        }

        if let index = document.topics.firstIndex(where: {
            MeetingSummaryNormalization.normalizedText($0.title) == normalized
        }) {
            let canonicalID = document.topics[index].id
            let canonicalTitle = document.topics[index].title
            var aliases = normalizedAliases(
                existing: document.topics[index].aliases,
                incoming: incoming.aliases
            )
            if title != canonicalTitle, !aliases.contains(normalized) {
                aliases.append(normalized)
            }
            let incomingIDAlias = MeetingSummaryNormalization.normalizedText(incomingID)
            if incomingID != canonicalID,
               !incomingIDAlias.isEmpty,
               !aliases.contains(incomingIDAlias) {
                aliases.append(incomingIDAlias)
            }
            document.topics[index].aliases = aliases
            document.topics[index].order = min(document.topics[index].order, incoming.order)
            return canonicalID
        }

        var inserted = incoming
        inserted.id = incomingID
        inserted.title = title
        inserted.aliases = normalizedAliases(existing: [], incoming: incoming.aliases)
        document.topics.append(inserted)
        return incomingID
    }

    @discardableResult
    private static func upsertItem(
        _ incoming: MeetingSummaryItem,
        in document: inout MeetingSummaryDocument
    ) -> String {
        let text = incoming.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return incoming.id
        }
        var normalizedIncoming = incoming
        normalizedIncoming.text = text
        if normalizedIncoming.id.isEmpty {
            let fingerprint = MeetingSummaryFingerprint.make(parts: [
                incoming.topicID,
                incoming.kind.rawValue,
                text
            ])
            normalizedIncoming.id = "item-\(fingerprint)"
        }

        if let index = document.items.firstIndex(where: { $0.id == normalizedIncoming.id }) {
            guard !document.items[index].lockedByUser || normalizedIncoming.source == .manual else {
                return document.items[index].id
            }
            document.items[index] = normalizedIncoming
            return normalizedIncoming.id
        }

        if let exactIndex = document.items.firstIndex(where: {
            $0.topicID == normalizedIncoming.topicID &&
                $0.kind == normalizedIncoming.kind &&
                MeetingSummaryNormalization.normalizedText($0.text) == MeetingSummaryNormalization.normalizedText(text)
        }) {
            return document.items[exactIndex].id
        }

        document.items.append(normalizedIncoming)
        return normalizedIncoming.id
    }

    private static func canonicalTopicID(
        _ requestedID: String,
        in document: MeetingSummaryDocument
    ) -> String {
        if document.topics.contains(where: { $0.id == requestedID }) {
            return requestedID
        }
        let normalizedID = MeetingSummaryNormalization.normalizedText(requestedID)
        return document.topics.first(where: { $0.aliases.contains(normalizedID) })?.id ?? requestedID
    }

    private static func normalizedAliases(existing: [String], incoming: [String]) -> [String] {
        var seen = Set<String>()
        return (existing + incoming).compactMap { alias in
            let normalized = MeetingSummaryNormalization.normalizedText(alias)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    private static func sort(_ document: inout MeetingSummaryDocument) {
        document.topics.sort {
            if $0.order != $1.order { return $0.order < $1.order }
            let lhs = MeetingSummaryNormalization.normalizedText($0.title)
            let rhs = MeetingSummaryNormalization.normalizedText($1.title)
            if lhs != rhs { return lhs < rhs }
            return $0.id < $1.id
        }
        var topicOrder: [String: Int] = [:]
        for (offset, topic) in document.topics.enumerated() where topicOrder[topic.id] == nil {
            topicOrder[topic.id] = offset
        }
        document.items.sort {
            let lhsTopic = topicOrder[$0.topicID] ?? Int.max
            let rhsTopic = topicOrder[$1.topicID] ?? Int.max
            if lhsTopic != rhsTopic { return lhsTopic < rhsTopic }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id < $1.id
        }
    }
}
