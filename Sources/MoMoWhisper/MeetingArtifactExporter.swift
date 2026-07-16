import Foundation
import MoMoWhisperSummaryCore

struct MeetingArtifactExportResult {
    var recordingURL: URL?
    var highlightsURL: URL
    var codexHandoffMarkdownURL: URL?
    var codexHandoffJSONURL: URL?
}

enum MeetingArtifactExporter {
    static let latestHandoffBaseName = "latest_meeting_handoff"
    static let latestValidHandoffBaseName = "latest_valid_meeting_handoff"
    static let currentHandoffBaseName = "current_meeting_handoff"

    static var defaultRecordingsDirectory: URL {
        MoMoWhisperStorage.recordingsDirectory
    }

    static var defaultHighlightsDirectory: URL {
        MoMoWhisperStorage.highlightsDirectory
    }

    static var defaultCodexHandoffDirectory: URL {
        MoMoWhisperStorage.codexHandoffDirectory
    }

    /// Deterministic final artifact paths are planned before the authoritative
    /// commit so metadata and the v2 handoff can refer to the same transaction;
    /// no second metadata-only save is needed after export.
    static func plannedHighlightsURL(
        metadata: MeetingSessionMetadata,
        directory: URL
    ) -> URL {
        let baseName = safeFileName(
            "\(dateFileFormatter.string(from: metadata.startedAt))-\(metadata.displayTitle)"
        )
        return directory.appendingPathComponent("\(baseName)-highlights.md")
    }

    static func plannedHandoffMarkdownURL(
        baseName: String,
        directory: URL
    ) -> URL {
        directory.appendingPathComponent("\(baseName).md")
    }

    /// Exports artifacts strictly from one committed authoritative snapshot.
    /// The v2 handoff carries the transaction ID and authority path needed by a
    /// reader to reject stale or mixed compatibility files.
    static func export(
        commit: MeetingSessionCommit,
        highlightsDirectory: URL,
        codexHandoffDirectory: URL,
        includeCodexHandoff: Bool,
        dateFormatter: DateFormatter
    ) throws -> MeetingArtifactExportResult {
        let snapshot = commit.snapshot
        let metadata = snapshot.metadata
        let sessionFolderPath = commit.authoritativeStateURL.deletingLastPathComponent().path
        let recordingURL = metadata.recordingFilePath.map { URL(fileURLWithPath: $0) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: highlightsDirectory, withIntermediateDirectories: true)

        let highlightsURL = plannedHighlightsURL(
            metadata: metadata,
            directory: highlightsDirectory
        )
        let highlightsDocument = makeHighlightsDocument(
            metadata: metadata,
            transcriptMarkdown: snapshot.transcriptMarkdown,
            highlightsMarkdown: snapshot.highlightsMarkdown,
            summaryDocument: snapshot.summaryDocument,
            recordingURL: recordingURL,
            sessionFolderPath: sessionFolderPath,
            dateFormatter: dateFormatter
        )
        try highlightsDocument.write(to: highlightsURL, atomically: true, encoding: .utf8)

        let handoffURLs: (markdown: URL, json: URL)?
        if includeCodexHandoff {
            handoffURLs = try writeCodexHandoff(
                baseName: latestHandoffBaseName,
                status: "ended",
                commit: commit,
                recordingURL: recordingURL,
                highlightsURL: highlightsURL,
                codexHandoffDirectory: codexHandoffDirectory,
                dateFormatter: dateFormatter
            )
            if isValidMeetingForHandoff(
                metadata: metadata,
                transcriptMarkdown: snapshot.transcriptMarkdown,
                summaryDocument: snapshot.summaryDocument
            ) {
                _ = try writeCodexHandoff(
                    baseName: latestValidHandoffBaseName,
                    status: "valid",
                    commit: commit,
                    recordingURL: recordingURL,
                    highlightsURL: highlightsURL,
                    codexHandoffDirectory: codexHandoffDirectory,
                    dateFormatter: dateFormatter
                )
            }
        } else {
            handoffURLs = nil
        }

        return MeetingArtifactExportResult(
            recordingURL: recordingURL,
            highlightsURL: highlightsURL,
            codexHandoffMarkdownURL: handoffURLs?.markdown,
            codexHandoffJSONURL: handoffURLs?.json
        )
    }

