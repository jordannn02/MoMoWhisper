#if canImport(XCTest)
import XCTest
@testable import MoMoWhisperSummaryCore

final class MeetingSummaryCoreTests: XCTestCase {
    func testFirstBatchDuplicateTopicsCollapseAndItemsRemap() {
        let delta = MeetingSummaryDelta(
            id: "batch-001",
            operations: [
                .upsertTopic(.init(id: "topic-a", title: "Release Planning", order: 0)),
                .upsertTopic(.init(id: "topic-b", title: "  release   planning  ", order: 1)),
                .upsertItem(.init(
                    id: "item-1",
                    topicID: "topic-b",
                    kind: .decision,
                    status: .confirmed,
                    text: "Ship the desktop beta after smoke tests.",
                    source: .ai,
                    order: 0
                ))
            ]
        )

        let result = MeetingSummaryReducer.applying(
            delta,
            to: .empty(id: "meeting-1", title: "Synthetic planning meeting")
        )

        XCTAssertEqual(result.topics.count, 1)
        XCTAssertEqual(result.topics.first?.id, "topic-a")
        XCTAssertEqual(result.items.first?.topicID, "topic-a")
        XCTAssertEqual(result.topics.first?.aliases, ["release planning"])
    }

    func testReplayingSameDeltaTwentyTimesIsIdempotent() {
        let delta = MeetingSummaryDelta(
            id: "batch-repeatable",
            operations: [
                .upsertTopic(.init(id: "topic-1", title: "Audio Quality")),
                .upsertItem(.init(
                    id: "item-1",
                    topicID: "topic-1",
                    kind: .risk,
                    status: .open,
                    text: "Background noise needs another controlled test.",
                    source: .ai
                ))
            ]
        )

        let initial = MeetingSummaryDocument.empty(id: "meeting-2", title: "Synthetic audio review")
        let once = MeetingSummaryReducer.applying(delta, to: initial)
        let replayed = (0..<20).reduce(initial) { document, _ in
            MeetingSummaryReducer.applying(delta, to: document)
        }

        XCTAssertEqual(replayed, once)
        XCTAssertEqual(replayed.appliedDeltaIDs, ["batch-repeatable"])
        XCTAssertEqual(replayed.revision, 1)
    }

    func testLockedManualItemRejectsAIOverwriteButAcceptsManualEdit() {
        let topic = MeetingSummaryTopic(id: "topic-1", title: "Scope")
        let locked = MeetingSummaryItem(
            id: "item-1",
            topicID: topic.id,
            kind: .requirement,
            status: .confirmed,
            text: "Keep the manual wording.",
            source: .manual,
            lockedByUser: true
        )
        let document = MeetingSummaryDocument(
            id: "meeting-3",
            title: "Synthetic scope review",
            topics: [topic],
            items: [locked]
        )

        let ignored = MeetingSummaryReducer.applying(
            .init(id: "ai-edit", operations: [
                .upsertItem(.init(
                    id: locked.id,
                    topicID: topic.id,
                    kind: .requirement,
                    status: .proposed,
                    text: "AI replacement wording.",
                    source: .ai
                ))
            ]),
            to: document
        )
        XCTAssertEqual(ignored.items.first?.text, "Keep the manual wording.")
        XCTAssertEqual(ignored.items.first?.status, .confirmed)

        let manual = MeetingSummaryReducer.applying(
            .init(id: "manual-edit", operations: [
                .upsertItem(.init(
                    id: locked.id,
                    topicID: topic.id,
                    kind: .requirement,
                    status: .confirmed,
                    text: "Keep the manually revised wording.",
                    source: .manual,
                    lockedByUser: true
                ))
            ]),
            to: ignored
        )
        XCTAssertEqual(manual.items.first?.text, "Keep the manually revised wording.")
        XCTAssertTrue(manual.items.first?.lockedByUser == true)
    }

