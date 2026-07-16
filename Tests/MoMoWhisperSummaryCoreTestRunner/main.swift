import Foundation
import MoMoWhisperSummaryCore

enum RegressionFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw RegressionFailure.failed(message)
    }
}

func testDuplicateTopicAndDeltaReplay() throws {
    let delta = MeetingSummaryDelta(id: "batch", operations: [
        .upsertTopic(.init(id: "a", title: "Release Planning", order: 0)),
        .upsertTopic(.init(id: "b", title: " release   planning ", order: 1)),
        .upsertItem(.init(
            id: "i",
            topicID: "b",
            kind: .decision,
            status: .confirmed,
            text: "Ship after smoke tests.",
            source: .ai
        ))
    ])
    let initial = MeetingSummaryDocument.empty(id: "m", title: "Synthetic")
    let once = MeetingSummaryReducer.applying(delta, to: initial)
    var replayed = initial
    for _ in 0..<20 {
        replayed = MeetingSummaryReducer.applying(delta, to: replayed)
    }
    try expect(once.topics.count == 1, "duplicate topics were not collapsed")
    try expect(once.items.first?.topicID == "a", "duplicate topic item was not remapped")
    try expect(replayed == once, "delta replay was not idempotent")
}

func testLockedManualItem() throws {
    let topic = MeetingSummaryTopic(id: "t", title: "Scope")
    let manual = MeetingSummaryItem(
        id: "i",
        topicID: topic.id,
        kind: .requirement,
        status: .confirmed,
        text: "Manual wording.",
        source: .manual,
        lockedByUser: true
    )
    let document = MeetingSummaryDocument(id: "m", title: "Synthetic", topics: [topic], items: [manual])
    let result = MeetingSummaryReducer.applying(
        .init(id: "ai", operations: [.upsertItem(.init(
            id: "i",
            topicID: topic.id,
            kind: .requirement,
            status: .proposed,
            text: "AI wording.",
            source: .ai
        ))]),
        to: document
    )
    try expect(result.items.first?.text == "Manual wording.", "AI overwrote a locked manual item")
}

func testMigrationAndRenderer() throws {
    let migrated = MeetingSummaryMigration.migrate(
        .init(topics: [.init(
            topic: "Release Scope",
            conclusion: "Desktop beta remains in scope.",
            openItems: ["Confirm accessibility pass."]
        )]),
        meetingID: "legacy",
        title: "Synthetic import"
    )
    try expect(Set(migrated.items.map(\.status)) == [.unknown], "migration invented a confirmation state")
    try expect(Set(migrated.items.map(\.source)) == [.legacy], "migration lost legacy provenance")
    let markdown = MeetingSummaryRenderer.render(migrated)
    try expect(markdown.components(separatedBy: "Release Scope").count - 1 == 1, "renderer repeated the topic prefix")
    let roundTrip = try JSONDecoder().decode(
        MeetingSummaryDocument.self,
        from: JSONEncoder().encode(migrated)
    )
    try expect(roundTrip == migrated, "document Codable round trip failed")
}

func testFallbackReplacementAndSupersede() throws {
    let topic = MeetingSummaryTopic(id: "t", title: "Recovery")
    var document = MeetingSummaryDocument.empty(id: "m", title: "Synthetic")
    document = MeetingSummaryReducer.applying(
        .init(id: "f1", operations: [.replaceFallback(
            scopeID: "segment",
            topic: topic,
            items: [
                .init(id: "a", topicID: topic.id, kind: .note, status: .unknown, text: "Old A", source: .localFallback),
                .init(id: "b", topicID: topic.id, kind: .note, status: .unknown, text: "Old B", source: .localFallback)
            ]
        )]),
        to: document
    )
    document = MeetingSummaryReducer.applying(
        .init(id: "f2", operations: [.replaceFallback(
            scopeID: "segment",
            topic: topic,
            items: [.init(id: "new", topicID: topic.id, kind: .note, status: .unknown, text: "Current", source: .localFallback)]
        )]),
        to: document
    )
    try expect(document.items.filter { $0.fallbackScopeID == "segment" }.map(\.id) == ["new"], "fallback replacement appended instead of replacing")

    document = MeetingSummaryReducer.applying(
        .init(id: "final", operations: [.supersedeItem(
            id: "new",
            replacement: .init(id: "final", topicID: topic.id, kind: .decision, status: .confirmed, text: "Reviewed", source: .ai),
            source: .ai
        )]),
        to: document
    )
    try expect(document.items.first { $0.id == "new" }?.status == .superseded, "final compaction did not supersede the old item")
    try expect(document.items.first { $0.id == "final" }?.status == .confirmed, "final replacement was not inserted")
}

