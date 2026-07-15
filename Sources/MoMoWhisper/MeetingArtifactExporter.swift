import Foundation

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

    static func export(
        metadata: MeetingSessionMetadata,
        transcriptMarkdown: String,
        highlightsMarkdown: String,
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
                metadata: metadata,
                transcriptMarkdown: transcriptMarkdown,
                highlightsMarkdown: highlightsMarkdown,
                recordingURL: recordingURL,
                highlightsURL: highlightsURL,
                sessionFolderPath: sessionFolderPath,
                codexHandoffDirectory: codexHandoffDirectory,
                dateFormatter: dateFormatter
            )
            if isValidMeetingForHandoff(metadata: metadata, transcriptMarkdown: transcriptMarkdown, highlightsMarkdown: highlightsMarkdown) {
                _ = try writeCodexHandoff(
                    baseName: latestValidHandoffBaseName,
                    status: "valid",
                    metadata: metadata,
                    transcriptMarkdown: transcriptMarkdown,
                    highlightsMarkdown: highlightsMarkdown,
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
            metadata: metadata,
            transcriptMarkdown: transcriptMarkdown,
            highlightsMarkdown: highlightsMarkdown,
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
        highlightsMarkdown: String
    ) -> Bool {
        let transcriptCount = max(metadata.transcriptCharacterCount, transcriptMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).count)
        let highlightsCount = max(metadata.highlightCharacterCount, highlightsMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).count)
        return transcriptCount >= 300 || highlightsCount >= 80
    }

    private static func writeCodexHandoff(
        baseName: String,
        status: String,
        metadata: MeetingSessionMetadata,
        transcriptMarkdown: String,
        highlightsMarkdown: String,
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
            metadata: metadata,
            transcriptMarkdown: transcriptMarkdown,
            highlightsMarkdown: highlightsMarkdown,
            recordingURL: recordingURL,
            highlightsURL: highlightsURL,
            sessionFolderPath: sessionFolderPath,
            dateFormatter: dateFormatter,
            updatedAt: updatedAt
        )

        try handoffDocument.write(to: markdownURL, atomically: true, encoding: .utf8)
        try makeCodexHandoffJSON(
            status: status,
            metadata: metadata,
            recordingURL: recordingURL,
            highlightsURL: highlightsURL,
            codexMarkdownURL: markdownURL,
            sessionFolderPath: sessionFolderPath,
            updatedAt: updatedAt
        )
        .write(to: jsonURL, options: .atomic)

        return (markdownURL, jsonURL)
    }

    private static func makeHighlightsDocument(
        metadata: MeetingSessionMetadata,
        transcriptMarkdown: String,
        highlightsMarkdown: String,
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

        ## 會議重點

        \(safeNotes)
        """
    }

    private static func makeCodexHandoffDocument(
        status: String,
        metadata: MeetingSessionMetadata,
        transcriptMarkdown: String,
        highlightsMarkdown: String,
        recordingURL: URL?,
        highlightsURL: URL,
        sessionFolderPath: String,
        dateFormatter: DateFormatter,
        updatedAt: Date
    ) -> String {
        let notes = highlightsMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeNotes = notes.isEmpty ? "尚未產生會議重點。" : notes

        return """
        # MoMoWhisper Codex Handoff

        - 狀態：\(status)
        - 更新時間：\(dateFormatter.string(from: updatedAt))
        - 會議標題：\(metadata.displayTitle)
        - 會議開始：\(dateFormatter.string(from: metadata.startedAt))
        - 會議結束：\(metadata.endedAt.map(dateFormatter.string(from:)) ?? "尚未記錄")
        - 會議重點檔：\(highlightsURL.path)
        - 錄音主檔（相容欄位）：\(recordingURL?.path ?? "尚未產生")
        - 錄音狀態：\(metadata.recordingReadiness.rawValue)
        - 錄音驗證邊界：\(metadata.recordingReadinessDetail)
        - 錄音分段：\(recordingPartsSummary(metadata.recordingParts))
        - handoff 有效範圍：逐字稿 / 重點內容門檻；錄音完整性必須另外驗證。
        - Session 資料夾：\(sessionFolderPath)
        - 逐字稿檔：\(sessionFolderPath)/transcript.md
        - 逐字稿字數：\(transcriptMarkdown.count)

        ## 給 Codex 的使用方式

        若狀態為 `active`，本檔代表進行中的會議快照；先讀本檔、`highlights.md`、`transcript.md`、`metadata.json`，再依使用者要求結合第二大腦回答。不要把本檔視為唯一事實來源；需要歷史脈絡時，應再查第二大腦。

        ## 會議重點

        \(safeNotes)

        ## 逐字稿摘要來源

        逐字稿全文請讀：\(sessionFolderPath)/transcript.md
        """
    }

    private static func makeCodexHandoffJSON(
        status: String,
        metadata: MeetingSessionMetadata,
        recordingURL: URL?,
        highlightsURL: URL,
        codexMarkdownURL: URL,
        sessionFolderPath: String,
        updatedAt: Date
    ) throws -> Data {
        let payload = CodexHandoffPayload(
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
            handoffValidityScope: "逐字稿 / 重點內容門檻；錄音完整性必須另外驗證。",
            highlightsPath: highlightsURL.path,
            codexHandoffPath: codexMarkdownURL.path,
            sessionFolderPath: sessionFolderPath,
            transcriptPath: "\(sessionFolderPath)/transcript.md",
            metadataPath: "\(sessionFolderPath)/metadata.json"
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

    private static let dateFileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private struct CodexHandoffPayload: Codable {
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