    func testManualHeadlineAndResolveStayLockedAgainstLaterAI() {
        let topic = MeetingSummaryTopic(id: "topic-lock", title: "Trust")
        let item = MeetingSummaryItem(
            id: "item-lock",
            topicID: topic.id,
            kind: .action,
            status: .open,
            text: "Verify the release artifact.",
            source: .ai
        )
        var document = MeetingSummaryDocument(
            id: "meeting-lock",
            title: "Synthetic trust review",
            topics: [topic],
            items: [item]
        )
        document = MeetingSummaryReducer.applying(
            .init(id: "manual-trust", operations: [
                .setManualHeadline("Human-reviewed headline."),
                .resolveItem(id: item.id, source: .manual)
            ]),
            to: document
        )
        document = MeetingSummaryReducer.applying(
            .init(id: "later-ai", operations: [
                .setHeadline("AI replacement headline."),
                .upsertItem(.init(
                    id: item.id,
                    topicID: topic.id,
                    kind: .action,
                    status: .open,
                    text: "AI reopened the action.",
                    source: .ai
                ))
            ]),
            to: document
        )

        XCTAssertEqual(document.headline, "Human-reviewed headline.")
        XCTAssertEqual(document.items.first?.status, .resolved)
        XCTAssertEqual(document.items.first?.text, item.text)
        XCTAssertTrue(document.items.first?.lockedByUser == true)
    }

    func testLegacyMigrationPreservesContentWithoutInventingConfirmation() throws {
        let legacy = LegacyMeetingSummaryState(topics: [
            .init(
                topic: "Release Scope",
                conclusion: "Desktop beta remains in scope.",
                openItems: ["Confirm the final accessibility pass."]
            )
        ])

        let migrated = MeetingSummaryMigration.migrate(
            legacy,
            meetingID: "legacy-meeting",
            title: "Imported synthetic meeting"
        )

        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.topics.map(\.title), ["Release Scope"])
        XCTAssertEqual(migrated.items.count, 2)
        XCTAssertEqual(Set(migrated.items.map(\.status)), [.unknown])
        XCTAssertEqual(Set(migrated.items.map(\.source)), [.legacy])
        XCTAssertEqual(Set(migrated.items.map(\.kind)), [.note, .openQuestion])

