#if canImport(MoMoWhisperSummaryCore)
import SwiftUI
import MoMoWhisperSummaryCore

enum MeetingSummaryDisplayMode: String, CaseIterable, Identifiable {
    case reading
    case raw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reading:
            return "閱讀"
        case .raw:
            return "原始文字"
        }
    }
}

enum MeetingSummaryFilter: String, CaseIterable, Identifiable {
    case all
    case decisions
    case requirements
    case actions
    case openQuestions
    case risks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .decisions:
            return "決議"
        case .requirements:
            return "需求"
        case .actions:
            return "待辦"
        case .openQuestions:
            return "待確認"
        case .risks:
            return "風險"
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "line.3.horizontal.decrease.circle"
        case .decisions:
            return "checkmark.seal"
        case .requirements:
            return "doc.text"
        case .actions:
            return "checklist"
        case .openQuestions:
            return "questionmark.bubble"
        case .risks:
            return "exclamationmark.triangle"
        }
    }

    func includes(_ kind: MeetingSummaryItemKind) -> Bool {
        switch (self, kind) {
        case (.all, _), (.decisions, .decision), (.requirements, .requirement),
             (.actions, .action), (.openQuestions, .openQuestion), (.risks, .risk):
            return true
        default:
            return false
        }
    }
}

enum MeetingSummaryViewPhase: Equatable {
    case idle
    case processing
    case ready
    case failed(message: String)
    case historical
}

struct MeetingSummaryViewStatus: Equatable {
    var phase: MeetingSummaryViewPhase
    var updatedAtText: String

    init(phase: MeetingSummaryViewPhase, updatedAtText: String = "") {
        self.phase = phase
        self.updatedAtText = updatedAtText
    }

    var isHistorical: Bool {
        if case .historical = phase { return true }
        return false
    }

    var isProcessing: Bool {
        if case .processing = phase { return true }
        return false
    }

    var failureMessage: String? {
        if case let .failed(message) = phase { return message }
        return nil
    }
}

enum MeetingSummaryCopyScope: Equatable {
    case headline
    case filtered
    case fullDocument
    case rawMarkdown
    case topic(id: String)
}

struct MeetingSummaryCopyPayload: Equatable {
    var scope: MeetingSummaryCopyScope
    var text: String
}

struct MeetingSummaryManualEditRequest: Equatable {
    var itemID: String
    var text: String
    var status: MeetingSummaryItemStatus
    var owner: String?
    var dueDate: String?
    var lockAfterSaving: Bool
}

