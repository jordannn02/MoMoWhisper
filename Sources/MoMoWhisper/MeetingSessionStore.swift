import AppKit
import Foundation
import MoMoWhisperSessionCore
import MoMoWhisperSummaryCore

enum MeetingRecordingReadiness: String, Codable, Equatable {
    case notStarted
    case prepared
    case recording
    case writerStopped
    case unavailable
    case failed
    case legacyUnverified

    var verificationBoundary: String {
        switch self {
        case .notStarted:
            return "尚未準備錄音；沒有可驗證的音訊。"
        case .prepared:
            return "已配置唯一輸出路徑；尚未驗證 writer 已寫入任何音訊。"
        case .recording:
            return "writer 目前接收音訊；尚未驗證時長、可播放性或完整性。"
        case .writerStopped:
            return "writer 已停止；檔案路徑或存在狀態不代表音訊已通過完整性驗證。"
        case .unavailable:
            return "writer 已停止但沒有可用輸出檔；不可視為有效錄音。"
        case .failed:
            return "錄音 writer 曾失敗；不可視為有效錄音。"
        case .legacyUnverified:
            return "舊版 metadata 只有單一路徑；無法據此判定完整性。"
        }
    }
}

struct MeetingRecordingPart: Codable, Identifiable, Equatable {
    var id: UUID
    var sequence: Int
    var filePath: String
    var startedAt: Date
    var endedAt: Date?
    var readiness: MeetingRecordingReadiness
}

struct MeetingSessionMetadata: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var startedAt: Date
    var updatedAt: Date
    var endedAt: Date?
    var folderName: String
    var transcriptCharacterCount: Int
    var highlightCharacterCount: Int
    var summaryProvider: String
    var transcriptionEngine: String
    var audioCaptureMode: String
    var recordingFilePath: String?
    var recordingParts: [MeetingRecordingPart]
    var recordingReadiness: MeetingRecordingReadiness
    var recordingReadinessDetail: String
    var exportedHighlightsFilePath: String?
    var codexHandoffFilePath: String?

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名會議" : title
    }

    init(
        id: UUID,
        title: String,
        startedAt: Date,
        updatedAt: Date,
        endedAt: Date?,
        folderName: String,
        transcriptCharacterCount: Int,
        highlightCharacterCount: Int,
        summaryProvider: String,
        transcriptionEngine: String,
        audioCaptureMode: String,
        recordingFilePath: String?,
        recordingParts: [MeetingRecordingPart] = [],
        recordingReadiness: MeetingRecordingReadiness = .notStarted,
        recordingReadinessDetail: String? = nil,
        exportedHighlightsFilePath: String?,
        codexHandoffFilePath: String?
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.endedAt = endedAt
        self.folderName = folderName
        self.transcriptCharacterCount = transcriptCharacterCount
        self.highlightCharacterCount = highlightCharacterCount
        self.summaryProvider = summaryProvider
        self.transcriptionEngine = transcriptionEngine
        self.audioCaptureMode = audioCaptureMode
        self.recordingFilePath = recordingFilePath
        self.recordingParts = recordingParts
        self.recordingReadiness = recordingReadiness
        self.recordingReadinessDetail = recordingReadinessDetail ?? recordingReadiness.verificationBoundary
        self.exportedHighlightsFilePath = exportedHighlightsFilePath
        self.codexHandoffFilePath = codexHandoffFilePath
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case startedAt
        case updatedAt
        case endedAt
        case folderName
        case transcriptCharacterCount
        case highlightCharacterCount
        case summaryProvider
        case transcriptionEngine
        case audioCaptureMode
        case recordingFilePath
        case recordingParts
        case recordingReadiness
        case recordingReadinessDetail
        case exportedHighlightsFilePath
        case codexHandoffFilePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let title = try container.decode(String.self, forKey: .title)
        let startedAt = try container.decode(Date.self, forKey: .startedAt)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        let endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        let recordingFilePath = try container.decodeIfPresent(String.self, forKey: .recordingFilePath)
        let decodedParts = try container.decodeIfPresent([MeetingRecordingPart].self, forKey: .recordingParts)
        let fallbackReadiness: MeetingRecordingReadiness = recordingFilePath == nil ? .notStarted : .legacyUnverified
        let recordingReadiness = try container.decodeIfPresent(MeetingRecordingReadiness.self, forKey: .recordingReadiness)
            ?? fallbackReadiness
        let recordingParts = decodedParts ?? recordingFilePath.map { path in
            [
                MeetingRecordingPart(
                    id: UUID(),
                    sequence: 1,
                    filePath: path,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    readiness: .legacyUnverified
                )
            ]
        } ?? []

        self.init(
            id: id,
            title: title,
            startedAt: startedAt,
            updatedAt: updatedAt,
            endedAt: endedAt,
            folderName: try container.decode(String.self, forKey: .folderName),
            transcriptCharacterCount: try container.decode(Int.self, forKey: .transcriptCharacterCount),
            highlightCharacterCount: try container.decode(Int.self, forKey: .highlightCharacterCount),
            summaryProvider: try container.decode(String.self, forKey: .summaryProvider),
            transcriptionEngine: try container.decode(String.self, forKey: .transcriptionEngine),
            audioCaptureMode: try container.decode(String.self, forKey: .audioCaptureMode),
            recordingFilePath: recordingFilePath,
            recordingParts: recordingParts,
            recordingReadiness: recordingReadiness,
            recordingReadinessDetail: try container.decodeIfPresent(String.self, forKey: .recordingReadinessDetail),
            exportedHighlightsFilePath: try container.decodeIfPresent(String.self, forKey: .exportedHighlightsFilePath),
            codexHandoffFilePath: try container.decodeIfPresent(String.self, forKey: .codexHandoffFilePath)
        )
    }
}

