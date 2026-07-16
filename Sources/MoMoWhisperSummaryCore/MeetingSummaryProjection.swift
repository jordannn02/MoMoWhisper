import Foundation

public struct MeetingSummaryDisplayProjection: Equatable, Sendable {
    public struct Section: Equatable, Identifiable, Sendable {
        public var topic: MeetingSummaryTopic
        public var items: [MeetingSummaryItem]

        public var id: String { topic.id }

        public init(topic: MeetingSummaryTopic, items: [MeetingSummaryItem]) {
            self.topic = topic
            self.items = items
        }
    }

    public var headline: String
    public var processing: MeetingSummaryProcessingState
    public var sections: [Section]
    public var ungroupedItems: [MeetingSummaryItem]

    public init(
        headline: String,
        processing: MeetingSummaryProcessingState,
        sections: [Section],
        ungroupedItems: [MeetingSummaryItem]
    ) {
        self.headline = headline
        self.processing = processing
        self.sections = sections
        self.ungroupedItems = ungroupedItems
    }

    public static func make(
        from document: MeetingSummaryDocument,
        includeInactive: Bool = false
    ) -> MeetingSummaryDisplayProjection {
        let visibleItems = document.items.filter {
            includeInactive || ($0.status != .resolved && $0.status != .superseded)
        }
        let sortedTopics = document.topics.sorted(by: topicOrder)
        let sections = sortedTopics.compactMap { topic -> Section? in
            let items = visibleItems
                .filter { $0.topicID == topic.id }
                .sorted(by: itemOrder)
            guard !items.isEmpty else {
                return nil
            }
            return Section(topic: topic, items: items)
        }
        let knownTopicIDs = Set(document.topics.map(\.id))
        let ungrouped = visibleItems
            .filter { !knownTopicIDs.contains($0.topicID) }
            .sorted(by: itemOrder)
        return .init(
            headline: document.headline,
            processing: document.processing,
            sections: sections,
            ungroupedItems: ungrouped
        )
    }

    private static func topicOrder(_ lhs: MeetingSummaryTopic, _ rhs: MeetingSummaryTopic) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        let lhsTitle = MeetingSummaryNormalization.normalizedText(lhs.title)
        let rhsTitle = MeetingSummaryNormalization.normalizedText(rhs.title)
        if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }
        return lhs.id < rhs.id
    }

    private static func itemOrder(_ lhs: MeetingSummaryItem, _ rhs: MeetingSummaryItem) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        return lhs.id < rhs.id
    }
}

/// A deterministic read-first projection for dense meeting topics.
///
/// The policy filters inactive audit items, surfaces the item kinds that most
/// often require attention, and preserves the caller's order for equal-priority
/// items. Topics at or below `previewThreshold` remain fully visible; larger
/// topics are reduced to `previewLimit` items until the reader expands them.
public enum MeetingSummaryReadingPolicy {
    public static let previewThreshold = 12
    public static let previewLimit = 8