/// A structured, read-first meeting summary surface.
///
/// The view deliberately receives immutable summary state and emits edits through closures.
/// AI refreshes therefore cannot silently mutate text that is currently being edited.
struct MeetingSummaryReaderView: View {
    let document: MeetingSummaryDocument
    let status: MeetingSummaryViewStatus
    let rawMarkdown: String
    let onCopy: (MeetingSummaryCopyPayload) -> Void
    var onEditItem: ((MeetingSummaryManualEditRequest) -> Void)?
    var onOpenEvidence: ((MeetingSummaryEvidence) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayMode: MeetingSummaryDisplayMode = .reading
    @State private var filter: MeetingSummaryFilter = .all
    @State private var searchText = ""
    @State private var expandedTopicIDs: Set<String> = []
    @State private var didSeedExpandedTopics = false
    @State private var editDraft: MeetingSummaryEditDraft?
    @State private var evidencePreview: MeetingSummaryEvidencePreview?
    @State private var copiedScope: MeetingSummaryCopyScope?
    @FocusState private var searchIsFocused: Bool

    init(
        document: MeetingSummaryDocument,
        status: MeetingSummaryViewStatus,
        rawMarkdown: String,
        onCopy: @escaping (MeetingSummaryCopyPayload) -> Void,
        onEditItem: ((MeetingSummaryManualEditRequest) -> Void)? = nil,
        onOpenEvidence: ((MeetingSummaryEvidence) -> Void)? = nil
    ) {
        self.document = document
        self.status = status
        self.rawMarkdown = rawMarkdown
        self.onCopy = onCopy
        self.onEditItem = onEditItem
        self.onOpenEvidence = onOpenEvidence
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            stickyControls

            Group {
                switch displayMode {
                case .reading:
                    readingSurface
                case .raw:
                    rawEditor
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: topicSections.map(\.id), initial: true) { _, topicIDs in
            seedExpandedTopics(from: topicIDs)
        }
        .onChange(of: document.id) { _, _ in
            resetPresentationState()
        }
        .sheet(item: $editDraft) { draft in
            MeetingSummaryItemEditor(
                draft: draft,
                onCancel: { editDraft = nil },
                onSave: { request in
                    onEditItem?(request)
                    editDraft = nil
                }
            )
        }
        .sheet(item: $evidencePreview) { preview in
            MeetingSummaryEvidenceSheet(
                evidence: preview.evidence,
                onClose: { evidencePreview = nil }
            )
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
    }

    private var stickyControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            SummaryProcessingStrip(
                processing: document.processing,
                status: status
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    modePicker
                    Spacer(minLength: 8)
                    copyMenu
                }

                VStack(alignment: .leading, spacing: 8) {
                    modePicker
                    copyMenu
                }
            }

            if displayMode == .reading {
                HStack(spacing: 8) {
                    Label("搜尋", systemImage: "magnifyingglass")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)

                    TextField("搜尋重點", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($searchIsFocused)
                        .accessibilityLabel("搜尋會議重點")

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("清除搜尋")
                        .accessibilityLabel("清除搜尋")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }

                filterBar
            }
        }
        .background(.background)
        .overlay(alignment: .topLeading) {
            Button("搜尋會議重點") {
                displayMode = .reading
                searchIsFocused = true
            }
            .keyboardShortcut("f", modifiers: [.command])
            .frame(width: 1, height: 1)
            .opacity(0.001)
            .accessibilityHidden(true)
        }
    }