struct MeetingSessionSnapshot: Codable, Equatable {
    var metadata: MeetingSessionMetadata
    var transcriptSegments: [TranscriptSegment]
    var transcriptMarkdown: String
    var summarySourceTranscript: String
    var highlightsMarkdown: String
    var rawSummaryState: LiveMeetingSummaryState
    var summaryDocument: MeetingSummaryDocument
    var summaryRetries: [MeetingSummaryRetryRecord]
    var quarantinedSummaryRetries: [MeetingSummaryRetryRecord]

    init(
        metadata: MeetingSessionMetadata,
        transcriptSegments: [TranscriptSegment],
        transcriptMarkdown: String,
        summarySourceTranscript: String? = nil,
        highlightsMarkdown: String,
        rawSummaryState: LiveMeetingSummaryState,
        summaryDocument: MeetingSummaryDocument? = nil,
        summaryRetries: [MeetingSummaryRetryRecord] = [],
        quarantinedSummaryRetries: [MeetingSummaryRetryRecord] = []
    ) {
        self.metadata = metadata
        self.transcriptSegments = transcriptSegments
        self.transcriptMarkdown = transcriptMarkdown
        self.summarySourceTranscript = summarySourceTranscript
            ?? transcriptMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        self.highlightsMarkdown = highlightsMarkdown
        self.rawSummaryState = rawSummaryState
        self.summaryDocument = summaryDocument ?? MeetingSummaryMigration.migrate(
            rawSummaryState.legacySummaryState,
            meetingID: metadata.id.uuidString,
            title: metadata.displayTitle
        )
        self.summaryRetries = summaryRetries
        self.quarantinedSummaryRetries = quarantinedSummaryRetries
    }
}

struct MeetingSummaryRetryRecord: Codable, Equatable {
    var id: String
    var transcript: String
    var recentTranscript: String
    var rangeStart: Int
    var rangeEnd: Int
    var isFinal: Bool
    var attempts: Int
    var sourcePrefixFingerprint: String?

    var unitCount: Int {
        max(0, rangeEnd - rangeStart)
    }
}

struct MeetingSummaryV2Envelope: Codable, Equatable {
    var document: MeetingSummaryDocument
    var retries: [MeetingSummaryRetryRecord]
}

struct MeetingSessionStateEnvelope: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var transactionID: String
    var snapshot: MeetingSessionSnapshot

    init(transactionID: String, snapshot: MeetingSessionSnapshot) {
        schemaVersion = Self.currentSchemaVersion
        self.transactionID = transactionID
        self.snapshot = snapshot
    }
}

/// A complete session snapshot that has crossed the authoritative-envelope
/// commit boundary. Compatibility files in the same folder are deliberately
/// excluded: downstream handoffs must bind to this transaction and URL.
struct MeetingSessionCommit: Equatable {
    let transactionID: String
    let snapshot: MeetingSessionSnapshot
    let authoritativeStateURL: URL

    fileprivate init(
        transactionID: String,
        snapshot: MeetingSessionSnapshot,
        authoritativeStateURL: URL
    ) {
        self.transactionID = transactionID
        self.snapshot = snapshot
        self.authoritativeStateURL = authoritativeStateURL
    }

    var authoritativeStateSchemaVersion: Int {
        MeetingSessionStateEnvelope.currentSchemaVersion
    }
}

struct MeetingSessionPendingTransaction: Codable, Equatable {
    var transactionID: String
}

/// Small, post-commit history record. The complete session envelope remains the
/// only authority for loading meeting content; this record exists so history
/// lists and trust badges never need to decode transcripts on the main actor.
struct MeetingSessionHistoryRecord: Codable, Equatable, Identifiable {
    var metadata: MeetingSessionMetadata
    var isMeaningfulForHandoff: Bool

    var id: UUID { metadata.id }

    init(metadata: MeetingSessionMetadata, isMeaningfulForHandoff: Bool) {
        self.metadata = metadata
        self.isMeaningfulForHandoff = isMeaningfulForHandoff
    }

    init(snapshot: MeetingSessionSnapshot) {
        metadata = snapshot.metadata
        isMeaningfulForHandoff = MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: snapshot.metadata.transcriptCharacterCount,
            summaryDocument: snapshot.summaryDocument
        )
    }
}

