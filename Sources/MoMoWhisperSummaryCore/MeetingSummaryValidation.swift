import Foundation

public enum MeetingSummaryDocumentValidationError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)
    case blankDocumentID
    case blankTopicID
    case blankTopicTitle(id: String)
    case duplicateTopicID(String)
    case blankItemID
    case blankItemText(id: String)
    case duplicateItemID(String)
    case unknownTopicReference(itemID: String, topicID: String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return "不支援的摘要 schema version：\(version)"
        case .blankDocumentID:
            return "摘要文件 ID 不可空白"
        case .blankTopicID:
            return "摘要 topic ID 不可空白"
        case let .blankTopicTitle(id):
            return "摘要 topic 標題不可空白：\(id)"
        case let .duplicateTopicID(id):
            return "摘要含有重複 topic ID：\(id)"
        case .blankItemID:
            return "摘要 item ID 不可空白"
        case let .blankItemText(id):
            return "摘要 item 文字不可空白：\(id)"
        case let .duplicateItemID(id):
            return "摘要含有重複 item ID：\(id)"
        case let .unknownTopicReference(itemID, topicID):
            return "摘要 item \(itemID) 引用不存在的 topic：\(topicID)"
        }
    }
}

public enum MeetingSummaryDocumentValidator {
    public static func validate(_ document: MeetingSummaryDocument) throws {
        guard document.schemaVersion == MeetingSummaryDocument.currentSchemaVersion else {
            throw MeetingSummaryDocumentValidationError.unsupportedSchemaVersion(document.schemaVersion)
        }
        guard !document.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingSummaryDocumentValidationError.blankDocumentID
        }

        var topicIDs = Set<String>()
        for topic in document.topics {
            let id = topic.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                throw MeetingSummaryDocumentValidationError.blankTopicID
            }
            guard topicIDs.insert(id).inserted else {
                throw MeetingSummaryDocumentValidationError.duplicateTopicID(id)
            }
            guard !topic.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingSummaryDocumentValidationError.blankTopicTitle(id: id)
            }
        }

        var itemIDs = Set<String>()
        for item in document.items {
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                throw MeetingSummaryDocumentValidationError.blankItemID
            }
            guard itemIDs.insert(id).inserted else {
                throw MeetingSummaryDocumentValidationError.duplicateItemID(id)
            }
            guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingSummaryDocumentValidationError.blankItemText(id: id)
            }
            guard topicIDs.contains(item.topicID) else {
                throw MeetingSummaryDocumentValidationError.unknownTopicReference(
                    itemID: id,
                    topicID: item.topicID
                )
            }
        }
    }
}
