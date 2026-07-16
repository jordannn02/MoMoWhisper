import Foundation
import MoMoWhisperSummaryCore

enum StoreSmokeFailure: Error {
    case failed(String)
    case injected(MeetingSessionStoreWriteStage)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw StoreSmokeFailure.failed(message)
    }
}

func characterOffsets(
    of needle: String,
    in haystack: String
) throws -> (start: Int, end: Int) {
    guard let range = haystack.range(of: needle) else {
        throw StoreSmokeFailure.failed("missing retry fixture range")
    }
    return (
        haystack.distance(from: haystack.startIndex, to: range.lowerBound),
        haystack.distance(from: haystack.startIndex, to: range.upperBound)
    )
}

func makeRetry(
    id: String,
    source: String,
    phrase: String,
    attempts: Int = 1
) throws -> MeetingSummaryRetryRecord {
    let offsets = try characterOffsets(of: phrase, in: source)
    return MeetingSummaryRetryRecord(
        id: id,
        transcript: phrase,
        recentTranscript: "Persisted context must not be trusted for outbound requests.",
        rangeStart: offsets.start,
        rangeEnd: offsets.end,
        isFinal: false,
        attempts: attempts,
        sourcePrefixFingerprint: MeetingSummaryRetryValidator.sourcePrefixFingerprint(
            source,
            endOffset: offsets.end
        )
    )
}

func makeSnapshot(
    metadata originalMetadata: MeetingSessionMetadata,
    source: String,
    highlights: String,
    itemText: String,
    retryID: String
) throws -> MeetingSessionSnapshot {
    var metadata = originalMetadata
    metadata.updatedAt = Date(timeIntervalSince1970: 1_721_234_568)
    metadata.transcriptCharacterCount = source.count
    metadata.highlightCharacterCount = highlights.count
    let retryPhrase = "Alpha retry range."
    let retry = try makeRetry(
        id: retryID,
        source: source,
        phrase: retryPhrase
    )
    let topic = MeetingSummaryTopic(id: "topic", title: "Persistence")
    let document = MeetingSummaryDocument(
        id: metadata.id.uuidString,
        title: metadata.displayTitle,
        topics: [topic],
        items: [
            .init(
                id: "item-\(retryID)",
                topicID: topic.id,
                kind: .action,
                status: .open,
                text: itemText,
                source: .localFallback,
                fallbackScopeID: "scope"
            )
        ],
        processing: .init(
            totalUnits: source.count,
            processedUnits: retry.rangeEnd,
            aiUnits: 0,
            fallbackUnits: retry.unitCount,
            pendingUnits: source.count - retry.rangeEnd,
            retryUnits: retry.unitCount,
            lastError: "Synthetic timeout"
        )
    )
    return MeetingSessionSnapshot(
        metadata: metadata,
        transcriptSegments: [],
        transcriptMarkdown: source,
        summarySourceTranscript: source,
        highlightsMarkdown: highlights,
        rawSummaryState: .empty,
        summaryDocument: document,
        summaryRetries: [retry]
    )
}

let fileManager = FileManager.default
let root = fileManager.temporaryDirectory
    .appendingPathComponent("momowhisper-session-store-smoke-\(UUID().uuidString)", isDirectory: true)
defer { try? fileManager.removeItem(at: root) }

let store = MeetingSessionStore(rootDirectory: root)
let metadata = try store.createSession(
    title: "Synthetic persistence smoke",
    now: Date(timeIntervalSince1970: 1_721_234_567)
)
let baseline = try makeSnapshot(
    metadata: metadata,
    source: "0123456789 Alpha retry range. Baseline tail context.",
    highlights: "Baseline synthetic summary",
    itemText: "Keep the previously committed snapshot.",
    retryID: "retry-baseline"
)
let updated = try makeSnapshot(
    metadata: metadata,
    source: "UPDATED--- Alpha retry range. Replacement tail context.",
    highlights: "Updated synthetic summary",
    itemText: "Use the newly committed snapshot.",
    retryID: "retry-updated"
)

_ = try store.save(snapshot: baseline)
let loaded = try store.loadSnapshot(metadata: metadata)
try expect(loaded == baseline, "complete authoritative snapshot did not round-trip")