struct MeetingSessionHistoryIndexEnvelope: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var transactionID: String
    var record: MeetingSessionHistoryRecord

    init(
        transactionID: String,
        snapshot: MeetingSessionSnapshot
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.transactionID = transactionID
        record = MeetingSessionHistoryRecord(snapshot: snapshot)
    }
}

/// Pure in-memory lookup used by SwiftUI-facing code. Repeated badge rendering
/// is therefore O(1) and performs no filesystem access.
struct MeetingSessionHistoryCache {
    private var meaningfulByID: [UUID: Bool] = [:]

    init(records: [MeetingSessionHistoryRecord] = []) {
        replace(with: records)
    }

    mutating func replace(with records: [MeetingSessionHistoryRecord]) {
        meaningfulByID = [:]
        for record in records where meaningfulByID[record.metadata.id] == nil {
            meaningfulByID[record.metadata.id] = record.isMeaningfulForHandoff
        }
    }

    mutating func upsert(_ record: MeetingSessionHistoryRecord) {
        meaningfulByID[record.metadata.id] = record.isMeaningfulForHandoff
    }

    mutating func remove(id: UUID) {
        meaningfulByID.removeValue(forKey: id)
    }

    func isMeaningfulForHandoff(_ metadata: MeetingSessionMetadata) -> Bool {
        meaningfulByID[metadata.id]
            ?? (metadata.transcriptCharacterCount >= MeetingSummaryHandoffValidity.defaultMinimumTranscriptCharacters)
    }
}

enum MeetingSessionStoreWriteStage: String, CaseIterable {
    case pendingTransaction
    case metadata
    case transcriptSegments
    case summaryV2CompatibilityEnvelope
    case rawSummaryState
    case summaryDocument
    case summaryRetryState
    case transcriptMarkdown
    case highlightsMarkdown
    case authoritativeEnvelope
    case historyIndex
}

enum MeetingSessionStoreReadStage: String, Equatable {
    case authoritativeEnvelope
    case historyIndex
    case pendingTransaction
    case compatibilityMetadata
    case compatibilitySummaryDocument
}

private struct MeetingSessionHistoryRecoveryCacheEntry {
    var pendingTransactionID: String
    var record: MeetingSessionHistoryRecord
}

struct MeetingSummaryRetryValidationResult: Equatable {
    var valid: [MeetingSummaryRetryRecord]
    var quarantined: [MeetingSummaryRetryRecord]
}

enum MeetingSummaryRetryValidator {
    static let maximumAttempts = 3

    static func validate(
        _ retries: [MeetingSummaryRetryRecord],
        against sourceTranscript: String
    ) -> MeetingSummaryRetryValidationResult {
        let normalizedIDs = retries.map {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let idCounts = Dictionary(grouping: normalizedIDs, by: { $0 }).mapValues(\.count)
        var valid: [MeetingSummaryRetryRecord] = []
        var quarantined: [MeetingSummaryRetryRecord] = []

        for (retry, normalizedID) in zip(retries, normalizedIDs) {
            let hasUniqueID = !normalizedID.isEmpty && idCounts[normalizedID] == 1
            let hasValidBounds = retry.rangeStart >= 0
                && retry.rangeEnd > retry.rangeStart
                && retry.rangeEnd <= sourceTranscript.count
            let hasValidAttempts = (0...maximumAttempts).contains(retry.attempts)
            let expectedTranscript = hasValidBounds
                ? exactSubstring(
                    sourceTranscript,
                    rangeStart: retry.rangeStart,
                    rangeEnd: retry.rangeEnd
                )
                : nil
            let hasExactTranscript = expectedTranscript == retry.transcript
                && !retry.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let persistedFingerprint = retry.sourcePrefixFingerprint?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedFingerprint = hasValidBounds
                ? sourcePrefixFingerprint(sourceTranscript, endOffset: retry.rangeEnd)
                : nil
            let hasExactFingerprint = persistedFingerprint != nil
                && persistedFingerprint == expectedFingerprint

            if hasUniqueID,
               hasValidBounds,
               hasValidAttempts,
               hasExactTranscript,
               hasExactFingerprint {
                var normalized = retry
                normalized.id = normalizedID
                normalized.sourcePrefixFingerprint = persistedFingerprint
                valid.append(normalized)
            } else {
                quarantined.append(retry)
            }
        }

        return .init(valid: valid, quarantined: quarantined)
    }

    static func sourcePrefixFingerprint(_ transcript: String, endOffset: Int) -> String {
        let boundedEnd = min(max(0, endOffset), transcript.count)
        return SummaryPipelineIdentity.rawOperationsFingerprint(
            Data(String(transcript.prefix(boundedEnd)).utf8)
        )
    }

    static func isExecutable(
        _ retry: MeetingSummaryRetryRecord,
        against sourceTranscript: String
    ) -> Bool {
        validate([retry], against: sourceTranscript).valid.count == 1
            && retry.attempts < maximumAttempts
    }

    private static func exactSubstring(
        _ transcript: String,
        rangeStart: Int,
        rangeEnd: Int
    ) -> String {
        let start = transcript.index(transcript.startIndex, offsetBy: rangeStart)
        let end = transcript.index(transcript.startIndex, offsetBy: rangeEnd)
        return String(transcript[start..<end])
    }
}

enum MeetingSessionStoreError: LocalizedError {
    case corruptSummaryDocument(path: String, underlying: Error)
    case corruptSummaryRetryState(path: String, underlying: Error)
    case corruptSummaryEnvelope(path: String, underlying: Error)
    case corruptSessionEnvelope(path: String, underlying: Error)
    case incompleteSessionTransaction(path: String)
    case untrustedAuthorityPath(path: String)
    case authorityTransactionMismatch(path: String, expected: String, actual: String)
    case authorityMeetingMismatch(path: String, expected: UUID, actual: UUID)