    /// Publishes an active/ended v2 handoff from a committed snapshot only.
    static func exportCurrentHandoff(
        commit: MeetingSessionCommit,
        codexHandoffDirectory: URL,
        isRecording: Bool,
        dateFormatter: DateFormatter
    ) throws -> MeetingArtifactExportResult {
        let metadata = commit.snapshot.metadata
        let recordingURL = metadata.recordingFilePath.map { URL(fileURLWithPath: $0) }
        let sessionHighlightsURL = commit.authoritativeStateURL
            .deletingLastPathComponent()
            .appendingPathComponent("highlights.md")
        let handoffURLs = try writeCodexHandoff(
            baseName: currentHandoffBaseName,
            status: isRecording ? "active" : "ended",
            commit: commit,
            recordingURL: recordingURL,
            highlightsURL: sessionHighlightsURL,
            codexHandoffDirectory: codexHandoffDirectory,
            dateFormatter: dateFormatter
        )

        return MeetingArtifactExportResult(
            recordingURL: recordingURL,
            highlightsURL: sessionHighlightsURL,
            codexHandoffMarkdownURL: handoffURLs.markdown,
            codexHandoffJSONURL: handoffURLs.json
        )
    }

    static func export(
        metadata: MeetingSessionMetadata,
        transcriptMarkdown: String,
        highlightsMarkdown: String,
        summaryDocument: MeetingSummaryDocument? = nil,
        recordingURL: URL?,
        sessionFolderPath: String,
        highlightsDirectory: URL,
        codexHandoffDirectory: URL,
        includeCodexHandoff: Bool,
        dateFormatter: DateFormatter
    ) throws -> MeetingArtifactExportResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: highlightsDirectory, withIntermediateDirectories: true)

        let baseName = safeFileName("\(dateFileFormatter.string(from: metadata.startedAt))-\(metadata.displayTitle)")
        let highlightsURL = highlightsDirectory.appendingPathComponent("\(baseName)-highlights.md")
        let highlightsDocument = makeHighlightsDocument(
            metadata: metadata,
            transcriptMarkdown: transcriptMarkdown,
            highlightsMarkdown: highlightsMarkdown,
            summaryDocument: summaryDocument,
            recordingURL: recordingURL,
            sessionFolderPath: sessionFolderPath,
            dateFormatter: dateFormatter
        )

        try highlightsDocument.write(to: highlightsURL, atomically: true, encoding: .utf8)

        let handoffURLs: (markdown: URL, json: URL)?
        if includeCodexHandoff {
            handoffURLs = try writeCodexHandoff(
                baseName: latestHandoffBaseName,
                status: "ended",
                commit: nil,
                metadata: metadata,
                transcriptMarkdown: transcriptMarkdown,
                highlightsMarkdown: highlightsMarkdown,
                summaryDocument: summaryDocument,
                recordingURL: recordingURL,
                highlightsURL: highlightsURL,
                sessionFolderPath: sessionFolderPath,
                codexHandoffDirectory: codexHandoffDirectory,
                dateFormatter: dateFormatter
            )
            if isValidMeetingForHandoff(
                metadata: metadata,
                transcriptMarkdown: transcriptMarkdown,
                summaryDocument: summaryDocument
            ) {
                _ = try writeCodexHandoff(
                    baseName: latestValidHandoffBaseName,
                    status: "valid",
                    commit: nil,
                    metadata: metadata,
                    transcriptMarkdown: transcriptMarkdown,
                    highlightsMarkdown: highlightsMarkdown,
                    summaryDocument: summaryDocument,
                    recordingURL: recordingURL,
                    highlightsURL: highlightsURL,
                    sessionFolderPath: sessionFolderPath,
                    codexHandoffDirectory: codexHandoffDirectory,
                    dateFormatter: dateFormatter
                )
            }
        } else {
            handoffURLs = nil
        }

        return MeetingArtifactExportResult(
            recordingURL: recordingURL,
            highlightsURL: highlightsURL,
            codexHandoffMarkdownURL: handoffURLs?.markdown,
            codexHandoffJSONURL: handoffURLs?.json
        )
    }

    static func exportCurrentHandoff(
        metadata: MeetingSessionMetadata,
        transcriptMarkdown: String,
        highlightsMarkdown: String,
        summaryDocument: MeetingSummaryDocument? = nil,
        recordingURL: URL?,
        sessionFolderPath: String,
        codexHandoffDirectory: URL,
        isRecording: Bool,
        dateFormatter: DateFormatter
    ) throws -> MeetingArtifactExportResult {
        let sessionHighlightsURL = URL(fileURLWithPath: sessionFolderPath, isDirectory: true)
            .appendingPathComponent("highlights.md")
        let handoffURLs = try writeCodexHandoff(
            baseName: currentHandoffBaseName,
            status: isRecording ? "active" : "ended",
            commit: nil,
            metadata: metadata,
            transcriptMarkdown: transcriptMarkdown,
            highlightsMarkdown: highlightsMarkdown,
            summaryDocument: summaryDocument,
            recordingURL: recordingURL,
            highlightsURL: sessionHighlightsURL,
            sessionFolderPath: sessionFolderPath,
            codexHandoffDirectory: codexHandoffDirectory,
            dateFormatter: dateFormatter
        )

        return MeetingArtifactExportResult(
            recordingURL: recordingURL,
            highlightsURL: sessionHighlightsURL,
            codexHandoffMarkdownURL: handoffURLs.markdown,
            codexHandoffJSONURL: handoffURLs.json
        )
    }

    static func safeFileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "MoMoWhisper-Meeting" : trimmed
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)

        return fallback
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .replacingOccurrences(of: "  ", with: " ")
    }

    static func isValidMeetingForHandoff(
        metadata: MeetingSessionMetadata,
        transcriptMarkdown: String,
        summaryDocument: MeetingSummaryDocument?
    ) -> Bool {
        let transcriptCount = max(
            metadata.transcriptCharacterCount,
            transcriptMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).count
        )
        return MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: transcriptCount,
            summaryDocument: summaryDocument
        )
    }

    private static func writeCodexHandoff(
        baseName: String,
        status: String,
        commit: MeetingSessionCommit?,
        metadata: MeetingSessionMetadata,
        transcriptMarkdown: String,
        highlightsMarkdown: String,
        summaryDocument: MeetingSummaryDocument?,
        recordingURL: URL?,
        highlightsURL: URL,
        sessionFolderPath: String,
        codexHandoffDirectory: URL,
        dateFormatter: DateFormatter
    ) throws -> (markdown: URL, json: URL) {
        try FileManager.default.createDirectory(at: codexHandoffDirectory, withIntermediateDirectories: true)

        let markdownURL = codexHandoffDirectory.appendingPathComponent("\(baseName).md")
        let jsonURL = codexHandoffDirectory.appendingPathComponent("\(baseName).json")
        let updatedAt = Date()
        let handoffDocument = makeCodexHandoffDocument(
            status: status,
            commit: commit,
            metadata: metadata,
            transcriptMarkdown: transcriptMarkdown,
            highlightsMarkdown: highlightsMarkdown,
            summaryDocument: summaryDocument,
            recordingURL: recordingURL,
            highlightsURL: highlightsURL,
            sessionFolderPath: sessionFolderPath,
            dateFormatter: dateFormatter,
            updatedAt: updatedAt
        )

        try handoffDocument.write(to: markdownURL, atomically: true, encoding: .utf8)
        try makeCodexHandoffJSON(
            status: status,
            commit: commit,
            metadata: metadata,
            summaryDocument: summaryDocument,
            recordingURL: recordingURL,
            highlightsURL: highlightsURL,
            codexMarkdownURL: markdownURL,
            sessionFolderPath: sessionFolderPath,
            updatedAt: updatedAt
        )
        .write(to: jsonURL, options: .atomic)

        return (markdownURL, jsonURL)
    }

    private static func writeCodexHandoff(
        baseName: String,
        status: String,
        commit: MeetingSessionCommit,
        recordingURL: URL?,
        highlightsURL: URL,
        codexHandoffDirectory: URL,
        dateFormatter: DateFormatter
    ) throws -> (markdown: URL, json: URL) {
        let snapshot = commit.snapshot
        return try writeCodexHandoff(
            baseName: baseName,
            status: status,
            commit: commit,
            metadata: snapshot.metadata,
            transcriptMarkdown: snapshot.transcriptMarkdown,
            highlightsMarkdown: snapshot.highlightsMarkdown,
            summaryDocument: snapshot.summaryDocument,
            recordingURL: recordingURL,
            highlightsURL: highlightsURL,
            sessionFolderPath: commit.authoritativeStateURL.deletingLastPathComponent().path,
            codexHandoffDirectory: codexHandoffDirectory,
            dateFormatter: dateFormatter
        )
    }

    private static func makeHighlightsDocument(
        metadata: MeetingSessionMetadata,
        transcriptMarkdown: String,
        highlightsMarkdown: String,
        summaryDocument: MeetingSummaryDocument?,
        recordingURL: URL?,
        sessionFolderPath: String,
        dateFormatter: DateFormatter
    ) -> String {
        let notes = highlightsMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeNotes = notes.isEmpty ? "尚未產生會議重點。" : notes

        return """
        # \(metadata.displayTitle)

        - 會議開始：\(dateFormatter.string(from: metadata.startedAt))
        - 會議結束：\(metadata.endedAt.map(dateFormatter.string(from:)) ?? "尚未記錄")
        - 錄音主檔（相容欄位）：\(recordingURL?.path ?? "尚未產生")
        - 錄音狀態：\(metadata.recordingReadiness.rawValue)
        - 錄音驗證邊界：\(metadata.recordingReadinessDetail)
        - 錄音分段：\(recordingPartsSummary(metadata.recordingParts))
        - Session：\(sessionFolderPath)
        - 逐字稿字數：\(transcriptMarkdown.count)
        \(summaryProcessingLine(summaryDocument))

        ## 會議重點

        \(safeNotes)
        """
    }

    private static func makeCodexHandoffDocument(
        status: String,
        commit: MeetingSessionCommit?,
        metadata: MeetingSessionMetadata,
        transcriptMarkdown: String,
        highlightsMarkdown: String,
        summaryDocument: MeetingSummaryDocument?,
        recordingURL: URL?,
        highlightsURL: URL,
        sessionFolderPath: String,
        dateFormatter: DateFormatter,
        updatedAt: Date
    ) -> String {
        let notes = highlightsMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeNotes = notes.isEmpty ? "尚未產生會議重點。" : notes
        let authoritySection: String
        let compatibilityTrustLabel: String
        let usageInstructions: String
        if let commit {
            authoritySection = """
            - Handoff schema：2
            - 權威會議狀態：\(commit.authoritativeStateURL.path)
            - Session transaction ID：\(commit.transactionID)
            - Session state schema：\(commit.authoritativeStateSchemaVersion)
            """
            compatibilityTrustLabel = "相容預覽，不可作為交易事實來源"
            usageInstructions = """
            本 handoff 只有在讀取「權威會議狀態」並驗證 transaction ID、meeting ID 與 schema 全數一致後，才能視為已驗證快照。`transcript.md`、`metadata.json`、`summary_document.json` 與 `highlights.md` 只是可能在下一次儲存中被覆寫的相容預覽，不得用來取代權威封包。

            若狀態為 `active`，本檔代表進行中會議的已提交快照；需要歷史脈絡時，再依使用者要求查詢第二大腦。
            """
        } else {
            authoritySection = """
            - Handoff schema：1（legacy，未綁定 session transaction）
            - 權威會議狀態：未提供；不得宣稱已驗證
            """
            compatibilityTrustLabel = "legacy 相容路徑，不可作為交易事實來源"
            usageInstructions = """
            這是 legacy 未綁定交易的 handoff，只能視為未驗證預覽。需要可信任的會議快照時，必須改用 schema 2 並驗證權威封包。
            """
        }

        return """
        # MoMoWhisper Codex Handoff

        - 狀態：\(status)
        - 更新時間：\(dateFormatter.string(from: updatedAt))
        \(authoritySection)
        - 會議標題：\(metadata.displayTitle)
        - 會議開始：\(dateFormatter.string(from: metadata.startedAt))
        - 會議結束：\(metadata.endedAt.map(dateFormatter.string(from:)) ?? "尚未記錄")
        - 會議重點檔（\(compatibilityTrustLabel)）：\(highlightsURL.path)
        - 錄音主檔（相容欄位）：\(recordingURL?.path ?? "尚未產生")
        - 錄音狀態：\(metadata.recordingReadiness.rawValue)
        - 錄音驗證邊界：\(metadata.recordingReadinessDetail)
        - 錄音分段：\(recordingPartsSummary(metadata.recordingParts))
        - handoff 有效範圍：逐字稿達 300 字門檻，或 Summary V2 含使用者鎖定的 headline / 人工或使用者鎖定的有效項目；純 AI、純備援內容不會覆蓋 latest_valid，錄音完整性必須另外驗證。
        - Session 資料夾：\(sessionFolderPath)
        - 逐字稿檔（\(compatibilityTrustLabel)）：\(sessionFolderPath)/transcript.md
        - Metadata 檔（\(compatibilityTrustLabel)）：\(sessionFolderPath)/metadata.json
        - 結構化摘要檔（\(compatibilityTrustLabel)）：\(sessionFolderPath)/summary_document.json
        - 逐字稿字數：\(transcriptMarkdown.count)
        \(summaryProcessingLine(summaryDocument))

        ## 給 Codex 的使用方式

        \(usageInstructions)

        ## 會議重點

        \(safeNotes)

        ## 逐字稿摘要來源

        逐字稿全文的權威版本位於 session state envelope 的 `snapshot.transcriptMarkdown`。相容預覽路徑：\(sessionFolderPath)/transcript.md
        """
    }

    private static func makeCodexHandoffJSON(
        status: String,
        commit: MeetingSessionCommit?,
        metadata: MeetingSessionMetadata,
        summaryDocument: MeetingSummaryDocument?,
        recordingURL: URL?,
        highlightsURL: URL,
        codexMarkdownURL: URL,
        sessionFolderPath: String,
        updatedAt: Date
    ) throws -> Data {
        let payload = CodexHandoffPayload(
            schemaVersion: commit == nil ? 1 : 2,
            sessionTransactionID: commit?.transactionID,
            sessionStatePath: commit?.authoritativeStateURL.path,
            sessionStateSchemaVersion: commit?.authoritativeStateSchemaVersion,
            meetingID: metadata.id.uuidString,
            title: metadata.displayTitle,
            handoffStatus: status,
            updatedAt: updatedAt,
            startedAt: metadata.startedAt,
            endedAt: metadata.endedAt,
            recordingPath: recordingURL?.path,
            recordingReadiness: metadata.recordingReadiness.rawValue,
            recordingReadinessDetail: metadata.recordingReadinessDetail,
            recordingParts: metadata.recordingParts.map(CodexRecordingPartPayload.init),
            handoffValidityScope: "逐字稿達 300 字門檻，或 Summary V2 含使用者鎖定的 headline / 人工或使用者鎖定的有效項目；純 AI、純備援內容不會覆蓋 latest_valid，錄音完整性必須另外驗證。",
            highlightsPath: highlightsURL.path,
            codexHandoffPath: codexMarkdownURL.path,
            sessionFolderPath: sessionFolderPath,
            transcriptPath: "\(sessionFolderPath)/transcript.md",
            metadataPath: "\(sessionFolderPath)/metadata.json",
            summaryDocumentPath: "\(sessionFolderPath)/summary_document.json",
            compatibilityPathsTrusted: false,
            compatibilityPathsBoundary: "transcriptPath, metadataPath, summaryDocumentPath, highlightsPath 只是可變相容預覽；必須驗證 sessionStatePath 的 transaction ID、meeting ID 與 schema 後才可信任。",
            summarySchemaVersion: summaryDocument?.schemaVersion,
            summaryProcessing: summaryDocument.map { CodexSummaryProcessingPayload($0.processing) }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    private static func recordingPartsSummary(_ parts: [MeetingRecordingPart]) -> String {
        guard !parts.isEmpty else {
            return "尚未建立 recording part"
        }

        return parts
            .sorted { $0.sequence < $1.sequence }
            .map { part in
                "part \(part.sequence) [\(part.readiness.rawValue)] \(part.filePath)"
            }
            .joined(separator: "；")
    }

    private static func summaryProcessingLine(_ document: MeetingSummaryDocument?) -> String {
        guard let processing = document?.processing else {
            return "- 摘要處理：舊版或尚未建立結構化摘要"
        }
        return "- 摘要處理：讀取 \(processing.processedUnits)/\(processing.totalUnits)；AI \(processing.aiUnits)；本機備援 \(processing.fallbackUnits)；待整理 \(processing.pendingUnits)；待重試 \(processing.retryUnits)"
    }

    private static let dateFileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private struct CodexHandoffPayload: Codable {
    var schemaVersion: Int
    var sessionTransactionID: String?
    var sessionStatePath: String?
    var sessionStateSchemaVersion: Int?
    var meetingID: String
    var title: String
    var handoffStatus: String
    var updatedAt: Date
    var startedAt: Date
    var endedAt: Date?
    var recordingPath: String?
    var recordingReadiness: String
    var recordingReadinessDetail: String
    var recordingParts: [CodexRecordingPartPayload]
    var handoffValidityScope: String
    var highlightsPath: String
    var codexHandoffPath: String
    var sessionFolderPath: String
    var transcriptPath: String
    var metadataPath: String
    var summaryDocumentPath: String?
    var compatibilityPathsTrusted: Bool
    var compatibilityPathsBoundary: String
    var summarySchemaVersion: Int?
    var summaryProcessing: CodexSummaryProcessingPayload?
}

private struct CodexSummaryProcessingPayload: Codable {
    var totalUnits: Int
    var processedUnits: Int
    var aiUnits: Int
    var fallbackUnits: Int
    var pendingUnits: Int
    var retryUnits: Int

    init(_ processing: MeetingSummaryProcessingState) {
        totalUnits = processing.totalUnits
        processedUnits = processing.processedUnits
        aiUnits = processing.aiUnits
        fallbackUnits = processing.fallbackUnits
        pendingUnits = processing.pendingUnits
        retryUnits = processing.retryUnits
    }
}

private struct CodexRecordingPartPayload: Codable {
    var id: String
    var sequence: Int
    var filePath: String
    var startedAt: Date
    var endedAt: Date?
    var readiness: String

    init(_ part: MeetingRecordingPart) {
        id = part.id.uuidString
        sequence = part.sequence
        filePath = part.filePath
        startedAt = part.startedAt
        endedAt = part.endedAt
        readiness = part.readiness.rawValue
    }
}