// Every write boundary is fault-injected. Before the authoritative envelope is
// committed, readers must see the previous complete snapshot. Once authority
// lands, snapshot readers see the new state; history either recovers it once
// from authority or reads the matching lightweight index.
for stage in MeetingSessionStoreWriteStage.allCases {
    _ = try store.save(snapshot: baseline)
    let faultingStore = MeetingSessionStore(rootDirectory: root, faultInjector: { observedStage in
        if observedStage == stage {
            throw StoreSmokeFailure.injected(stage)
        }
    })
    do {
        _ = try faultingStore.save(snapshot: updated)
        throw StoreSmokeFailure.failed("fault was not injected after \(stage.rawValue)")
    } catch StoreSmokeFailure.injected(let injectedStage) {
        try expect(injectedStage == stage, "wrong fault stage surfaced")
    }

    let recovered = try store.loadSnapshot(metadata: metadata)
    if stage == .authoritativeEnvelope || stage == .historyIndex {
        try expect(recovered == updated, "final envelope commit did not publish the new complete snapshot")
    } else {
        try expect(recovered == baseline, "partial write at \(stage.rawValue) leaked a mixed snapshot")
    }

    let recoveredHistory = try store.loadHistoryRecords()
    let expectedHistory = MeetingSessionHistoryRecord(
        snapshot: stage == .authoritativeEnvelope || stage == .historyIndex ? updated : baseline
    )
    try expect(
        recoveredHistory == [expectedHistory],
        "history recovery selected the wrong committed transaction after \(stage.rawValue)"
    )

    if stage == .authoritativeEnvelope {
        var recoveryReads: [MeetingSessionStoreReadStage] = []
        let observingRecoveryStore = MeetingSessionStore(
            rootDirectory: root,
            readObserver: { recoveryReads.append($0) }
        )
        _ = try observingRecoveryStore.loadHistoryRecords()
        _ = try observingRecoveryStore.loadHistoryRecords()
        try expect(
            recoveryReads.filter { $0 == .authoritativeEnvelope }.count == 1,
            "pending/old-index recovery decoded authority more than once"
        )
    }
}

// A first save that fails before the authoritative commit is not a committed
// session. It must remain hidden from history and refuse mixed-file fallback.
for stage in MeetingSessionStoreWriteStage.allCases
where stage != .authoritativeEnvelope && stage != .historyIndex {
    let firstWriteRoot = root.appendingPathComponent("first-write-\(stage.rawValue)", isDirectory: true)
    let firstStore = MeetingSessionStore(rootDirectory: firstWriteRoot)
    let firstMetadata = try firstStore.createSession(
        title: "First write fault",
        now: Date(timeIntervalSince1970: 1_721_234_567)
    )
    let firstSnapshot = try makeSnapshot(
        metadata: firstMetadata,
        source: "0123456789 Alpha retry range. First write.",
        highlights: "First write summary",
        itemText: "First write",
        retryID: "retry-first"
    )
    let faultingFirstStore = MeetingSessionStore(rootDirectory: firstWriteRoot, faultInjector: { observedStage in
        if observedStage == stage {
            throw StoreSmokeFailure.injected(stage)
        }
    })
    do {
        _ = try faultingFirstStore.save(snapshot: firstSnapshot)
        throw StoreSmokeFailure.failed("first-write fault was not injected after \(stage.rawValue)")
    } catch StoreSmokeFailure.injected {
        // Expected.
    }
    let firstWriteHistory = try firstStore.loadMetadata()
    try expect(firstWriteHistory.isEmpty, "uncommitted first save appeared in history")
    do {
        _ = try firstStore.loadSnapshot(metadata: firstMetadata)
        throw StoreSmokeFailure.failed("uncommitted first save loaded mixed compatibility files")
    } catch MeetingSessionStoreError.incompleteSessionTransaction {
        // Expected.
    }
}