    var errorDescription: String? {
        switch self {
        case let .corruptSummaryDocument(path, _):
            return "結構化摘要檔損壞，已停止載入以避免誤用舊資料：\(path)"
        case let .corruptSummaryRetryState(path, _):
            return "摘要重試狀態檔損壞，已停止載入以避免遺失未完成範圍：\(path)"
        case let .corruptSummaryEnvelope(path, _):
            return "摘要 V2 狀態封包損壞，已停止載入以避免文件與重試範圍不一致：\(path)"
        case let .corruptSessionEnvelope(path, _):
            return "會議完整狀態封包損壞，已停止載入以避免逐字稿、摘要與 metadata 混用：\(path)"
        case let .incompleteSessionTransaction(path):
            return "會議保存交易尚未完成，沒有可安全載入的完整快照：\(path)"
        case let .untrustedAuthorityPath(path):
            return "handoff 指向的會議權威檔不在可信任的 session 路徑內：\(path)"
        case let .authorityTransactionMismatch(path, expected, actual):
            return "handoff 交易與會議權威檔不一致，已拒絕載入：\(path) (expected \(expected), actual \(actual))"
        case let .authorityMeetingMismatch(path, expected, actual):
            return "handoff 會議 ID 與會議權威檔不一致，已拒絕載入：\(path) (expected \(expected), actual \(actual))"
        }
    }
}

final class MeetingSessionStore {
    private let fileManager = FileManager.default
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder
    private let faultInjector: ((MeetingSessionStoreWriteStage) throws -> Void)?
    private let readObserver: ((MeetingSessionStoreReadStage) -> Void)?
    private var recoveredHistoryByFolder: [String: MeetingSessionHistoryRecoveryCacheEntry] = [:]

    let rootDirectory: URL

    init(
        rootDirectory: URL = MeetingSessionStore.defaultRootDirectory,
        readObserver: ((MeetingSessionStoreReadStage) -> Void)? = nil,
        faultInjector: ((MeetingSessionStoreWriteStage) throws -> Void)? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.faultInjector = faultInjector
        self.readObserver = readObserver
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        jsonEncoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        jsonDecoder = decoder
    }

    static var defaultRootDirectory: URL {
        MoMoWhisperStorage.meetingsDirectory
    }

    func createSession(title: String?, now: Date = Date()) throws -> MeetingSessionMetadata {
        try ensureRootDirectory()
        let displayTitle = normalizedTitle(title, startedAt: now)
        let folderName = makeFolderName(title: displayTitle, startedAt: now)
        let folderURL = rootDirectory.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return MeetingSessionMetadata(
            id: UUID(),
            title: displayTitle,
            startedAt: now,
            updatedAt: now,
            endedAt: nil,
            folderName: folderName,
            transcriptCharacterCount: 0,
            highlightCharacterCount: 0,
            summaryProvider: "",
            transcriptionEngine: "",
            audioCaptureMode: "",
            recordingFilePath: nil,
            recordingParts: [],
            recordingReadiness: .notStarted,
            exportedHighlightsFilePath: nil,
            codexHandoffFilePath: nil
        )
    }

    @discardableResult
    func save(snapshot: MeetingSessionSnapshot) throws -> MeetingSessionMetadata {
        try commit(snapshot: snapshot).snapshot.metadata
    }