    private var modePicker: some View {
        Picker("顯示模式", selection: $displayMode) {
            ForEach(MeetingSummaryDisplayMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 230)
        .accessibilityHint("閱讀模式顯示結構化重點；原始文字模式可檢視 Markdown")
    }

    private var copyMenu: some View {
        Menu {
            if displayMode == .raw {
                Button("複製目前 Markdown") {
                    copy(.rawMarkdown)
                }
                .disabled(rawMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button("複製一句話摘要") {
                    copy(.headline)
                }
                .disabled(document.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("複製目前篩選結果") {
                    copy(.filtered)
                }
                .disabled(filteredTopicSections.allSatisfy(\.items.isEmpty))

                Button("複製完整重點") {
                    copy(.fullDocument)
                }
                .disabled(document.items.isEmpty && document.headline.isEmpty)
            }
        } label: {
            Label(copiedScope == nil ? "複製" : "已複製", systemImage: copiedScope == nil ? "doc.on.doc" : "checkmark")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("選擇要複製的會議重點範圍")
        .accessibilityLabel(copiedScope == nil ? "複製會議重點" : "會議重點已複製")
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MeetingSummaryFilter.allCases) { option in
                    Button {
                        filter = option
                    } label: {
                        Label(option.title, systemImage: filter == option ? "checkmark" : option.systemImage)
                            .font(.subheadline.weight(filter == option ? .semibold : .regular))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(filter == option ? .accentColor : .secondary)
                    .accessibilityAddTraits(filter == option ? .isSelected : [])
                }
            }
        }
        .accessibilityLabel("重點類型篩選")
    }

    @ViewBuilder
    private var readingSurface: some View {
        if shouldShowBlockingFailure {
            summaryUnavailable(
                title: "會議重點整理失敗",
                detail: effectiveFailureMessage ?? "未取得錯誤資訊，逐字稿仍會保留。",
                systemImage: "exclamationmark.triangle"
            )
        } else if hasNoSummaryContent {
            if status.isProcessing || document.processing.pendingUnits > 0 {
                summaryUnavailable(
                    title: "正在整理會議重點",
                    detail: "逐字稿正在分段處理；完成前不會把推測內容標示為決議。",
                    systemImage: "ellipsis.bubble"
                )
            } else {
                summaryUnavailable(
                    title: "尚無會議重點",
                    detail: status.isHistorical ? "這場歷史會議沒有結構化摘要。可切換到原始文字查看舊版內容。" : "開始錄音後，已確認、提案與待確認內容會分開呈現。",
                    systemImage: "list.bullet.clipboard"
                )
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let warning = nonBlockingWarning {
                        SummaryTrustBanner(message: warning)
                    }

                    headlineCard

                    if filteredTopicSections.isEmpty {
                        summaryUnavailable(
                            title: "沒有符合的重點",
                            detail: "請切換類型或清除搜尋條件。",
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                        .frame(minHeight: 180)
                    } else {
                        ForEach(filteredTopicSections) { section in
                            SummaryTopicSection(
                                section: section,
                                isExpanded: expansionBinding(for: section.id),
                                isHistorical: status.isHistorical,
                                limitsDenseTopics: filter == .all
                                    && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                onCopy: { copy(.topic(id: section.id)) },
                                onEdit: onEditItem == nil ? nil : { item in
                                    editDraft = MeetingSummaryEditDraft(
                                        id: item.id,
                                        text: item.text,
                                        status: item.status,
                                        owner: item.owner ?? "",
                                        dueDate: item.dueDate ?? "",
                                        isLocked: item.lockedByUser
                                    )
                                },
                                onOpenEvidence: { evidence in
                                    if let onOpenEvidence {
                                        onOpenEvidence(evidence)
                                    } else {
                                        evidencePreview = MeetingSummaryEvidencePreview(evidence: evidence)
                                    }
                                }
                            )
                            .id("\(document.id)|\(section.id)|\(filter.rawValue)|\(searchText)")
                        }
                    }
                }
                .padding(.vertical, 2)
                .padding(.trailing, 4)
            }
            .scrollIndicators(.visible)
        }
    }

    private var rawEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: status.isHistorical ? "clock.arrow.circlepath" : "doc.plaintext")
                    .foregroundStyle(.secondary)
                Text(status.isHistorical ? "歷史 Markdown（唯讀）" : "原始 Markdown（唯讀）")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !status.updatedAtText.isEmpty {
                    Text(status.updatedAtText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                Text(rawMarkdown.isEmpty ? "尚無原始 Markdown" : rawMarkdown)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(rawMarkdown.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .accessibilityLabel("原始會議重點 Markdown，唯讀")

            Text("原始 Markdown 僅供查核；請在閱讀模式逐項修改，避免與結構化資料分叉。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var headlineCard: some View {
        let headline = document.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        if !headline.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("一句話摘要", systemImage: "quote.opening")
                        .font(.headline)
                    Spacer()
                    Button {
                        copy(.headline)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("複製一句話摘要")
                    .accessibilityLabel("複製一句話摘要")
                }

                Text(headline)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("一句話摘要：\(headline)")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
            }
        }
    }

    private func summaryUnavailable(title: String, detail: String, systemImage: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var topicSections: [MeetingSummaryTopicSectionModel] {
        var seenTopicIDs = Set<String>()
        let orderedTopics = document.topics.sorted {
            if $0.order == $1.order { return $0.title < $1.title }
            return $0.order < $1.order
        }.filter {
            seenTopicIDs.insert($0.id).inserted
        }
        let knownTopicIDs = Set(orderedTopics.map(\.id))
        let groupedItems = Dictionary(grouping: document.items, by: \.topicID)

        var sections = orderedTopics.map { topic in
            MeetingSummaryTopicSectionModel(
                id: topic.id,
                title: topic.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名主題" : topic.title,
                items: sortedItems(groupedItems[topic.id] ?? [])
            )
        }

        let unmatched = groupedItems
            .filter { !knownTopicIDs.contains($0.key) }
            .flatMap(\.value)
        if !unmatched.isEmpty {
            sections.append(
                MeetingSummaryTopicSectionModel(
                    id: "__unassigned__",
                    title: "其他重點",
                    items: sortedItems(unmatched)
                )
            )
        }

        return sections.filter { !$0.items.isEmpty }
    }

    private var filteredTopicSections: [MeetingSummaryTopicSectionModel] {
        topicSections.compactMap { section in
            let items = section.items.filter { item in
                filter.includes(item.kind) && itemMatchesSearch(item, topicTitle: section.title)
            }
            guard !items.isEmpty else { return nil }
            return MeetingSummaryTopicSectionModel(id: section.id, title: section.title, items: items)
        }
    }

    private var hasNoSummaryContent: Bool {
        document.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && document.items.isEmpty
    }

    private var effectiveFailureMessage: String? {
        status.failureMessage ?? document.processing.lastError
    }

    private var shouldShowBlockingFailure: Bool {
        hasNoSummaryContent && effectiveFailureMessage != nil
    }

    private var nonBlockingWarning: String? {
        var messages: [String] = []
        if let message = effectiveFailureMessage {
            messages.append("最新整理未完成，已保留既有重點：\(message)")
        }
        if document.processing.fallbackUnits > 0 {
            messages.append("部分內容來自本機備援，並非 AI 正式整理；請依來源標籤查核。")
        }
        if document.processing.pendingUnits > 0 {
            messages.append("仍有內容等待整理，目前畫面是部分結果。")
        }
        if document.processing.retryUnits > 0 {
            messages.append("仍有 \(document.processing.retryUnits) 個字元等待 AI 重試；本機備援內容會保留到重試成功。")
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private func sortedItems(_ items: [MeetingSummaryItem]) -> [MeetingSummaryItem] {
        items.sorted {
            if $0.order == $1.order { return $0.id < $1.id }
            return $0.order < $1.order
        }
    }

    private func itemMatchesSearch(_ item: MeetingSummaryItem, topicTitle: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        return item.text.localizedCaseInsensitiveContains(query)
            || topicTitle.localizedCaseInsensitiveContains(query)
            || (item.owner?.localizedCaseInsensitiveContains(query) ?? false)
    }

    private func expansionBinding(for topicID: String) -> Binding<Bool> {
        Binding(
            get: { expandedTopicIDs.contains(topicID) },
            set: { isExpanded in
                if isExpanded {
                    expandedTopicIDs.insert(topicID)
                } else {
                    expandedTopicIDs.remove(topicID)
                }
            }
        )
    }

    private func seedExpandedTopics(from topicIDs: [String]) {
        guard !didSeedExpandedTopics, !topicIDs.isEmpty else { return }
        expandedTopicIDs = Set(topicIDs.prefix(topicIDs.count <= 8 ? topicIDs.count : 3))
        didSeedExpandedTopics = true
    }

    private func resetPresentationState() {
        displayMode = .reading
        filter = .all
        searchText = ""
        expandedTopicIDs = []
        didSeedExpandedTopics = false
        editDraft = nil
        evidencePreview = nil
        copiedScope = nil
        seedExpandedTopics(from: topicSections.map(\.id))
    }

    private func copy(_ scope: MeetingSummaryCopyScope) {
        let payload = MeetingSummaryCopyPayload(scope: scope, text: copyText(for: scope))
        guard !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onCopy(payload)
        copiedScope = scope
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedScope == scope {
                copiedScope = nil
            }
        }
    }

    private func copyText(for scope: MeetingSummaryCopyScope) -> String {
        switch scope {
        case .headline:
            return document.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        case .filtered:
            return renderMarkdown(sections: filteredTopicSections, includeHeadline: true)
        case .fullDocument:
            return MeetingSummaryRenderer.render(
                document,
                options: .init(
                    includeInactiveItems: true,
                    includeProcessing: true,
                    usesDenseTopicPreview: false
                )
            )
        case .rawMarkdown:
            return rawMarkdown
        case let .topic(id):
            let sections = topicSections.filter { $0.id == id }
            return renderMarkdown(sections: sections, includeHeadline: false)
        }
    }

    private func renderMarkdown(
        sections: [MeetingSummaryTopicSectionModel],
        includeHeadline: Bool
    ) -> String {
        var lines: [String] = []
        let headline = document.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        if includeHeadline, !headline.isEmpty {
            lines.append("## 一句話摘要")
            lines.append(headline)
        }

        for section in sections {
            if !lines.isEmpty { lines.append("") }
            lines.append("## \(section.title)")
            for item in section.items {
                lines.append("- [\(item.kind.displayTitle)｜\(item.status.displayTitle)] \(item.text)")
                let metadata = item.copyMetadata
                if !metadata.isEmpty {
                    lines.append("  - \(metadata.joined(separator: " · "))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

private struct SummaryProcessingStrip: View {
    let processing: MeetingSummaryProcessingState
    let status: MeetingSummaryViewStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(lifecycleTitle, systemImage: lifecycleImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(lifecycleColor)
                Spacer()
                if !status.updatedAtText.isEmpty {
                    Text(status.updatedAtText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    metrics
                }

                VStack(alignment: .leading, spacing: 6) {
                    metrics
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("會議重點整理狀態")
    }

    @ViewBuilder
    private var metrics: some View {
        SummaryProcessingMetric(
            title: "已處理",
            value: percent(processing.processedUnits),
            detail: unitDetail(processing.processedUnits),
            systemImage: "chart.bar.fill",
            tint: .accentColor
        )
        SummaryProcessingMetric(
            title: "AI",
            value: percent(processing.aiUnits),
            detail: unitDetail(processing.aiUnits),
            systemImage: "sparkles",
            tint: .blue
        )
        SummaryProcessingMetric(
            title: "本機備援",
            value: percent(processing.fallbackUnits),
            detail: unitDetail(processing.fallbackUnits),
            systemImage: "desktopcomputer",
            tint: processing.fallbackUnits > 0 ? .orange : .secondary
        )
        SummaryProcessingMetric(
            title: "待整理",
            value: percent(processing.pendingUnits),
            detail: unitDetail(processing.pendingUnits),
            systemImage: "hourglass",
            tint: processing.pendingUnits > 0 ? .orange : .secondary
        )
        if processing.retryUnits > 0 {
            SummaryProcessingMetric(
                title: "待重試",
                value: percent(processing.retryUnits),
                detail: unitDetail(processing.retryUnits),
                systemImage: "arrow.clockwise",
                tint: .orange
            )
        }
    }

    private var lifecycleTitle: String {
        switch status.phase {
        case .idle:
            return "等待會議內容"
        case .processing:
            return "正在整理"
        case .ready:
            if processing.fallbackUnits > 0 || processing.pendingUnits > 0 || processing.retryUnits > 0 { return "部分完成" }
            return "整理完成"
        case .failed:
            return "整理失敗，已保留既有內容"
        case .historical:
            return "歷史會議"
        }
    }

    private var lifecycleImage: String {
        switch status.phase {
        case .idle:
            return "pause.circle"
        case .processing:
            return "ellipsis.circle"
        case .ready:
            return processing.fallbackUnits > 0 || processing.pendingUnits > 0 || processing.retryUnits > 0
                ? "exclamationmark.circle"
                : "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        case .historical:
            return "clock.arrow.circlepath"
        }
    }

    private var lifecycleColor: Color {
        switch status.phase {
        case .failed:
            return .red
        case .processing:
            return .accentColor
        case .ready where processing.fallbackUnits > 0 || processing.pendingUnits > 0 || processing.retryUnits > 0:
            return .orange
        case .ready:
            return .green
        case .idle, .historical:
            return .secondary
        }
    }

    private func percent(_ units: Int) -> String {
        guard processing.totalUnits > 0 else { return "0%" }
        let ratio = min(max(Double(units) / Double(processing.totalUnits), 0), 1)
        return "\(Int((ratio * 100).rounded()))%"
    }

    private func unitDetail(_ units: Int) -> String {
        "\(units.formatted()) / \(processing.totalUnits.formatted())"
    }
}

private struct SummaryProcessingMetric: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help("\(title)：\(detail)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value)，\(detail)")
    }
}

private struct SummaryTrustBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MeetingSummaryTopicSectionModel: Identifiable {
    let id: String
    let title: String
    let items: [MeetingSummaryItem]
}

private struct SummaryTopicSection: View {
    let section: MeetingSummaryTopicSectionModel
    @Binding var isExpanded: Bool
    let isHistorical: Bool
    let limitsDenseTopics: Bool
    let onCopy: () -> Void
    let onEdit: ((MeetingSummaryItem) -> Void)?
    let onOpenEvidence: ((MeetingSummaryEvidence) -> Void)?
    @State private var showsAllActiveItems = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            LazyVStack(alignment: .leading, spacing: 0) {
                let archivedItems = section.items.filter(\.status.isArchived)

                ForEach(displayedActiveItems, id: \.id) { item in
                    SummaryItemRow(
                        item: item,
                        isHistorical: isHistorical,
                        onEdit: onEdit,
                        onOpenEvidence: onOpenEvidence
                    )
                    if item.id != displayedActiveItems.last?.id || requiresActiveItemExpansion || !archivedItems.isEmpty {
                        Divider()
                    }
                }

                if requiresActiveItemExpansion {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button(showsAllActiveItems ? "收起" : "顯示全部 \(prioritizedActiveItems.count) 項") {
                            showsAllActiveItems.toggle()
                        }
                        .buttonStyle(.link)

                        if !showsAllActiveItems {
                            Text("目前先顯示決議、待辦與待確認等 8 項高優先重點")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .contain)
                }

                if !archivedItems.isEmpty {
                    DisclosureGroup("已解決／已取代（\(archivedItems.count)）") {
                        ForEach(archivedItems, id: \.id) { item in
                            SummaryItemRow(
                                item: item,
                                isHistorical: isHistorical,
                                onEdit: onEdit,
                                onOpenEvidence: onOpenEvidence
                            )
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Text(section.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text("\(section.items.count) 項")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.trailing, 28)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .padding(.top, 11)
            .padding(.trailing, 11)
            .help("複製「\(section.title)」")
            .accessibilityLabel("複製 \(section.title)")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
    }

    private var prioritizedActiveItems: [MeetingSummaryItem] {
        MeetingSummaryReadingPolicy.prioritizedActiveItems(section.items)
    }

    private var requiresActiveItemExpansion: Bool {
        limitsDenseTopics && MeetingSummaryReadingPolicy.requiresExpansion(section.items)
    }

    private var displayedActiveItems: [MeetingSummaryItem] {
        guard requiresActiveItemExpansion, !showsAllActiveItems else {
            return prioritizedActiveItems
        }
        return MeetingSummaryReadingPolicy.previewItems(section.items)
    }
}

private struct SummaryItemRow: View {
    let item: MeetingSummaryItem
    let isHistorical: Bool
    let onEdit: ((MeetingSummaryItem) -> Void)?
    let onOpenEvidence: ((MeetingSummaryEvidence) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.systemImage)
                .foregroundStyle(item.kind.tint)
                .frame(width: 18)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(item.text)
                    .font(.body)
                    .foregroundStyle(item.status.isArchived ? .secondary : .primary)
                    .strikethrough(item.status == .superseded, color: .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { metadata }
                    VStack(alignment: .leading, spacing: 5) { metadata }
                }
            }

            if !isHistorical, let onEdit {
                Button {
                    onEdit(item)
                } label: {
                    Image(systemName: item.lockedByUser ? "lock.fill" : "pencil")
                }
                .buttonStyle(.borderless)
                .help(item.lockedByUser ? "編輯已鎖定的人工內容" : "人工修改並可鎖定")
                .accessibilityLabel("編輯重點：\(item.text)")
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var metadata: some View {
        SummaryMetadataBadge(
            title: item.kind.displayTitle,
            systemImage: item.kind.systemImage,
            tint: item.kind.tint
        )
        SummaryMetadataBadge(
            title: item.status.displayTitle,
            systemImage: item.status.systemImage,
            tint: item.status.tint
        )
        SummaryMetadataBadge(
            title: item.source.displayTitle,
            systemImage: item.source.systemImage,
            tint: item.source.tint
        )

        if let owner = item.owner, !owner.isEmpty {
            SummaryMetadataBadge(title: owner, systemImage: "person", tint: .secondary)
        }
        if let dueDate = item.dueDate, !dueDate.isEmpty {
            SummaryMetadataBadge(
                title: dueDate,
                systemImage: "calendar",
                tint: .secondary
            )
        }
        if item.lockedByUser {
            SummaryMetadataBadge(title: "人工鎖定", systemImage: "lock.fill", tint: .purple)
        }
        if let evidence = item.evidence.first, let onOpenEvidence {
            Button {
                onOpenEvidence(evidence)
            } label: {
                Label("查看來源", systemImage: "quote.bubble")
                    .font(.caption)
            }
            .buttonStyle(.link)
            .accessibilityHint("開啟逐字稿來源片段")
        }
    }
}

private struct SummaryMetadataBadge: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.09), in: Capsule())
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityLabel(title)
    }
}

private struct MeetingSummaryEditDraft: Identifiable {
    let id: String
    let text: String
    let status: MeetingSummaryItemStatus
    let owner: String
    let dueDate: String
    let isLocked: Bool
}

private struct MeetingSummaryItemEditor: View {
    let draft: MeetingSummaryEditDraft
    let onCancel: () -> Void
    let onSave: (MeetingSummaryManualEditRequest) -> Void

    @State private var text: String
    @State private var status: MeetingSummaryItemStatus
    @State private var owner: String
    @State private var dueDate: String
    @State private var lockAfterSaving: Bool

    init(
        draft: MeetingSummaryEditDraft,
        onCancel: @escaping () -> Void,
        onSave: @escaping (MeetingSummaryManualEditRequest) -> Void
    ) {
        self.draft = draft
        self.onCancel = onCancel
        self.onSave = onSave
        self._text = State(initialValue: draft.text)
        self._status = State(initialValue: draft.status)
        self._owner = State(initialValue: draft.owner)
        self._dueDate = State(initialValue: draft.dueDate)
        self._lockAfterSaving = State(initialValue: draft.isLocked)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("人工修改會議重點")
                    .font(.title2.weight(.semibold))
                Text("儲存後來源會標示為「人工」；鎖定可避免後續 AI 自動覆寫。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .frame(minHeight: 150)
                .accessibilityLabel("重點內容")

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("狀態")
                        .foregroundStyle(.secondary)
                    Picker("狀態", selection: $status) {
                        ForEach(MeetingSummaryItemStatus.allCases, id: \.self) { option in
                            Text(option.displayTitle).tag(option)
                        }
                    }
                    .labelsHidden()
                }

                GridRow {
                    Text("負責人")
                        .foregroundStyle(.secondary)
                    TextField("未指定", text: $owner)
                }

                GridRow {
                    Text("期限")
                        .foregroundStyle(.secondary)
                    TextField("例如 2026-07-31", text: $dueDate)
                }
            }

            Toggle("鎖定人工內容，避免 AI 覆寫", isOn: $lockAfterSaving)

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("儲存") {
                    onSave(
                        MeetingSummaryManualEditRequest(
                            itemID: draft.id,
                            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                            status: status,
                            owner: owner.nilIfBlank,
                            dueDate: dueDate.nilIfBlank,
                            lockAfterSaving: lockAfterSaving
                        )
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 540, minHeight: 300)
    }
}

private struct MeetingSummaryEvidencePreview: Identifiable {
    let id = UUID()
    let evidence: MeetingSummaryEvidence
}

private struct MeetingSummaryEvidenceSheet: View {
    let evidence: MeetingSummaryEvidence
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("逐字稿來源", systemImage: "quote.bubble")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("關閉", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }

            if let excerpt = evidence.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ContentUnavailableView(
                    "沒有來源摘錄",
                    systemImage: "text.quote",
                    description: Text("此重點保留了來源位置，但沒有可顯示的逐字稿摘錄。")
                )
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                if let segmentID = evidence.segmentID, !segmentID.isEmpty {
                    GridRow {
                        Text("片段")
                            .foregroundStyle(.secondary)
                        Text(segmentID)
                            .textSelection(.enabled)
                    }
                }
                if let startOffset = evidence.startOffset {
                    GridRow {
                        Text("起點")
                            .foregroundStyle(.secondary)
                        Text(startOffset.formatted())
                            .monospacedDigit()
                    }
                }
                if let endOffset = evidence.endOffset {
                    GridRow {
                        Text("終點")
                            .foregroundStyle(.secondary)
                        Text(endOffset.formatted())
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 440, idealWidth: 560, minHeight: 240)
    }
}

private extension MeetingSummaryItemKind {
    var displayTitle: String {
        switch self {
        case .decision: return "決議"
        case .requirement: return "需求"
        case .action: return "待辦"
        case .openQuestion: return "待確認"
        case .risk: return "風險"
        case .fact: return "事實"
        case .note: return "備註"
        }
    }

    var systemImage: String {
        switch self {
        case .decision: return "checkmark.seal"
        case .requirement: return "doc.text"
        case .action: return "checklist"
        case .openQuestion: return "questionmark.bubble"
        case .risk: return "exclamationmark.triangle"
        case .fact: return "info.circle"
        case .note: return "note.text"
        }
    }

    var tint: Color {
        switch self {
        case .decision: return .green
        case .requirement: return .blue
        case .action: return .accentColor
        case .openQuestion: return .orange
        case .risk: return .red
        case .fact, .note: return .secondary
        }
    }
}

private extension MeetingSummaryItemStatus {
    var displayTitle: String {
        switch self {
        case .confirmed: return "已確認"
        case .proposed: return "提案"
        case .open: return "待處理"
        case .resolved: return "已解決"
        case .superseded: return "已取代"
        case .unknown: return "未確認"
        }
    }

    var systemImage: String {
        switch self {
        case .confirmed: return "checkmark.circle.fill"
        case .proposed: return "lightbulb"
        case .open: return "circle.dashed"
        case .resolved: return "checkmark.circle"
        case .superseded: return "arrow.triangle.2.circlepath"
        case .unknown: return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .confirmed, .resolved: return .green
        case .proposed: return .blue
        case .open: return .orange
        case .superseded, .unknown: return .secondary
        }
    }

    var isArchived: Bool {
        self == .resolved || self == .superseded
    }
}

private extension MeetingSummarySource {
    var displayTitle: String {
        switch self {
        case .ai: return "AI"
        case .localFallback: return "本機備援"
        case .manual: return "人工"
        case .legacy: return "舊版"
        }
    }

    var systemImage: String {
        switch self {
        case .ai: return "sparkles"
        case .localFallback: return "desktopcomputer"
        case .manual: return "person.crop.circle"
        case .legacy: return "clock.arrow.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .ai: return .blue
        case .localFallback: return .orange
        case .manual: return .purple
        case .legacy: return .secondary
        }
    }
}

private extension MeetingSummaryItem {
    var copyMetadata: [String] {
        var values = ["狀態：\(status.displayTitle)", "來源：\(source.displayTitle)"]
        if let owner, !owner.isEmpty { values.append("負責人：\(owner)") }
        if let dueDate, !dueDate.isEmpty { values.append("期限：\(dueDate)") }
        if lockedByUser { values.append("人工鎖定") }
        return values
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

#if DEBUG
private enum MeetingSummaryPreviewFixture {
    static let document = MeetingSummaryDocument(
        id: "preview-summary",
        title: "產品需求討論",
        headline: "團隊同意先完成離線流程，再以可驗證的測試結果決定是否擴大試用。",
        topics: [
            .init(id: "scope", title: "範圍與決議", order: 0),
            .init(id: "delivery", title: "交付與待確認", order: 1)
        ],
        items: [
            .init(
                id: "decision-1",
                topicID: "scope",
                kind: .decision,
                status: .confirmed,
                text: "第一階段維持本機處理，不上傳原始音訊。",
                source: .ai,
                order: 0,
                evidence: [.init(segmentID: "segment-12", startOffset: 840, endOffset: 882, excerpt: "第一階段先全部留在本機，不上傳原始音訊。")]
            ),
            .init(
                id: "requirement-1",
                topicID: "scope",
                kind: .requirement,
                status: .proposed,
                text: "匯出內容需清楚標示 AI、本機備援與人工修改來源。",
                source: .manual,
                lockedByUser: true,
                order: 1
            ),
            .init(
                id: "action-1",
                topicID: "delivery",
                kind: .action,
                status: .open,
                text: "補齊兩小時長會議的摘要回歸測試。",
                owner: "測試負責人",
                dueDate: "2026-07-31",
                source: .ai,
                order: 0
            ),
            .init(
                id: "question-1",
                topicID: "delivery",
                kind: .openQuestion,
                status: .unknown,
                text: "是否需要新增團隊共用範本仍待確認。",
                source: .localFallback,
                order: 1,
                fallbackScopeID: "fallback-preview"
            )
        ],
        processing: .init(
            totalUnits: 10_000,
            processedUnits: 8_400,
            aiUnits: 7_200,
            fallbackUnits: 1_200,
            pendingUnits: 1_600
        )
    )
}

#endif
#endif