// Compatibility files can be torn or corrupt without affecting current readers.
_ = try store.save(snapshot: baseline)
let folderURL = store.sessionFolderURL(for: metadata)
let summaryURL = folderURL.appendingPathComponent("summary_document.json")
let retryURL = folderURL.appendingPathComponent("summary_retry_state.json")
try Data("{not-valid-json".utf8).write(to: summaryURL, options: .atomic)
try Data("[]".utf8).write(to: retryURL, options: .atomic)
let loadedAcrossTornCompatibilityWrite = try store.loadSnapshot(metadata: metadata)
try expect(loadedAcrossTornCompatibilityWrite == baseline, "authoritative envelope did not protect all session fields")

// Handoff schema v2 binds every trusted read to one committed authority
// transaction. Mutable compatibility files remain explicit, untrusted previews.
let handoffRoot = root.appendingPathComponent("handoff-authority-binding", isDirectory: true)
let handoffDirectory = root.appendingPathComponent("handoff-output", isDirectory: true)
let handoffStore = MeetingSessionStore(rootDirectory: handoffRoot)
let handoffMetadata = try handoffStore.createSession(
    title: "Handoff transaction binding",
    now: Date(timeIntervalSince1970: 1_722_000_000)
)
let handoffBaseline = try makeSnapshot(
    metadata: handoffMetadata,
    source: "0123456789 Alpha retry range. Handoff baseline authority.",
    highlights: "Handoff baseline summary",
    itemText: "Trust only the committed authority envelope.",
    retryID: "retry-handoff-baseline"
)
let handoffUpdated = try makeSnapshot(
    metadata: handoffMetadata,
    source: "UPDATED--- Alpha retry range. Handoff replacement authority.",
    highlights: "Handoff updated summary",
    itemText: "Reject a stale handoff transaction.",
    retryID: "retry-handoff-updated"
)
let handoffCommit = try handoffStore.commit(snapshot: handoffBaseline)
let handoffDateFormatter = DateFormatter()
handoffDateFormatter.locale = Locale(identifier: "en_US_POSIX")
handoffDateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
let handoffResult = try MeetingArtifactExporter.exportCurrentHandoff(
    commit: handoffCommit,
    codexHandoffDirectory: handoffDirectory,
    isRecording: true,
    dateFormatter: handoffDateFormatter
)
guard let handoffJSONURL = handoffResult.codexHandoffJSONURL else {
    throw StoreSmokeFailure.failed("v2 handoff JSON was not written")
}
let handoffJSON = try JSONSerialization.jsonObject(
    with: Data(contentsOf: handoffJSONURL)
) as? [String: Any]
try expect(handoffJSON?["schemaVersion"] as? Int == 2, "handoff did not publish schema v2")
try expect(
    handoffJSON?["sessionTransactionID"] as? String == handoffCommit.transactionID,
    "handoff transaction ID was not bound to the commit"
)
try expect(
    handoffJSON?["sessionStatePath"] as? String == handoffCommit.authoritativeStateURL.path,
    "handoff authority path was not bound to the commit"
)
try expect(
    handoffJSON?["sessionStateSchemaVersion"] as? Int == MeetingSessionStateEnvelope.currentSchemaVersion,
    "handoff authority schema was not declared"
)
try expect(
    handoffJSON?["compatibilityPathsTrusted"] as? Bool == false,
    "handoff did not explicitly mark compatibility paths untrusted"
)

let verifiedHandoffCommit = try handoffStore.readVerifiedCommit(
    at: handoffCommit.authoritativeStateURL,
    expectedTransactionID: handoffCommit.transactionID,
    expectedMeetingID: handoffMetadata.id
)
try expect(verifiedHandoffCommit == handoffCommit, "strict authority read did not reproduce the commit")

// A crash after a compatibility write must not make the v2 handoff trust that
// partial content. The old authority and transaction still verify exactly.
let compatibilityFaultingStore = MeetingSessionStore(
    rootDirectory: handoffRoot,
    faultInjector: { stage in
        if stage == .metadata {
            throw StoreSmokeFailure.injected(stage)
        }
    }
)
do {
    _ = try compatibilityFaultingStore.commit(snapshot: handoffUpdated)
    throw StoreSmokeFailure.failed("handoff compatibility fault was not injected")
} catch StoreSmokeFailure.injected(.metadata) {
    // Expected.
}
let verifiedAcrossCompatibilityFault = try handoffStore.readVerifiedCommit(
    at: handoffCommit.authoritativeStateURL,
    expectedTransactionID: handoffCommit.transactionID,
    expectedMeetingID: handoffMetadata.id
)
try expect(
    verifiedAcrossCompatibilityFault.snapshot == handoffBaseline,
    "torn compatibility files changed the handoff authority snapshot"
)

