@preconcurrency import AVFoundation
import AppKit
import CoreGraphics
import Darwin
import Foundation
import Speech
import MoMoWhisperSessionCore

@MainActor
final class SpeechTranscriptionService: ObservableObject {
    @Published var transcript = ""
    @Published var partialTranscript = ""
    @Published var meetingNotes = ""
    @Published var isRecording = false
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
    @Published var meetingHistorySearchText = "" {
        didSet {
            refreshMeetingHistory()
        }
    }

    private let audioEngine = AVAudioEngine()
    private let audioRouter = SpeechAudioBufferRouter()
    private let microphoneLevelMeter = SpeechAudioLevelMeter()
    private let systemAudioCapture = SystemAudioCapture()
    private let meetingSessionStore = MeetingSessionStore()
    private let meetingAudioRecorder = MeetingAudioRecorder()

    private var speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechAnalyzerSession: SpeechAnalyzerSessionHandling?
    private var systemSpeechAnalyzerSession: SpeechAnalyzerSessionHandling?
    private var microphoneAudioProcessor: AudioInputProcessor?
    private var pendingCommitTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var summaryRequestTask: Task<Void, Never>?
    private var postRecordingSummaryTask: Task<Void, Never>?
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
    private var currentRecordingURL: URL?
    private var recordingLifecycle = MeetingRecordingLifecycle()
    private var isLoadingSummarySettings = false

