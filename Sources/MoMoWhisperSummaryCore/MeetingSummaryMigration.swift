import Foundation

public struct LegacyMeetingSummaryState: Codable, Equatable, Sendable {
    public struct Topic: Codable, Equatable, Sendable {
        public var topic: String
        public var conclusion: String
        public var openItems: [String]

        public init(topic: String, conclusion: String, openItems: [String]) {
            self.topic = topic
            self.conclusion = conclusion
            self.openItems = openItems
        }

        private enum CodingKeys: String, CodingKey {
            case topic
            case conclusion
            case openItems = "open_items"
        }
    }

    public var topics: [Topic]

    public init(topics: [Topic]) {
        self.topics = topics
    }
}

public enum MeetingSummaryMigration {
    public static func migrate(
        _ legacy: LegacyMeetingSummaryState,
        meetingID: String,
        title: String
    ) -> MeetingSummaryDocument {
        var operations: [MeetingSummaryDeltaOperation] = []
        for (topicIndex, legacyTopic) in legacy.topics.enumerated() {
            let topicTitle = legacyTopic.topic.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !topicTitle.isEmpty else {
                continue
            }
            let topicID = "legacy-topic-\(MeetingSummaryFingerprint.make(topicTitle))"
            operations.append(.upsertTopic(.init(
                id: topicID,
                title: topicTitle,
                order: topicIndex
            )))

            let conclusion = legacyTopic.conclusion.trimmingCharacters(in: .whitespacesAndNewlines)
            if !conclusion.isEmpty {
                operations.append(.upsertItem(.init(
                    id: legacyItemID(topicID: topicID, kind: .note, text: conclusion, index: 0),
                    topicID: topicID,
                    kind: .note,
                    status: .unknown,
                    text: conclusion,
                    source: .legacy,
                    order: 0
                )))
            }

            for (itemIndex, rawItem) in legacyTopic.openItems.enumerated() {
                let text = rawItem.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    continue
                }
                operations.append(.upsertItem(.init(
                    id: legacyItemID(topicID: topicID, kind: .openQuestion, text: text, index: itemIndex + 1),
                    topicID: topicID,
                    kind: .openQuestion,
                    status: .unknown,
                    text: text,
                    source: .legacy,
                    order: itemIndex + 1
                )))
            }
        }

        return MeetingSummaryReducer.applying(
            MeetingSummaryDelta(
                id: "legacy-migration-\(MeetingSummaryFingerprint.make(parts: [meetingID, title]))",
                operations: operations
            ),
            to: .empty(id: meetingID, title: title)
        )
    }

    public static func decodeAndMigrate(
        _ data: Data,
        meetingID: String,
        title: String,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> MeetingSummaryDocument {
        if let current = try? decoder.decode(MeetingSummaryDocument.self, from: data) {
            return current
        }
        return migrate(
            try decoder.decode(LegacyMeetingSummaryState.self, from: data),
            meetingID: meetingID,
            title: title
        )
    }

    private static func legacyItemID(
        topicID: String,
        kind: MeetingSummaryItemKind,
        text: String,
        index: Int
    ) -> String {
        let fingerprint = MeetingSummaryFingerprint.make(parts: [
            topicID,
            kind.rawValue,
            text,
            String(index)
        ])
        return "legacy-item-\(fingerprint)"
    }
}