    /// Persists one complete snapshot and returns proof of the committed
    /// authoritative transaction. Callers must use this value, rather than the
    /// mutable compatibility files, when publishing a downstream handoff.
    @discardableResult
    func commit(snapshot: MeetingSessionSnapshot) throws -> MeetingSessionCommit {
        try ensureRootDirectory()
        let folderURL = sessionFolderURL(for: snapshot.metadata)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        try MeetingSummaryDocumentValidator.validate(snapshot.summaryDocument)
        var committedSnapshot = sanitizedSnapshot(snapshot)
        committedSnapshot.quarantinedSummaryRetries = []
        let transactionID = UUID().uuidString
        let pendingURL = folderURL.appendingPathComponent(Self.pendingTransactionFileName)
        try validateSnapshotIntegrity(committedSnapshot, in: folderURL)

        try writeJSON(
            MeetingSessionPendingTransaction(transactionID: transactionID),
            to: pendingURL
        )
        try injectFault(after: .pendingTransaction)
        try writeJSON(committedSnapshot.metadata, to: folderURL.appendingPathComponent("metadata.json"))
        try injectFault(after: .metadata)
        try writeJSON(committedSnapshot.transcriptSegments, to: folderURL.appendingPathComponent("transcript.json"))
        try injectFault(after: .transcriptSegments)
        // The envelope is the atomic source of truth for V2 document + retry
        // ledger for legacy readers. The complete-session envelope below is the
        // final content-bearing commit for current readers; only the lightweight
        // post-commit history index is written after it.
        try writeJSON(
            MeetingSummaryV2Envelope(
                document: committedSnapshot.summaryDocument,
                retries: committedSnapshot.summaryRetries
            ),
            to: folderURL.appendingPathComponent("summary_v2_state.json")
        )
        try injectFault(after: .summaryV2CompatibilityEnvelope)
        try writeJSON(committedSnapshot.rawSummaryState, to: folderURL.appendingPathComponent("raw_summary_state.json"))
        try injectFault(after: .rawSummaryState)
        try writeJSON(committedSnapshot.summaryDocument, to: folderURL.appendingPathComponent("summary_document.json"))
        try injectFault(after: .summaryDocument)
        try writeJSON(committedSnapshot.summaryRetries, to: folderURL.appendingPathComponent("summary_retry_state.json"))
        try injectFault(after: .summaryRetryState)
        try writeText(committedSnapshot.transcriptMarkdown, to: folderURL.appendingPathComponent("transcript.md"))
        try injectFault(after: .transcriptMarkdown)
        try writeText(committedSnapshot.highlightsMarkdown, to: folderURL.appendingPathComponent("highlights.md"))
        try injectFault(after: .highlightsMarkdown)

        try writeJSON(
            MeetingSessionStateEnvelope(
                transactionID: transactionID,
                snapshot: committedSnapshot
            ),
            to: folderURL.appendingPathComponent(Self.authoritativeEnvelopeFileName)
        )
        try injectFault(after: .authoritativeEnvelope)
        // Commit the small history index only after the authoritative snapshot.
        // An older index is still a safe committed view if a crash occurs between
        // these writes; a missing index uses the explicit recovery path below.
        try writeJSON(
            MeetingSessionHistoryIndexEnvelope(
                transactionID: transactionID,
                snapshot: committedSnapshot
            ),
            to: folderURL.appendingPathComponent(Self.historyIndexFileName)
        )
        try injectFault(after: .historyIndex)
        try? fileManager.removeItem(at: pendingURL)
        recoveredHistoryByFolder.removeValue(forKey: folderURL.path)

        return MeetingSessionCommit(
            transactionID: transactionID,
            snapshot: committedSnapshot,
            authoritativeStateURL: folderURL.appendingPathComponent(Self.authoritativeEnvelopeFileName)
        )
    }

    /// Reads a handoff's authoritative envelope and fails closed unless its
    /// path, transaction ID, meeting ID, schema, and decodable snapshot
    /// structure agree. This is a consistency check, not a cryptographic
    /// anti-tamper signature, and is the only supported trust upgrade for
    /// compatibility paths.
    func readVerifiedCommit(
        at authoritativeStateURL: URL,
        expectedTransactionID: String,
        expectedMeetingID: UUID
    ) throws -> MeetingSessionCommit {
        let candidateURL = authoritativeStateURL.standardizedFileURL
        let resolvedCandidateURL = candidateURL.resolvingSymlinksInPath()
        let resolvedRootURL = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedFolderURL = resolvedCandidateURL.deletingLastPathComponent()
        let rootPath = resolvedRootURL.path.hasSuffix("/")
            ? resolvedRootURL.path
            : resolvedRootURL.path + "/"

        guard resolvedCandidateURL.lastPathComponent == Self.authoritativeEnvelopeFileName,
              resolvedFolderURL.path.hasPrefix(rootPath) else {
            throw MeetingSessionStoreError.untrustedAuthorityPath(path: candidateURL.path)
        }

        let envelope: MeetingSessionStateEnvelope
        do {
            envelope = try loadAuthoritativeEnvelope(
                at: resolvedCandidateURL,
                in: resolvedFolderURL
            )
        } catch let error as MeetingSessionStoreError {
            throw error
        } catch {
            throw MeetingSessionStoreError.corruptSessionEnvelope(
                path: candidateURL.path,
                underlying: error
            )
        }

        let normalizedExpectedTransactionID = expectedTransactionID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedExpectedTransactionID.isEmpty,
              envelope.transactionID == normalizedExpectedTransactionID else {
            throw MeetingSessionStoreError.authorityTransactionMismatch(
                path: candidateURL.path,
                expected: normalizedExpectedTransactionID,
                actual: envelope.transactionID
            )
        }
        guard envelope.snapshot.metadata.id == expectedMeetingID else {
            throw MeetingSessionStoreError.authorityMeetingMismatch(
                path: candidateURL.path,
                expected: expectedMeetingID,
                actual: envelope.snapshot.metadata.id
            )
        }

        return MeetingSessionCommit(
            transactionID: envelope.transactionID,
            snapshot: envelope.snapshot,
            authoritativeStateURL: candidateURL
        )
    }

