import Foundation
import MoMoWhisperSessionCore
import MoMoWhisperSummaryCore

enum MeetingPersistenceArtifactIntent: @unchecked Sendable {
    case none
    case live(isRecording: Bool, codexHandoffDirectory: URL)
    case final(
        highlightsDirectory: URL,
        codexHandoffDirectory: URL,
        includeCodexHandoff: Bool
    )
}

struct MeetingPersistenceRequest: @unchecked Sendable {
    var snapshot: MeetingSessionSnapshot
    var artifactIntent: MeetingPersistenceArtifactIntent
}

struct MeetingPersistenceResult: @unchecked Sendable {
    var token: PersistenceRevisionToken
    var commit: MeetingSessionCommit
    var artifactResult: MeetingArtifactExportResult?
    var artifactWarning: String?
    var latestValidHandoffVerification: MeetingLatestValidHandoffVerification?
    var deliveryArtifactChecks: [DeliveryArtifactCheck]
}

struct MeetingLatestValidHandoffVerification: Sendable {
    var exists: Bool
    var isReady: Bool
}

/// The coordinator guarantees this backend is called by one writer at a time.
/// It deliberately owns a separate store instance so the main actor never
/// performs JSON encoding or filesystem writes during recognition callbacks.
final class MeetingPersistenceBackend: @unchecked Sendable {
    private let store: MeetingSessionStore
    private let dateFormatter: DateFormatter

    init(rootDirectory: URL = MeetingSessionStore.defaultRootDirectory) {
        store = MeetingSessionStore(rootDirectory: rootDirectory)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateFormatter = formatter
    }

    func persist(
        token: PersistenceRevisionToken,
        request: MeetingPersistenceRequest
    ) throws -> MeetingPersistenceResult {
        let commit = try store.commit(snapshot: request.snapshot)
        var artifactResult: MeetingArtifactExportResult?
        var artifactWarning: String?

        do {
            switch request.artifactIntent {
            case .none:
                break
            case let .live(isRecording, codexHandoffDirectory):
                artifactResult = try MeetingArtifactExporter.exportCurrentHandoff(
                    commit: commit,
                    codexHandoffDirectory: codexHandoffDirectory,
                    isRecording: isRecording,
                    dateFormatter: dateFormatter
                )
            case let .final(highlightsDirectory, codexHandoffDirectory, includeCodexHandoff):
                artifactResult = try MeetingArtifactExporter.export(
                    commit: commit,
                    highlightsDirectory: highlightsDirectory,
                    codexHandoffDirectory: codexHandoffDirectory,
                    includeCodexHandoff: includeCodexHandoff,
                    dateFormatter: dateFormatter
                )
            }
        } catch {
            // The authoritative snapshot is already committed. Preserve that
            // success and report artifact generation as a separate warning.
            artifactWarning = error.localizedDescription
        }

        let latestValidHandoffVerification = verifyLatestValidHandoff(
            commit: commit,
            intent: request.artifactIntent
        )
        let deliveryArtifactChecks = inspectDeliveryArtifacts(
            commit: commit,
            artifactResult: artifactResult
        )

        return MeetingPersistenceResult(
            token: token,
            commit: commit,
            artifactResult: artifactResult,
            artifactWarning: artifactWarning,
            latestValidHandoffVerification: latestValidHandoffVerification,
            deliveryArtifactChecks: deliveryArtifactChecks
        )
    }

    private func inspectDeliveryArtifacts(
        commit: MeetingSessionCommit,
        artifactResult: MeetingArtifactExportResult?
    ) -> [DeliveryArtifactCheck] {
        let snapshot = commit.snapshot
        var checks = [
            DeliveryArtifactInspector.inspectTextContent(
                label: "逐字稿",
                text: snapshot.transcriptMarkdown,
                sourcePath: "\(commit.authoritativeStateURL.path)#/snapshot/transcriptMarkdown",
                minimumCharacters: 300
            ),
            DeliveryArtifactInspector.inspectTextContent(
                label: "會議重點",
                text: snapshot.highlightsMarkdown,
                sourcePath: "\(commit.authoritativeStateURL.path)#/snapshot/highlightsMarkdown",
                minimumCharacters: 80
            )
        ]

        let recordingParts = snapshot.metadata.recordingParts.sorted { $0.sequence < $1.sequence }
        if recordingParts.isEmpty {
            checks.append(DeliveryArtifactInspector.inspectBinaryFile(
                label: "錄音 part",
                path: snapshot.metadata.recordingFilePath ?? "",
                minimumBytes: 45
            ))
        } else {
            checks.append(contentsOf: recordingParts.map { part in
                DeliveryArtifactInspector.inspectBinaryFile(
                    label: "錄音 part \(part.sequence)",
                    path: part.filePath,
                    minimumBytes: 45
                )
            })
        }

        checks.append(DeliveryArtifactInspector.inspectTextFile(
            label: "Codex handoff",
            // Only trust the artifact produced by this transaction. Falling
            // back to metadata can make a failed export look healthy by
            // finding a stale global handoff from an older meeting.
            path: artifactResult?.codexHandoffMarkdownURL?.path ?? "",
            minimumCharacters: 1
        ))
        return checks
    }

    private func verifyLatestValidHandoff(
        commit: MeetingSessionCommit,
        intent: MeetingPersistenceArtifactIntent
    ) -> MeetingLatestValidHandoffVerification {
        let codexHandoffDirectory: URL
        switch intent {
        case .none:
            codexHandoffDirectory = MeetingArtifactExporter.defaultCodexHandoffDirectory
        case let .live(_, directory):
            codexHandoffDirectory = directory
        case let .final(_, directory, _):
            codexHandoffDirectory = directory
        }

        let jsonURL = codexHandoffDirectory.appendingPathComponent(
            "\(MeetingArtifactExporter.latestValidHandoffBaseName).json"
        )
        let exists = FileManager.default.fileExists(atPath: jsonURL.path)
        let currentCommitIsValid = MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: commit.snapshot.metadata.transcriptCharacterCount,
            summaryDocument: commit.snapshot.summaryDocument
        )
        guard exists,
              let data = FileManager.default.contents(atPath: jsonURL.path),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (payload["schemaVersion"] as? NSNumber)?.intValue == 2,
              payload["compatibilityPathsTrusted"] as? Bool == false,
              let payloadMeetingIDText = payload["meetingID"] as? String,
              let payloadMeetingID = UUID(uuidString: payloadMeetingIDText),
              let transactionID = payload["sessionTransactionID"] as? String,
              let sessionStatePath = payload["sessionStatePath"] as? String,
              let verified = try? store.readVerifiedCommit(
                  at: URL(fileURLWithPath: sessionStatePath),
                  expectedTransactionID: transactionID,
                  expectedMeetingID: payloadMeetingID
              ),
              MeetingSummaryHandoffValidity.isValid(
                  transcriptCharacterCount: verified.snapshot.metadata.transcriptCharacterCount,
                  summaryDocument: verified.snapshot.summaryDocument
              ),
              !currentCommitIsValid || (
                  payloadMeetingID == commit.snapshot.metadata.id
                      && verified.transactionID == commit.transactionID
              ) else {
            return .init(exists: exists, isReady: false)
        }
        return .init(exists: true, isReady: true)
    }
}