    init() {
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
    private static let deliveryTranscriptMinimumCharacters = 300
    private static let deliveryHighlightsMinimumCharacters = 80
    private static let deliveryRecordingMinimumBytes = 45

    private struct SummaryRequestPlan {
        var payloadTranscript: String
        var recentTranscript: String
        var summarizedCharacterCount: Int
        var requestIsFinal: Bool
        var continuation: SummaryContinuation

        var fallbackTranscript: String {
            payloadTranscript.isEmpty ? recentTranscript : payloadTranscript
        }
    }

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

    var transcriptCharacterCount: Int {
        visibleTranscriptOutput().count
    }

    var meetingNotesCharacterCount: Int {
        meetingNotesOutput().count
    }

    var summarizedTranscriptCount: Int {
        min(max(0, lastSummarizedTranscriptCharacterCount), transcriptCharacterCount)
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

    var latestValidMeetingMetadata: MeetingSessionMetadata? {
        meetingHistory.first { metadata in
            metadata.isMeaningfulForHandoff
        }
    }

    var latestValidCodexHandoffJSONPath: String {
        MeetingArtifactExporter.defaultCodexHandoffDirectory
            .appendingPathComponent("\(MeetingArtifactExporter.latestValidHandoffBaseName).json")
            .path
    }

    var latestValidCodexHandoffExists: Bool {
        FileManager.default.fileExists(atPath: latestValidCodexHandoffJSONPath)
    }

    var latestValidCodexHandoffReady: Bool {
        let handoffCheck = DeliveryArtifactInspector.inspectTextFile(
            label: "latest_valid handoff",
            path: latestValidCodexHandoffJSONPath,
            minimumCharacters: 1
        )
        guard handoffCheck.meetsRequirement,
              let expectedMeetingID = latestValidMeetingMetadata?.id.uuidString,
              let data = FileManager.default.contents(atPath: latestValidCodexHandoffJSONPath),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["meetingID"] as? String == expectedMeetingID else {
            return false
        }

        let transcriptPath = payload["transcriptPath"] as? String ?? ""
        let highlightsPath = payload["highlightsPath"] as? String ?? ""
        let transcriptCheck = DeliveryArtifactInspector.inspectTextFile(
            label: "逐字稿",
            path: transcriptPath,
            minimumCharacters: Self.deliveryTranscriptMinimumCharacters
        )
        let highlightsCheck = DeliveryArtifactInspector.inspectTextFile(
            label: "會議重點",
            path: highlightsPath,
            minimumCharacters: Self.deliveryHighlightsMinimumCharacters
        )
        return transcriptCheck.meetsRequirement || highlightsCheck.meetsRequirement
    }

    var deliveryArtifactChecks: [DeliveryArtifactCheck] {
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

        let sessionFolder = meetingSessionStore.sessionFolderURL(for: metadata)
        var checks = [
            DeliveryArtifactInspector.inspectTextFile(
                label: "逐字稿",
                path: sessionFolder.appendingPathComponent("transcript.md").path,
                minimumCharacters: Self.deliveryTranscriptMinimumCharacters
            ),
            DeliveryArtifactInspector.inspectTextFile(
                label: "會議重點",
                path: metadata.exportedHighlightsFilePath
                    ?? sessionFolder.appendingPathComponent("highlights.md").path,
                minimumCharacters: Self.deliveryHighlightsMinimumCharacters
            )
        ]

        let recordingParts = metadata.recordingParts.sorted { $0.sequence < $1.sequence }
        if recordingParts.isEmpty {
            checks.append(
                DeliveryArtifactInspector.inspectBinaryFile(
                    label: "錄音 part",
                    path: metadata.recordingFilePath ?? "",
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
                path: metadata.codexHandoffFilePath ?? "",
                minimumCharacters: 1
            )
        )
        return checks
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

    func toggleRecording() async {
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
        lastError = nil

        if isRecording {
            await stopRecording(runFinalSummary: false)
        } else {
            autosaveCurrentSession(endedAt: Date())
        }

        cancelSummaryWorkForSessionBoundary()

        if hasContent {
            exportFinalArtifactsIfPossible()
        }

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
            failStartingRecording()
            statusText = "權限未開"
            return
        }

        guard recordingLifecycle.isStartStillActive else {
            abortStartingRecording()
            return
        }

        if usesSpeechAnalyzerRecognition {
            guard #available(macOS 26.0, *) else {
                statusText = "語音服務不可用"
                lastError = "SpeechAnalyzer 需要 macOS 26 或更新版本。"
                failStartingRecording()
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
            failStartingRecording()
            return
        }
        } else {
            guard let speechRecognizer, speechRecognizer.isAvailable else {
                statusText = "語音服務不可用"
                lastError = "目前語音辨識服務不可用，請稍後再試或切換語言。"
                failStartingRecording()
                return
            }
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
            failStartingRecording()
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
                failStartingRecording()
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
                failStartingRecording()
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
            failStartingRecording()
            return
        }

        guard recordingLifecycle.isStartStillActive, recordingLifecycle.markRecordingStarted() else {
            abortStartingRecording()
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

    func stopRecording(runFinalSummary: Bool = true) async {
        switch recordingLifecycle.requestStop() {
        case .stopActiveRecording:
            break
        case .abortStarting:
            abortStartingRecording()
            return
        case .ignored:
            return
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
        autosaveCurrentSession(endedAt: Date())
        recordingLifecycle.finishStop()

        guard runFinalSummary else {
            exportFinalArtifactsIfPossible()
            return
        }

        if runMeetingSummary(isFinal: true, force: true) {
            startPostRecordingSummaryDrain()
        } else {
            exportFinalArtifactsIfPossible()
        }
    }

    func clear() {
        autosaveCurrentSession(endedAt: Date())
        recordingLifecycle.reset()
        currentRecordingURL = nil
        transcript = ""
        partialTranscript = ""
        meetingNotes = ""
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
        deepSeekDiagnosticsText = "DeepSeek cache 待開始"
        summaryStatusText = "待整理"
    }

    private func cancelSummaryWorkForSessionBoundary() {
        summaryGeneration += 1
        summaryTask?.cancel()
        summaryTask = nil
        summaryRequestTask?.cancel()
        summaryRequestTask = nil
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
        deepSeekDiagnosticsText = "DeepSeek cache 待開始"
    }

    func refreshMeetingNotes() {
        runMeetingSummary(isFinal: true, force: true)
    }

    func startNewMeetingSession(title: String? = nil) {
        do {
            let metadata = try meetingSessionStore.createSession(title: title)
            currentSessionMetadata = metadata
            currentSessionStartedAt = metadata.startedAt
            currentRecordingURL = nil
            if case .startingNewSession = recordingLifecycle.state {
                // startRecording() attaches this freshly allocated session before creating a part.
            } else {
                recordingLifecycle.prepareNewSession(metadata.id)
            }
            transcriptSegments = []
            refreshMeetingHistory()
            autosaveCurrentSession()
        } catch {
            lastError = "建立會議歷史失敗：\(error.localizedDescription)"
        }
    }

    func refreshMeetingHistory() {
        do {
            meetingHistory = try meetingSessionStore.searchMetadata(query: meetingHistorySearchText)
        } catch {
            meetingHistory = []
            lastError = "讀取會議歷史失敗：\(error.localizedDescription)"
        }
    }

    func loadMeetingSession(_ metadata: MeetingSessionMetadata) {
        guard !isRecording else {
            lastError = "錄音中不可載入歷史會議。"
            return
        }

        cancelSummaryWorkForSessionBoundary()

        do {
            let snapshot = try meetingSessionStore.loadSnapshot(metadata: metadata)
            currentSessionMetadata = snapshot.metadata
            currentSessionStartedAt = snapshot.metadata.startedAt
            recordingLifecycle.markHistoryLoaded(snapshot.metadata.id)
            currentRecordingURL = nil
            lastRecordingFilePath = snapshot.metadata.recordingFilePath ?? ""
            transcriptSegments = snapshot.transcriptSegments
            transcript = snapshot.transcriptMarkdown
            partialTranscript = ""
            meetingNotes = snapshot.highlightsMarkdown
            liveSummaryState = snapshot.rawSummaryState
            latestRecognitionText = ""
            latestFullRecognitionText = ""
            committedRecognitionText = ""
            liveDraftStartedAt = nil
            resetCommittedTranscriptTracking()
            lastUpdatedAt = snapshot.metadata.updatedAt
            lastSummaryUpdatedAt = snapshot.metadata.updatedAt
            lastSummarizedTranscriptCharacterCount = transcript.count
            statusText = "已載入歷史"
            summaryStatusText = "已載入重點"
        } catch {
            lastError = "載入歷史會議失敗：\(error.localizedDescription)"
        }
    }

    func resumeCurrentMeetingSession() async {
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
        await startRecording()
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

    private func failStartingRecording() {
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
                    metadata.recordingParts[index].endedAt = Date()
                    metadata.recordingParts[index].readiness = .failed
                }
                metadata.recordingReadiness = .failed
                metadata.recordingReadinessDetail = metadata.recordingReadiness.verificationBoundary
                currentSessionMetadata = metadata
            }
        }

        isRecording = false
        recordingLifecycle.failStart()
        autosaveCurrentSession(endedAt: Date())
    }

    private func abortStartingRecording() {
        stopRecognitionOnly()
        systemAudioCapture.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        microphoneAudioProcessor = nil
        cancelSpeechAnalyzerSession()

        if currentRecordingURL != nil {
            finishRecordingArtifact()
        }

        isRecording = false
        recordingLifecycle.finishStop()
        autosaveCurrentSession(endedAt: Date())
        statusText = "已停止"
    }

    private func exportLiveHandoffIfPossible() {
        guard codexHandoffEnabled, let metadata = currentSessionMetadata else {
            return
        }

        let transcriptMarkdown = visibleTranscriptOutput()
        let highlightsMarkdown = meetingNotesOutput()
        let hasMeetingContent = !transcriptMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !highlightsMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard isRecording || hasMeetingContent else {
            return
        }

        let sessionFolderPath = meetingSessionStore.sessionFolderURL(for: metadata).path
        let recordingURL = currentRecordingURL
            ?? metadata.recordingFilePath.map { URL(fileURLWithPath: $0) }

        do {
            let result = try MeetingArtifactExporter.exportCurrentHandoff(
                metadata: metadata,
                transcriptMarkdown: transcriptMarkdown,
                highlightsMarkdown: highlightsMarkdown,
                recordingURL: recordingURL,
                sessionFolderPath: sessionFolderPath,
                codexHandoffDirectory: MeetingArtifactExporter.defaultCodexHandoffDirectory,
                isRecording: isRecording,
                dateFormatter: Self.dateFormatter
            )

            lastCodexHandoffPath = result.codexHandoffMarkdownURL?.path ?? ""
            if isRecording {
                artifactStatusText = "即時 handoff 已更新"
            }
        } catch {
            lastError = "即時 handoff 更新失敗：\(error.localizedDescription)"
        }
    }

    private func exportFinalArtifactsIfPossible() {
        guard var metadata = currentSessionMetadata else {
            return
        }

        let transcriptMarkdown = visibleTranscriptOutput()
        let highlightsMarkdown = meetingNotesOutput()
        let sessionFolderPath = meetingSessionStore.sessionFolderURL(for: metadata).path
        let recordingURL = currentRecordingURL
            ?? metadata.recordingFilePath.map { URL(fileURLWithPath: $0) }

        do {
            let result = try MeetingArtifactExporter.export(
                metadata: metadata,
                transcriptMarkdown: transcriptMarkdown,
                highlightsMarkdown: highlightsMarkdown,
                recordingURL: recordingURL,
                sessionFolderPath: sessionFolderPath,
                highlightsDirectory: URL(fileURLWithPath: highlightsOutputDirectoryPath, isDirectory: true),
                codexHandoffDirectory: MeetingArtifactExporter.defaultCodexHandoffDirectory,
                includeCodexHandoff: codexHandoffEnabled,
                dateFormatter: Self.dateFormatter
            )

            metadata.recordingFilePath = result.recordingURL?.path
            metadata.exportedHighlightsFilePath = result.highlightsURL.path
            metadata.codexHandoffFilePath = result.codexHandoffMarkdownURL?.path
            currentSessionMetadata = metadata

            lastRecordingFilePath = result.recordingURL?.path ?? ""
            lastHighlightsFilePath = result.highlightsURL.path
            lastCodexHandoffPath = result.codexHandoffMarkdownURL?.path ?? ""
            artifactStatusText = codexHandoffEnabled
                ? "已輸出錄音、重點與 Codex handoff"
                : "已輸出錄音與會議重點"
            autosaveCurrentSession(endedAt: metadata.endedAt)
        } catch {
            lastError = "會後輸出失敗：\(error.localizedDescription)"
            artifactStatusText = "會後輸出失敗"
        }
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

    private func autosaveCurrentSession(endedAt: Date? = nil) {
        guard var metadata = currentSessionMetadata else {
            return
        }

        let now = Date()
        let transcriptMarkdown = visibleTranscriptOutput()
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

        let snapshot = MeetingSessionSnapshot(
            metadata: metadata,
            transcriptSegments: transcriptSegments,
            transcriptMarkdown: transcriptMarkdown,
            highlightsMarkdown: highlightsMarkdown,
            rawSummaryState: liveSummaryState
        )

        do {
            currentSessionMetadata = try meetingSessionStore.save(snapshot: snapshot)
            currentSessionStartedAt = currentSessionMetadata?.startedAt
            refreshMeetingHistory()
            exportLiveHandoffIfPossible()
        } catch {
            lastError = "自動保存會議失敗：\(error.localizedDescription)"
        }
    }

    func clearLiveDraftState() {
        partialTranscript = ""
        latestRecognitionText = ""
        liveDraftStartedAt = nil
        resetCommittedTranscriptTracking()
    }

    func visibleTranscriptOutput() -> String {
        [transcript, liveDraftTranscriptLine()]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
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

    private func handleRecognition(text: String?, isFinal: Bool, errorMessage: String?) {
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

            speechRecognitionStatusText = "辨識中斷"
            lastError = errorMessage
            Task {
                await stopRecording()
            }
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
        recognitionTask = Self.startRecognitionTask(
            recognizer: speechRecognizer,
            request: request
        ) { [weak self] text, isFinal, errorMessage in
            self?.handleRecognition(text: text, isFinal: isFinal, errorMessage: errorMessage)
        }
    }

    private func stopRecognitionOnly() {
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
        autosaveCurrentSession()
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
        autosaveCurrentSession()
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
        "\(prefix) · 未整理 \(unsummarizedTranscriptCount)"
    }

    private var shouldContinuePostRecordingSummaryDrain: Bool {
        summaryProvider != .disabled && unsummarizedTranscriptCount > 0
    }

    private func evaluateAutomaticSummaryTrigger() {
        guard shouldRunAutomaticSummary() else {
            return
        }

        runMeetingSummary(isFinal: false)
    }

    private func shouldRunAutomaticSummary() -> Bool {
        guard summaryProvider != .disabled,
              summaryTriggerMode != .manualOnly,
              !isSummaryRequestInFlight else {
            return false
        }

        let liveText = visibleTranscriptOutput()
        guard !liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let newCharacterCount = liveText.count - min(lastSummarizedTranscriptCharacterCount, liveText.count)
        let characterReached = newCharacterCount >= max(100, summaryCharacterThreshold)
        let lastAutomaticSummaryAt = lastAutomaticSummaryAt ?? Date()
        let timeReached = Date().timeIntervalSince(lastAutomaticSummaryAt) >= max(30, summaryIntervalSeconds)

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
        let liveText = visibleTranscriptOutput()
        guard !liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let safeStart = min(lastSummarizedTranscriptCharacterCount, liveText.count)
        let newStartIndex = liveText.index(liveText.startIndex, offsetBy: safeStart)
        let newTranscript = String(liveText[newStartIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard force || isFinal || !newTranscript.isEmpty else {
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
        let currentState = liveSummaryState
        let requestGeneration = summaryGeneration
        let requestPlan = makeSummaryRequestPlan(
            liveText: liveText,
            newTranscript: newTranscript,
            safeStart: safeStart,
            isFinal: isFinal
        )
        summaryStatusText = requestPlan.requestIsFinal
            ? "最後梳理中"
            : (isFinal ? "最後分段整理中" : "整理中")

        summaryRequestTask = Task { [weak self] in
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
                    let state = try await summarizer.summarize(
                        newTranscript: requestPlan.payloadTranscript,
                        recentTranscript: requestPlan.recentTranscript,
                        currentState: currentState,
                        isFinal: requestPlan.requestIsFinal
                    )
                    self?.applyDeepSeekDiagnostics(summarizer.lastDiagnostics)
                    await self?.applySummaryState(
                        state,
                        summarizedCharacterCount: requestPlan.summarizedCharacterCount,
                    isFinal: requestPlan.requestIsFinal,
                    continuation: requestPlan.continuation,
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
                    let notes = try await transcriptAnalyzer.summarizeMeeting(requestPlan.recentTranscript)
                await self?.applySummaryText(
                    notes,
                    summarizedCharacterCount: requestPlan.summarizedCharacterCount,
                    isFinal: requestPlan.requestIsFinal,
                    continuation: requestPlan.continuation,
                    requestGeneration: requestGeneration
                )
            case .localFallback(let reason):
                await self?.applyLocalFallbackSummary(
                    reason: reason,
                    transcript: requestPlan.fallbackTranscript,
                    summarizedCharacterCount: requestPlan.summarizedCharacterCount,
                    isFinal: requestPlan.requestIsFinal,
                    continuation: requestPlan.continuation,
                    requestGeneration: requestGeneration
                )
            case .disabled:
                await self?.applySummaryText(
                    Self.emptySummaryMarkdown,
                    summarizedCharacterCount: requestPlan.summarizedCharacterCount,
                    isFinal: requestPlan.requestIsFinal,
                    continuation: requestPlan.continuation,
                    requestGeneration: requestGeneration
                )
            }
            } catch {
                self?.applyDeepSeekDiagnostics(nil)
                await self?.applyLocalFallbackSummary(
                    reason: error.localizedDescription,
                transcript: requestPlan.fallbackTranscript,
                summarizedCharacterCount: requestPlan.summarizedCharacterCount,
                isFinal: requestPlan.requestIsFinal,
                continuation: requestPlan.continuation,
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
        isFinal: Bool
    ) -> SummaryRequestPlan {
        let recentTranscript = String(liveText.suffix(Self.recentTranscriptCharacterLimit))
        let chunkLimit = isFinal ? Self.finalSummaryChunkCharacterLimit : Self.liveSummaryChunkCharacterLimit
        let chunk = String(newTranscript.prefix(chunkLimit)).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !chunk.isEmpty else {
            return SummaryRequestPlan(
                payloadTranscript: "",
                recentTranscript: recentTranscript,
                summarizedCharacterCount: liveText.count,
                requestIsFinal: isFinal,
                continuation: .none
            )
        }

        let summarizedCharacterCount = min(liveText.count, safeStart + chunk.count)
        let hasRemainingTranscript = newTranscript.count > chunk.count

        return SummaryRequestPlan(
            payloadTranscript: chunk,
            recentTranscript: recentTranscript,
            summarizedCharacterCount: summarizedCharacterCount,
            requestIsFinal: isFinal && !hasRemainingTranscript,
            continuation: hasRemainingTranscript ? (isFinal ? .final : .live) : .none
        )
    }

    private func applySummaryState(
        _ state: LiveMeetingSummaryState,
        summarizedCharacterCount: Int,
        isFinal: Bool,
        continuation: SummaryContinuation = .none,
        requestGeneration: Int? = nil
    ) {
        guard isCurrentSummaryGeneration(requestGeneration) else {
            return
        }

        let hadExistingSummary = !liveSummaryState.isEmpty
        let mergedState = liveSummaryState.merged(with: state)
        liveSummaryState = mergedState
        meetingNotes = mergedState.markdown()
        lastSummarizedTranscriptCharacterCount = summarizedCharacterCount
        queueSummaryContinuation(continuation)
        finishSummaryRequest(
            isFinal: isFinal,
            statusText: state.isEmpty && hadExistingSummary ? "無新增重點，已保留" : nil
        )
    }

    private func applySummaryText(
        _ text: String,
        summarizedCharacterCount: Int,
        isFinal: Bool,
        statusText: String? = nil,
        continuation: SummaryContinuation = .none,
        requestGeneration: Int? = nil
    ) {
        guard isCurrentSummaryGeneration(requestGeneration) else {
            return
        }

        lastError = nil
        meetingNotes = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastSummarizedTranscriptCharacterCount = summarizedCharacterCount
        queueSummaryContinuation(continuation)
        finishSummaryRequest(isFinal: isFinal, statusText: statusText)
    }

    private func applyLocalFallbackSummary(
        reason: String,
        transcript: String,
        summarizedCharacterCount: Int,
        isFinal: Bool,
        continuation: SummaryContinuation = .none,
        requestGeneration: Int? = nil
    ) {
        guard isCurrentSummaryGeneration(requestGeneration) else {
            return
        }

        let fallbackSummary = Self.localFallbackSummaryMarkdown(from: transcript)
        let existingNotes = meetingNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPostRecordingFinalDrain = continuation == .final
        let didApplyFallback: Bool
        if existingNotes.isEmpty || liveSummaryState.isEmpty {
            meetingNotes = fallbackSummary
            lastError = "AI 整理未完成，已改用本機粗整理：\(reason)"
            didApplyFallback = true
        } else if isFinal || isPostRecordingFinalDrain {
            meetingNotes = """
            \(existingNotes)

            ---

            ## 本機備援補充

            \(fallbackSummary)
            """
            lastError = "AI 會後分段整理未完成，已保留既有重點並附上本機補充：\(reason)"
            didApplyFallback = true
        } else {
            meetingNotes = existingNotes
            lastError = "AI 整理未完成，已保留既有重點：\(reason)"
            didApplyFallback = false
        }
        if didApplyFallback {
            lastSummarizedTranscriptCharacterCount = summarizedCharacterCount
            queueSummaryContinuation(continuation)
        }
        finishSummaryRequest(
            isFinal: isFinal,
            statusText: existingNotes.isEmpty || liveSummaryState.isEmpty
            ? (isFinal ? "本機備援完成" : "本機備援已更新")
            : ((isFinal || isPostRecordingFinalDrain) ? "已保留並補充" : "已保留既有重點")
        )
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

    private func applyDeepSeekDiagnostics(_ diagnostics: DeepSeekMeetingDiagnostics?) {
        guard let diagnostics else {
            return
        }

        let rate = Int((diagnostics.cacheHitRate * 100).rounded())
        let finish = diagnostics.finishReason ?? "unknown"
        deepSeekDiagnosticsText = "DeepSeek cache \(rate)% · hit \(diagnostics.promptCacheHitTokens) / miss \(diagnostics.promptCacheMissTokens) · \(finish)"
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

    private static func localFallbackSummaryMarkdown(from transcript: String) -> String {
        let lines = transcript
            .components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(
                    of: #"^\[[^\]]+\]\s*"#,
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        let recentLines = Array(lines.suffix(10))
        let topicLines = Array(recentLines.prefix(5))
        let conclusionLines = recentLines.filter { line in
            let markers = ["決定", "結論", "所以", "需要", "要", "可以", "不能", "問題", "原因"]
            return markers.contains { line.contains($0) }
        }
        let questionLines = recentLines.filter { line in
            line.contains("?") ||
            line.contains("？") ||
            line.contains("為什麼") ||
            line.contains("是否") ||
            line.contains("確認")
        }

        return """
        ## 議題主題

        \(Self.bulletMarkdown(from: topicLines, empty: "尚無明確議題"))

        ## 主題結論

        \(Self.bulletMarkdown(from: Array(conclusionLines.prefix(5)), empty: "尚需 AI 或人工確認結論"))

        ## 主題未確認事項

        \(Self.bulletMarkdown(from: Array(questionLines.prefix(5)), empty: "尚無"))
        """
    }

    private static func bulletMarkdown(from lines: [String], empty: String) -> String {
        let cleaned = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleaned.isEmpty else {
            return "- \(empty)"
        }

        return cleaned
            .map { "- \($0)" }
            .joined(separator: "\n")
    }

    private static let emptySummaryMarkdown = """
    ## 議題主題

    - 尚無明確議題

    ## 主題結論

    - 尚無明確結論

    ## 主題未確認事項

    - 尚無
    """

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