func testScaleNormalizationAndProcessing() throws {
    let topics = (0..<50).map { MeetingSummaryTopic(id: "t\($0)", title: "Synthetic Topic \($0)", order: $0) }
    let items = topics.flatMap { topic in
        (0..<4).map { index in
            MeetingSummaryItem(
                id: "\(topic.id)-i\(index)",
                topicID: topic.id,
                kind: .note,
                status: .unknown,
                text: "Synthetic detail \(index)",
                source: .ai,
                order: index
            )
        }
    }
    let projection = MeetingSummaryDisplayProjection.make(from: .init(
        id: "large",
        title: "Synthetic scale",
        topics: Array(topics.reversed()),
        items: Array(items.reversed())
    ))
    try expect(projection.sections.count == 50, "scale fixture lost topics")
    try expect(projection.sections.flatMap(\.items).count == 200, "scale fixture lost items")
    try expect(
        MeetingSummaryFingerprint.make(" AUDIO Quality！ ") == MeetingSummaryFingerprint.make("audio quality"),
        "normalization fingerprint is not deterministic"
    )

    let processing = MeetingSummaryProcessingState(
        totalUnits: 100,
        processedUnits: 120,
        aiUnits: 90,
        fallbackUnits: 40,
        pendingUnits: 10,
        retryUnits: 50
    )
    try expect(processing.processedUnits == 100, "processed coverage exceeded total")
    try expect(processing.aiUnits == 90 && processing.fallbackUnits == 10, "coverage partitions exceeded processed units")
    try expect(processing.retryUnits == 10, "retry coverage was not bounded by fallback units")
}

func testDenseTopicReadingPolicy() throws {
    let topic = MeetingSummaryTopic(id: "dense-topic", title: "Dense Review")
    let leadingKinds: [MeetingSummaryItemKind] = [
        .note,
        .fact,
        .requirement,
        .decision,
        .risk,
        .action,
        .openQuestion
    ]
    let items = (0..<202).map { index in
        MeetingSummaryItem(
            id: "dense-item-\(index)",
            topicID: topic.id,
            kind: index < leadingKinds.count ? leadingKinds[index] : .note,
            status: .open,
            text: "Synthetic dense detail \(index)",
            source: .ai,
            order: index
        )
    }
    let projection = MeetingSummaryDisplayProjection.make(from: .init(
        id: "dense-meeting",
        title: "Synthetic dense meeting",
        topics: [topic],
        items: items
    ))

    try expect(projection.sections.count == 1, "dense fixture did not retain exactly one topic")
    guard let section = projection.sections.first else {
        throw RegressionFailure.failed("dense fixture topic was missing")
    }
    try expect(section.items.count == 202, "dense fixture did not retain all 202 items")
    try expect(MeetingSummaryReadingPolicy.requiresExpansion(section.items), "dense topic did not require expansion")

    let prioritized = MeetingSummaryReadingPolicy.prioritizedActiveItems(section.items)
    try expect(
        Array(prioritized.prefix(7).map(\.kind)) == [.decision, .action, .openQuestion, .requirement, .risk, .fact, .note],
        "dense topic priority order is incorrect"
    )
    try expect(
        Array(prioritized.filter { $0.kind == .note }.prefix(3).map(\.id)) == ["dense-item-0", "dense-item-7", "dense-item-8"],
        "equal-priority dense items did not preserve stable input order"
    )
    let inactiveItems = [
        MeetingSummaryItem(
            id: "dense-item-resolved",
            topicID: topic.id,
            kind: .decision,
            status: .resolved,
            text: "Resolved audit detail",
            source: .ai
        ),
        MeetingSummaryItem(
            id: "dense-item-superseded",
            topicID: topic.id,
            kind: .action,
            status: .superseded,
            text: "Superseded audit detail",
            source: .ai
        )
    ]
    try expect(
        MeetingSummaryReadingPolicy.prioritizedActiveItems(section.items + inactiveItems).count == 202,
        "inactive audit items leaked into the read-first projection"
    )

    let preview = MeetingSummaryReadingPolicy.previewItems(section.items)
    try expect(preview.count == 8, "dense topic preview did not stop at eight items")
    try expect(
        preview.map(\.id) == [
            "dense-item-3",
            "dense-item-5",
            "dense-item-6",
            "dense-item-2",
            "dense-item-4",
            "dense-item-1",
            "dense-item-0",
            "dense-item-7"
        ],
        "dense topic preview did not select the expected high-priority items"
    )

    let document = MeetingSummaryDocument(
        id: "dense-render",
        title: "Synthetic dense render",
        topics: [topic],
        items: items
    )
    let readable = MeetingSummaryRenderer.render(document)
    try expect(readable.components(separatedBy: "- [").count - 1 == 8, "readable export was not bounded")
    try expect(readable.contains("另有 194 項"), "readable export omitted no audit pointer")
    let fullAudit = MeetingSummaryRenderer.render(
        document,
        options: .init(usesDenseTopicPreview: false)
    )
    try expect(fullAudit.components(separatedBy: "- [").count - 1 == 202, "full audit export lost items")
}

