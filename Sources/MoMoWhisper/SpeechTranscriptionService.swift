@preconcurrency import AVFoundation
import AppKit
import CoreGraphics
import Darwin
import Foundation
import Speech
import MoMoWhisperSessionCore
import MoMoWhisperSummaryCore

@MainActor
final class SpeechTranscriptionService: ObservableObject {
    @Published var transcript = ""
    @Published var partialTranscript = ""
    @Published var meetingNotes = ""
    @Published private(set) var rawMeetingNotes = ""
    @Published private(set) var summaryDocument = MeetingSummaryDocument.empty(
        id: "unsaved-meeting",
        title: "未命名會議"
    )
    @Published var isRecording = false
    @Published private(set) var isSessionTransitionInProgress = false
    @Published var statusText = "待開始"
    @Published var summaryStatusText = "待整理"
    @Published var lastError: String?
    @Published var microphoneInputStatusText = "麥克風待開始"
    @Published var systemAudioInputStatusText = "系統音訊待開始"
    @Published var speechRecognitionStatusText = "辨識待開始"
    @Published var deepSeekDiagnosticsText = "DeepSeek cache 待開始"
    @Published var preflightStatusText = "會前檢查待開始"
    @Published var preflightSummary = PreflightSummary.pending
    @Published var preflightLastCheckedAt: Date?
    @Published var onboardingPermissionStatusText = "權限待檢查"
    @Published var availableInputDevices: [AudioInputDevice] = []
    @Published var selectedInputDeviceID = AudioInputDevice.systemDefaultID {
        didSet {
            if oldValue != selectedInputDeviceID {
                invalidatePreflight()
            }
        }
    }
    @Published var audioCaptureMode: AudioCaptureMode = .microphoneOnly {
        didSet {
            saveSummarySettings()
            if oldValue != audioCaptureMode {
                invalidatePreflight()
            }
            if !audioCaptureMode.capturesSystemAudio {
                systemAudioCapture.stop()
                systemAudioInputStatusText = isRecording ? "系統音訊未啟用" : "系統音訊待開始"
            }
            if lastError?.contains("系統音訊") == true {
                lastError = nil
            }
        }
    }
    @Published var selectedTranscriptionEngine: TranscriptionEngine = .preferredForCurrentOS {
        didSet {
            if oldValue != selectedTranscriptionEngine {
                invalidatePreflight()
            }
        }
    }
    @Published var summaryProvider: MeetingSummaryProvider = .disabled {
        didSet { saveSummarySettings() }
    }
    @Published var summaryTriggerMode: MeetingSummaryTriggerMode = .either {
        didSet { saveSummarySettings() }
    }
    @Published var summaryIntervalSeconds: Double = 60 {
        didSet { saveSummarySettings() }
    }
    @Published var summaryCharacterThreshold: Int = 300 {
        didSet { saveSummarySettings() }
    }
    @Published var deepSeekBaseURLText = "https://api.deepseek.com" {
        didSet { saveSummarySettings() }
    }
    @Published var deepSeekModel = "deepseek-v4-flash" {
        didSet { saveSummarySettings() }
    }
    @Published var lmStudioBaseURLText = "" {
        didSet { saveSummarySettings() }
    }
    @Published var lmStudioModel = "google/gemma-3n-e4b" {
        didSet { saveSummarySettings() }
    }
    @Published var customBaseURLText = "" {
        didSet { saveSummarySettings() }
    }
    @Published var customModel = "" {
        didSet { saveSummarySettings() }
    }
    @Published var inputGainDecibels: Double = 0 {
        didSet { saveSummarySettings() }
    }
    @Published var voiceSensitivityMode: VoiceSensitivityMode = .off {
        didSet { saveSummarySettings() }
    }
    @Published var manualVoiceThresholdDecibels: Double = -58 {
        didSet { saveSummarySettings() }
    }
    @Published var pauseCommitDelaySeconds: Double = 1.20 {
        didSet { saveSummarySettings() }
    }
    @Published var recordingOutputDirectoryPath = MeetingArtifactExporter.defaultRecordingsDirectory.path {
        didSet { saveSummarySettings() }
    }
    @Published var highlightsOutputDirectoryPath = MeetingArtifactExporter.defaultHighlightsDirectory.path {
        didSet { saveSummarySettings() }
    }
    @Published var codexHandoffEnabled = true {
        didSet { saveSummarySettings() }
    }
    @Published var artifactStatusText = "會後輸出待開始"
    @Published var lastRecordingFilePath = ""
    @Published var lastHighlightsFilePath = ""
    @Published var lastCodexHandoffPath = ""
    @Published var localeIdentifier = "mixed-zh-en" {
        didSet {
            if oldValue != localeIdentifier {
                speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: recognitionLocaleIdentifier))
                invalidatePreflight()
            }
        }
    }
    @Published var currentSessionMetadata: MeetingSessionMetadata?
    @Published var meetingHistory: [MeetingSessionMetadata] = []
    @Published private(set) var latestValidCodexHandoffExists = false
    @Published private(set) var latestValidCodexHandoffReady = false
    @Published private(set) var deliveryArtifactChecks: [DeliveryArtifactCheck] = []
    @Published var meetingHistorySearchText = "" {
        didSet {
            refreshMeetingHistory()
        }
    }

    private let audioEngine = AVAudioEngine()
    private let audioRouter = SpeechAudioBufferRouter()
    private let microphoneLevelMeter = SpeechAudioLevelMeter()
    private let systemAudioCapture = SystemAudioCapture()
    private let meetingSessionStore: MeetingSessionStore
    private let meetingPersistenceCoordinator: LatestWinsPersistenceCoordinator<
        MeetingPersistenceRequest,
        MeetingPersistenceResult
    >
    private let meetingAudioRecorder = MeetingAudioRecorder()

    private var speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionGeneration: UInt64 = 0
    private var speechAnalyzerSession: SpeechAnalyzerSessionHandling?
    private var systemSpeechAnalyzerSession: SpeechAnalyzerSessionHandling?
    private var microphoneAudioProcessor: AudioInputProcessor?
    private var pendingCommitTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var summaryRequestTask: Task<Void, Never>?
    private var postRecordingSummaryTask: Task<Void, Never>?
    private var manualTranscriptEditTask: Task<Void, Never>?
    private var latestRecognitionText = ""
    private var latestFullRecognitionText = ""
    private var committedRecognitionText = ""
    private var liveDraftStartedAt: Date?
    private var lastCommittedTranscriptText = ""
    private var lastCommittedTranscriptAt: Date?
    private var lastCommittedTranscriptTimestamp: Date?
    private var lastCommittedTranscriptSource: TranscriptSource = .unknown
    private var microphoneBufferCount = 0
    private var systemAudioBufferCount = 0
    private var recognitionUpdateCount = 0
    private var lastMicrophoneLevelDecibels: Float = -120
    private var lastSystemAudioLevelDecibels: Float = -120
    private var lastMicrophoneStatusUpdateAt = Date.distantPast
    private var lastSystemAudioStatusUpdateAt = Date.distantPast
    private var liveSummaryState = LiveMeetingSummaryState.empty
    private var transcriptSegments: [TranscriptSegment] = []
    private var currentSessionStartedAt: Date?
    private var isSummaryRequestInFlight = false
    private var shouldRunSummaryAfterCurrentRequest = false
    private var shouldRunFinalSummaryAfterCurrentRequest = false
    private var summaryGeneration = 0
    private var lastUpdatedAt: Date?
    private var lastSummaryUpdatedAt: Date?
    private var lastAutomaticSummaryAt: Date?
    private var lastSummarizedTranscriptCharacterCount = 0
    private var lastSummarizedTranscriptPrefix = ""
    private var accumulatedAISummaryUnits = 0
    private var accumulatedFallbackSummaryUnits = 0
    private var pendingSummaryRetries: [PendingSummaryRetry] = []
    private var meetingHistoryCache = MeetingSessionHistoryCache()
    private var currentSessionCommit: MeetingSessionCommit?
    private var persistenceEpoch: UInt64 = 1
    private var persistenceRevision: UInt64 = 0
    private var isTerminationQuiescing = false
    private var activeSessionOperationID: UUID?
    private var latestPersistenceRevisionBySession: [UUID: UInt64] = [:]
    private var lastArtifactTrustCacheRefreshAt = Date.distantPast
    private var manualTranscriptEditInvalidatedSummary = false
    private var currentRecordingURL: URL?
    private var recordingLifecycle = MeetingRecordingLifecycle()
    private var isLoadingSummarySettings = false

    init() {
        let rootDirectory = MeetingSessionStore.defaultRootDirectory
        meetingSessionStore = MeetingSessionStore(rootDirectory: rootDirectory)
        let persistenceBackend = MeetingPersistenceBackend(rootDirectory: rootDirectory)
        meetingPersistenceCoordinator = LatestWinsPersistenceCoordinator { token, request in
            try persistenceBackend.persist(token: token, request: request)
        }
        loadSummarySettings()
        refreshInputDevices()
        refreshMeetingHistory()
    }

    nonisolated static var systemAudioDiagnosticsLogURL: URL {
        MoMoWhisperStorage.diagnosticsDirectory.appendingPathComponent("system-audio-diagnostics.log")
    }

    private static let liveSummaryChunkCharacterLimit = 4_000
    private static let finalSummaryChunkCharacterLimit = 6_000
    private static let recentTranscriptCharacterLimit = 8_000
    private static let postRecordingSummaryInitialDelayNanoseconds: UInt64 = 3_000_000_000
    private static let postRecordingSummaryDrainIntervalNanoseconds: UInt64 = 20_000_000_000
    private static let maximumBackgroundSummaryRetryAttempts = 3
    private static let fallbackScopeID = "summary-local-fallback"
    private static let fallbackTopicID = "summary-local-fallback-topic"
    private static let deliveryTranscriptMinimumCharacters = 300
    private static let deliveryHighlightsMinimumCharacters = 80
    private static let deliveryRecordingMinimumBytes = 45

    private struct SummaryRequestPlan {
        var id: String
        var payloadTranscript: String
        var recentTranscript: String
        var rangeStart: Int
        var rangeEnd: Int
        var summarizedCharacterCount: Int
        var requestIsFinal: Bool
        var continuation: SummaryContinuation
        var retryID: String?
        var retryRecord: MeetingSummaryRetryRecord?
        var sourcePrefixFingerprint: String

        var unitCount: Int {
            max(0, rangeEnd - rangeStart)
        }

        var fallbackTranscript: String {
            payloadTranscript.isEmpty ? recentTranscript : payloadTranscript
        }
    }

    private typealias PendingSummaryRetry = MeetingSummaryRetryRecord

    private enum SummaryContinuation {
        case none
        case live
        case final
    }

    private nonisolated static func appendSystemAudioDiagnostic(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        let url = systemAudioDiagnosticsLogURL

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } else {
                try line.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("MoMoWhisper system audio diagnostic failed: \(error.localizedDescription)")
        }
    }

    func saveSummaryAPIKey(_ apiKey: String, kind: MeetingSummaryAPIKeyKind) {
        do {
            try KeychainSecretStore.writePassword(
                apiKey,
                service: kind.primaryKeychainService
            )
            saveSummarySettings(force: true)
            lastError = nil
            summaryStatusText = "\(kind.displayName) API key 與設定已儲存"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func hasSummaryAPIKey(kind: MeetingSummaryAPIKeyKind) -> Bool {
        return KeychainSecretStore.hasPassword(services: kind.keychainServices)
    }

    private func loadSummarySettings() {
        isLoadingSummarySettings = true
        defer { isLoadingSummarySettings = false }

        let defaults = UserDefaults.standard

        if let rawProvider = defaults.string(forKey: Self.summaryProviderKey),
           let provider = MeetingSummaryProvider(rawValue: rawProvider) {
            summaryProvider = provider
        }

        if let rawMode = defaults.string(forKey: Self.summaryTriggerModeKey),
           let mode = MeetingSummaryTriggerMode(rawValue: rawMode) {
            summaryTriggerMode = mode
        }

        let savedInterval = defaults.double(forKey: Self.summaryIntervalSecondsKey)
        if savedInterval > 0 {
            summaryIntervalSeconds = savedInterval
        }

        let savedThreshold = defaults.integer(forKey: Self.summaryCharacterThresholdKey)
        if savedThreshold > 0 {
            summaryCharacterThreshold = savedThreshold
        }

        if let text = defaults.string(forKey: Self.deepSeekBaseURLKey), !text.isEmpty {
            deepSeekBaseURLText = text
        }
        if let text = defaults.string(forKey: Self.deepSeekModelKey), !text.isEmpty {
            deepSeekModel = text
        }
        if let text = defaults.string(forKey: Self.lmStudioBaseURLKey) {
            lmStudioBaseURLText = text
        }
        if let text = defaults.string(forKey: Self.lmStudioModelKey), !text.isEmpty {
            lmStudioModel = text
        }
        if let text = defaults.string(forKey: Self.customBaseURLKey) {
            customBaseURLText = text
        }
        if let text = defaults.string(forKey: Self.customModelKey) {
            customModel = text
        }

        if defaults.object(forKey: Self.inputGainDecibelsKey) != nil {
            inputGainDecibels = defaults.double(forKey: Self.inputGainDecibelsKey)
        }

        if let rawMode = defaults.string(forKey: Self.voiceSensitivityModeKey),
           let mode = VoiceSensitivityMode(rawValue: rawMode) {
            voiceSensitivityMode = mode
        }

        if let rawMode = defaults.string(forKey: Self.audioCaptureModeKey),
           let mode = AudioCaptureMode(rawValue: rawMode) {
            audioCaptureMode = mode
        }

        if defaults.object(forKey: Self.manualVoiceThresholdDecibelsKey) != nil {
            manualVoiceThresholdDecibels = defaults.double(forKey: Self.manualVoiceThresholdDecibelsKey)
        }

        let savedPauseDelay = defaults.double(forKey: Self.pauseCommitDelaySecondsKey)
        if savedPauseDelay > 0 {
            pauseCommitDelaySeconds = savedPauseDelay
        }

        if let path = defaults.string(forKey: Self.recordingOutputDirectoryKey), !path.isEmpty {
            recordingOutputDirectoryPath = path
        }

        if let path = defaults.string(forKey: Self.highlightsOutputDirectoryKey), !path.isEmpty {
            highlightsOutputDirectoryPath = path
        }

        if defaults.object(forKey: Self.codexHandoffEnabledKey) != nil {
            codexHandoffEnabled = defaults.bool(forKey: Self.codexHandoffEnabledKey)
        }

        migrateLiveSummaryDefaultsIfNeeded(defaults: defaults)
    }

    private func migrateLiveSummaryDefaultsIfNeeded(defaults: UserDefaults) {
        guard defaults.integer(forKey: Self.summaryDefaultsVersionKey) < 2 else {
            return
        }

        let looksLikeOldDefaults =
            summaryProvider == .deepSeek &&
            summaryTriggerMode == .time &&
            Int(summaryIntervalSeconds.rounded()) == 300 &&
            summaryCharacterThreshold == 1_200

        if looksLikeOldDefaults && !hasSummaryAPIKey(kind: .deepSeek) {
            summaryProvider = .automatic
            summaryTriggerMode = .either
            summaryIntervalSeconds = 60
            summaryCharacterThreshold = 300
            defaults.set(summaryProvider.rawValue, forKey: Self.summaryProviderKey)
            defaults.set(summaryTriggerMode.rawValue, forKey: Self.summaryTriggerModeKey)
            defaults.set(summaryIntervalSeconds, forKey: Self.summaryIntervalSecondsKey)
            defaults.set(summaryCharacterThreshold, forKey: Self.summaryCharacterThresholdKey)
        }

        defaults.set(2, forKey: Self.summaryDefaultsVersionKey)
    }

    private func saveSummarySettings(force: Bool = false) {
        guard force || !isLoadingSummarySettings else {
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(summaryProvider.rawValue, forKey: Self.summaryProviderKey)
        defaults.set(summaryTriggerMode.rawValue, forKey: Self.summaryTriggerModeKey)
        defaults.set(max(30, summaryIntervalSeconds), forKey: Self.summaryIntervalSecondsKey)
        defaults.set(max(100, summaryCharacterThreshold), forKey: Self.summaryCharacterThresholdKey)
        defaults.set(deepSeekBaseURLText, forKey: Self.deepSeekBaseURLKey)
        defaults.set(deepSeekModel, forKey: Self.deepSeekModelKey)
        defaults.set(lmStudioBaseURLText, forKey: Self.lmStudioBaseURLKey)
        defaults.set(lmStudioModel, forKey: Self.lmStudioModelKey)
        defaults.set(customBaseURLText, forKey: Self.customBaseURLKey)
        defaults.set(customModel, forKey: Self.customModelKey)
        defaults.set(min(24, max(-12, inputGainDecibels)), forKey: Self.inputGainDecibelsKey)
        defaults.set(voiceSensitivityMode.rawValue, forKey: Self.voiceSensitivityModeKey)
        defaults.set(audioCaptureMode.rawValue, forKey: Self.audioCaptureModeKey)
        defaults.set(min(-20, max(-85, manualVoiceThresholdDecibels)), forKey: Self.manualVoiceThresholdDecibelsKey)
        defaults.set(min(2.0, max(0.15, pauseCommitDelaySeconds)), forKey: Self.pauseCommitDelaySecondsKey)
        defaults.set(recordingOutputDirectoryPath, forKey: Self.recordingOutputDirectoryKey)
        defaults.set(highlightsOutputDirectoryPath, forKey: Self.highlightsOutputDirectoryKey)
        defaults.set(codexHandoffEnabled, forKey: Self.codexHandoffEnabledKey)
        defaults.synchronize()
    }

    var hasContent: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !meetingNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasTranscriptContent: Bool {
        !visibleTranscriptOutput().isEmpty
    }

    var hasMeetingNotesContent: Bool {
        !meetingNotesOutput().isEmpty
    }

    var isViewingHistoricalSession: Bool {
        if case .loadedHistory = recordingLifecycle.state {
            return true
        }
        return false
    }

    var isSummaryRequestActive: Bool {
        isSummaryRequestInFlight
            || shouldRunSummaryAfterCurrentRequest
            || shouldRunFinalSummaryAfterCurrentRequest
            || postRecordingSummaryTask != nil
    }

    var transcriptCharacterCount: Int {
        visibleTranscriptOutput().count
    }

    var meetingNotesCharacterCount: Int {
        meetingNotesOutput().count
    }

    var summarizedTranscriptCount: Int {
        min(max(0, summaryDocument.processing.processedUnits), transcriptCharacterCount)
    }

    var unsummarizedTranscriptCount: Int {
        max(0, transcriptCharacterCount - summarizedTranscriptCount)
    }

    var summaryCoverageRatio: Double {
        guard transcriptCharacterCount > 0 else {
            return hasMeetingNotesContent ? 1 : 0
        }
        return min(1, Double(summarizedTranscriptCount) / Double(transcriptCharacterCount))
    }

    var summaryAICharacterCount: Int {
        min(summaryDocument.processing.aiUnits, transcriptCharacterCount)
    }

    var summaryFallbackCoverageCharacterCount: Int {
        min(summaryDocument.processing.fallbackUnits, transcriptCharacterCount)
    }

    var summaryPendingCharacterCount: Int {
        max(0, transcriptCharacterCount - summarizedTranscriptCount)
    }

    var latestValidMeetingMetadata: MeetingSessionMetadata? {
        meetingHistory.first { metadata in
            isMeetingMeaningfulForHandoff(metadata)
        }
    }

    func isMeetingMeaningfulForHandoff(_ metadata: MeetingSessionMetadata) -> Bool {
        if currentSessionMetadata?.id == metadata.id {
            return metadata.isMeaningfulForHandoff(summaryDocument: summaryDocument)
        }
        return meetingHistoryCache.isMeaningfulForHandoff(metadata)
    }

    var latestValidCodexHandoffJSONPath: String {
        MeetingArtifactExporter.defaultCodexHandoffDirectory
            .appendingPathComponent("\(MeetingArtifactExporter.latestValidHandoffBaseName).json")
            .path
    }

    private func inspectLatestValidCodexHandoffReadiness() -> Bool {
        let handoffCheck = DeliveryArtifactInspector.inspectTextFile(
            label: "latest_valid handoff",
            path: latestValidCodexHandoffJSONPath,
            minimumCharacters: 1
        )
        guard handoffCheck.meetsRequirement,
              let expectedMeetingID = latestValidMeetingMetadata?.id.uuidString,
              let data = FileManager.default.contents(atPath: latestValidCodexHandoffJSONPath),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (payload["schemaVersion"] as? NSNumber)?.intValue == 2,
              payload["meetingID"] as? String == expectedMeetingID,
              payload["compatibilityPathsTrusted"] as? Bool == false,
              let transactionID = payload["sessionTransactionID"] as? String,
              let sessionStatePath = payload["sessionStatePath"] as? String,
              let meetingID = UUID(uuidString: expectedMeetingID),
              let commit = try? meetingSessionStore.readVerifiedCommit(
                  at: URL(fileURLWithPath: sessionStatePath),
                  expectedTransactionID: transactionID,
                  expectedMeetingID: meetingID
              ) else {
            return false
        }
        return MeetingSummaryHandoffValidity.isValid(
            transcriptCharacterCount: commit.snapshot.metadata.transcriptCharacterCount,
            summaryDocument: commit.snapshot.summaryDocument
        )
    }

    private func inspectDeliveryArtifacts() -> [DeliveryArtifactCheck] {
        guard let metadata = currentSessionMetadata else {
            return [
                DeliveryArtifactInspector.inspectTextFile(
                    label: "逐字稿",
                    path: "",
                    minimumCharacters: Self.deliveryTranscriptMinimumCharacters
                ),
                DeliveryArtifactInspector.inspectTextFile(
                    label: "會議重點",
                    path: "",
                    minimumCharacters: Self.deliveryHighlightsMinimumCharacters
                ),
                DeliveryArtifactInspector.inspectBinaryFile(
                    label: "錄音 part",
                    path: "",
                    minimumBytes: Self.deliveryRecordingMinimumBytes
                ),
                DeliveryArtifactInspector.inspectTextFile(label: "Codex handoff", path: "", minimumCharacters: 1)
            ]
        }

        let committedSnapshot = currentSessionCommit?.snapshot
        let authoritativePath = currentSessionCommit?.authoritativeStateURL.path
            ?? meetingSessionStore.authoritativeStateURL(for: metadata).path
        var checks = [
            DeliveryArtifactInspector.inspectTextContent(
                label: "逐字稿",
                text: committedSnapshot?.transcriptMarkdown ?? "",
                sourcePath: "\(authoritativePath)#/snapshot/transcriptMarkdown",
                minimumCharacters: Self.deliveryTranscriptMinimumCharacters
            ),
            DeliveryArtifactInspector.inspectTextContent(
                label: "會議重點",
                text: committedSnapshot?.highlightsMarkdown ?? "",
                sourcePath: "\(authoritativePath)#/snapshot/highlightsMarkdown",
                minimumCharacters: Self.deliveryHighlightsMinimumCharacters
            )
        ]

        let committedMetadata = committedSnapshot?.metadata ?? metadata
        let recordingParts = committedMetadata.recordingParts.sorted { $0.sequence < $1.sequence }
        if recordingParts.isEmpty {
            checks.append(
                DeliveryArtifactInspector.inspectBinaryFile(
                    label: "錄音 part",
                    path: committedMetadata.recordingFilePath ?? "",
                    minimumBytes: Self.deliveryRecordingMinimumBytes
                )
            )
        } else {
            checks.append(contentsOf: recordingParts.map { part in
                DeliveryArtifactInspector.inspectBinaryFile(
                    label: "錄音 part \(part.sequence)",
                    path: part.filePath,
                    minimumBytes: Self.deliveryRecordingMinimumBytes
                )
            })
        }

        checks.append(
            DeliveryArtifactInspector.inspectTextFile(
                label: "Codex handoff",
                path: committedMetadata.codexHandoffFilePath ?? "",
                minimumCharacters: 1
            )
        )
        return checks
    }

    /// Refresh filesystem-backed trust evidence outside SwiftUI view
    /// evaluation. Views render only these published values and therefore never
    /// decode session snapshots or artifact files while evaluating `body`.
    private func refreshArtifactTrustCache(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastArtifactTrustCacheRefreshAt) >= 5 else {
            return
        }
        lastArtifactTrustCacheRefreshAt = now
        latestValidCodexHandoffExists = FileManager.default.fileExists(
            atPath: latestValidCodexHandoffJSONPath
        )
        latestValidCodexHandoffReady = inspectLatestValidCodexHandoffReadiness()
        deliveryArtifactChecks = inspectDeliveryArtifacts()
    }

    var vocabularyCount: Int {
        MeetingVocabulary.contextualStrings.count
    }

    var languageDisplayName: String {
        switch localeIdentifier {
        case "mixed-zh-en":
            return "中英混合"
        case "zh-TW":
            return "繁中"
        case "en-US":
            return "英文"
        case "ja-JP":
            return "日文"
        default:
            return localeIdentifier
        }
    }

    var recognitionModeText: String {
        let sourceText = audioCaptureMode.statusName
        let languageText = isMixedMode ? "中英混合" : languageDisplayName
        return "\(selectedTranscriptionEngine.shortDisplayName) · \(sourceText) · \(languageText)"
    }

    var sentenceBreakText: String {
        if usesSpeechAnalyzerRecognition {
            return "Apple 本機 SpeechAnalyzer · \(summaryTriggerDescription)"
        }

        return summaryTriggerDescription
    }

    var engineDisplayName: String {
        return "\(selectedTranscriptionEngine.displayName) + \(summaryProvider.displayName)"
    }

    var summaryTriggerDescription: String {
        let seconds = max(30, Int(summaryIntervalSeconds.rounded()))
        let timeText = seconds >= 60 ? "\(seconds / 60) 分鐘" : "\(seconds) 秒"
        let characterText = "\(max(100, summaryCharacterThreshold)) 字"

        switch summaryTriggerMode {
        case .time:
            return "自動：每 \(timeText)"
        case .characters:
            return "自動：每 \(characterText)"
        case .either:
            return "自動：\(timeText) 或 \(characterText)"
        case .both:
            return "自動：\(timeText) 且 \(characterText)"
        case .manualOnly:
            return "只手動整理"
        }
    }

    var audioSensitivityText: String {
        let gainText = "\(Self.oneDecimalFormatter.string(from: NSNumber(value: inputGainDecibels)) ?? "\(inputGainDecibels)") dB"
        let delayText = "\(Self.twoDecimalFormatter.string(from: NSNumber(value: pauseCommitDelaySeconds)) ?? "\(pauseCommitDelaySeconds)") 秒"

        switch voiceSensitivityMode {
        case .off:
            return "增益 \(gainText) · 靈敏度不設門檻 · 備援定稿 \(delayText)"
        case .automatic:
            return "增益 \(gainText) · 自動靈敏度 · 備援定稿 \(delayText)"
        case .manual:
            let thresholdText = "\(Self.oneDecimalFormatter.string(from: NSNumber(value: manualVoiceThresholdDecibels)) ?? "\(manualVoiceThresholdDecibels)") dB"
            return "增益 \(gainText) · 手動門檻 \(thresholdText) · 備援定稿 \(delayText)"
        }
    }

    var updatedAtText: String {
        guard let lastUpdatedAt else {
            return statusText
        }

        return "\(statusText) · \(Self.timeFormatter.string(from: lastUpdatedAt))"
    }

    var summaryUpdatedAtText: String {
        guard let lastSummaryUpdatedAt else {
            return summaryStatusText
        }

        return "\(summaryStatusText) · \(Self.timeFormatter.string(from: lastSummaryUpdatedAt))"
    }

    var preflightUpdatedAtText: String {
        guard let preflightLastCheckedAt else {
            return preflightStatusText
        }

        return "\(preflightStatusText) · \(Self.timeFormatter.string(from: preflightLastCheckedAt))"
    }

    private var isMixedMode: Bool {
        localeIdentifier == "mixed-zh-en"
    }

    private var recognitionLocaleIdentifier: String {
        isMixedMode ? "zh-TW" : localeIdentifier
    }

    private var usesSpeechAnalyzerRecognition: Bool {
        selectedTranscriptionEngine == .speechAnalyzer
    }

    private var primaryTranscriptSource: TranscriptSource {
        switch audioCaptureMode {
        case .systemAudioOnly:
            return .systemAudio
        case .microphoneOnly, .microphoneWithSystemMonitor:
            return .microphone
        }
    }

    private func invalidatePreflight() {
        guard preflightSummary.level != .pending else {
            return
        }
        preflightSummary = .pending
        preflightStatusText = "設定已變更，請重新執行會前檢查"
        preflightLastCheckedAt = nil
    }

    private func beginSessionOperation() -> UUID? {
        guard activeSessionOperationID == nil else {
            lastError = "錄音或會議狀態正在切換，請稍候再試。"
            return nil
        }
        let operationID = UUID()
        activeSessionOperationID = operationID
        isSessionTransitionInProgress = true
        return operationID
    }

    private func endSessionOperation(_ operationID: UUID) {
        guard activeSessionOperationID == operationID else { return }
        activeSessionOperationID = nil
        isSessionTransitionInProgress = false
    }

    private func isCurrentSessionOperation(_ operationID: UUID) -> Bool {
        activeSessionOperationID == operationID
    }

    func toggleRecording() async {
        guard !isTerminationQuiescing else { return }
        switch recordingLifecycle.state {
        case .recording:
            await stopRecording()
        case .startingNewSession, .startingRecordingPart(_):
            if recordingLifecycle.requestStop() == .abortStarting {
                statusText = "停止啟動中"
            }
        case .stopping(_):
            return
        case .idle, .ready(_), .ended(_), .loadedHistory(_):
            await startRecording()
        }
    }

    func startNextMeeting() async {
        guard !isTerminationQuiescing else { return }
        guard let operationID = beginSessionOperation() else { return }
        defer { endSessionOperation(operationID) }
        lastError = nil
        cancelSummaryWorkForSessionBoundary()

        if isRecording {
            guard await stopRecording(
                operationID: operationID,
                runFinalSummary: false
            ) else {
                statusText = "切換前保存失敗"
                return
            }
        } else if !isViewingHistoricalSession {
            if let saveTask = autosaveCurrentSession(
                endedAt: Date(),
                debounceNanoseconds: 0
            ), !(await saveTask.value) {
                return
            }
        }

        cancelSummaryWorkForSessionBoundary()

        resetLiveMeetingStateForNextMeeting()
        startNewMeetingSession()

        statusText = "下一場待開始"
        summaryStatusText = "待整理"
        artifactStatusText = "已切換下一場會議"
    }

    func refreshInputDevices() {
        let devices = AudioInputDeviceProvider.inputDevices()
        availableInputDevices = devices
        if !devices.contains(where: { $0.id == selectedInputDeviceID }) {
            selectedInputDeviceID = AudioInputDevice.systemDefaultID
        }
    }

    func requestOnboardingPermissions() async {
        lastError = nil
        onboardingPermissionStatusText = "權限檢查中"
        let granted = await requestPermissions(needsMicrophone: true)
        onboardingPermissionStatusText = granted ? "語音辨識與麥克風已允許" : "權限尚未完成"
        refreshInputDevices()
    }

    func runPreMeetingHealthCheck() async {
        guard !isRecording else {
            preflightStatusText = "錄音中不可執行會前檢查"
            preflightSummary = .completed(outcomes: [.failed])
            preflightLastCheckedAt = Date()
            return
        }

        lastError = nil
        preflightStatusText = "會前檢查中"
        preflightSummary = .running
        refreshInputDevices()

        var checks: [String] = []
        var outcomes: [PreflightCheckOutcome] = []

        if audioCaptureMode.usesMicrophone {
            do {
                _ = try AudioInputDeviceProvider.selectedDeviceID(for: selectedInputDeviceID)
                let deviceName = availableInputDevices.first(where: { $0.id == selectedInputDeviceID })?.name
                    ?? AudioInputDevice.systemDefault.name
                microphoneInputStatusText = "麥克風檢查通過 · \(deviceName)"
                checks.append("麥克風 \(deviceName)")
                outcomes.append(.passed)
            } catch {
                microphoneInputStatusText = "麥克風檢查失敗"
                lastError = "麥克風裝置不可用：\(error.localizedDescription)"
                checks.append("麥克風失敗")
                outcomes.append(.failed)
            }
        } else {
            microphoneInputStatusText = "麥克風未啟用"
            checks.append("麥克風未啟用")
            outcomes.append(.skipped)
        }

        if audioCaptureMode.capturesSystemAudio {
            await testSystemAudioCapture()
            let systemStatus = systemAudioInputStatusText
            checks.append(systemStatus)
            if systemStatus.contains("失敗") || systemStatus.contains("未收到") {
                outcomes.append(.failed)
            } else if systemStatus.contains("靜音") {
                outcomes.append(.warning)
            } else {
                outcomes.append(.passed)
            }
        } else {
            systemAudioInputStatusText = "系統音訊未啟用"
            checks.append("系統音訊未啟用")
            outcomes.append(.skipped)
        }

        speechRecognitionStatusText = "辨識檢查通過 · \(selectedTranscriptionEngine.shortDisplayName)"
        checks.append("辨識 \(selectedTranscriptionEngine.shortDisplayName)")
        outcomes.append(.passed)

        let compactSummary = checks.joined(separator: " / ")
        preflightSummary = .completed(outcomes: outcomes)
        switch preflightSummary.level {
        case .blocked:
            preflightStatusText = "會前檢查需處理：\(compactSummary)"
        case .warning:
            preflightStatusText = "會前檢查有提醒：\(compactSummary)"
        case .ready:
            preflightStatusText = "會前檢查通過：\(compactSummary)"
        case .pending, .running:
            break
        }
        preflightLastCheckedAt = Date()
    }

    func testSystemAudioCapture() async {
        guard !isRecording else {
            Self.appendSystemAudioDiagnostic("test skipped: recording is active")
            return
        }

        let preflightBeforeRequest = CGPreflightScreenCaptureAccess()
        Self.appendSystemAudioDiagnostic("test start: preflightBeforeRequest=\(preflightBeforeRequest)")
        lastError = nil
        systemAudioCapture.stop()
        systemAudioBufferCount = 0
        lastSystemAudioLevelDecibels = -120
        systemAudioInputStatusText = "系統音訊測試中"

        guard Self.requestScreenCaptureAccessIfNeeded() else {
            systemAudioInputStatusText = "系統音訊測試失敗"
            lastError = Self.systemAudioPermissionMessage(for: SystemAudioCapturePermissionError.screenCaptureDenied)
            Self.appendSystemAudioDiagnostic("test permission denied: preflightAfterRequest=\(CGPreflightScreenCaptureAccess())")
            return
        }

        Self.appendSystemAudioDiagnostic("test permission ok: preflightAfterRequest=\(CGPreflightScreenCaptureAccess())")
        do {
            try await systemAudioCapture.start(
                audioRouter: nil,
                audioProcessor: nil,
                onAudioBuffer: nil,
                onAudioLevel: { [weak self] decibels, bufferCount, format in
                    self?.updateSystemAudioLevel(
                        decibels: decibels,
                        bufferCount: bufferCount,
                        format: format
                    )
            },
            onError: { [weak self] message in
                self?.systemAudioInputStatusText = "系統音訊測試失敗"
                self?.lastError = message
                Self.appendSystemAudioDiagnostic("test stream error: \(message)")
            }
            )

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            systemAudioCapture.stop()

            if systemAudioBufferCount > 0, lastSystemAudioLevelDecibels > -90 {
                systemAudioInputStatusText = "系統音訊測試成功 · buffer \(systemAudioBufferCount)"
                Self.appendSystemAudioDiagnostic("test success: buffers=\(systemAudioBufferCount) level=\(lastSystemAudioLevelDecibels)dB")
            } else if systemAudioBufferCount > 0 {
                systemAudioInputStatusText = "系統音訊測試收到靜音 buffer"
                lastError = "系統音訊已有 buffer，但音量仍接近靜音（\(lastSystemAudioLevelDecibels)dB）。請確認輸出未靜音、正在播放可被螢幕錄音捕捉的 App 音訊；若要進逐字稿，請選「系統音訊」或「麥克風 + 系統音訊」。"
                Self.appendSystemAudioDiagnostic("test silent buffers: buffers=\(systemAudioBufferCount) level=\(lastSystemAudioLevelDecibels)dB")
            } else {
                systemAudioInputStatusText = "系統音訊測試未收到 buffer"
                lastError = "系統音訊測試未收到音訊 buffer。請確認正在播放電腦音訊，並檢查螢幕與系統錄音權限。"
                Self.appendSystemAudioDiagnostic("test no buffers: preflight=\(CGPreflightScreenCaptureAccess())")
            }
    } catch {
        systemAudioInputStatusText = "系統音訊測試失敗"
        lastError = Self.systemAudioPermissionMessage(for: error)
        Self.appendSystemAudioDiagnostic("test failed: \(error.localizedDescription)")
    }
    }

    func startRecording() async {
        guard !isTerminationQuiescing else { return }
        guard let operationID = beginSessionOperation() else { return }
        defer { endSessionOperation(operationID) }
        await startRecording(operationID: operationID)
    }

    private func startRecording(operationID: UUID) async {
        guard isCurrentSessionOperation(operationID), !isTerminationQuiescing else { return }
        lastError = nil
        stopPostRecordingSummaryDrain()

        let resolvedEngine = selectedTranscriptionEngine.resolvedForCurrentOS
        if resolvedEngine != selectedTranscriptionEngine {
            selectedTranscriptionEngine = resolvedEngine
            speechRecognitionStatusText = "已改用 Apple Speech"
        }

        if audioCaptureMode.usesMicrophone,
           audioCaptureMode.routesSystemAudioToTranscript,
           !usesSpeechAnalyzerRecognition {
            statusText = "模式不支援"
            lastError = "「麥克風 + 系統音訊」需要 SpeechAnalyzer 雙通道辨識；請切回 SpeechAnalyzer，避免 Apple Speech 單一路徑把兩路音訊硬混。"
            return
        }

        let startDecision = recordingLifecycle.requestStart()
        switch startDecision {
        case .ignored:
            statusText = "錄音狀態轉換中"
            return
        case .createNewSession:
            cancelSummaryWorkForSessionBoundary()
            if !isViewingHistoricalSession, currentSessionMetadata != nil {
                let boundaryTask = hasContent
                    ? exportFinalArtifactsIfPossible()
                    : autosaveCurrentSession(debounceNanoseconds: 0)
                if let boundaryTask, !(await boundaryTask.value) {
                    recordingLifecycle.failStart()
                    statusText = "建立新會議前保存失敗"
                    return
                }
            }
            guard isCurrentSessionOperation(operationID),
                  case .startingNewSession = recordingLifecycle.state else {
                _ = await abortStartingRecording()
                return
            }
            cancelSummaryWorkForSessionBoundary()
            resetLiveMeetingStateForNextMeeting()
            guard recordingLifecycle.requestStart() == .createNewSession else {
                lastError = "無法建立新的錄音 session。"
                return
            }
            startNewMeetingSession()
            guard let metadata = currentSessionMetadata,
                  case .startRecordingPart(_) = recordingLifecycle.attachNewSession(metadata.id) else {
                recordingLifecycle.failStart()
                lastError = "建立錄音 session 後無法準備 recording part。"
                return
            }
        case .startRecordingPart(_):
            break
        }

        guard await requestPermissions(needsMicrophone: audioCaptureMode.usesMicrophone) else {
            _ = await failStartingRecording()
            statusText = "權限未開"
            return
        }

        guard isCurrentSessionOperation(operationID),
              recordingLifecycle.isStartStillActive else {
            _ = await abortStartingRecording()
            return
        }

        if usesSpeechAnalyzerRecognition {
            guard #available(macOS 26.0, *) else {
                statusText = "語音服務不可用"
                lastError = "SpeechAnalyzer 需要 macOS 26 或更新版本。"
                _ = await failStartingRecording()
                return
            }

        do {
            try await startSpeechAnalyzerSession()
            if audioCaptureMode.usesMicrophone && audioCaptureMode.routesSystemAudioToTranscript {
                try await startSystemSpeechAnalyzerSession()
            }
        } catch {
            statusText = "SpeechAnalyzer 啟動失敗"
            lastError = error.localizedDescription
            cancelSpeechAnalyzerSession()
            _ = await failStartingRecording()
            return
        }
        } else {
            guard let speechRecognizer, speechRecognizer.isAvailable else {
                statusText = "語音服務不可用"
                lastError = "目前語音辨識服務不可用，請稍後再試或切換語言。"
                _ = await failStartingRecording()
                return
            }
        }

        guard isCurrentSessionOperation(operationID),
              recordingLifecycle.isStartStillActive else {
            cancelSpeechAnalyzerSession()
            _ = await abortStartingRecording()
            return
        }

        stopRecognitionOnly()
        resetRecognitionSegment()
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resetCommittedTranscriptTracking()
        }
        microphoneLevelMeter.reset()
        microphoneAudioProcessor = audioCaptureMode.usesMicrophone
            ? AudioInputProcessor(configuration: currentAudioProcessingConfiguration())
            : nil
        microphoneBufferCount = 0
        systemAudioBufferCount = 0
        recognitionUpdateCount = 0
        lastMicrophoneLevelDecibels = -120
        lastSystemAudioLevelDecibels = -120
        lastMicrophoneStatusUpdateAt = .distantPast
        lastSystemAudioStatusUpdateAt = .distantPast
        microphoneInputStatusText = audioCaptureMode.usesMicrophone ? "麥克風啟動中" : "麥克風未啟用"
        systemAudioInputStatusText = audioCaptureMode.capturesSystemAudio ? "系統音訊啟動中" : "系統音訊未啟用"
        speechRecognitionStatusText = usesSpeechAnalyzerRecognition ? "SpeechAnalyzer 啟動中" : "辨識啟動中"

        guard prepareRecordingArtifactForCurrentSession() else {
            statusText = "輸出未就緒"
            cancelSpeechAnalyzerSession()
            _ = await failStartingRecording()
            return
        }

        if audioCaptureMode.usesMicrophone {
            let inputNode = audioEngine.inputNode
            do {
                try AudioInputDeviceProvider.applyInputDevice(selection: selectedInputDeviceID, to: inputNode)
            } catch {
                statusText = "啟動失敗"
                lastError = error.localizedDescription
                cancelSpeechAnalyzerSession()
                _ = await failStartingRecording()
                return
            }

            let format = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            let analyzerAudioBufferHandler = speechAnalyzerAudioBufferHandler()
            let audioRecorder = meetingAudioRecorder
            let microphoneAudioBufferHandler: @Sendable (AVAudioPCMBuffer) -> Void = { buffer in
                audioRecorder.append(buffer)
                analyzerAudioBufferHandler?(buffer)
            }
            let microphoneAudioProcessor = microphoneAudioProcessor

            Self.installAudioTap(
                on: inputNode,
                format: format,
                router: usesSpeechAnalyzerRecognition ? nil : audioRouter,
                levelMeter: microphoneLevelMeter,
                audioProcessor: microphoneAudioProcessor,
                onAudioBuffer: microphoneAudioBufferHandler
            ) { [weak self] decibels, bufferCount in
                self?.updateMicrophoneLevel(decibels: decibels, bufferCount: bufferCount, format: format)
            }

            do {
                audioEngine.prepare()
                try audioEngine.start()
            } catch {
                inputNode.removeTap(onBus: 0)
                statusText = "啟動失敗"
                lastError = error.localizedDescription
                cancelSpeechAnalyzerSession()
                _ = await failStartingRecording()
                return
            }
        } else {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }

        if usesSpeechAnalyzerRecognition {
            speechRecognitionStatusText = "SpeechAnalyzer 辨識中"
        } else {
            startNewRecognitionTask(resetSegment: true)
        }

        let systemAudioReady = await startSystemAudioCaptureIfNeeded()
        guard systemAudioReady || !audioCaptureMode.routesSystemAudioToTranscript else {
            statusText = "啟動失敗"
            speechRecognitionStatusText = "辨識未啟動"
            stopRecognitionOnly()
            cancelSpeechAnalyzerSession()
            _ = await failStartingRecording()
            return
        }

        guard isCurrentSessionOperation(operationID),
              recordingLifecycle.isStartStillActive,
              recordingLifecycle.markRecordingStarted() else {
            _ = await abortStartingRecording()
            return
        }

        markCurrentRecordingPartAsRecording()
        isRecording = true
        statusText = "收音中"
        microphoneInputStatusText = audioCaptureMode.usesMicrophone ? "麥克風收音中" : "麥克風未啟用"
        lastAutomaticSummaryAt = Date().addingTimeInterval(-max(30, summaryIntervalSeconds))
        startLiveSummaryLoop()
        exportLiveHandoffIfPossible()
    }

    @discardableResult
    func stopRecording(runFinalSummary: Bool = true) async -> Bool {
        guard let operationID = beginSessionOperation() else { return false }
        defer { endSessionOperation(operationID) }
        return await stopRecording(
            operationID: operationID,
            runFinalSummary: runFinalSummary
        )
    }

    private func stopRecording(
        operationID: UUID,
        runFinalSummary: Bool
    ) async -> Bool {
        guard isCurrentSessionOperation(operationID) else { return false }
        switch recordingLifecycle.requestStop() {
        case .stopActiveRecording:
            break
        case .abortStarting:
            return await abortStartingRecording()
        case .ignored:
            return true
        }

        let shouldFinishSpeechAnalyzer = usesSpeechAnalyzerRecognition

        if !shouldFinishSpeechAnalyzer {
            commitPendingSentence()
        }

        partialTranscript = ""
        latestRecognitionText = ""
        latestFullRecognitionText = ""
        committedRecognitionText = ""
        liveDraftStartedAt = nil
        speechRecognitionStatusText = "辨識已停止"

        stopRecognitionOnly()
        systemAudioCapture.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        microphoneAudioProcessor = nil

        if shouldFinishSpeechAnalyzer {
            await finishSpeechAnalyzerSession()
        }

        finishRecordingArtifact()

        systemAudioInputStatusText = audioCaptureMode.capturesSystemAudio ? "系統音訊已停止" : "系統音訊未啟用"
        microphoneInputStatusText = audioCaptureMode.usesMicrophone ? "麥克風已停止" : "麥克風未啟用"
        stopLiveSummaryLoop()
        statusText = "已停止"
        isRecording = false
        cancelSummaryWorkForSessionBoundary()
        guard let saveTask = autosaveCurrentSession(
            endedAt: Date(),
            debounceNanoseconds: 0
        ) else {
            recordingLifecycle.finishStop()
            lastError = "停止錄音後無法建立保存工作。"
            return false
        }
        guard await saveTask.value else {
            recordingLifecycle.finishStop()
            return false
        }
        recordingLifecycle.finishStop()

        guard runFinalSummary else {
            return true
        }

        if runMeetingSummary(isFinal: true, force: true) {
            startPostRecordingSummaryDrain()
        }
        return true
    }

    func clear() async {
        guard !isTerminationQuiescing else { return }
        guard let operationID = beginSessionOperation() else { return }
        defer { endSessionOperation(operationID) }
        guard !isRecording else {
            lastError = "錄音中不可清空；請先停止錄音，確認保存完成後再清空。"
            return
        }
        switch recordingLifecycle.state {
        case .startingNewSession, .startingRecordingPart, .stopping:
            lastError = "錄音狀態切換中，暫時不可清空。"
            return
        case .idle, .ready, .recording, .ended, .loadedHistory:
            break
        }
        cancelSummaryWorkForSessionBoundary()
        if !isViewingHistoricalSession {
            if let saveTask = autosaveCurrentSession(
                endedAt: Date(),
                debounceNanoseconds: 0
            ), !(await saveTask.value) {
                return
            }
        }
        persistenceEpoch &+= 1
        currentSessionCommit = nil
        recordingLifecycle.reset()
        currentRecordingURL = nil
        transcript = ""
        partialTranscript = ""
        meetingNotes = ""
        rawMeetingNotes = ""
        summaryDocument = .empty(id: "unsaved-meeting", title: "未命名會議")
        currentSessionMetadata = nil
        currentSessionStartedAt = nil
        transcriptSegments = []
        latestRecognitionText = ""
        latestFullRecognitionText = ""
        committedRecognitionText = ""
        liveDraftStartedAt = nil
        resetCommittedTranscriptTracking()
        microphoneBufferCount = 0
        systemAudioBufferCount = 0
        recognitionUpdateCount = 0
        lastMicrophoneLevelDecibels = -120
        lastSystemAudioLevelDecibels = -120
        microphoneInputStatusText = "麥克風待開始"
        systemAudioInputStatusText = "系統音訊待開始"
        speechRecognitionStatusText = "辨識待開始"
        microphoneAudioProcessor = nil
        pendingCommitTask?.cancel()
        pendingCommitTask = nil
        cancelSpeechAnalyzerSession()
        cancelSummaryWorkForSessionBoundary()
        liveSummaryState = .empty
        lastError = nil
        lastUpdatedAt = nil
        lastSummaryUpdatedAt = nil
        lastAutomaticSummaryAt = nil
        lastSummarizedTranscriptCharacterCount = 0
        lastSummarizedTranscriptPrefix = ""
        accumulatedAISummaryUnits = 0
        accumulatedFallbackSummaryUnits = 0
        pendingSummaryRetries = []
        deepSeekDiagnosticsText = "DeepSeek cache 待開始"
        summaryStatusText = "待整理"
    }

    private func cancelSummaryWorkForSessionBoundary() {
        summaryGeneration += 1
        summaryTask?.cancel()
        summaryTask = nil
        summaryRequestTask?.cancel()
        summaryRequestTask = nil
        manualTranscriptEditTask?.cancel()
        manualTranscriptEditTask = nil
        manualTranscriptEditInvalidatedSummary = false
        stopPostRecordingSummaryDrain()
        stopLiveSummaryLoop()
        isSummaryRequestInFlight = false
        shouldRunSummaryAfterCurrentRequest = false
        shouldRunFinalSummaryAfterCurrentRequest = false
    }

    private func resetLiveMeetingStateForNextMeeting() {
        recordingLifecycle.reset()
        transcript = ""
        partialTranscript = ""
        meetingNotes = ""
        rawMeetingNotes = ""
        summaryDocument = .empty(id: "unsaved-meeting", title: "未命名會議")
        currentSessionMetadata = nil
        currentSessionStartedAt = nil
        transcriptSegments = []
        latestRecognitionText = ""
        latestFullRecognitionText = ""
        committedRecognitionText = ""
        liveDraftStartedAt = nil
        resetCommittedTranscriptTracking()
        microphoneBufferCount = 0
        systemAudioBufferCount = 0
        recognitionUpdateCount = 0
        lastMicrophoneLevelDecibels = -120
        lastSystemAudioLevelDecibels = -120
        microphoneInputStatusText = audioCaptureMode.usesMicrophone ? "麥克風待開始" : "麥克風未啟用"
        systemAudioInputStatusText = audioCaptureMode.capturesSystemAudio ? "系統音訊待開始" : "系統音訊未啟用"
        speechRecognitionStatusText = "辨識待開始"
        microphoneAudioProcessor = nil
        currentRecordingURL = nil
        lastRecordingFilePath = ""
        lastHighlightsFilePath = ""
        lastCodexHandoffPath = ""
        liveSummaryState = .empty
        lastUpdatedAt = nil
        lastSummaryUpdatedAt = nil
        lastAutomaticSummaryAt = nil
        lastSummarizedTranscriptCharacterCount = 0
        lastSummarizedTranscriptPrefix = ""
        accumulatedAISummaryUnits = 0
        accumulatedFallbackSummaryUnits = 0
        pendingSummaryRetries = []
        deepSeekDiagnosticsText = "DeepSeek cache 待開始"
    }

    func refreshMeetingNotes() {
        guard !isTerminationQuiescing, activeSessionOperationID == nil else { return }
        if pendingSummaryRetries.contains(where: { $0.attempts >= Self.maximumBackgroundSummaryRetryAttempts }) {
            pendingSummaryRetries = pendingSummaryRetries.map { retry in
                var rearmed = retry
                rearmed.attempts = 0
                return rearmed
            }
            summaryStatusText = "已重新啟用本機備援範圍，準備重試"
            reconcileSummaryProcessing(totalUnits: summaryTranscriptOutput().count)
        }
        runMeetingSummary(isFinal: true, force: true)
    }

    func updateSummaryItem(
        id: String,
        text: String,
        status: MeetingSummaryItemStatus,
        owner: String? = nil,
        dueDate: String? = nil
    ) {
        guard !isTerminationQuiescing, activeSessionOperationID == nil else { return }
        guard var item = summaryDocument.items.first(where: { $0.id == id }) else {
            return
        }
        item.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        item.status = status
        item.owner = Self.nilIfBlank(owner)
        item.dueDate = Self.nilIfBlank(dueDate)
        item.source = .manual
        item.lockedByUser = true
        applyDocumentDelta(.init(
            id: "manual-update-\(id)-\(UUID().uuidString)",
            operations: [.upsertItem(item)]
        ))
        autosaveCurrentSession()
    }

    func setSummaryItemLocked(id: String, locked: Bool) {
        guard !isTerminationQuiescing, activeSessionOperationID == nil else { return }
        guard var item = summaryDocument.items.first(where: { $0.id == id }) else {
            return
        }
        item.source = .manual
        item.lockedByUser = locked
        applyDocumentDelta(.init(
            id: "manual-lock-\(id)-\(UUID().uuidString)",
            operations: [.upsertItem(item)]
        ))
        autosaveCurrentSession()
    }

    func resolveSummaryItem(id: String) {
        guard !isTerminationQuiescing, activeSessionOperationID == nil else { return }
        guard var item = summaryDocument.items.first(where: { $0.id == id }) else {
            return
        }
        item.status = .resolved
        item.source = .manual
        item.lockedByUser = true
        applyDocumentDelta(.init(
            id: "manual-resolve-\(id)-\(UUID().uuidString)",
            operations: [.upsertItem(item)]
        ))
        autosaveCurrentSession()
    }

    func updateSummaryHeadline(_ headline: String) {
        guard !isTerminationQuiescing, activeSessionOperationID == nil else { return }
        applyDocumentDelta(.init(
            id: "manual-headline-\(UUID().uuidString)",
            operations: [.setManualHeadline(headline)]
        ))
        autosaveCurrentSession()
    }

    func startNewMeetingSession(title: String? = nil) {
        do {
            persistenceEpoch &+= 1
            currentSessionCommit = nil
            let metadata = try meetingSessionStore.createSession(title: title)
            currentSessionMetadata = metadata
            currentSessionStartedAt = metadata.startedAt
            summaryDocument = .empty(id: metadata.id.uuidString, title: metadata.displayTitle)
            liveSummaryState = .empty
            meetingNotes = ""
            rawMeetingNotes = ""
            lastSummarizedTranscriptCharacterCount = 0
            lastSummarizedTranscriptPrefix = ""
            accumulatedAISummaryUnits = 0
            accumulatedFallbackSummaryUnits = 0
            pendingSummaryRetries = []
            currentRecordingURL = nil
            if case .startingNewSession = recordingLifecycle.state {
                // startRecording() attaches this freshly allocated session before creating a part.
            } else {
                recordingLifecycle.prepareNewSession(metadata.id)
            }
            transcriptSegments = []
            refreshMeetingHistory()
            autosaveCurrentSession()
            refreshArtifactTrustCache(force: true)
        } catch {
            lastError = "建立會議歷史失敗：\(error.localizedDescription)"
        }
    }

    func refreshMeetingHistory() {
        do {
            let records = try meetingSessionStore.searchHistoryRecords(query: meetingHistorySearchText)
            meetingHistoryCache.replace(with: records)
            meetingHistory = records.map(\.metadata)
            refreshArtifactTrustCache()
        } catch {
            meetingHistoryCache.replace(with: [])
            meetingHistory = []
            refreshArtifactTrustCache()
            lastError = "讀取會議歷史失敗：\(error.localizedDescription)"
        }
    }

    /// Autosave already has the committed record in memory, so update the
    /// visible history and badge cache directly instead of rescanning every
    /// meeting folder after each recognized utterance.
    private func upsertCommittedHistoryRecord(_ record: MeetingSessionHistoryRecord) {
        meetingHistory.removeAll { $0.id == record.metadata.id }
        if historyRecordMatchesCurrentSearch(record) {
            meetingHistory.append(record.metadata)
            meetingHistory.sort { $0.updatedAt > $1.updatedAt }
            meetingHistoryCache.upsert(record)
        } else {
            meetingHistoryCache.remove(id: record.metadata.id)
        }
    }

    private func historyRecordMatchesCurrentSearch(_ record: MeetingSessionHistoryRecord) -> Bool {
        let keywords = meetingHistorySearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !keywords.isEmpty else {
            return true
        }

        let metadata = record.metadata
        let haystack = [
            metadata.title,
            metadata.folderName,
            metadata.summaryProvider,
            metadata.transcriptionEngine,
            metadata.audioCaptureMode,
            MeetingSessionStore.displayDateFormatter.string(from: metadata.startedAt)
        ]
        .joined(separator: " ")
        .lowercased()
        return keywords.allSatisfy { haystack.contains($0) }
    }

    func loadMeetingSession(_ metadata: MeetingSessionMetadata) async {
        guard !isTerminationQuiescing else { return }
        guard let operationID = beginSessionOperation() else { return }
        defer { endSessionOperation(operationID) }
        guard !isRecording else {
            lastError = "錄音中不可載入歷史會議。"
            return
        }

        cancelSummaryWorkForSessionBoundary()
        if !isViewingHistoricalSession,
           let saveTask = autosaveCurrentSession(
               endedAt: currentSessionMetadata?.endedAt,
               debounceNanoseconds: 0
           ), !(await saveTask.value) {
            return
        }

        do {
            persistenceEpoch &+= 1
            let committedSession = try? meetingSessionStore.loadCommit(metadata: metadata)
            let snapshot = try committedSession?.snapshot
                ?? meetingSessionStore.loadSnapshot(metadata: metadata)
            currentSessionCommit = committedSession
            currentSessionMetadata = snapshot.metadata
            currentSessionStartedAt = snapshot.metadata.startedAt
            recordingLifecycle.markHistoryLoaded(snapshot.metadata.id)
            currentRecordingURL = nil
            lastRecordingFilePath = snapshot.metadata.recordingFilePath ?? ""
            transcriptSegments = snapshot.transcriptSegments
            transcript = snapshot.summarySourceTranscript
            partialTranscript = ""
            rawMeetingNotes = snapshot.highlightsMarkdown
            meetingNotes = snapshot.highlightsMarkdown
            liveSummaryState = snapshot.rawSummaryState
            summaryDocument = snapshot.summaryDocument
            if !summaryDocument.items.isEmpty || !summaryDocument.headline.isEmpty {
                meetingNotes = MeetingSummaryRenderer.render(summaryDocument)
            }
            latestRecognitionText = ""
            latestFullRecognitionText = ""
            committedRecognitionText = ""
            liveDraftStartedAt = nil
            resetCommittedTranscriptTracking()
            lastUpdatedAt = snapshot.metadata.updatedAt
            lastSummaryUpdatedAt = snapshot.metadata.updatedAt
            lastSummarizedTranscriptCharacterCount = min(
                transcript.count,
                summaryDocument.processing.processedUnits
            )
            lastSummarizedTranscriptPrefix = String(
                summaryTranscriptOutput().prefix(lastSummarizedTranscriptCharacterCount)
            )
            accumulatedAISummaryUnits = summaryDocument.processing.aiUnits
            accumulatedFallbackSummaryUnits = summaryDocument.processing.fallbackUnits
            // Exact retry ranges are persisted separately. Loading remains read-only:
            // no retry is executed until the user explicitly resumes or starts work.
            pendingSummaryRetries = snapshot.summaryRetries
            statusText = "已載入歷史"
            summaryStatusText = "已載入重點"
            if !snapshot.quarantinedSummaryRetries.isEmpty {
                lastError = "已隔離 \(snapshot.quarantinedSummaryRetries.count) 筆失效的摘要重試；不會送往 AI 服務。"
            }
            refreshArtifactTrustCache(force: true)
        } catch {
            lastError = "載入歷史會議失敗：\(error.localizedDescription)"
        }
    }

    func resumeCurrentMeetingSession() async {
        guard !isTerminationQuiescing else { return }
        guard let operationID = beginSessionOperation() else { return }
        defer { endSessionOperation(operationID) }
        guard case let .startRecordingPart(sessionID) = recordingLifecycle.requestExplicitResume() else {
            lastError = "只有已結束或已載入的會議可以明確續錄。"
            return
        }

        guard var metadata = currentSessionMetadata, metadata.id == sessionID else {
            recordingLifecycle.failStart()
            lastError = "找不到要續錄的會議。"
            return
        }

        metadata.endedAt = nil
        metadata.updatedAt = Date()
        currentSessionMetadata = metadata
        // startRecording() owns the writer setup. Restoring ready here makes this an
        // explicit resume that creates a new part rather than reopening an old WAV.
        recordingLifecycle.prepareNewSession(sessionID)
        await startRecording(operationID: operationID)
    }

    func openMeetingSessionFolder(_ metadata: MeetingSessionMetadata) {
        NSWorkspace.shared.open(meetingSessionStore.sessionFolderURL(for: metadata))
    }

    func copyMeetingSessionFolderPath(_ metadata: MeetingSessionMetadata) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meetingSessionStore.sessionFolderURL(for: metadata).path, forType: .string)
    }

    var currentSessionFolderPath: String? {
        currentSessionMetadata.map { meetingSessionStore.sessionFolderURL(for: $0).path }
    }

    var codexHandoffDirectoryPath: String {
        MeetingArtifactExporter.defaultCodexHandoffDirectory.path
    }

    func chooseRecordingOutputDirectory() {
        chooseDirectory(
            title: "選擇錄音檔存放位置",
            currentPath: recordingOutputDirectoryPath
        ) { [weak self] url in
            self?.recordingOutputDirectoryPath = url.path
            self?.artifactStatusText = "錄音將輸出到 \(url.path)"
        }
    }

    func chooseHighlightsOutputDirectory() {
        chooseDirectory(
            title: "選擇會議重點存放位置",
            currentPath: highlightsOutputDirectoryPath
        ) { [weak self] url in
            self?.highlightsOutputDirectoryPath = url.path
            self?.artifactStatusText = "會議重點將輸出到 \(url.path)"
        }
    }

    func revealRecordingOutputDirectory() {
        revealDirectory(path: recordingOutputDirectoryPath)
    }

    func revealHighlightsOutputDirectory() {
        revealDirectory(path: highlightsOutputDirectoryPath)
    }

    func revealCodexHandoffDirectory() {
        revealDirectory(path: codexHandoffDirectoryPath)
    }

    func resetArtifactOutputDirectories() {
        recordingOutputDirectoryPath = MeetingArtifactExporter.defaultRecordingsDirectory.path
        highlightsOutputDirectoryPath = MeetingArtifactExporter.defaultHighlightsDirectory.path
        artifactStatusText = "已恢復 MoMoWhisper 預設輸出位置"
    }

    func copyLatestCodexHandoffPath() {
        let path = lastCodexHandoffPath.isEmpty
            ? MeetingArtifactExporter.defaultCodexHandoffDirectory.appendingPathComponent("latest_meeting_handoff.md").path
            : lastCodexHandoffPath
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        artifactStatusText = "已複製 Codex handoff 路徑"
    }

    private func chooseDirectory(title: String, currentPath: String, onSelection: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: currentPath, isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            onSelection(url)
        }
    }

    private func revealDirectory(path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func prepareRecordingArtifactForCurrentSession() -> Bool {
        guard var metadata = currentSessionMetadata else {
            artifactStatusText = "尚未建立會議，無法準備錄音檔"
            return false
        }

        do {
            let outputDirectory = URL(fileURLWithPath: recordingOutputDirectoryPath, isDirectory: true)
            let partID = UUID()
            let sequence = metadata.recordingParts.count + 1
            let recordingURL = try meetingAudioRecorder.start(
                outputDirectory: outputDirectory,
                fileBaseName: "\(metadata.folderName)-part-\(sequence)-\(partID.uuidString.prefix(8))"
            )

            currentRecordingURL = recordingURL
            lastRecordingFilePath = recordingURL.path
            metadata.recordingFilePath = recordingURL.path
            metadata.recordingParts.append(
                MeetingRecordingPart(
                    id: partID,
                    sequence: sequence,
                    filePath: recordingURL.path,
                    startedAt: Date(),
                    endedAt: nil,
                    readiness: .prepared
                )
            )
            metadata.recordingReadiness = .prepared
            metadata.recordingReadinessDetail = metadata.recordingReadiness.verificationBoundary
            currentSessionMetadata = metadata
            artifactStatusText = "錄音 part \(sequence) 已準備；尚未驗證音訊內容"
            return true
        } catch {
            currentRecordingURL = nil
            metadata.recordingReadiness = .failed
            metadata.recordingReadinessDetail = "錄音 writer 無法配置：\(error.localizedDescription)"
            currentSessionMetadata = metadata
            lastError = "錄音檔準備失敗：\(error.localizedDescription)"
            artifactStatusText = "錄音檔準備失敗"
            return false
        }
    }

    private func markCurrentRecordingPartAsRecording() {
        guard let recordingURL = currentRecordingURL, var metadata = currentSessionMetadata else {
            return
        }

        if let index = metadata.recordingParts.lastIndex(where: { $0.filePath == recordingURL.path }) {
            metadata.recordingParts[index].readiness = .recording
        }
        metadata.recordingReadiness = .recording
        metadata.recordingReadinessDetail = metadata.recordingReadiness.verificationBoundary
        currentSessionMetadata = metadata
    }

    private func finishRecordingArtifact() {
        guard let activeRecordingURL = currentRecordingURL else {
            return
        }

        let stoppedURL = meetingAudioRecorder.stop() ?? activeRecordingURL
        currentRecordingURL = stoppedURL
        let errorMessage = meetingAudioRecorder.consumeLastErrorMessage()

        if let errorMessage {
            lastError = "錄音檔寫入失敗：\(errorMessage)"
            artifactStatusText = "錄音檔寫入失敗"
        }

        lastRecordingFilePath = stoppedURL.path
        if var metadata = currentSessionMetadata {
            metadata.recordingFilePath = stoppedURL.path
            let partReadiness: MeetingRecordingReadiness
            if errorMessage != nil {
                partReadiness = .failed
            } else if FileManager.default.fileExists(atPath: stoppedURL.path) {
                partReadiness = .writerStopped
            } else {
                partReadiness = .unavailable
            }
            if let index = metadata.recordingParts.lastIndex(where: { $0.filePath == stoppedURL.path }) {
                metadata.recordingParts[index].endedAt = Date()
                metadata.recordingParts[index].readiness = partReadiness
            }
            metadata.recordingReadiness = partReadiness
            metadata.recordingReadinessDetail = partReadiness.verificationBoundary
            currentSessionMetadata = metadata
        }

        if FileManager.default.fileExists(atPath: stoppedURL.path) {
            artifactStatusText = "錄音 writer 已停止；尚未驗證音訊完整性"
        } else {
            artifactStatusText = "錄音未收到音訊 buffer"
        }
    }

    private func failStartingRecording() async -> Bool {
        let endedAt = Date()
        stopRecognitionOnly()
        systemAudioCapture.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        microphoneAudioProcessor = nil
        cancelSpeechAnalyzerSession()

        if let recordingURL = currentRecordingURL {
            _ = meetingAudioRecorder.stop()
            if var metadata = currentSessionMetadata {
                if let index = metadata.recordingParts.lastIndex(where: { $0.filePath == recordingURL.path }) {
                    metadata.recordingParts[index].endedAt = endedAt
                    metadata.recordingParts[index].readiness = .failed
                }
                metadata.recordingReadiness = .failed
                metadata.recordingReadinessDetail = metadata.recordingReadiness.verificationBoundary
                metadata.endedAt = endedAt
                metadata.updatedAt = endedAt
                currentSessionMetadata = metadata
            }
        } else if var metadata = currentSessionMetadata {
            metadata.endedAt = endedAt
            metadata.updatedAt = endedAt
            currentSessionMetadata = metadata
        }

        isRecording = false
        recordingLifecycle.failStart()
        guard let saveTask = autosaveCurrentSession(
            endedAt: endedAt,
            debounceNanoseconds: 0
        ) else {
            return currentSessionMetadata == nil
        }
        return await saveTask.value
    }

    private func abortStartingRecording() async -> Bool {
        let endedAt = Date()
        stopRecognitionOnly()
        systemAudioCapture.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        microphoneAudioProcessor = nil
        cancelSpeechAnalyzerSession()

        if currentRecordingURL != nil {
            finishRecordingArtifact()
        }

        if var metadata = currentSessionMetadata {
            metadata.endedAt = endedAt
            metadata.updatedAt = endedAt
            currentSessionMetadata = metadata
        }

        isRecording = false
        recordingLifecycle.finishStop()
        statusText = "已停止"
        guard let saveTask = autosaveCurrentSession(
            endedAt: endedAt,
            debounceNanoseconds: 0
        ) else {
            return currentSessionMetadata == nil
        }
        return await saveTask.value
    }

    private func exportLiveHandoffIfPossible() {
        autosaveCurrentSession()
    }

    /// Called by AppDelegate before AppKit terminates the process. A zero-delay
    /// revision supersedes any pending 250 ms autosave and waits until the
    /// authoritative snapshot plus required final artifacts are durable.
    func prepareForTermination() async -> Bool {
        guard !isTerminationQuiescing else { return false }
        isTerminationQuiescing = true
        var completed = false
        defer {
            if !completed {
                isTerminationQuiescing = false
            }
        }
        guard let operationID = beginSessionOperation() else { return false }
        defer { endSessionOperation(operationID) }
        cancelSummaryWorkForSessionBoundary()

        switch recordingLifecycle.state {
        case .recording, .startingNewSession, .startingRecordingPart:
            completed = await stopRecording(
                operationID: operationID,
                runFinalSummary: false
            )
            return completed
        case .stopping:
            lastError = "正在停止錄音，請稍後再結束 MoMoWhisper。"
            return false
        case .idle, .ready, .ended, .loadedHistory:
            break
        }

        guard !isViewingHistoricalSession,
              currentSessionMetadata != nil,
              hasContent || currentSessionMetadata?.recordingFilePath != nil else {
            completed = true
            return true
        }

        guard let saveTask = autosaveCurrentSession(
            endedAt: currentSessionMetadata?.endedAt ?? Date(),
            debounceNanoseconds: 0
        ) else {
            lastError = "結束前無法建立保存工作。"
            return false
        }
        completed = await saveTask.value
        return completed
    }

    @discardableResult
    private func exportFinalArtifactsIfPossible() -> Task<Bool, Never>? {
        artifactStatusText = "會後輸出中"
        return autosaveCurrentSession(
            endedAt: currentSessionMetadata?.endedAt,
            finalExport: true,
            debounceNanoseconds: 0
        )
    }

    private func ensureActiveMeetingSession() {
        if currentSessionMetadata == nil {
            startNewMeetingSession()
        }
    }

    private func appendTranscriptSegment(_ text: String, timestamp: Date, source: TranscriptSource) {
        ensureActiveMeetingSession()
        let relativeTime = max(0, timestamp.timeIntervalSince(currentSessionStartedAt ?? timestamp))
        transcriptSegments.append(
            TranscriptSegment(
                id: UUID(),
                text: text,
                timestamp: timestamp,
                relativeTime: relativeTime,
                source: source
            )
        )
    }

    private func replaceLastTranscriptSegment(_ text: String, timestamp: Date, source: TranscriptSource) {
        ensureActiveMeetingSession()
        let relativeTime = max(0, timestamp.timeIntervalSince(currentSessionStartedAt ?? timestamp))
        let replacement = TranscriptSegment(
            id: transcriptSegments.last?.id ?? UUID(),
            text: text,
            timestamp: timestamp,
            relativeTime: relativeTime,
            source: source
        )

        if transcriptSegments.isEmpty {
            transcriptSegments.append(replacement)
        } else {
            transcriptSegments[transcriptSegments.count - 1] = replacement
        }
    }

    @discardableResult
    private func autosaveCurrentSession(
        endedAt: Date? = nil,
        finalExport: Bool = false,
        debounceNanoseconds: UInt64? = nil
    ) -> Task<Bool, Never>? {
        guard !isViewingHistoricalSession else {
            return nil
        }
        guard var metadata = currentSessionMetadata else {
            return nil
        }

        let now = Date()
        let transcriptMarkdown = visibleTranscriptOutput()
        reconcileSummaryProcessing(totalUnits: summaryTranscriptOutput().count)
        let highlightsMarkdown = meetingNotesOutput()
        metadata.updatedAt = now
        if let endedAt {
            metadata.endedAt = endedAt
        }
        metadata.transcriptCharacterCount = transcriptMarkdown.count
        metadata.highlightCharacterCount = highlightsMarkdown.count
        metadata.summaryProvider = summaryProvider.displayName
        metadata.transcriptionEngine = selectedTranscriptionEngine.displayName
        metadata.audioCaptureMode = audioCaptureMode.displayName

        let highlightsDirectory = URL(
            fileURLWithPath: highlightsOutputDirectoryPath,
            isDirectory: true
        )
        let codexHandoffDirectory = MeetingArtifactExporter.defaultCodexHandoffDirectory
        let shouldPublishFinalArtifacts = finalExport || metadata.endedAt != nil
        if shouldPublishFinalArtifacts {
            metadata.exportedHighlightsFilePath = MeetingArtifactExporter.plannedHighlightsURL(
                metadata: metadata,
                directory: highlightsDirectory
            ).path
            metadata.codexHandoffFilePath = codexHandoffEnabled
                ? MeetingArtifactExporter.plannedHandoffMarkdownURL(
                    baseName: MeetingArtifactExporter.latestHandoffBaseName,
                    directory: codexHandoffDirectory
                ).path
                : nil
        }

        let snapshot = MeetingSessionSnapshot(
            metadata: metadata,
            transcriptSegments: transcriptSegments,
            transcriptMarkdown: transcriptMarkdown,
            summarySourceTranscript: summaryTranscriptOutput(),
            highlightsMarkdown: highlightsMarkdown,
            rawSummaryState: liveSummaryState,
            summaryDocument: summaryDocument,
            summaryRetries: pendingSummaryRetries
        )

        let hasMeetingContent = !transcriptMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !highlightsMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let artifactIntent: MeetingPersistenceArtifactIntent
        if shouldPublishFinalArtifacts {
            artifactIntent = .final(
                highlightsDirectory: highlightsDirectory,
                codexHandoffDirectory: codexHandoffDirectory,
                includeCodexHandoff: codexHandoffEnabled
            )
        } else if codexHandoffEnabled, isRecording || hasMeetingContent {
            artifactIntent = .live(
                isRecording: isRecording,
                codexHandoffDirectory: codexHandoffDirectory
            )
        } else {
            artifactIntent = .none
        }

        persistenceRevision &+= 1
        let token = PersistenceRevisionToken(
            sessionID: metadata.id,
            epoch: persistenceEpoch,
            revision: persistenceRevision
        )
        latestPersistenceRevisionBySession[metadata.id] = token.revision
        let request = MeetingPersistenceRequest(
            snapshot: snapshot,
            artifactIntent: artifactIntent
        )
        let delay = debounceNanoseconds
            ?? ((endedAt != nil || finalExport) ? 0 : 250_000_000)

        return Task { [weak self, meetingPersistenceCoordinator] in
            do {
                let outcome = try await meetingPersistenceCoordinator.submit(
                    token: token,
                    payload: request,
                    debounceNanoseconds: delay
                )
                guard case let .committed(result) = outcome else { return false }
                self?.applyPersistenceResult(result)
                // A boundary commit is not complete when its requested
                // handoff/highlights export failed. Callers that switch
                // sessions or terminate must remain in place and allow retry.
                return result.artifactWarning == nil
            } catch {
                self?.applyPersistenceFailure(error, token: token)
                return false
            }
        }
    }

    private func applyPersistenceResult(_ result: MeetingPersistenceResult) {
        let committedMetadata = result.commit.snapshot.metadata
        let record = MeetingSessionHistoryRecord(snapshot: result.commit.snapshot)
        if latestPersistenceRevisionBySession[committedMetadata.id] == result.token.revision {
            upsertCommittedHistoryRecord(record)
        }

        guard currentSessionMetadata?.id == result.token.sessionID,
              persistenceEpoch == result.token.epoch,
              latestPersistenceRevisionBySession[result.token.sessionID] == result.token.revision else {
            return
        }

        currentSessionMetadata = committedMetadata
        currentSessionStartedAt = committedMetadata.startedAt
        currentSessionCommit = result.commit
        if let artifact = result.artifactResult {
            lastRecordingFilePath = artifact.recordingURL?.path ?? committedMetadata.recordingFilePath ?? ""
            lastHighlightsFilePath = artifact.highlightsURL.path
            lastCodexHandoffPath = artifact.codexHandoffMarkdownURL?.path ?? ""
            if committedMetadata.endedAt != nil {
                artifactStatusText = artifact.codexHandoffMarkdownURL == nil
                    ? "已輸出錄音與會議重點"
                    : "已輸出錄音、重點與 Codex handoff"
            } else if artifact.codexHandoffMarkdownURL != nil {
                artifactStatusText = "即時 handoff 已更新"
            }
        }
        if let warning = result.artifactWarning {
            lastError = "會議已保存，但輸出附件失敗：\(warning)"
            artifactStatusText = "會議已保存；附件輸出失敗"
        }
        if let verification = result.latestValidHandoffVerification {
            latestValidCodexHandoffExists = verification.exists
            latestValidCodexHandoffReady = verification.isReady
        }
        // Committed transcript/highlights are already in memory. Do not decode
        // the growing authority envelope again on the main actor after every
        // recognition autosave.
        deliveryArtifactChecks = result.deliveryArtifactChecks
        lastArtifactTrustCacheRefreshAt = Date()
    }

    private func applyPersistenceFailure(
        _ error: Error,
        token: PersistenceRevisionToken
    ) {
        guard currentSessionMetadata?.id == token.sessionID,
              persistenceEpoch == token.epoch,
              latestPersistenceRevisionBySession[token.sessionID] == token.revision else {
            return
        }
        lastError = "自動保存會議失敗：\(error.localizedDescription)"
    }

    func clearLiveDraftState() {
        partialTranscript = ""
        latestRecognitionText = ""
        liveDraftStartedAt = nil
        resetCommittedTranscriptTracking()
    }

    func updateTranscriptManually(_ updatedTranscript: String) {
        guard !isTerminationQuiescing, activeSessionOperationID == nil else { return }
        guard !isViewingHistoricalSession, updatedTranscript != transcript else {
            return
        }
        cancelInFlightSummaryRequestForTranscriptMutation()
        transcript = updatedTranscript
        let invalidatedSummary = resetSummaryCoverageIfTranscriptChanged(summaryTranscriptOutput())
        lastUpdatedAt = Date()
        manualTranscriptEditInvalidatedSummary = manualTranscriptEditInvalidatedSummary || invalidatedSummary
        manualTranscriptEditTask?.cancel()
        summaryStatusText = invalidatedSummary ? "逐字稿已修改，將重新整理" : "逐字稿編輯中"
        manualTranscriptEditTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.finishManualTranscriptEdit()
        }
    }

    func visibleTranscriptOutput() -> String {
        [transcript, liveDraftTranscriptLine()]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func summaryTranscriptOutput() -> String {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func summarySourcePrefixFingerprint(_ transcript: String, endOffset: Int) -> String {
        let boundedEnd = min(max(0, endOffset), transcript.count)
        return SummaryPipelineIdentity.rawOperationsFingerprint(
            Data(String(transcript.prefix(boundedEnd)).utf8)
        )
    }

    private func liveDraftTranscriptLine() -> String {
        let draft = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else {
            return ""
        }

        let timestamp = liveDraftStartedAt ?? Date()
        return "[\(Self.timeFormatter.string(from: timestamp))] [\(primaryTranscriptSource.shortLabel)] \(draft)"
    }

    func meetingNotesOutput() -> String {
        meetingNotes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func markdownOutput() -> String {
        let liveText = visibleTranscriptOutput()

        return """
        # 會議紀錄

        - 產生時間：\(Self.dateFormatter.string(from: Date()))
        - 語言：\(languageDisplayName)
        - 來源：\(selectedTranscriptionEngine.displayName) + \(summaryProvider.displayName)

        ## 會議重點

        \(meetingNotes)

        ## 逐字稿

        \(liveText)
        """
    }

    @available(macOS 26.0, *)
    private func startSpeechAnalyzerSession() async throws {
        cancelSpeechAnalyzerSession()
        let session = SpeechAnalyzerTranscriptionSession()
        speechAnalyzerSession = session

        try await session.start(
            locale: Locale(identifier: recognitionLocaleIdentifier),
            contextualStrings: MeetingVocabulary.contextualStrings,
            onResult: { [weak self] text, isFinal in
                self?.handleSpeechAnalyzerResult(text: text, isFinal: isFinal)
            },
            onStatus: { [weak self] status in
                self?.speechRecognitionStatusText = status
                if status == "SpeechAnalyzer 辨識中斷" {
                    self?.handleRecognitionEngineFailure(status)
                }
            }
        )
    }

    @available(macOS 26.0, *)
    private func startSystemSpeechAnalyzerSession() async throws {
        cancelSystemSpeechAnalyzerSession()
        let session = SpeechAnalyzerTranscriptionSession()
        systemSpeechAnalyzerSession = session

        try await session.start(
            locale: Locale(identifier: recognitionLocaleIdentifier),
            contextualStrings: MeetingVocabulary.contextualStrings,
            onResult: { [weak self] text, isFinal in
                self?.handleSystemSpeechAnalyzerResult(text: text, isFinal: isFinal)
            },
            onStatus: { [weak self] status in
                self?.systemAudioInputStatusText = "系統音訊 \(status)"
                if status == "SpeechAnalyzer 辨識中斷" {
                    self?.handleRecognitionEngineFailure("系統音訊 \(status)")
                }
            }
        )
    }

    private func finishSpeechAnalyzerSession() async {
        let session = speechAnalyzerSession
        let systemSession = systemSpeechAnalyzerSession
        speechAnalyzerSession = nil
        systemSpeechAnalyzerSession = nil
        await session?.finish()
        await systemSession?.finish()
    }

    private func cancelSpeechAnalyzerSession() {
        let session = speechAnalyzerSession
        let systemSession = systemSpeechAnalyzerSession
        speechAnalyzerSession = nil
        systemSpeechAnalyzerSession = nil
        session?.cancel()
        systemSession?.cancel()
    }

    private func cancelSystemSpeechAnalyzerSession() {
        let session = systemSpeechAnalyzerSession
        systemSpeechAnalyzerSession = nil
        session?.cancel()
    }

    private func requestPermissions(needsMicrophone: Bool) async -> Bool {
        let speechStatus = await Self.requestSpeechAuthorization()

        guard speechStatus == .authorized else {
            lastError = "請在系統設定允許語音辨識權限。"
            return false
        }

        guard needsMicrophone else {
            return true
        }

        let micGranted = await Self.requestMicrophoneAccess()

        guard micGranted else {
            lastError = "請在系統設定允許麥克風權限。"
            return false
        }

        return true
    }

    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private nonisolated static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private nonisolated static func installAudioTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        router: SpeechAudioBufferRouter?,
        levelMeter: SpeechAudioLevelMeter,
        audioProcessor: AudioInputProcessor? = nil,
        onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil,
        onAudioLevel: @escaping @MainActor @Sendable (Float, Int) -> Void
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            levelMeter.observe(buffer, onUpdate: onAudioLevel)

            let processedBuffer: AVAudioPCMBuffer
            if let audioProcessor {
                guard let routedBuffer = audioProcessor.process(buffer) else {
                    return
                }
                processedBuffer = routedBuffer
            } else {
                processedBuffer = buffer
            }

            router?.append(processedBuffer)
            onAudioBuffer?(processedBuffer)
        }
    }

    private nonisolated static func startRecognitionTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        onUpdate: @escaping @MainActor @Sendable (String?, Bool, String?) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorMessage = error?.localizedDescription

            Task { @MainActor in
                onUpdate(text, isFinal, errorMessage)
            }
        }
    }

    private func startSystemAudioCaptureIfNeeded() async -> Bool {
        guard audioCaptureMode.capturesSystemAudio else {
            Self.appendSystemAudioDiagnostic("start skipped: mode=\(audioCaptureMode.rawValue)")
            return true
        }

        Self.appendSystemAudioDiagnostic("start requested: mode=\(audioCaptureMode.rawValue) preflightBeforeRequest=\(CGPreflightScreenCaptureAccess())")
        guard Self.requestScreenCaptureAccessIfNeeded() else {
            systemAudioInputStatusText = "系統音訊未啟用"
            lastError = Self.systemAudioPermissionMessage(for: SystemAudioCapturePermissionError.screenCaptureDenied)
            Self.appendSystemAudioDiagnostic("start permission denied: preflightAfterRequest=\(CGPreflightScreenCaptureAccess())")
            return false
        }

        let routeToTranscript = audioCaptureMode.routesSystemAudioToTranscript
        let analyzerAudioBufferHandler = routeToTranscript ? systemSpeechAnalyzerAudioBufferHandler() : nil
        let audioRecorder = meetingAudioRecorder
        let shouldRecordSystemAudio = audioCaptureMode == .systemAudioOnly
        let systemAudioBufferHandler: @Sendable (AVAudioPCMBuffer) -> Void = { buffer in
            if shouldRecordSystemAudio {
                audioRecorder.append(buffer)
            }
            analyzerAudioBufferHandler?(buffer)
        }
        Self.appendSystemAudioDiagnostic("start permission ok: routeToTranscript=\(routeToTranscript) usesSpeechAnalyzer=\(usesSpeechAnalyzerRecognition)")
        do {
            try await systemAudioCapture.start(
                audioRouter: routeToTranscript && !usesSpeechAnalyzerRecognition ? audioRouter : nil,
                audioProcessor: nil,
                onAudioBuffer: systemAudioBufferHandler,
                onAudioLevel: { [weak self] decibels, bufferCount, format in
                    self?.updateSystemAudioLevel(
                        decibels: decibels,
                        bufferCount: bufferCount,
                        format: format
                    )
                },
                onError: { [weak self] message in
                    self?.systemAudioInputStatusText = "系統音訊未啟用"
                    self?.lastError = message
                    Self.appendSystemAudioDiagnostic("start stream error: \(message)")
                }
            )
            systemAudioInputStatusText = routeToTranscript ? "系統音訊辨識中" : "系統音訊監測中"
            Self.appendSystemAudioDiagnostic("start success: status=\(systemAudioInputStatusText)")
            return true
        } catch {
            systemAudioInputStatusText = "系統音訊未啟用"
            lastError = Self.systemAudioPermissionMessage(for: error)
            Self.appendSystemAudioDiagnostic("start failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func systemAudioPermissionMessage(for error: Error) -> String {
        let message = error.localizedDescription
        let normalized = message.lowercased()
        if normalized.contains("tcc") ||
            normalized.contains("denied") ||
            normalized.contains("declined") ||
            message.contains("拒絕") {
            return "系統音訊啟動失敗：macOS 拒絕螢幕與系統錄音權限。請用選單「音訊 > 開啟螢幕與系統錄音設定」，允許 MoMoWhisper，然後完全重開 app。原始錯誤：\(message)"
        }
        return "系統音訊啟動失敗：\(message)"
    }

    nonisolated static func openSystemAudioPermissionSettings() {
        let settingsURLs = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ]

        for urlString in settingsURLs {
            guard let url = URL(string: urlString) else {
                continue
            }
            if NSWorkspace.shared.open(url) {
                return
            }
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private nonisolated static func requestScreenCaptureAccessIfNeeded() -> Bool {
        guard !CGPreflightScreenCaptureAccess() else {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }

    private func speechAnalyzerAudioBufferHandler() -> (@Sendable (AVAudioPCMBuffer) -> Void)? {
        guard usesSpeechAnalyzerRecognition, let speechAnalyzerSession else {
            return nil
        }

        return { buffer in
            speechAnalyzerSession.append(buffer)
        }
    }

    private func systemSpeechAnalyzerAudioBufferHandler() -> (@Sendable (AVAudioPCMBuffer) -> Void)? {
        guard usesSpeechAnalyzerRecognition else {
            return nil
        }

        let targetSession = systemSpeechAnalyzerSession ?? speechAnalyzerSession
        guard let targetSession else {
            return nil
        }

        return { buffer in
            targetSession.append(buffer)
        }
    }

    private func currentAudioProcessingConfiguration() -> AudioInputProcessingConfiguration {
        AudioInputProcessingConfiguration(
            gainDecibels: min(24, max(-12, inputGainDecibels)),
            sensitivityMode: voiceSensitivityMode,
            manualThresholdDecibels: min(-20, max(-85, manualVoiceThresholdDecibels))
        )
    }

    private func handleSpeechAnalyzerResult(text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        recognitionUpdateCount += 1

        if isFinal {
            updateLiveDraft(trimmed)
            commitPendingSentence()
            speechRecognitionStatusText = "SpeechAnalyzer 回傳 \(recognitionUpdateCount) 次"
        } else {
            updateLiveDraft(trimmed)
            speechRecognitionStatusText = "SpeechAnalyzer 暫稿 \(recognitionUpdateCount) 次"
        }
    }

    private func handleSystemSpeechAnalyzerResult(text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        if isFinal {
            recognitionUpdateCount += 1
            appendRecognizedText(trimmed, source: .systemAudio)
            systemAudioInputStatusText = "系統音訊辨識回傳 \(recognitionUpdateCount) 次"
        } else {
            systemAudioInputStatusText = "系統音訊辨識暫稿"
        }
    }

    private func handleRecognition(
        text: String?,
        isFinal: Bool,
        errorMessage: String?,
        generation: UInt64
    ) {
        // SFSpeechRecognitionTask delivers on a non-main callback and then
        // hops to MainActor. A result already queued before stop/cancel must
        // not mutate the ended session after its boundary snapshot was taken.
        guard generation == recognitionGeneration else { return }
        if let text {
            recognitionUpdateCount += 1
            speechRecognitionStatusText = "Speech 回傳 \(recognitionUpdateCount) 次"
            latestFullRecognitionText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let pendingText = pendingRecognitionText(from: latestFullRecognitionText)

            if !pendingText.isEmpty {
                updateLiveDraft(pendingText)
                schedulePauseCommit()
            }

            if isFinal {
                commitPendingSentence()
                startNewRecognitionTask(resetSegment: true)
            }
        }

        if let errorMessage {
            if Self.isExpectedCancellation(errorMessage) {
                return
            }
            handleRecognitionEngineFailure(errorMessage)
        }
    }

    private func handleRecognitionEngineFailure(_ message: String) {
        speechRecognitionStatusText = "辨識中斷"
        lastError = message

        switch recordingLifecycle.state {
        case .startingNewSession, .startingRecordingPart:
            // startRecording owns the active session operation. Mark its
            // lifecycle as stopping so its next post-await guard aborts and
            // cleans up, instead of attempting a nested stop that the gate
            // must reject.
            _ = recordingLifecycle.requestStop()
            statusText = "辨識啟動失敗"
        case .recording:
            Task { [weak self] in
                await self?.stopRecording()
            }
        case .idle, .ready, .stopping, .ended, .loadedHistory:
            break
        }
    }

    private static func isExpectedCancellation(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("canceled") ||
            normalized.contains("cancelled") ||
            normalized.contains("216") ||
            normalized.contains("203")
    }

    private func startNewRecognitionTask(resetSegment: Bool) {
        guard !usesSpeechAnalyzerRecognition else {
            return
        }

        stopRecognitionOnly()

        if resetSegment {
            resetRecognitionSegment()
        }

        guard let speechRecognizer else {
            speechRecognitionStatusText = "辨識服務不可用"
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = MeetingVocabulary.contextualStrings

        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        recognitionRequest = request
        audioRouter.route(to: request)
        let callbackGeneration = recognitionGeneration
        recognitionTask = Self.startRecognitionTask(
            recognizer: speechRecognizer,
            request: request
        ) { [weak self] text, isFinal, errorMessage in
            self?.handleRecognition(
                text: text,
                isFinal: isFinal,
                errorMessage: errorMessage,
                generation: callbackGeneration
            )
        }
    }

    private func stopRecognitionOnly() {
        recognitionGeneration &+= 1
        pendingCommitTask?.cancel()
        pendingCommitTask = nil
        audioRouter.close()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }

    private func resetRecognitionSegment() {
        latestRecognitionText = ""
        latestFullRecognitionText = ""
        committedRecognitionText = ""
        liveDraftStartedAt = nil
    }

    private func resetCommittedTranscriptTracking() {
        lastCommittedTranscriptText = ""
        lastCommittedTranscriptAt = nil
        lastCommittedTranscriptTimestamp = nil
        lastCommittedTranscriptSource = .unknown
    }

    private func pendingRecognitionText(from fullText: String) -> String {
        let fullText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else {
            return ""
        }

        let committed = committedRecognitionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !committed.isEmpty else {
            return fullText
        }

        if fullText.hasPrefix(committed) {
            let suffix = fullText.dropFirst(committed.count)
            return suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return fullText
    }

    private func updateLiveDraft(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        if liveDraftStartedAt == nil {
            liveDraftStartedAt = Date()
        }

        latestRecognitionText = trimmed
        partialTranscript = trimmed
        lastUpdatedAt = Date()
        evaluateAutomaticSummaryTrigger()
    }

    private func schedulePauseCommit() {
        pendingCommitTask?.cancel()
        let delayNanoseconds = UInt64(max(0.15, min(2.0, pauseCommitDelaySeconds)) * 1_000_000_000)
        pendingCommitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            await self?.commitPendingSentence()
        }
    }

    private func commitPendingSentence() {
        let text = latestRecognitionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }

        commitOrReplaceRecognizedText(
            text,
            timestamp: liveDraftStartedAt ?? Date(),
            source: primaryTranscriptSource
        )
        committedRecognitionText = latestFullRecognitionText.isEmpty
            ? [committedRecognitionText, text].filter { !$0.isEmpty }.joined(separator: " ")
            : latestFullRecognitionText
        latestRecognitionText = ""
        partialTranscript = ""
        liveDraftStartedAt = nil
    }

    private func commitOrReplaceRecognizedText(
        _ text: String,
        timestamp: Date = Date(),
        source: TranscriptSource
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        if shouldAttachToPreviousTranscriptLine(trimmed, source: source) {
            let replacement = lastCommittedTranscriptText.hasSuffix(trimmed)
                ? lastCommittedTranscriptText
                : "\(lastCommittedTranscriptText)\(trimmed)"
            replaceLastRecognizedText(
                replacement,
                timestamp: lastCommittedTranscriptTimestamp ?? timestamp,
                source: source
            )
            return
        }

        if shouldReplaceLastCommittedTranscript(with: trimmed, source: source) {
            replaceLastRecognizedText(
                trimmed,
                timestamp: lastCommittedTranscriptTimestamp ?? timestamp,
                source: source
            )
        } else {
            appendRecognizedText(trimmed, timestamp: timestamp, source: source)
            lastCommittedTranscriptTimestamp = timestamp
        }

        lastCommittedTranscriptText = trimmed
        lastCommittedTranscriptAt = Date()
        lastCommittedTranscriptSource = source
    }

    private func appendRecognizedText(
        _ text: String,
        timestamp: Date = Date(),
        source: TranscriptSource
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let line = "[\(Self.timeFormatter.string(from: timestamp))] [\(source.shortLabel)] \(trimmed)"
        if transcript.isEmpty {
            transcript = line
        } else {
            transcript += "\n\(line)"
        }
        appendTranscriptSegment(trimmed, timestamp: timestamp, source: source)

        lastCommittedTranscriptText = trimmed
        lastCommittedTranscriptAt = Date()
        lastCommittedTranscriptTimestamp = timestamp
        lastCommittedTranscriptSource = source
        lastUpdatedAt = Date()
        _ = resetSummaryCoverageIfTranscriptChanged(summaryTranscriptOutput())
        autosaveCurrentSession()
        if isSummaryRequestInFlight {
            shouldRunSummaryAfterCurrentRequest = true
        }
        evaluateAutomaticSummaryTrigger()
    }

    private func replaceLastRecognizedText(
        _ text: String,
        timestamp: Date = Date(),
        source: TranscriptSource
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let line = "[\(Self.timeFormatter.string(from: timestamp))] [\(source.shortLabel)] \(trimmed)"
        var lines = transcript.components(separatedBy: "\n")
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || lines.isEmpty {
            transcript = line
        } else {
            lines[lines.count - 1] = line
            transcript = lines.joined(separator: "\n")
        }

        lastCommittedTranscriptText = trimmed
        lastCommittedTranscriptAt = Date()
        lastCommittedTranscriptTimestamp = timestamp
        lastCommittedTranscriptSource = source
        lastUpdatedAt = Date()
        replaceLastTranscriptSegment(trimmed, timestamp: timestamp, source: source)
        _ = resetSummaryCoverageIfTranscriptChanged(summaryTranscriptOutput())
        autosaveCurrentSession()
        if isSummaryRequestInFlight {
            shouldRunSummaryAfterCurrentRequest = true
        }
        evaluateAutomaticSummaryTrigger()
    }

    private func shouldAttachToPreviousTranscriptLine(_ text: String, source: TranscriptSource) -> Bool {
        guard !lastCommittedTranscriptText.isEmpty,
              lastCommittedTranscriptSource == source,
              let lastCommittedTranscriptAt,
              Date().timeIntervalSince(lastCommittedTranscriptAt) <= 4 else {
            return false
        }

        let punctuationCharacters = CharacterSet.punctuationCharacters
        let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty, scalars.count <= 3 else {
            return false
        }

        return scalars.allSatisfy { punctuationCharacters.contains($0) }
    }

    private func shouldReplaceLastCommittedTranscript(with text: String, source: TranscriptSource) -> Bool {
        guard lastCommittedTranscriptSource == source,
              let lastCommittedTranscriptAt,
              Date().timeIntervalSince(lastCommittedTranscriptAt) <= 4 else {
            return false
        }

        let previous = normalizedTranscriptText(lastCommittedTranscriptText)
        let current = normalizedTranscriptText(text)
        guard !previous.isEmpty, !current.isEmpty else {
            return false
        }

        if current.hasPrefix(previous) || previous.hasPrefix(current) {
            return true
        }

        let commonPrefixLength = zip(previous, current).prefix { pair in
            pair.0 == pair.1
        }.count
        let similarity = Double(commonPrefixLength) / Double(max(previous.count, current.count))
        return similarity >= 0.72
    }

    private func normalizedTranscriptText(_ text: String) -> String {
        let ignoredCharacters = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return text
            .lowercased()
            .unicodeScalars
            .filter { !ignoredCharacters.contains($0) }
            .map(String.init)
            .joined()
    }

    private func updateMicrophoneLevel(decibels: Float, bufferCount: Int, format: AVAudioFormat) {
        microphoneBufferCount = bufferCount
        lastMicrophoneLevelDecibels = decibels
        guard shouldPublishMicrophoneLevelStatus() else {
            return
        }
        microphoneInputStatusText = "麥克風 \(Self.decibelFormatter.string(from: NSNumber(value: decibels)) ?? "\(decibels)") dB / \(Int(format.sampleRate)) Hz / buffer \(bufferCount)"
    }

    private func updateSystemAudioLevel(decibels: Float, bufferCount: Int, format: AVAudioFormat) {
        systemAudioBufferCount = bufferCount
        lastSystemAudioLevelDecibels = decibels
        guard shouldPublishSystemAudioLevelStatus() else {
            return
        }
        let prefix = audioCaptureMode.routesSystemAudioToTranscript ? "系統音訊辨識" : "系統音訊監測"
        systemAudioInputStatusText = "\(prefix) \(Self.decibelFormatter.string(from: NSNumber(value: decibels)) ?? "\(decibels)") dB / \(Int(format.sampleRate)) Hz / buffer \(bufferCount)"
    }

    private func shouldPublishMicrophoneLevelStatus() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastMicrophoneStatusUpdateAt) >= 1 else {
            return false
        }
        lastMicrophoneStatusUpdateAt = now
        return true
    }

    private func shouldPublishSystemAudioLevelStatus() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastSystemAudioStatusUpdateAt) >= 1 else {
            return false
        }
        lastSystemAudioStatusUpdateAt = now
        return true
    }

    private func startLiveSummaryLoop() {
        stopLiveSummaryLoop()
        summaryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else {
                    return
                }
                await self?.evaluateAutomaticSummaryTrigger()
            }
        }
    }

    private func stopLiveSummaryLoop() {
        summaryTask?.cancel()
        summaryTask = nil
    }

    private func startPostRecordingSummaryDrain() {
        guard shouldContinuePostRecordingSummaryDrain else {
            return
        }

        if postRecordingSummaryTask != nil {
            return
        }

        summaryStatusText = postRecordingSummaryStatusText(prefix: "會後慢慢整理中")
        postRecordingSummaryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.postRecordingSummaryInitialDelayNanoseconds)

            while !Task.isCancelled {
                guard let self else {
                    return
                }

                let shouldContinue = self.runPostRecordingSummaryDrainStep()
                guard shouldContinue else {
                    return
                }

                try? await Task.sleep(nanoseconds: Self.postRecordingSummaryDrainIntervalNanoseconds)
            }
        }
    }

    private func stopPostRecordingSummaryDrain() {
        postRecordingSummaryTask?.cancel()
        postRecordingSummaryTask = nil
    }

    private func runPostRecordingSummaryDrainStep() -> Bool {
        guard !isRecording else {
            stopPostRecordingSummaryDrain()
            return false
        }

        guard shouldContinuePostRecordingSummaryDrain else {
            stopPostRecordingSummaryDrain()
            if !isSummaryRequestInFlight {
                summaryStatusText = "已完成"
                exportFinalArtifactsIfPossible()
            }
            return false
        }

        if isSummaryRequestInFlight {
            shouldRunFinalSummaryAfterCurrentRequest = true
            summaryStatusText = postRecordingSummaryStatusText(prefix: "會後整理排隊中")
            return true
        }

        summaryStatusText = postRecordingSummaryStatusText(prefix: "會後慢慢整理中")
        return runMeetingSummary(isFinal: true, force: true)
    }

    private func postRecordingSummaryStatusText(prefix: String) -> String {
        let retryCount = retryableSummaryRetries.count
        let retrySuffix = retryCount == 0 ? "" : " · 待重試 \(retryCount) 批"
        return "\(prefix) · 未整理 \(unsummarizedTranscriptCount)\(retrySuffix)"
    }

    private var shouldContinuePostRecordingSummaryDrain: Bool {
        summaryProvider != .disabled && (unsummarizedTranscriptCount > 0 || !retryableSummaryRetries.isEmpty)
    }

    private var retryableSummaryRetries: [PendingSummaryRetry] {
        pendingSummaryRetries.filter {
            $0.attempts < Self.maximumBackgroundSummaryRetryAttempts
        }
    }

    private func evaluateAutomaticSummaryTrigger() {
        guard shouldRunAutomaticSummary() else {
            return
        }

        runMeetingSummary(isFinal: false)
    }

    private func shouldRunAutomaticSummary() -> Bool {
        guard isRecording,
              !isViewingHistoricalSession,
              manualTranscriptEditTask == nil,
              summaryProvider != .disabled,
              summaryTriggerMode != .manualOnly,
              !isSummaryRequestInFlight else {
            return false
        }

        let liveText = summaryTranscriptOutput()
        guard !liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let transcriptWasRewritten = resetSummaryCoverageIfTranscriptChanged(liveText)

        let newCharacterCount = liveText.count - min(lastSummarizedTranscriptCharacterCount, liveText.count)
        let characterReached = newCharacterCount >= max(100, summaryCharacterThreshold)
        let lastAutomaticSummaryAt = lastAutomaticSummaryAt ?? Date()
        let timeReached = Date().timeIntervalSince(lastAutomaticSummaryAt) >= max(30, summaryIntervalSeconds)

        if !retryableSummaryRetries.isEmpty && timeReached {
            return true
        }

        if transcriptWasRewritten {
            return true
        }

        switch summaryTriggerMode {
        case .time:
            return timeReached && newCharacterCount > 0
        case .characters:
            return characterReached
        case .either:
            return (timeReached && newCharacterCount > 0) || characterReached
        case .both:
            return timeReached && characterReached
        case .manualOnly:
            return false
        }
    }

    @discardableResult
    private func runMeetingSummary(isFinal: Bool, force: Bool = false) -> Bool {
        let liveText = summaryTranscriptOutput()
        guard !liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        _ = resetSummaryCoverageIfTranscriptChanged(liveText)

        let safeStart = min(lastSummarizedTranscriptCharacterCount, liveText.count)
        let newStartIndex = liveText.index(liveText.startIndex, offsetBy: safeStart)
        let newTranscript = String(liveText[newStartIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingRetry = validatedPendingSummaryRetry(against: liveText)

        guard force || isFinal || !newTranscript.isEmpty || pendingRetry != nil else {
            return false
        }

        if isSummaryRequestInFlight {
            if isFinal {
                shouldRunFinalSummaryAfterCurrentRequest = true
            } else {
                shouldRunSummaryAfterCurrentRequest = true
            }
            return true
        }

        isSummaryRequestInFlight = true
        shouldRunSummaryAfterCurrentRequest = false
        shouldRunFinalSummaryAfterCurrentRequest = false

        let executionConfiguration = makeSummaryExecutionConfiguration()
        let currentCatalog = Self.summaryCatalogJSON(from: summaryDocument)
        let existingTopicIDs = Set(summaryDocument.topics.flatMap { topic in
            [topic.id] + topic.aliases
        })
        let requestGeneration = summaryGeneration
        let requestPlan = makeSummaryRequestPlan(
            liveText: liveText,
            newTranscript: newTranscript,
            safeStart: safeStart,
            isFinal: isFinal,
            retry: pendingRetry
        )
        summaryStatusText = requestPlan.requestIsFinal
            ? "最後梳理中"
            : (isFinal ? "最後分段整理中" : "整理中")

        summaryRequestTask = Task { [weak self] in
            guard let self else { return }
            guard self.isSummaryRequestSourceCurrent(requestPlan) else {
                self.discardStaleSummaryRequest()
                return
            }
            do {
                switch executionConfiguration {
                case .openAICompatible(let baseURL, let apiKey, let model):
                    let summarizer = DeepSeekMeetingSummarizer(
                        configuration: .init(
                            baseURL: baseURL,
                            apiKey: apiKey,
                            model: model
                        )
                    )
                    let delta = try SummaryProviderDeltaValidator.validated(
                        try await summarizer.summarize(
                            newTranscript: requestPlan.payloadTranscript,
                            recentTranscript: requestPlan.recentTranscript,
                            currentCatalog: currentCatalog,
                            isFinal: requestPlan.requestIsFinal
                        ),
                        existingTopicIDs: existingTopicIDs
                    )
                    self.applyDeepSeekDiagnostics(summarizer.lastDiagnostics)
                    await self.applySummaryDelta(
                        delta,
                        plan: requestPlan,
                        isFinal: requestPlan.requestIsFinal,
                        requestGeneration: requestGeneration
                    )
                case .lmStudioConfigured(let baseURL, let apiToken, let model):
                    let transcriptAnalyzer = LMStudioTranscriptPolisher(
                        configuration: .init(
                            baseURL: baseURL,
                            apiToken: apiToken,
                            model: model
                        )
                    )
                    let input = requestPlan.payloadTranscript.isEmpty
                        ? requestPlan.recentTranscript
                        : requestPlan.payloadTranscript
                    let delta = try SummaryProviderDeltaValidator.validated(
                        try await transcriptAnalyzer.summarizeMeeting(
                            input,
                            currentCatalog: currentCatalog,
                            isFinal: requestPlan.requestIsFinal
                        ),
                        existingTopicIDs: existingTopicIDs
                    )
                    self.applyLMStudioDiagnostics(transcriptAnalyzer.lastDiagnostics)
                    await self.applySummaryDelta(
                        delta,
                        plan: requestPlan,
                        isFinal: requestPlan.requestIsFinal,
                        requestGeneration: requestGeneration
                    )
                case .localFallback(let reason):
                    await self.applyLocalFallbackSummary(
                        reason: reason,
                        plan: requestPlan,
                        retryNeeded: false,
                        requestGeneration: requestGeneration
                    )
                case .disabled:
                    await self.finishTranscriptOnlySummaryRequest(
                        plan: requestPlan,
                        requestGeneration: requestGeneration
                    )
                }
            } catch {
                guard !Task.isCancelled,
                      self.isCurrentSummaryGeneration(requestGeneration) else {
                    return
                }
                self.applyDeepSeekDiagnostics(nil)
                await self.applyLocalFallbackSummary(
                    reason: error.localizedDescription,
                    plan: requestPlan,
                    retryNeeded: true,
                    requestGeneration: requestGeneration
                )
            }
        }

        return true
    }

    private func makeSummaryRequestPlan(
        liveText: String,
        newTranscript: String,
        safeStart: Int,
        isFinal: Bool,
        retry: PendingSummaryRetry?
    ) -> SummaryRequestPlan {
        let recentTranscript = String(liveText.suffix(Self.recentTranscriptCharacterLimit))
        if let retry {
            let hasNewTranscript = !newTranscript.isEmpty
            let hasMoreRetries = retryableSummaryRetries.count > 1
            return SummaryRequestPlan(
                id: retry.id,
                payloadTranscript: retry.transcript,
                // Context is recomputed from the currently validated source.
                // Persisted context is never trusted as outbound request data.
                recentTranscript: recentTranscript,
                rangeStart: retry.rangeStart,
                rangeEnd: retry.rangeEnd,
                summarizedCharacterCount: lastSummarizedTranscriptCharacterCount,
                requestIsFinal: isFinal && !hasNewTranscript && !hasMoreRetries,
                continuation: (hasNewTranscript || hasMoreRetries) ? (isFinal ? .final : .live) : .none,
                retryID: retry.id,
                retryRecord: retry,
                sourcePrefixFingerprint: retry.sourcePrefixFingerprint
                    ?? Self.summarySourcePrefixFingerprint(liveText, endOffset: retry.rangeEnd)
            )
        }

        let chunkLimit = isFinal ? Self.finalSummaryChunkCharacterLimit : Self.liveSummaryChunkCharacterLimit
        let unsummarizedTranscript = String(liveText.dropFirst(safeStart))
        let rawChunk = String(unsummarizedTranscript.prefix(chunkLimit))
        let chunk = rawChunk

        guard !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SummaryRequestPlan(
                id: "summary-\(safeStart)-\(safeStart)-\(isFinal ? "final" : "live")",
                payloadTranscript: "",
                recentTranscript: recentTranscript,
                rangeStart: safeStart,
                rangeEnd: safeStart,
                summarizedCharacterCount: safeStart,
                requestIsFinal: isFinal,
                continuation: .none,
                retryID: nil,
                retryRecord: nil,
                sourcePrefixFingerprint: Self.summarySourcePrefixFingerprint(liveText, endOffset: safeStart)
            )
        }

        let summarizedCharacterCount = min(liveText.count, safeStart + rawChunk.count)
        let hasRemainingTranscript = unsummarizedTranscript.count > rawChunk.count

        return SummaryRequestPlan(
            id: "summary-\(safeStart)-\(summarizedCharacterCount)-\(isFinal ? "final" : "live")",
            payloadTranscript: chunk,
            recentTranscript: recentTranscript,
            rangeStart: safeStart,
            rangeEnd: summarizedCharacterCount,
            summarizedCharacterCount: summarizedCharacterCount,
            requestIsFinal: isFinal && !hasRemainingTranscript,
            continuation: hasRemainingTranscript ? (isFinal ? .final : .live) : .none,
            retryID: nil,
            retryRecord: nil,
            sourcePrefixFingerprint: Self.summarySourcePrefixFingerprint(
                liveText,
                endOffset: summarizedCharacterCount
            )
        )
    }

    private func applySummaryDelta(
        _ providerDelta: MeetingSummaryDelta,
        plan: SummaryRequestPlan,
        isFinal: Bool,
        requestGeneration: Int? = nil
    ) {
        guard isCurrentSummaryGeneration(requestGeneration) else {
            return
        }
        guard isSummaryRequestSourceCurrent(plan) else {
            discardStaleSummaryRequest()
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let operationData = (try? encoder.encode(providerDelta.operations)) ?? Data()
        let operationsFingerprint = SummaryPipelineIdentity.rawOperationsFingerprint(operationData)
        let effectiveDeltaID = SummaryPipelineIdentity.providerDeltaID(
            meetingID: summaryDocument.id,
            rangeStart: plan.rangeStart,
            rangeEnd: plan.rangeEnd,
            isFinal: plan.requestIsFinal,
            retryKey: plan.retryID,
            sourceFingerprint: plan.sourcePrefixFingerprint,
            operationsFingerprint: operationsFingerprint
        )
        guard !summaryDocument.appliedDeltaIDs.contains(effectiveDeltaID) else {
            queueSummaryContinuation(plan.continuation)
            finishSummaryRequest(isFinal: isFinal, statusText: "重複批次已忽略")
            return
        }

        if let retryID = plan.retryID {
            pendingSummaryRetries.removeAll { $0.id == retryID }
            accumulatedFallbackSummaryUnits = max(0, accumulatedFallbackSummaryUnits - plan.unitCount)
            accumulatedAISummaryUnits += plan.unitCount
        } else {
            lastSummarizedTranscriptCharacterCount = max(
                lastSummarizedTranscriptCharacterCount,
                plan.summarizedCharacterCount
            )
            rememberSummarizedTranscriptPrefix()
            accumulatedAISummaryUnits += plan.unitCount
        }

        let totalUnits = summaryTranscriptOutput().count
        var operations = providerDelta.operations
        operations.append(contentsOf: currentFallbackProjectionOperations())
        operations.append(.updateProcessing(makeProcessingState(totalUnits: totalUnits, lastError: nil)))
        applyDocumentDelta(.init(id: effectiveDeltaID, operations: operations))

        lastError = nil
        queueSummaryContinuation(plan.continuation)
        finishSummaryRequest(
            isFinal: isFinal,
            statusText: providerDelta.operations.isEmpty ? "無新增重點，已保留" : nil
        )
    }

    private func finishTranscriptOnlySummaryRequest(
        plan: SummaryRequestPlan,
        requestGeneration: Int? = nil
    ) {
        guard isCurrentSummaryGeneration(requestGeneration) else {
            return
        }
        finishSummaryRequest(isFinal: plan.requestIsFinal, statusText: "僅逐字稿模式")
    }

    private func applyLocalFallbackSummary(
        reason: String,
        plan: SummaryRequestPlan,
        retryNeeded: Bool,
        requestGeneration: Int? = nil
    ) {
        guard isCurrentSummaryGeneration(requestGeneration) else {
            return
        }
        guard isSummaryRequestSourceCurrent(plan) else {
            discardStaleSummaryRequest()
            return
        }

        guard plan.unitCount > 0 else {
            let processingError = Self.sanitizedSummaryError(reason)
            applyDocumentDelta(.init(
                id: "fallback-empty-\(plan.id)-\(UUID().uuidString)",
                operations: [.updateProcessing(makeProcessingState(
                    totalUnits: summaryTranscriptOutput().count,
                    lastError: processingError
                ))]
            ))
            lastError = "AI 最後梳理未完成，已保留既有重點：\(processingError)"
            queueSummaryContinuation(plan.continuation)
            finishSummaryRequest(isFinal: plan.requestIsFinal, statusText: "已保留既有重點")
            return
        }

        var willRetry = retryNeeded
        if let retryID = plan.retryID,
           let index = pendingSummaryRetries.firstIndex(where: { $0.id == retryID }) {
            if retryNeeded {
                pendingSummaryRetries[index].attempts += 1
            } else {
                pendingSummaryRetries[index].attempts = Self.maximumBackgroundSummaryRetryAttempts
            }
            willRetry = pendingSummaryRetries[index].attempts < Self.maximumBackgroundSummaryRetryAttempts
        } else {
            lastSummarizedTranscriptCharacterCount = max(
                lastSummarizedTranscriptCharacterCount,
                plan.summarizedCharacterCount
            )
            rememberSummarizedTranscriptPrefix()
            accumulatedFallbackSummaryUnits += plan.unitCount
            let attempts = retryNeeded ? 1 : Self.maximumBackgroundSummaryRetryAttempts
            pendingSummaryRetries.append(PendingSummaryRetry(
                id: "retry-\(plan.id)",
                transcript: plan.fallbackTranscript,
                recentTranscript: plan.recentTranscript,
                rangeStart: plan.rangeStart,
                rangeEnd: plan.rangeEnd,
                isFinal: plan.requestIsFinal,
                attempts: attempts,
                sourcePrefixFingerprint: plan.sourcePrefixFingerprint
            ))
            willRetry = attempts < Self.maximumBackgroundSummaryRetryAttempts
        }

        let processingError = Self.sanitizedSummaryError(reason)
        let processing = makeProcessingState(
            totalUnits: summaryTranscriptOutput().count,
            lastError: processingError
        )
        var operations = currentFallbackProjectionOperations()
        operations.append(.updateProcessing(processing))
        applyDocumentDelta(.init(
            id: "fallback-\(plan.id)-\(UUID().uuidString)",
            operations: operations
        ))

        let retryText = willRetry ? "；已排入重試" : ""
        lastError = "AI 整理未完成，已保留既有重點並以本機粗整理替代\(retryText)：\(processingError)"
        queueSummaryContinuation(plan.continuation)
        finishSummaryRequest(
            isFinal: plan.requestIsFinal,
            statusText: willRetry ? "本機備援已更新 · 待重試" : "本機備援已更新"
        )
    }

    private func applyDocumentDelta(_ delta: MeetingSummaryDelta) {
        summaryDocument = MeetingSummaryReducer.applying(delta, to: summaryDocument)
        liveSummaryState = Self.legacyProjection(from: summaryDocument)
        meetingNotes = MeetingSummaryRenderer.render(summaryDocument)
        rawMeetingNotes = meetingNotes
    }

    @discardableResult
    private func resetSummaryCoverageIfTranscriptChanged(_ currentTranscript: String) -> Bool {
        guard lastSummarizedTranscriptCharacterCount > 0 else {
            return false
        }

        let boundedCount = min(lastSummarizedTranscriptCharacterCount, currentTranscript.count)
        let currentPrefix = String(currentTranscript.prefix(boundedCount))
        guard boundedCount != lastSummarizedTranscriptCharacterCount
                || currentPrefix != lastSummarizedTranscriptPrefix else {
            return false
        }

        summaryGeneration += 1
        summaryRequestTask?.cancel()
        summaryRequestTask = nil
        isSummaryRequestInFlight = false
        shouldRunSummaryAfterCurrentRequest = false
        shouldRunFinalSummaryAfterCurrentRequest = false
        lastSummarizedTranscriptCharacterCount = 0
        lastSummarizedTranscriptPrefix = ""
        accumulatedAISummaryUnits = 0
        accumulatedFallbackSummaryUnits = 0
        pendingSummaryRetries = []
        let preservedItems = summaryDocument.items.filter {
            $0.source == .manual || $0.lockedByUser
        }
        let preservedTopicIDs = Set(preservedItems.map(\.topicID))
        summaryDocument.items = preservedItems
        summaryDocument.topics = summaryDocument.topics.filter { preservedTopicIDs.contains($0.id) }
        if summaryDocument.headlineLockedByUser != true {
            summaryDocument.headline = ""
        }
        summaryDocument.processing = .init(
            totalUnits: currentTranscript.count,
            processedUnits: 0,
            pendingUnits: currentTranscript.count,
            lastError: "逐字稿已修改，原 AI／本機備援重點已失效，需重新整理"
        )
        summaryDocument.appliedDeltaIDs = []
        summaryDocument.revision += 1
        liveSummaryState = Self.legacyProjection(from: summaryDocument)
        meetingNotes = MeetingSummaryRenderer.render(summaryDocument)
        rawMeetingNotes = meetingNotes
        lastError = "逐字稿已修改；已保留人工鎖定內容，其他重點需要重新整理。"
        summaryStatusText = "逐字稿已修改，將重新整理"
        return true
    }

    private func rememberSummarizedTranscriptPrefix() {
        let currentTranscript = summaryTranscriptOutput()
        let boundedCount = min(lastSummarizedTranscriptCharacterCount, currentTranscript.count)
        lastSummarizedTranscriptPrefix = String(currentTranscript.prefix(boundedCount))
    }

    private func reconcileSummaryProcessing(totalUnits: Int) {
        let processing = makeProcessingState(
            totalUnits: totalUnits,
            lastError: summaryDocument.processing.lastError
        )
        guard processing != summaryDocument.processing else {
            return
        }
        applyDocumentDelta(.init(
            id: "processing-sync-\(UUID().uuidString)",
            operations: [.updateProcessing(processing)]
        ))
    }

    private func makeProcessingState(
        totalUnits: Int,
        lastError: String?
    ) -> MeetingSummaryProcessingState {
        let boundedTotal = max(0, totalUnits)
        let processed = min(max(0, lastSummarizedTranscriptCharacterCount), boundedTotal)
        let ai = min(max(0, accumulatedAISummaryUnits), processed)
        let fallback = min(max(0, accumulatedFallbackSummaryUnits), max(0, processed - ai))
        return MeetingSummaryProcessingState(
            totalUnits: boundedTotal,
            processedUnits: processed,
            aiUnits: ai,
            fallbackUnits: fallback,
            pendingUnits: max(0, boundedTotal - processed),
            retryUnits: retryableSummaryRetries.reduce(0) { $0 + $1.unitCount },
            lastError: lastError
        )
    }

    private func currentFallbackProjectionOperations() -> [MeetingSummaryDeltaOperation] {
        guard !pendingSummaryRetries.isEmpty else {
            let hasFallbackProjection = summaryDocument.items.contains {
                $0.fallbackScopeID == Self.fallbackScopeID
            }
            if accumulatedFallbackSummaryUnits > 0 {
                return []
            }
            return hasFallbackProjection ? [Self.emptyFallbackProjectionOperation] : []
        }
        return Self.fallbackProjectionOperations(from: pendingSummaryRetries)
    }

    private static var emptyFallbackProjectionOperation: MeetingSummaryDeltaOperation {
        .replaceFallback(
            scopeID: fallbackScopeID,
            topic: .init(id: fallbackTopicID, title: "本機備援補充", order: Int.max - 1),
            items: []
        )
    }

    private static func fallbackProjectionOperations(from retries: [PendingSummaryRetry]) -> [MeetingSummaryDeltaOperation] {
        let ranges = retries.map {
            SummaryFallbackRange(
                id: $0.id,
                transcript: $0.transcript,
                rangeStart: $0.rangeStart,
                rangeEnd: $0.rangeEnd
            )
        }
        return [SummaryFallbackProjection.operation(
            from: ranges,
            scopeID: fallbackScopeID,
            topicID: fallbackTopicID
        )]
    }

    private func queueSummaryContinuation(_ continuation: SummaryContinuation) {
        switch continuation {
        case .none:
            break
        case .live:
            shouldRunSummaryAfterCurrentRequest = true
        case .final:
            shouldRunFinalSummaryAfterCurrentRequest = true
        }
    }

    private func isCurrentSummaryGeneration(_ requestGeneration: Int?) -> Bool {
        guard let requestGeneration else {
            return true
        }

        return requestGeneration == summaryGeneration
    }

    private func isSummaryRequestSourceCurrent(_ plan: SummaryRequestPlan) -> Bool {
        let currentTranscript = summaryTranscriptOutput()
        guard currentTranscript.count >= plan.rangeEnd else {
            return false
        }
        if let retryRecord = plan.retryRecord,
           !MeetingSummaryRetryValidator.isExecutable(
               retryRecord,
               against: currentTranscript
           ) {
            return false
        }
        return Self.summarySourcePrefixFingerprint(
            currentTranscript,
            endOffset: plan.rangeEnd
        ) == plan.sourcePrefixFingerprint
    }

    private func validatedPendingSummaryRetry(
        against liveText: String
    ) -> PendingSummaryRetry? {
        let validation = MeetingSummaryRetryValidator.validate(
            pendingSummaryRetries,
            against: liveText
        )
        pendingSummaryRetries = validation.valid
        if !validation.quarantined.isEmpty {
            lastError = "已隔離 \(validation.quarantined.count) 筆失效的摘要重試；不會送往 AI 服務。"
        }
        return validation.valid.first {
            MeetingSummaryRetryValidator.isExecutable($0, against: liveText)
        }
    }

    private func discardStaleSummaryRequest() {
        isSummaryRequestInFlight = false
        summaryRequestTask = nil
        summaryStatusText = "逐字稿已更新，已丟棄過期整理結果"
        if isRecording {
            evaluateAutomaticSummaryTrigger()
        } else if summaryProvider != .disabled {
            startPostRecordingSummaryDrain()
        }
    }

    private func cancelInFlightSummaryRequestForTranscriptMutation() {
        guard isSummaryRequestInFlight else { return }
        summaryGeneration += 1
        summaryRequestTask?.cancel()
        summaryRequestTask = nil
        isSummaryRequestInFlight = false
        shouldRunSummaryAfterCurrentRequest = false
        shouldRunFinalSummaryAfterCurrentRequest = false
    }

    private func finishManualTranscriptEdit() {
        manualTranscriptEditTask = nil
        let invalidatedSummary = manualTranscriptEditInvalidatedSummary
        manualTranscriptEditInvalidatedSummary = false
        autosaveCurrentSession()
        if !isRecording, summaryProvider != .disabled {
            startPostRecordingSummaryDrain()
        } else if invalidatedSummary || isRecording {
            evaluateAutomaticSummaryTrigger()
        }
    }

    private func applyDeepSeekDiagnostics(_ diagnostics: DeepSeekMeetingDiagnostics?) {
        guard let diagnostics else {
            return
        }

        let rate = Int((diagnostics.cacheHitRate * 100).rounded())
        let finish = diagnostics.finishReason ?? "unknown"
        deepSeekDiagnosticsText = "DeepSeek tokens \(diagnostics.promptTokens)/\(diagnostics.completionTokens)/\(diagnostics.totalTokens) · cache \(rate)% · hit \(diagnostics.promptCacheHitTokens) / miss \(diagnostics.promptCacheMissTokens) · finish \(finish)"
    }

    private func applyLMStudioDiagnostics(_ diagnostics: LMStudioSummaryDiagnostics?) {
        guard let diagnostics else {
            return
        }
        deepSeekDiagnosticsText = "LM Studio tokens \(diagnostics.inputTokens)/\(diagnostics.outputTokens) · ops \(diagnostics.operationCount) · finish \(diagnostics.finishReason ?? "unknown")"
    }

    private func applySummaryError(_ error: Error) {
        summaryStatusText = "整理失敗"
        lastError = error.localizedDescription
        isSummaryRequestInFlight = false
    }

    private func finishSummaryRequest(isFinal: Bool, statusText: String? = nil) {
        lastSummaryUpdatedAt = Date()
        lastAutomaticSummaryAt = Date()
        summaryStatusText = statusText ?? (isFinal ? "已完成" : "已更新")
        isSummaryRequestInFlight = false
        autosaveCurrentSession(endedAt: isFinal && !isRecording ? Date() : nil)

        if shouldRunFinalSummaryAfterCurrentRequest {
            shouldRunFinalSummaryAfterCurrentRequest = false
            if !runMeetingSummary(isFinal: true, force: true), !isRecording {
                if shouldContinuePostRecordingSummaryDrain {
                    startPostRecordingSummaryDrain()
                } else {
                    stopPostRecordingSummaryDrain()
                    exportFinalArtifactsIfPossible()
                }
            }
            return
        }

        if shouldRunSummaryAfterCurrentRequest {
            shouldRunSummaryAfterCurrentRequest = false
            evaluateAutomaticSummaryTrigger()
            return
        }

        if isFinal && !isRecording {
            if shouldContinuePostRecordingSummaryDrain {
                startPostRecordingSummaryDrain()
            } else {
                stopPostRecordingSummaryDrain()
                exportFinalArtifactsIfPossible()
            }
        }
    }

    private func makeSummaryExecutionConfiguration() -> SummaryExecutionConfiguration {
        switch summaryProvider {
        case .automatic:
            return .localFallback(reason: "使用本機整理；未連線第三方摘要服務。")
        case .deepSeek:
            return makeDeepSeekExecutionConfiguration()
                ?? .localFallback(reason: "DeepSeek API key 未設定。")
        case .lmStudio:
            return makeLMStudioExecutionConfiguration()
                ?? .localFallback(reason: "LM Studio API URL 未設定。")
        case .customOpenAI:
            return makeCustomExecutionConfiguration()
                ?? .localFallback(reason: "自訂 OpenAI 相容 API 未設定。")
        case .disabled:
            return .disabled
        }
    }

    private func makeDeepSeekExecutionConfiguration() -> SummaryExecutionConfiguration? {
        let apiKey = KeychainSecretStore.readPassword(
            services: MeetingSummaryAPIKeyKind.deepSeek.keychainServices
        )

        guard let apiKey, !apiKey.isEmpty,
              let baseURL = URL(string: deepSeekBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines)),
              !deepSeekModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return .openAICompatible(
            baseURL: baseURL,
            apiKey: apiKey,
            model: deepSeekModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func makeCustomExecutionConfiguration() -> SummaryExecutionConfiguration? {
        let apiKey = KeychainSecretStore.readPassword(services: MeetingSummaryAPIKeyKind.customOpenAI.keychainServices)
        guard let apiKey, !apiKey.isEmpty,
              let baseURL = URL(string: customBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines)),
              !customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return .openAICompatible(
            baseURL: baseURL,
            apiKey: apiKey,
            model: customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func makeLMStudioExecutionConfiguration() -> SummaryExecutionConfiguration? {
        let trimmedURL = lmStudioBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty,
              let baseURL = URL(string: trimmedURL),
              !lmStudioModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return .lmStudioConfigured(
            baseURL: baseURL,
            apiToken: KeychainSecretStore.readPassword(services: MeetingSummaryAPIKeyKind.lmStudio.keychainServices) ?? "",
            model: lmStudioModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private enum SummaryExecutionConfiguration: Sendable {
        case openAICompatible(baseURL: URL, apiKey: String, model: String)
        case lmStudioConfigured(baseURL: URL, apiToken: String, model: String)
        case localFallback(reason: String)
        case disabled
    }

    private static func summaryCatalogJSON(from document: MeetingSummaryDocument) -> String {
        let topics: [[String: Any]] = document.topics.map { topic in
            [
                "id": topic.id,
                "title": topic.title,
                "aliases": topic.aliases
            ]
        }
        let items: [[String: Any]] = document.items
            .filter { $0.status != .resolved && $0.status != .superseded }
            .prefix(300)
            .map { item in
                var value: [String: Any] = [
                    "id": item.id,
                    "topic_id": item.topicID,
                    "kind": item.kind.rawValue,
                    "status": item.status.rawValue,
                    "text": String(item.text.prefix(96)),
                    "locked_by_user": item.lockedByUser
                ]
                if let owner = nilIfBlank(item.owner) {
                    value["owner"] = owner
                }
                if let dueDate = nilIfBlank(item.dueDate) {
                    value["due_date"] = dueDate
                }
                return value
            }
        let payload: [String: Any] = [
            "headline": String(document.headline.prefix(120)),
            "topics": topics,
            "items": items
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return #"{"headline":"","topics":[],"items":[]}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func legacyProjection(from document: MeetingSummaryDocument) -> LiveMeetingSummaryState {
        let activeItems = document.items.filter { $0.status != .resolved && $0.status != .superseded }
        let topics = document.topics.compactMap { topic -> LiveMeetingSummaryState.TopicSummary? in
            let topicItems = activeItems.filter { $0.topicID == topic.id }
            if topic.id == fallbackTopicID && topicItems.isEmpty {
                return nil
            }
            let conclusions = topicItems.filter {
                [.decision, .requirement, .fact, .note].contains($0.kind)
            }
            let openItems = topicItems.filter {
                [.action, .openQuestion, .risk].contains($0.kind)
            }
            return .init(
                topic: topic.title,
                conclusion: conclusions.map(\.text).joined(separator: "；"),
                openItems: openItems.map(\.text)
            )
        }
        return LiveMeetingSummaryState(topics: topics)
    }

    private static func sanitizedSummaryError(_ reason: String) -> String {
        SummaryErrorSanitizer.sanitize(reason)
    }

    private static func nilIfBlank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let summaryDefaultsVersionKey = "summary.defaults.version"
    private static let summaryProviderKey = "summary.provider"
    private static let summaryTriggerModeKey = "summary.trigger.mode"
    private static let summaryIntervalSecondsKey = "summary.interval.seconds"
    private static let summaryCharacterThresholdKey = "summary.character.threshold"
    private static let deepSeekBaseURLKey = "summary.deepseek.baseURL"
    private static let deepSeekModelKey = "summary.deepseek.model"
    private static let lmStudioBaseURLKey = "summary.lmstudio.baseURL"
    private static let lmStudioModelKey = "summary.lmstudio.model"
    private static let customBaseURLKey = "summary.custom.baseURL"
    private static let customModelKey = "summary.custom.model"
    private static let inputGainDecibelsKey = "audio.input.gain.decibels"
    private static let voiceSensitivityModeKey = "audio.voice.sensitivity.mode"
    private static let audioCaptureModeKey = "audio.capture.mode"
    private static let manualVoiceThresholdDecibelsKey = "audio.voice.manual.threshold.decibels"
    private static let pauseCommitDelaySecondsKey = "audio.pause.commit.delay.seconds"
    private static let recordingOutputDirectoryKey = "artifacts.recording.output.directory"
    private static let highlightsOutputDirectoryKey = "artifacts.highlights.output.directory"
    private static let codexHandoffEnabledKey = "artifacts.codex.handoff.enabled"

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let decibelFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private static let oneDecimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()

private static let twoDecimalFormatter: NumberFormatter = {
let formatter = NumberFormatter()
formatter.minimumFractionDigits = 2
formatter.maximumFractionDigits = 2
return formatter
}()
}

private enum SystemAudioCapturePermissionError: LocalizedError {
    case screenCaptureDenied

    var errorDescription: String? {
        switch self {
        case .screenCaptureDenied:
            return "使用者拒絕應用程式、視窗、顯示器擷取的 TCC 權限。"
        }
    }
}