    func loadCommit(metadata: MeetingSessionMetadata) throws -> MeetingSessionCommit {
        let folderURL = sessionFolderURL(for: metadata)
        let envelope = try loadAuthoritativeEnvelope(from: folderURL)
        guard envelope.snapshot.metadata.id == metadata.id else {
            throw MeetingSessionStoreError.authorityMeetingMismatch(
                path: authoritativeStateURL(for: metadata).path,
                expected: metadata.id,
                actual: envelope.snapshot.metadata.id
            )
        }
        return MeetingSessionCommit(
            transactionID: envelope.transactionID,
            snapshot: envelope.snapshot,
            authoritativeStateURL: authoritativeStateURL(for: metadata)
        )
    }

    func loadMetadata() throws -> [MeetingSessionMetadata] {
        try loadHistoryRecords().map(\.metadata)
    }

    func loadHistoryRecords() throws -> [MeetingSessionHistoryRecord] {
        try ensureRootDirectory()
        let folders = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return folders.compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            return historyRecord(from: folder)
        }
        .sorted { $0.metadata.updatedAt > $1.metadata.updatedAt }
    }

    func searchMetadata(query: String) throws -> [MeetingSessionMetadata] {
        try searchHistoryRecords(query: query).map(\.metadata)
    }

    func searchHistoryRecords(query: String) throws -> [MeetingSessionHistoryRecord] {
        let allRecords = try loadHistoryRecords()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return allRecords
        }