// Once a different authoritative transaction lands, a stale or tampered
// handoff must fail closed instead of following mutable compatibility paths.
let authorityFaultingStore = MeetingSessionStore(
    rootDirectory: handoffRoot,
    faultInjector: { stage in
        if stage == .authoritativeEnvelope {
            throw StoreSmokeFailure.injected(stage)
        }
    }
)
do {
    _ = try authorityFaultingStore.commit(snapshot: handoffUpdated)
    throw StoreSmokeFailure.failed("handoff authority fault was not injected")
} catch StoreSmokeFailure.injected(.authoritativeEnvelope) {
    // Expected: authority committed, but no MeetingSessionCommit was returned.
}
do {
    _ = try handoffStore.readVerifiedCommit(
        at: handoffCommit.authoritativeStateURL,
        expectedTransactionID: handoffCommit.transactionID,
        expectedMeetingID: handoffMetadata.id
    )
    throw StoreSmokeFailure.failed("stale handoff transaction verified after authority advanced")
} catch MeetingSessionStoreError.authorityTransactionMismatch {
    // Expected.
}
do {
    _ = try handoffStore.readVerifiedCommit(
        at: handoffCommit.authoritativeStateURL,
        expectedTransactionID: "tampered-transaction-id",
        expectedMeetingID: handoffMetadata.id
    )
    throw StoreSmokeFailure.failed("tampered handoff transaction verified")
} catch MeetingSessionStoreError.authorityTransactionMismatch {
    // Expected.
}
do {
    _ = try handoffStore.readVerifiedCommit(
        at: root.appendingPathComponent("outside/session_state_v1.json"),
        expectedTransactionID: handoffCommit.transactionID,
        expectedMeetingID: handoffMetadata.id
    )
    throw StoreSmokeFailure.failed("handoff authority outside the meeting root verified")
} catch MeetingSessionStoreError.untrustedAuthorityPath {
    // Expected.
}

// A many/long-meeting history refresh reads one lightweight index per row and
// never touches transcript-bearing authoritative envelopes. Repeated row badge
// evaluation then stays entirely in memory.
let historyPerformanceRoot = root.appendingPathComponent("history-index-performance", isDirectory: true)
let historyWriter = MeetingSessionStore(rootDirectory: historyPerformanceRoot)
let longMeetingCount = 18
let longTranscriptTail = String(repeating: "Long synthetic transcript payload for performance coverage. ", count: 1_500)
for index in 0..<longMeetingCount {
    let longMetadata = try historyWriter.createSession(
        title: "Long meeting \(index)",
        now: Date(timeIntervalSince1970: 1_730_000_000 + Double(index))
    )
    let longSnapshot = try makeSnapshot(
        metadata: longMetadata,
        source: "0123456789 Alpha retry range. \(longTranscriptTail)",
        highlights: "Long meeting \(index) synthetic summary",
        itemText: "Preserve lightweight validity for meeting \(index).",
        retryID: "retry-long-\(index)"
    )
    _ = try historyWriter.save(snapshot: longSnapshot)
}

var historyReads: [MeetingSessionStoreReadStage] = []
let historyReader = MeetingSessionStore(
    rootDirectory: historyPerformanceRoot,
    readObserver: { historyReads.append($0) }
)
let longHistory = try historyReader.loadHistoryRecords()
try expect(longHistory.count == longMeetingCount, "long-meeting history lost rows")
try expect(
    historyReads.filter { $0 == .historyIndex }.count == longMeetingCount,
    "history refresh did not read exactly one lightweight index per meeting"
)
try expect(
    !historyReads.contains(.authoritativeEnvelope),
    "routine history refresh decoded a transcript-bearing authoritative envelope"
)
try expect(
    !historyReads.contains(.compatibilityMetadata) && !historyReads.contains(.compatibilitySummaryDocument),
    "indexed history unexpectedly fell back to compatibility files"
)