func testBoundedHistoryAndNearDuplicateCandidate() throws {
    var document = MeetingSummaryDocument.empty(id: "history", title: "Synthetic")
    for index in 0..<600 {
        document = MeetingSummaryReducer.applying(
            .init(id: "d\(index)", operations: [.setHeadline("Revision \(index)")]),
            to: document
        )
    }
    try expect(document.appliedDeltaIDs.count == MeetingSummaryDocument.appliedDeltaHistoryLimit, "delta history grew without bound")
    let candidates = MeetingSummaryDuplicateAnalyzer.itemCandidates(in: [
        .init(id: "a", topicID: "t", kind: .note, status: .unknown, text: "Confirm desktop installation smoke test", source: .ai),
        .init(id: "b", topicID: "t", kind: .note, status: .unknown, text: "Confirm desktop installation smoke tests", source: .ai)
    ])
    try expect(candidates.first?.kind == .conservativeNearSynonym, "conservative near-duplicate candidate was not surfaced")
}

func testTopicAliasesAndCanonicalSupersedeLink() throws {
    var document = MeetingSummaryReducer.applying(
        .init(id: "topic-order", operations: [
            .upsertItem(.init(id: "early", topicID: "duplicate", kind: .note, status: .unknown, text: "Early item", source: .ai)),
            .upsertTopic(.init(id: "canonical", title: "Release Scope")),
            .upsertTopic(.init(id: "duplicate", title: " release scope "))
        ]),
        to: .empty(id: "aliases", title: "Synthetic")
    )
    document = MeetingSummaryReducer.applying(
        .init(id: "later-item", operations: [
            .upsertItem(.init(id: "later", topicID: "duplicate", kind: .action, status: .open, text: "Later item", source: .ai))
        ]),
        to: document
    )
    try expect(Set(document.items.map(\.topicID)) == ["canonical"], "topic aliases did not survive across deltas")
    try expect(MeetingSummaryDisplayProjection.make(from: document).ungroupedItems.isEmpty, "topic alias created an orphan item")

    let canonicalReplacement = MeetingSummaryItem(
        id: "replacement-canonical",
        topicID: "canonical",
        kind: .decision,
        status: .confirmed,
        text: "Reviewed statement",
        source: .ai
    )
    document.items.append(canonicalReplacement)
    document = MeetingSummaryReducer.applying(
        .init(id: "supersede-canonical", operations: [.supersedeItem(
            id: "early",
            replacement: .init(id: "replacement-provider", topicID: "canonical", kind: .decision, status: .confirmed, text: "Reviewed statement", source: .ai),
            source: .ai
        )]),
        to: document
    )
    try expect(
        document.items.first { $0.id == "early" }?.supersededByItemID == canonicalReplacement.id,
        "supersede audit link did not use the canonical replacement ID"
    )
}

func testManualHeadlineAndResolveLocks() throws {
    let topic = MeetingSummaryTopic(id: "trust", title: "Trust")
    let item = MeetingSummaryItem(id: "action", topicID: topic.id, kind: .action, status: .open, text: "Verify artifact", source: .ai)
    var document = MeetingSummaryDocument(id: "manual-locks", title: "Synthetic", topics: [topic], items: [item])
    document = MeetingSummaryReducer.applying(
        .init(id: "manual", operations: [
            .setManualHeadline("Reviewed headline"),
            .resolveItem(id: item.id, source: .manual)
        ]),
        to: document
    )
    document = MeetingSummaryReducer.applying(
        .init(id: "ai-after-manual", operations: [
            .setHeadline("AI headline"),
            .upsertItem(.init(id: item.id, topicID: topic.id, kind: .action, status: .open, text: "AI reopened", source: .ai))
        ]),
        to: document
    )
    try expect(document.headline == "Reviewed headline", "AI overwrote a manual headline")
    try expect(document.items.first?.status == .resolved, "AI reopened a manually resolved item")
    try expect(document.items.first?.lockedByUser == true, "manual resolve did not lock the item")
}