        let encoded = try JSONEncoder().encode(migrated)
        XCTAssertEqual(try JSONDecoder().decode(MeetingSummaryDocument.self, from: encoded), migrated)
    }

    func testRendererPrintsTopicPrefixOnlyOnce() {
        let topic = MeetingSummaryTopic(id: "topic-1", title: "Distribution")
        let document = MeetingSummaryDocument(
            id: "meeting-4",
            title: "Synthetic distribution review",
            headline: "The beta can proceed after verification.",
            topics: [topic],
            items: [
                .init(id: "i1", topicID: topic.id, kind: .decision, status: .confirmed, text: "Publish the beta.", source: .ai, order: 0),
                .init(id: "i2", topicID: topic.id, kind: .action, status: .open, text: "Run installation smoke tests.", source: .ai, order: 1),
                .init(id: "i3", topicID: topic.id, kind: .risk, status: .open, text: "Document the trust boundary.", source: .ai, order: 2)
            ]
        )

        let markdown = MeetingSummaryRenderer.render(document)

        XCTAssertEqual(markdown.components(separatedBy: "Distribution").count - 1, 1)
        XCTAssertTrue(markdown.contains("## Distribution"))
        XCTAssertTrue(markdown.contains("- [決議 · 已確認] Publish the beta."))
        XCTAssertTrue(markdown.contains("- [待辦 · 待處理] Run installation smoke tests."))
    }

    func testFallbackReplacementKeepsOneCurrentScopeProjection() {
        let initial = MeetingSummaryDocument.empty(id: "meeting-5", title: "Synthetic fallback review")
        let topic = MeetingSummaryTopic(id: "fallback-topic", title: "Local Recovery")
        let first = MeetingSummaryReducer.applying(
            .init(id: "fallback-1", operations: [
                .replaceFallback(
                    scopeID: "segment-12",
                    topic: topic,
                    items: [
                        .init(id: "old-a", topicID: topic.id, kind: .note, status: .unknown, text: "First local note.", source: .localFallback),
                        .init(id: "old-b", topicID: topic.id, kind: .note, status: .unknown, text: "Second local note.", source: .localFallback)
                    ]
                )
            ]),
            to: initial
        )
        let replaced = MeetingSummaryReducer.applying(
            .init(id: "fallback-2", operations: [
                .replaceFallback(
                    scopeID: "segment-12",
                    topic: topic,
                    items: [
                        .init(id: "new-a", topicID: topic.id, kind: .note, status: .unknown, text: "Replacement local note.", source: .localFallback)
                    ]
                )
            ]),
            to: first
        )

        XCTAssertEqual(replaced.items.filter { $0.fallbackScopeID == "segment-12" }.map(\.id), ["new-a"])
        XCTAssertFalse(replaced.items.contains { $0.id == "old-a" || $0.id == "old-b" })
    }

    func testFinalSupersedeRetainsAuditTrailAndAddsReplacement() {
        let topic = MeetingSummaryTopic(id: "topic-1", title: "Final Review")
        let old = MeetingSummaryItem(
            id: "old-item",
            topicID: topic.id,
            kind: .fact,
            status: .proposed,
            text: "An early draft statement.",
            source: .ai
        )
        let initial = MeetingSummaryDocument(
            id: "meeting-6",
            title: "Synthetic final review",
            topics: [topic],
            items: [old]
        )
        let replacement = MeetingSummaryItem(
            id: "new-item",
            topicID: topic.id,
            kind: .decision,
            status: .confirmed,
            text: "The final reviewed statement.",
            source: .ai
        )

        let result = MeetingSummaryReducer.applying(
            .init(id: "final-compact", operations: [
                .supersedeItem(id: old.id, replacement: replacement, source: .ai)
            ]),
            to: initial
        )

        XCTAssertEqual(result.items.first { $0.id == old.id }?.status, .superseded)
        XCTAssertEqual(result.items.first { $0.id == old.id }?.supersededByItemID, replacement.id)
        XCTAssertEqual(result.items.first { $0.id == replacement.id }?.status, .confirmed)
    }

    func testOutOfOrderAndCrossDeltaTopicAliasesRemainGrouped() {
        let first = MeetingSummaryReducer.applying(
            .init(id: "first", operations: [
                .upsertItem(.init(
                    id: "item-before-topic",
                    topicID: "duplicate-topic-id",
                    kind: .note,
                    status: .unknown,
                    text: "The item arrived before its topic operation.",
                    source: .ai
                )),
                .upsertTopic(.init(id: "canonical-topic-id", title: "Release Scope", order: 0)),
                .upsertTopic(.init(id: "duplicate-topic-id", title: " release scope ", order: 1))
            ]),
            to: .empty(id: "meeting-aliases", title: "Synthetic aliases")
        )

        XCTAssertEqual(first.items.first?.topicID, "canonical-topic-id")

        let second = MeetingSummaryReducer.applying(
            .init(id: "second", operations: [
                .upsertItem(.init(
                    id: "later-item",
                    topicID: "duplicate-topic-id",
                    kind: .action,
                    status: .open,
                    text: "A later batch reused the merged topic identifier.",
                    source: .ai
                ))
            ]),
            to: first
        )

        XCTAssertEqual(Set(second.items.map(\.topicID)), ["canonical-topic-id"])
        XCTAssertTrue(MeetingSummaryDisplayProjection.make(from: second).ungroupedItems.isEmpty)
    }

    func testSupersedeAuditLinkUsesCanonicalReplacementID() {
        let topic = MeetingSummaryTopic(id: "topic", title: "Review")
        let old = MeetingSummaryItem(
            id: "old",
            topicID: topic.id,
            kind: .note,
            status: .proposed,
            text: "Draft statement.",
            source: .ai
        )
        let canonicalReplacement = MeetingSummaryItem(
            id: "canonical-replacement",
            topicID: topic.id,
            kind: .decision,
            status: .confirmed,
            text: "Reviewed statement.",
            source: .ai
        )
        let initial = MeetingSummaryDocument(
            id: "meeting-supersede-alias",
            title: "Synthetic supersede alias",
            topics: [topic],
            items: [old, canonicalReplacement]
        )
        let duplicateReplacement = MeetingSummaryItem(
            id: "provider-replacement",
            topicID: topic.id,
            kind: .decision,
            status: .confirmed,
            text: canonicalReplacement.text,
            source: .ai
        )

        let result = MeetingSummaryReducer.applying(
            .init(id: "supersede-alias", operations: [
                .supersedeItem(id: old.id, replacement: duplicateReplacement, source: .ai)
            ]),
            to: initial
        )

        XCTAssertEqual(
            result.items.first { $0.id == old.id }?.supersededByItemID,
            canonicalReplacement.id
        )
        XCTAssertFalse(result.items.contains { $0.id == duplicateReplacement.id })
    }

    func testProjectionHandlesFiftyTopicsAndTwoHundredItemsDeterministically() {
        let topics = (0..<50).map {
            MeetingSummaryTopic(id: "topic-\($0)", title: "Synthetic Topic \($0)", order: $0)
        }
        let items = topics.flatMap { topic in
            (0..<4).map { index in
                MeetingSummaryItem(
                    id: "\(topic.id)-item-\(index)",
                    topicID: topic.id,
                    kind: index == 0 ? .decision : .note,
                    status: index == 0 ? .confirmed : .unknown,
                    text: "Synthetic detail \(index).",
                    source: .ai,
                    order: index
                )
            }
        }
        let document = MeetingSummaryDocument(
            id: "meeting-large",
            title: "Synthetic scale fixture",
            topics: Array(topics.reversed()),
            items: Array(items.reversed())
        )

        let projection = MeetingSummaryDisplayProjection.make(from: document)

        XCTAssertEqual(projection.sections.count, 50)
        XCTAssertEqual(projection.sections.flatMap(\.items).count, 200)
        XCTAssertEqual(projection.sections.first?.topic.id, "topic-0")
        XCTAssertEqual(projection.sections.last?.topic.id, "topic-49")
        XCTAssertEqual(projection.sections.first?.items.map(\.order), [0, 1, 2, 3])
    }

    func testReadingPolicyPreviewsOneDenseTopicByPriorityAndStableOrder() throws {
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
                text: "Synthetic dense detail \(index).",
                source: .ai,
                order: index
            )
        }
        let projection = MeetingSummaryDisplayProjection.make(from: .init(
            id: "meeting-dense",
            title: "Synthetic dense meeting",
            topics: [topic],
            items: items
        ))
        let section = try XCTUnwrap(projection.sections.first)

        XCTAssertEqual(projection.sections.count, 1)
        XCTAssertEqual(section.items.count, 202)
        XCTAssertTrue(MeetingSummaryReadingPolicy.requiresExpansion(section.items))

        let prioritized = MeetingSummaryReadingPolicy.prioritizedActiveItems(section.items)
        XCTAssertEqual(
            Array(prioritized.prefix(7).map(\.kind)),
            [.decision, .action, .openQuestion, .requirement, .risk, .fact, .note]
        )
        XCTAssertEqual(
            Array(prioritized.filter { $0.kind == .note }.prefix(3).map(\.id)),
            ["dense-item-0", "dense-item-7", "dense-item-8"]
        )

        let inactiveItems = [
            MeetingSummaryItem(
                id: "dense-item-resolved",
                topicID: topic.id,
                kind: .decision,
                status: .resolved,
                text: "Resolved audit detail.",
                source: .ai
            ),
            MeetingSummaryItem(
                id: "dense-item-superseded",
                topicID: topic.id,
                kind: .action,
                status: .superseded,
                text: "Superseded audit detail.",
                source: .ai
            )
        ]
        XCTAssertEqual(
            MeetingSummaryReadingPolicy.prioritizedActiveItems(section.items + inactiveItems).count,
            202
        )

        let preview = MeetingSummaryReadingPolicy.previewItems(section.items)
        XCTAssertEqual(preview.count, 8)
        XCTAssertEqual(
            preview.map(\.id),
            [
                "dense-item-3",
                "dense-item-5",
                "dense-item-6",
                "dense-item-2",
                "dense-item-4",
                "dense-item-1",
                "dense-item-0",
                "dense-item-7"
            ]
        )

        let document = MeetingSummaryDocument(
            id: "dense-render",
            title: "Synthetic dense render",
            topics: [topic],
            items: items
        )
        let readable = MeetingSummaryRenderer.render(document)
        XCTAssertEqual(readable.components(separatedBy: "- [").count - 1, 8)
        XCTAssertTrue(readable.contains("另有 194 項"))

        let fullAudit = MeetingSummaryRenderer.render(
            document,
            options: .init(usesDenseTopicPreview: false)
        )
        XCTAssertEqual(fullAudit.components(separatedBy: "- [").count - 1, 202)
        XCTAssertFalse(fullAudit.contains("另有 194 項"))
    }

    func testNormalizationFingerprintAndDuplicateCandidatesAreDeterministic() {
        XCTAssertEqual(
            MeetingSummaryNormalization.normalizedText("  AUDIO   Quality！ "),
            "audio quality"
        )
        XCTAssertEqual(
            MeetingSummaryFingerprint.make("  AUDIO   Quality！ "),
            MeetingSummaryFingerprint.make("audio quality")
        )

        let exactTopics = [
            MeetingSummaryTopic(id: "a", title: "Audio Quality"),
            MeetingSummaryTopic(id: "b", title: " audio   quality ")
        ]
        let exact = MeetingSummaryDuplicateAnalyzer.topicCandidates(in: exactTopics)
        XCTAssertEqual(exact, [.init(firstID: "a", secondID: "b", kind: .exact, score: 1)])

        let nearItems = [
            MeetingSummaryItem(id: "one", topicID: "t", kind: .note, status: .unknown, text: "Confirm desktop installation smoke test", source: .ai),
            MeetingSummaryItem(id: "two", topicID: "t", kind: .note, status: .unknown, text: "Confirm desktop installation smoke tests", source: .ai)
        ]
        let candidates = MeetingSummaryDuplicateAnalyzer.itemCandidates(in: nearItems)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.kind, .conservativeNearSynonym)
        XCTAssertGreaterThanOrEqual(candidates.first?.score ?? 0, 0.8)
    }

    func testProcessingStateSeparatesAIAndFallbackCoverage() {
        let state = MeetingSummaryProcessingState(
            totalUnits: 1_000,
            processedUnits: 900,
            aiUnits: 700,
            fallbackUnits: 200,
            pendingUnits: 100,
            retryUnits: 80,
            lastError: "Synthetic provider timeout"
        )

        XCTAssertEqual(state.processedRatio, 0.9, accuracy: 0.0001)
        XCTAssertEqual(state.aiRatio, 0.7, accuracy: 0.0001)
        XCTAssertEqual(state.fallbackRatio, 0.2, accuracy: 0.0001)
        XCTAssertEqual(state.retryUnits, 80)
        XCTAssertFalse(state.isFullyAIProcessed)

        let empty = MeetingSummaryProcessingState(
            totalUnits: 0,
            processedUnits: 20,
            aiUnits: -1,
            fallbackUnits: 20,
            pendingUnits: -4
        )
        XCTAssertEqual(empty.processedRatio, 0)
        XCTAssertEqual(empty.aiRatio, 0)
        XCTAssertEqual(empty.fallbackRatio, 0)
        XCTAssertFalse(empty.isFullyAIProcessed)
    }

    func testProcessingStateCodableRoundTripPreservesBoundedCoverage() throws {
        let state = MeetingSummaryProcessingState(
            totalUnits: 100,
            processedUnits: 120,
            aiUnits: 90,
            fallbackUnits: 40,
            pendingUnits: 10,
            retryUnits: 50
        )
        XCTAssertEqual(state.processedUnits, 100)
        XCTAssertEqual(state.aiUnits, 90)
        XCTAssertEqual(state.fallbackUnits, 10)
        XCTAssertEqual(state.pendingUnits, 0)
        XCTAssertEqual(state.retryUnits, 10)

        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(MeetingSummaryProcessingState.self, from: data), state)
    }

    func testAppliedDeltaHistoryIsBoundedWithoutChangingState() {
        var document = MeetingSummaryDocument.empty(id: "meeting-history", title: "Synthetic history")
        for index in 0..<600 {
            document = MeetingSummaryReducer.applying(
                .init(id: "delta-\(index)", operations: [.setHeadline("Revision \(index)")]),
                to: document
            )
        }

        XCTAssertEqual(document.headline, "Revision 599")
        XCTAssertEqual(document.revision, 600)
        XCTAssertEqual(document.appliedDeltaIDs.count, MeetingSummaryDocument.appliedDeltaHistoryLimit)
        XCTAssertEqual(document.appliedDeltaIDs.last, "delta-599")
    }

    func testDocumentValidatorRejectsFutureSchemaDuplicateIDsAndOrphans() {
        XCTAssertThrowsError(try MeetingSummaryDocumentValidator.validate(.init(
            schemaVersion: 99,
            id: "future",
            title: "Synthetic"
        ))) { error in
            XCTAssertEqual(error as? MeetingSummaryDocumentValidationError, .unsupportedSchemaVersion(99))
        }

        let duplicateTopics = MeetingSummaryDocument(
            id: "duplicates",
            title: "Synthetic",
            topics: [
                .init(id: "same", title: "One"),
                .init(id: "same", title: "Two")
            ]
        )
        XCTAssertThrowsError(try MeetingSummaryDocumentValidator.validate(duplicateTopics))

        let orphan = MeetingSummaryDocument(
            id: "orphan",
            title: "Synthetic",
            items: [
                .init(id: "item", topicID: "missing", kind: .note, status: .unknown, text: "Synthetic", source: .ai)
            ]
        )
        XCTAssertThrowsError(try MeetingSummaryDocumentValidator.validate(orphan))
    }

    func testHandoffValidityIgnoresRenderedLengthAndRequiresTrustedSemanticContent() {
        let titleOnlyDocument = MeetingSummaryDocument.empty(
            id: "title-only",
            title: String(repeating: "Long rendered title ", count: 20)
        )
        XCTAssertFalse(MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: 12,
            summaryDocument: titleOnlyDocument
        ))

        var headlineDocument = titleOnlyDocument
        headlineDocument.headline = "The team approved the release gate."
        XCTAssertFalse(MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: 12,
            summaryDocument: headlineDocument
        ))
        headlineDocument.headlineLockedByUser = true
        XCTAssertTrue(MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: 12,
            summaryDocument: headlineDocument
        ))

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
        XCTAssertFalse(MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: 12,
            summaryDocument: itemDocument
        ))

        var lockedItemDocument = itemDocument
        lockedItemDocument.items[0].lockedByUser = true
        XCTAssertTrue(MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: 12,
            summaryDocument: lockedItemDocument
        ))

        var fallbackDocument = itemDocument
        fallbackDocument.items[0].source = .localFallback
        XCTAssertFalse(MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: 12,
            summaryDocument: fallbackDocument
        ))

        var manualDocument = itemDocument
        manualDocument.items[0].source = .manual
        XCTAssertTrue(MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: 12,
            summaryDocument: manualDocument
        ))

        var inactiveDocument = manualDocument
        inactiveDocument.items[0].status = .superseded
        XCTAssertFalse(MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: 12,
            summaryDocument: inactiveDocument
        ))

        XCTAssertTrue(MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: MeetingSummaryHandoffValidity.defaultMinimumTranscriptCharacters,
            summaryDocument: nil
        ))
    }
}
#endif