let rowCache = MeetingSessionHistoryCache(records: longHistory)
let readsBeforeBadgeRendering = historyReads.count
for _ in 0..<1_000 {
    for record in longHistory {
        try expect(
            rowCache.isMeaningfulForHandoff(record.metadata),
            "cached history validity changed during row rendering"
        )
    }
}
try expect(
    historyReads.count == readsBeforeBadgeRendering,
    "row validity rendering performed filesystem reads"
)

// Persisted retry records are semantically validated before the app can use
// them. Ambiguous, stale, malformed, or source-mismatched records are isolated.
let authoritativeURL = folderURL.appendingPathComponent("session_state_v1.json")
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
var envelope = try decoder.decode(
    MeetingSessionStateEnvelope.self,
    from: Data(contentsOf: authoritativeURL)
)
let validRetry = baseline.summaryRetries[0]
var blankID = validRetry
blankID.id = "   "
var duplicateA = validRetry
duplicateA.id = "duplicate"
var duplicateB = validRetry
duplicateB.id = "duplicate"
var invalidBounds = validRetry
invalidBounds.id = "bad-bounds"
invalidBounds.rangeEnd = baseline.summarySourceTranscript.count + 1
var negativeAttempts = validRetry
negativeAttempts.id = "negative-attempts"
negativeAttempts.attempts = -1
var excessiveAttempts = validRetry
excessiveAttempts.id = "excessive-attempts"
excessiveAttempts.attempts = MeetingSummaryRetryValidator.maximumAttempts + 1
var mismatchedTranscript = validRetry
mismatchedTranscript.id = "mismatched-transcript"
mismatchedTranscript.transcript = "Different source text"
var staleFingerprint = validRetry
staleFingerprint.id = "stale-fingerprint"
staleFingerprint.sourcePrefixFingerprint = "0000000000000000"
var missingFingerprint = validRetry
missingFingerprint.id = "missing-fingerprint"
missingFingerprint.sourcePrefixFingerprint = nil
let invalidRetries = [
    blankID,
    duplicateA,
    duplicateB,
    invalidBounds,
    negativeAttempts,
    excessiveAttempts,
    mismatchedTranscript,
    staleFingerprint,
    missingFingerprint
]
try expect(
    MeetingSummaryRetryValidator.isExecutable(validRetry, against: baseline.summarySourceTranscript),
    "valid retry was rejected by the pre-network execution guard"
)
try expect(
    !MeetingSummaryRetryValidator.isExecutable(staleFingerprint, against: baseline.summarySourceTranscript),
    "stale retry passed the pre-network execution guard"
)
try expect(
    !MeetingSummaryRetryValidator.isExecutable(mismatchedTranscript, against: baseline.summarySourceTranscript),
    "source-mismatched retry passed the pre-network execution guard"
)
var exhaustedRetry = validRetry
exhaustedRetry.attempts = MeetingSummaryRetryValidator.maximumAttempts
try expect(
    !MeetingSummaryRetryValidator.isExecutable(exhaustedRetry, against: baseline.summarySourceTranscript),
    "exhausted retry passed the pre-network execution guard"
)
envelope.snapshot.summaryRetries = [validRetry] + invalidRetries
try encoder.encode(envelope).write(to: authoritativeURL, options: .atomic)

let retrySanitized = try store.loadSnapshot(metadata: metadata)
try expect(retrySanitized.summaryRetries == [validRetry], "invalid retries reached the executable retry ledger")
try expect(
    retrySanitized.quarantinedSummaryRetries.count == invalidRetries.count,
    "invalid retries were not quarantined"
)
try expect(
    retrySanitized.summaryDocument.processing.retryUnits == validRetry.unitCount,
    "processing retry units were not reconciled to the validated ledger"
)

try Data("{not-valid-json".utf8).write(to: authoritativeURL, options: .atomic)
do {
    _ = try store.loadSnapshot(metadata: metadata)
    throw StoreSmokeFailure.failed("corrupt authoritative envelope silently downgraded")
} catch MeetingSessionStoreError.corruptSessionEnvelope {
    // Expected: corrupt authoritative evidence must not silently fall back.
}

print("Meeting session store crash-consistency, lightweight-history, and retry-validation smoke tests passed")