    public static func prioritizedActiveItems(
        _ items: [MeetingSummaryItem]
    ) -> [MeetingSummaryItem] {
        items.enumerated()
            .filter { isActive($0.element) }
            .sorted { lhs, rhs in
                let lhsPriority = priority(of: lhs.element.kind)
                let rhsPriority = priority(of: rhs.element.kind)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    public static func previewItems(
        _ items: [MeetingSummaryItem],
        threshold: Int = previewThreshold,
        limit: Int = previewLimit
    ) -> [MeetingSummaryItem] {
        let prioritized = prioritizedActiveItems(items)
        guard prioritized.count > max(0, threshold) else {
            return prioritized
        }
        return Array(prioritized.prefix(max(0, limit)))
    }

    public static func requiresExpansion(
        _ items: [MeetingSummaryItem],
        threshold: Int = previewThreshold
    ) -> Bool {
        prioritizedActiveItems(items).count > max(0, threshold)
    }

    private static func isActive(_ item: MeetingSummaryItem) -> Bool {
        item.status != .resolved && item.status != .superseded
    }

    private static func priority(of kind: MeetingSummaryItemKind) -> Int {
        switch kind {
        case .decision: return 0
        case .action: return 1
        case .openQuestion: return 2
        case .requirement: return 3
        case .risk: return 4
        case .fact: return 5
        case .note: return 6
        }
    }
}

public enum MeetingSummaryRenderer {
    public struct Options: Equatable, Sendable {
        public enum Language: String, Codable, Sendable {
            case traditionalChinese
            case english
        }

        public var language: Language
        public var includeInactiveItems: Bool
        public var includeProcessing: Bool
        public var usesDenseTopicPreview: Bool

        public init(
            language: Language = .traditionalChinese,
            includeInactiveItems: Bool = false,
            includeProcessing: Bool = true,
            usesDenseTopicPreview: Bool = true
        ) {
            self.language = language
            self.includeInactiveItems = includeInactiveItems
            self.includeProcessing = includeProcessing
            self.usesDenseTopicPreview = usesDenseTopicPreview
        }
    }

    public static func render(
        _ document: MeetingSummaryDocument,
        options: Options = .init()
    ) -> String {
        let projection = MeetingSummaryDisplayProjection.make(
            from: document,
            includeInactive: options.includeInactiveItems
        )
        var lines: [String] = ["# \(document.title)"]

        if !projection.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append(options.language == .traditionalChinese ? "## 一句話摘要" : "## Headline")
            lines.append("")
            lines.append(projection.headline)
        }

        if options.includeProcessing {
            lines.append("")
            lines.append(options.language == .traditionalChinese ? "## 整理狀態" : "## Processing")
            lines.append("")
            lines.append(processingLine(projection.processing, language: options.language))
        }

        for section in projection.sections {
            lines.append("")
            lines.append("## \(section.topic.title)")
            lines.append("")
            let shouldPreview = options.usesDenseTopicPreview
                && !options.includeInactiveItems
                && MeetingSummaryReadingPolicy.requiresExpansion(section.items)
            let renderedItems = shouldPreview
                ? MeetingSummaryReadingPolicy.previewItems(section.items)
                : section.items
            lines.append(contentsOf: renderedItems.map {
                "- [\(kindLabel($0.kind, language: options.language)) · \(statusLabel($0.status, language: options.language))] \($0.text)"
            })
            if shouldPreview {
                let omitted = max(0, section.items.count - renderedItems.count)
                lines.append(options.language == .traditionalChinese
                    ? "- …另有 \(omitted) 項；完整稽核請查看 session_state_v1.json#/snapshot/summaryDocument（summary_document.json 僅為相容預覽）。"
                    : "- …\(omitted) more items; the full audit is session_state_v1.json#/snapshot/summaryDocument (summary_document.json is a compatibility preview).")
            }
        }

        if !projection.ungroupedItems.isEmpty {
            lines.append("")
            lines.append(options.language == .traditionalChinese ? "## 未分類" : "## Ungrouped")
            lines.append("")
            lines.append(contentsOf: projection.ungroupedItems.map {
                "- [\(kindLabel($0.kind, language: options.language)) · \(statusLabel($0.status, language: options.language))] \($0.text)"
            })
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func processingLine(
        _ state: MeetingSummaryProcessingState,
        language: Options.Language
    ) -> String {
        let processed = Int((state.processedRatio * 100).rounded())
        let ai = Int((state.aiRatio * 100).rounded())
        let fallback = Int((state.fallbackRatio * 100).rounded())
        if language == .traditionalChinese {
            let retry = state.retryUnits > 0 ? " · 待重試 \(state.retryUnits) 字元" : ""
            return "已處理 \(processed)% · AI \(ai)% · 本機備援 \(fallback)%\(retry)"
        }
        let retry = state.retryUnits > 0 ? " · Retry \(state.retryUnits) units" : ""
        return "Processed \(processed)% · AI \(ai)% · Local fallback \(fallback)%\(retry)"
    }

    private static func kindLabel(
        _ kind: MeetingSummaryItemKind,
        language: Options.Language
    ) -> String {
        if language == .english {
            switch kind {
            case .decision: return "Decision"
            case .requirement: return "Requirement"
            case .action: return "Action"
            case .openQuestion: return "Open question"
            case .risk: return "Risk"
            case .fact: return "Fact"
            case .note: return "Note"
            }
        }
        switch kind {
        case .decision: return "決議"
        case .requirement: return "需求"
        case .action: return "待辦"
        case .openQuestion: return "待確認"
        case .risk: return "風險"
        case .fact: return "事實"
        case .note: return "補充"
        }
    }

    private static func statusLabel(
        _ status: MeetingSummaryItemStatus,
        language: Options.Language
    ) -> String {
        if language == .english {
            switch status {
            case .confirmed: return "Confirmed"
            case .proposed: return "Proposed"
            case .open: return "Open"
            case .resolved: return "Resolved"
            case .superseded: return "Superseded"
            case .unknown: return "Unknown"
            }
        }
        switch status {
        case .confirmed: return "已確認"
        case .proposed: return "提案"
        case .open: return "待處理"
        case .resolved: return "已解決"
        case .superseded: return "已取代"
        case .unknown: return "未確認"
        }
    }
}

public typealias MeetingSummaryMarkdownRenderer = MeetingSummaryRenderer
