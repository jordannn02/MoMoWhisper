import AppKit
import Foundation
import MoMoWhisperSessionCore

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
    var highlightsMarkdown: String
    var rawSummaryState: LiveMeetingSummaryState
}

final class MeetingSessionStore {
    private let fileManager = FileManager.default
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    let rootDirectory: URL

    init(rootDirectory: URL = MeetingSessionStore.defaultRootDirectory) {
        self.rootDirectory = rootDirectory
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
        try ensureRootDirectory()
        let folderURL = sessionFolderURL(for: snapshot.metadata)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        try writeJSON(snapshot.metadata, to: folderURL.appendingPathComponent("metadata.json"))
        try writeJSON(snapshot.transcriptSegments, to: folderURL.appendingPathComponent("transcript.json"))
        try writeJSON(snapshot.rawSummaryState, to: folderURL.appendingPathComponent("raw_summary_state.json"))
        try writeText(snapshot.transcriptMarkdown, to: folderURL.appendingPathComponent("transcript.md"))
        try writeText(snapshot.highlightsMarkdown, to: folderURL.appendingPathComponent("highlights.md"))

        return snapshot.metadata
    }

    func loadMetadata() throws -> [MeetingSessionMetadata] {
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
            let metadataURL = folder.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metadataURL) else {
                return nil
            }
            return try? jsonDecoder.decode(MeetingSessionMetadata.self, from: data)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func searchMetadata(query: String) throws -> [MeetingSessionMetadata] {
        let allMetadata = try loadMetadata()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return allMetadata
        }

        let keywords = trimmedQuery
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        return allMetadata.filter { metadata in
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
        let storedMetadata = try readJSON(MeetingSessionMetadata.self, from: folderURL.appendingPathComponent("metadata.json"))
        let transcriptSegments = (try? readJSON([TranscriptSegment].self, from: folderURL.appendingPathComponent("transcript.json"))) ?? []
        let rawSummaryState = (try? readJSON(LiveMeetingSummaryState.self, from: folderURL.appendingPathComponent("raw_summary_state.json"))) ?? .empty
        let transcriptMarkdown = (try? String(contentsOf: folderURL.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
        let highlightsMarkdown = (try? String(contentsOf: folderURL.appendingPathComponent("highlights.md"), encoding: .utf8)) ?? ""

        return MeetingSessionSnapshot(
            metadata: storedMetadata,
            transcriptSegments: transcriptSegments,
            transcriptMarkdown: transcriptMarkdown,
            highlightsMarkdown: highlightsMarkdown,
            rawSummaryState: rawSummaryState
        )
    }

    func sessionFolderURL(for metadata: MeetingSessionMetadata) -> URL {
        rootDirectory.appendingPathComponent(metadata.folderName, isDirectory: true)
    }

    private func ensureRootDirectory() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
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