func testDocumentValidationTrustBoundary() throws {
    do {
        try MeetingSummaryDocumentValidator.validate(.init(
            schemaVersion: 99,
            id: "future",
            title: "Synthetic"
        ))
        throw RegressionFailure.failed("future schema was accepted")
    } catch MeetingSummaryDocumentValidationError.unsupportedSchemaVersion {
    }

    let duplicates = MeetingSummaryDocument(
        id: "duplicates",
        title: "Synthetic",
        topics: [.init(id: "same", title: "One"), .init(id: "same", title: "Two")]
    )
    do {
        try MeetingSummaryDocumentValidator.validate(duplicates)
        throw RegressionFailure.failed("duplicate topic IDs were accepted")
    } catch MeetingSummaryDocumentValidationError.duplicateTopicID {
    }
}

func testHandoffValidityRequiresTrustedSemanticSummaryContent() throws {
    let titleOnlyDocument = MeetingSummaryDocument.empty(
        id: "title-only",
        title: String(repeating: "Long rendered title ", count: 20)
    )
    try expect(
        !MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: 12,
            summaryDocument: titleOnlyDocument
        ),
        "short transcript plus a long rendered title must not become latest_valid"
    )

    var headlineDocument = titleOnlyDocument
    headlineDocument.headline = "The team approved the release gate."
    try expect(
        !MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: 12,
            summaryDocument: headlineDocument
        ),
        "an unlocked generated headline must not make a short handoff valid"
    )
    headlineDocument.headlineLockedByUser = true
    try expect(
        MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: 12,
            summaryDocument: headlineDocument
        ),
        "a user-locked Summary V2 headline must make the handoff valid"
    )

    let topic = MeetingSummaryTopic(id: "semantic", title: "Release")
    let itemDocument = MeetingSummaryDocument(
        id: "active-item",
        title: "Short meeting",
        topics: [topic],
        items: [.init(
            id: "decision",
            topicID: topic.id,
            kind: .decision,
            status: .confirmed,
            text: "Ship after the smoke test passes.",
            source: .ai
        )]
    )
    try expect(
        !MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: 12,
            summaryDocument: itemDocument
        ),
        "an unreviewed AI item must not make a short handoff valid"
    )

    var lockedItemDocument = itemDocument
    lockedItemDocument.items[0].lockedByUser = true
    try expect(
        MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: 12,
            summaryDocument: lockedItemDocument
        ),
        "a user-locked active item must make the handoff valid"
    )

    var fallbackDocument = itemDocument
    fallbackDocument.items[0].source = .localFallback
    try expect(
        !MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: 12,
            summaryDocument: fallbackDocument
        ),
        "a fallback-only summary must not make a short handoff valid"
    )

    var manualDocument = itemDocument
    manualDocument.items[0].source = .manual
    try expect(
        MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: 12,
            summaryDocument: manualDocument
        ),
        "an active manual item must make the handoff valid"
    )

    var inactiveDocument = manualDocument
    inactiveDocument.items[0].status = .resolved
    try expect(
        !MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: 12,
            summaryDocument: inactiveDocument
        ),
        "an inactive item must not make the handoff valid"
    )

    try expect(
        MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: MeetingSummaryHandoffValidity.defaultMinimumTranscriptCharacters,
            summaryDocument: nil
        ),
        "a transcript at the minimum threshold must make the handoff valid"
    )
}

do {
    try testDuplicateTopicAndDeltaReplay()
    try testLockedManualItem()
    try testMigrationAndRenderer()
    try testFallbackReplacementAndSupersede()
    try testScaleNormalizationAndProcessing()
    try testDenseTopicReadingPolicy()
    try testBoundedHistoryAndNearDuplicateCandidate()
    try testTopicAliasesAndCanonicalSupersedeLink()
    try testManualHeadlineAndResolveLocks()
    try testDocumentValidationTrustBoundary()
    try testHandoffValidityRequiresTrustedSemanticSummaryContent()
    print("MoMoWhisperSummaryCore regression suite passed")
} catch {
    fputs("MoMoWhisperSummaryCore regression suite failed: \(error)\n", stderr)
    exit(1)
}