        let keywords = trimmedQuery
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        return allRecords.filter { record in
            let metadata = record.metadata
            let haystack = [
                metadata.title,
                metadata.folderName,
                metadata.summaryProvider,
                metadata.transcriptionEngine,
                metadata.audioCaptureMode,
                Self.displayDateFormatter.string(from: metadata.startedAt)
            ]
            .joined(separator: " ")
            .lowercased()

            return keywords.allSatisfy { haystack.contains($0) }
        }
    }

    func loadSnapshot(metadata: MeetingSessionMetadata) throws -> MeetingSessionSnapshot {
        let folderURL = sessionFolderURL(for: metadata)
        let authoritativeURL = folderURL.appendingPathComponent(Self.authoritativeEnvelopeFileName)
        if fileManager.fileExists(atPath: authoritativeURL.path) {
            do {
                return try loadAuthoritativeSnapshot(from: folderURL)
            } catch {
                throw MeetingSessionStoreError.corruptSessionEnvelope(
                    path: authoritativeURL.path,
                    underlying: error
                )
            }
        }
        let pendingURL = folderURL.appendingPathComponent(Self.pendingTransactionFileName)
        if fileManager.fileExists(atPath: pendingURL.path) {
            throw MeetingSessionStoreError.incompleteSessionTransaction(path: pendingURL.path)
        }
        let storedMetadata = try readJSON(MeetingSessionMetadata.self, from: folderURL.appendingPathComponent("metadata.json"))
        let transcriptSegments = (try? readJSON([TranscriptSegment].self, from: folderURL.appendingPathComponent("transcript.json"))) ?? []
        let rawSummaryState = (try? readJSON(LiveMeetingSummaryState.self, from: folderURL.appendingPathComponent("raw_summary_state.json"))) ?? .empty
        let transcriptMarkdown = (try? String(contentsOf: folderURL.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
        let highlightsMarkdown = (try? String(contentsOf: folderURL.appendingPathComponent("highlights.md"), encoding: .utf8)) ?? ""
        let summaryEnvelopeURL = folderURL.appendingPathComponent("summary_v2_state.json")
        let summaryDocumentURL = folderURL.appendingPathComponent("summary_document.json")
        let summaryRetryURL = folderURL.appendingPathComponent("summary_retry_state.json")
        let summaryDocument: MeetingSummaryDocument
        let summaryRetries: [MeetingSummaryRetryRecord]
        if fileManager.fileExists(atPath: summaryEnvelopeURL.path) {
            do {
                let envelope = try readJSON(MeetingSummaryV2Envelope.self, from: summaryEnvelopeURL)
                try MeetingSummaryDocumentValidator.validate(envelope.document)
                summaryDocument = envelope.document
                summaryRetries = MeetingSummaryRetryValidator.validate(
                    envelope.retries,
                    against: transcriptMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
                ).valid
            } catch {
                throw MeetingSessionStoreError.corruptSummaryEnvelope(
                    path: summaryEnvelopeURL.path,
                    underlying: error
                )
            }
        } else if fileManager.fileExists(atPath: summaryDocumentURL.path) {
            do {
                summaryDocument = try readJSON(MeetingSummaryDocument.self, from: summaryDocumentURL)
                try MeetingSummaryDocumentValidator.validate(summaryDocument)
            } catch {
                throw MeetingSessionStoreError.corruptSummaryDocument(path: summaryDocumentURL.path, underlying: error)
            }
            if fileManager.fileExists(atPath: summaryRetryURL.path) {
                do {
                    summaryRetries = MeetingSummaryRetryValidator.validate(
                        try readJSON([MeetingSummaryRetryRecord].self, from: summaryRetryURL),
                        against: transcriptMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
                    ).valid
                } catch {
                    throw MeetingSessionStoreError.corruptSummaryRetryState(path: summaryRetryURL.path, underlying: error)
                }
            } else {
                summaryRetries = []
            }
        } else {
            summaryDocument = MeetingSummaryMigration.migrate(
                rawSummaryState.legacySummaryState,
                meetingID: storedMetadata.id.uuidString,
                title: storedMetadata.displayTitle
            )
            summaryRetries = []
        }

        return MeetingSessionSnapshot(
            metadata: storedMetadata,
            transcriptSegments: transcriptSegments,
            transcriptMarkdown: transcriptMarkdown,
            summarySourceTranscript: transcriptMarkdown.trimmingCharacters(in: .whitespacesAndNewlines),
            highlightsMarkdown: highlightsMarkdown,
            rawSummaryState: rawSummaryState,
            summaryDocument: summaryDocument,
            summaryRetries: summaryRetries
        )
    }

    func sessionFolderURL(for metadata: MeetingSessionMetadata) -> URL {
        rootDirectory.appendingPathComponent(metadata.folderName, isDirectory: true)
    }

    func authoritativeStateURL(for metadata: MeetingSessionMetadata) -> URL {
        sessionFolderURL(for: metadata)
            .appendingPathComponent(Self.authoritativeEnvelopeFileName)
    }

    private func historyRecord(from folderURL: URL) -> MeetingSessionHistoryRecord? {
        let indexURL = folderURL.appendingPathComponent(Self.historyIndexFileName)
        var indexEnvelope: MeetingSessionHistoryIndexEnvelope?
        if fileManager.fileExists(atPath: indexURL.path) {
            readObserver?(.historyIndex)
            if let envelope = try? readJSON(MeetingSessionHistoryIndexEnvelope.self, from: indexURL),
               envelope.schemaVersion == MeetingSessionHistoryIndexEnvelope.currentSchemaVersion,
               !envelope.transactionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               envelope.record.metadata.folderName == folderURL.lastPathComponent {
                indexEnvelope = envelope
            }
        }

        let pendingURL = folderURL.appendingPathComponent(Self.pendingTransactionFileName)
        guard fileManager.fileExists(atPath: pendingURL.path) else {
            return indexEnvelope?.record ?? compatibilityHistoryRecord(from: folderURL)
        }

        readObserver?(.pendingTransaction)
        guard let pending = try? readJSON(MeetingSessionPendingTransaction.self, from: pendingURL),
              !pending.transactionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A valid committed index remains safe even if a stale marker is
            // damaged. Without one, fail closed rather than read torn files.
            return indexEnvelope?.record
        }

        if let cached = recoveredHistoryByFolder[folderURL.path],
           cached.pendingTransactionID == pending.transactionID {
            return cached.record
        }

        if let indexEnvelope, indexEnvelope.transactionID == pending.transactionID {
            // The index and authority were both committed; the process only
            // failed before removing the pending marker.
            return indexEnvelope.record
        }

        let authoritativeURL = folderURL.appendingPathComponent(Self.authoritativeEnvelopeFileName)
        guard fileManager.fileExists(atPath: authoritativeURL.path),
              let authoritative = try? loadAuthoritativeEnvelope(from: folderURL) else {
            return indexEnvelope?.record
        }

        let recoveredRecord: MeetingSessionHistoryRecord
        if let indexEnvelope,
           authoritative.transactionID == indexEnvelope.transactionID,
           authoritative.transactionID != pending.transactionID {
            // The new transaction stopped before authority commit. Keep the
            // previously committed lightweight view.
            recoveredRecord = indexEnvelope.record
        } else {
            // Authority matches the pending transaction (or is otherwise the
            // only valid committed evidence), so derive the lightweight record
            // once. The full envelope is never used as a routine history path.
            recoveredRecord = MeetingSessionHistoryRecord(snapshot: authoritative.snapshot)
        }
        recoveredHistoryByFolder[folderURL.path] = MeetingSessionHistoryRecoveryCacheEntry(
            pendingTransactionID: pending.transactionID,
            record: recoveredRecord
        )
        return recoveredRecord
    }

    private func compatibilityHistoryRecord(
        from folderURL: URL
    ) -> MeetingSessionHistoryRecord? {
        let metadataURL = folderURL.appendingPathComponent("metadata.json")
        readObserver?(.compatibilityMetadata)
        guard let metadata = try? readJSON(MeetingSessionMetadata.self, from: metadataURL),
              metadata.folderName == folderURL.lastPathComponent else {
            return nil
        }

        let isMeaningful: Bool
        if metadata.transcriptCharacterCount >= MeetingSummaryHandoffValidity.defaultMinimumTranscriptCharacters {
            isMeaningful = true
        } else {
            let summaryURL = folderURL.appendingPathComponent("summary_document.json")
            if fileManager.fileExists(atPath: summaryURL.path) {
                readObserver?(.compatibilitySummaryDocument)
            }
            if let document = try? readJSON(MeetingSummaryDocument.self, from: summaryURL),
               (try? MeetingSummaryDocumentValidator.validate(document)) != nil,
               document.id == metadata.id.uuidString {
                isMeaningful = MeetingSummaryHandoffValidity.hasSemanticContent(document)
            } else {
                isMeaningful = false
            }
        }

        return MeetingSessionHistoryRecord(
            metadata: metadata,
            isMeaningfulForHandoff: isMeaningful
        )
    }

    private func ensureRootDirectory() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    private func loadAuthoritativeSnapshot(from folderURL: URL) throws -> MeetingSessionSnapshot {
        try loadAuthoritativeEnvelope(from: folderURL).snapshot
    }

    private func loadAuthoritativeEnvelope(from folderURL: URL) throws -> MeetingSessionStateEnvelope {
        try loadAuthoritativeEnvelope(
            at: folderURL.appendingPathComponent(Self.authoritativeEnvelopeFileName),
            in: folderURL
        )
    }

    private func loadAuthoritativeEnvelope(
        at authoritativeURL: URL,
        in folderURL: URL
    ) throws -> MeetingSessionStateEnvelope {
        readObserver?(.authoritativeEnvelope)
        var envelope = try readJSON(
            MeetingSessionStateEnvelope.self,
            from: authoritativeURL
        )
        guard envelope.schemaVersion == MeetingSessionStateEnvelope.currentSchemaVersion else {
            throw CocoaError(.coderReadCorrupt)
        }
        guard !envelope.transactionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CocoaError(.coderReadCorrupt)
        }
        envelope.snapshot = sanitizedSnapshot(envelope.snapshot)
        try validateSnapshotIntegrity(envelope.snapshot, in: folderURL)
        return envelope
    }

    private func sanitizedSnapshot(_ snapshot: MeetingSessionSnapshot) -> MeetingSessionSnapshot {
        var sanitized = snapshot
        let retryValidation = MeetingSummaryRetryValidator.validate(
            snapshot.summaryRetries,
            against: snapshot.summarySourceTranscript
        )
        sanitized.summaryRetries = retryValidation.valid
        sanitized.quarantinedSummaryRetries = snapshot.quarantinedSummaryRetries + retryValidation.quarantined
        sanitized.summaryDocument.processing.retryUnits = retryValidation.valid
            .filter { $0.attempts < MeetingSummaryRetryValidator.maximumAttempts }
            .reduce(0) { $0 + $1.unitCount }
        return sanitized
    }

    private func validateSnapshotIntegrity(
        _ snapshot: MeetingSessionSnapshot,
        in folderURL: URL
    ) throws {
        let sourceIsRepresentedInTranscript = snapshot.summarySourceTranscript.isEmpty
            || snapshot.transcriptMarkdown == snapshot.summarySourceTranscript
            || snapshot.transcriptMarkdown.hasPrefix(snapshot.summarySourceTranscript + "\n")
        guard snapshot.metadata.folderName == folderURL.lastPathComponent,
              snapshot.summaryDocument.id == snapshot.metadata.id.uuidString,
              snapshot.metadata.transcriptCharacterCount == snapshot.transcriptMarkdown.count,
              snapshot.metadata.highlightCharacterCount == snapshot.highlightsMarkdown.count,
              snapshot.summaryDocument.processing.totalUnits == snapshot.summarySourceTranscript.count,
              sourceIsRepresentedInTranscript else {
            throw CocoaError(.coderReadCorrupt)
        }
        try MeetingSummaryDocumentValidator.validate(snapshot.summaryDocument)
    }

    private func injectFault(after stage: MeetingSessionStoreWriteStage) throws {
        try faultInjector?(stage)
    }

    private func normalizedTitle(_ title: String?, startedAt: Date) -> String {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return "會議 \(Self.displayDateFormatter.string(from: startedAt))"
    }

    private func makeFolderName(title: String, startedAt: Date) -> String {
        let datePrefix = Self.folderDateFormatter.string(from: startedAt)
        let safeTitle = title
            .replacingOccurrences(of: #"[\\/:*?"<>|#\[\]\n\r\t]"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        let suffix = safeTitle.isEmpty ? "meeting" : String(safeTitle.prefix(48))
        return "\(datePrefix)_\(suffix)"
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try jsonEncoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try jsonDecoder.decode(type, from: data)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static let authoritativeEnvelopeFileName = "session_state_v1.json"
    private static let pendingTransactionFileName = ".session_state_pending.json"
    private static let historyIndexFileName = "history_index_v1.json"

    private static let folderDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }()

    static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
