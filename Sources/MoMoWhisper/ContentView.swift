import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MoMoWhisperSummaryCore

private enum CompactLivePane: String, CaseIterable, Identifiable {
    case transcript
    case summary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcript: return "逐字稿"
        case .summary: return "會議重點"
        }
    }
}

@MainActor
struct ContentView: View {
    @EnvironmentObject private var transcriber: SpeechTranscriptionService
    @State private var copiedTranscript = false
    @State private var copiedMeetingNotes = false
    @State private var showingSettings = false
    @State private var showingHistory = false
    @State private var showingOnboarding = false
    @State private var showingSummaryDiagnostics = false
    @State private var selectedSection: WorkspaceSection = .live
    @State private var compactLivePane: CompactLivePane = .transcript
    @AppStorage("momowhisper.onboarding.completed.v1") private var onboardingCompleted = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                recordingStatusBar
                Divider().overlay(AppTheme.border)
                HStack(spacing: 0) {
                    NavigationRail(
                        selection: selectedSection,
                        select: { selectedSection = $0 },
                        showHistory: {
                            transcriber.refreshMeetingHistory()
                            showingHistory = true
                        },
                        showSettings: { showingSettings = true }
                    )
                    Divider().overlay(AppTheme.border)
                    VStack(spacing: 0) {
                        TrustStatusStrip()
                        Divider().overlay(AppTheme.border)
                        Group {
                            switch selectedSection {
                            case .live:
                                liveWorkspace(isCompact: geometry.size.width < 1_100)
                            case .commandCenter:
                                commandCenter
                            }
                        }
                        Divider().overlay(AppTheme.border)
                        EvidenceCommandBar(
                            copyTranscript: copyTranscript,
                            copyNotes: copyMeetingNotes,
                            exportMarkdown: saveMarkdown,
                            showCommandCenter: { selectedSection = .commandCenter }
                        )
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .background(AppTheme.background)
        .preferredColorScheme(.light)
        .onAppear {
            transcriber.refreshInputDevices()
            transcriber.refreshMeetingHistory()
            if !onboardingCompleted {
                showingOnboarding = true
            }
        }
        .sheet(isPresented: $showingSettings) {
            SummarySettingsView()
                .environmentObject(transcriber)
        }
        .sheet(isPresented: $showingHistory) {
            MeetingHistoryView()
                .environmentObject(transcriber)
        }
        .sheet(isPresented: $showingOnboarding) {
            MoMoWhisperOnboardingView {
                onboardingCompleted = true
                showingOnboarding = false
            }
            .environmentObject(transcriber)
        }
    }

    @ViewBuilder
    private func liveWorkspace(isCompact: Bool) -> some View {
        if isCompact {
            VStack(spacing: 0) {
                Picker("目前內容", selection: $compactLivePane) {
                    ForEach(CompactLivePane.allCases) { pane in
                        Text(pane.title).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)

                Divider().overlay(AppTheme.border)

                Group {
                    switch compactLivePane {
                    case .transcript:
                        transcriptPane
                    case .summary:
                        summaryPane
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(AppTheme.background)
        } else {
            HStack(spacing: 0) {
                transcriptPane
                    .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(AppTheme.border)
                summaryPane
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(AppTheme.background)
        }
    }

    private var commandCenter: some View {
        PostMeetingCommandCenter(
            copyTranscript: copyTranscript,
            copyNotes: copyMeetingNotes,
            exportMarkdown: saveMarkdown,
            openRecordings: transcriber.revealRecordingOutputDirectory,
            openHighlights: transcriber.revealHighlightsOutputDirectory,
            openHandoff: transcriber.revealCodexHandoffDirectory
        )
    }

    private var recordingStatusBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        brandHeader
                        TrustPill(
                            title: "狀態",
                            value: transcriber.isRecording ? "錄音中" : "待開始",
                            systemImage: transcriber.isRecording ? "record.circle" : "pause.circle",
                            tone: transcriber.isRecording ? .danger : .neutral
                        )
                        TrustPill(
                            title: "音源",
                            value: transcriber.audioCaptureMode.displayName,
                            systemImage: "waveform",
                            tone: transcriber.audioCaptureMode.capturesSystemAudio ? .ready : .neutral
                        )
                        TrustPill(
                            title: "整理",
                            value: "\(Int((transcriber.summaryCoverageRatio * 100).rounded()))%",
                            systemImage: "gauge.medium",
                            tone: transcriber.summaryCoverageRatio > 0.9 ? .ready : .warning
                        )
                        TrustPill(
                            title: "Handoff",
                            value: transcriber.latestValidCodexHandoffReady ? "已驗證" : "待確認",
                            systemImage: "checkmark.seal",
                            tone: transcriber.latestValidCodexHandoffReady ? .ready : .warning
                        )
                    }
                }
                nextMeetingButton
                recordingButton
            }

            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        languagePicker
                        microphonePicker
                        audioCaptureModePicker
                        recognitionEnginePicker
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        preflightCheckButton
                        systemAudioTestButton
                        refreshDevicesButton
                        onboardingButton
                        historyButton
                        settingsButton
                        updateNotesButton
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.controlSurface, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
            }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(AppTheme.chrome)
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                brandHeader
                languagePicker
            microphonePicker
            refreshDevicesButton
            audioCaptureModePicker
            preflightCheckButton
            systemAudioTestButton
            Spacer(minLength: 16)
            recordingButton
            }

            HStack(spacing: 8) {
                recognitionEnginePicker
                Spacer(minLength: 0)
                historyButton
                settingsButton
                updateNotesButton
                clearButton
                copyTranscriptButton
                copyMeetingNotesButton
                exportButton
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .onAppear {
            transcriber.refreshInputDevices()
        }
        .sheet(isPresented: $showingSettings) {
            SummarySettingsView()
                .environmentObject(transcriber)
        }
        .sheet(isPresented: $showingHistory) {
            MeetingHistoryView()
                .environmentObject(transcriber)
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 9) {
            appIconMark
            Text("MoMoWhisper")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppTheme.primaryInk)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: 190, alignment: .leading)
        .clipped()
        .layoutPriority(4)
    }

    private var appIconMark: some View {
        VerifiedWaveMark(size: 34)
    }

    private func toolbarControl<Content: View>(
        title: String,
        systemImage: String,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.primaryInk)
                .labelStyle(.titleAndIcon)

            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: width)
        .frame(minHeight: 36)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private func selectionMenuLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.primaryInk)
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(AppTheme.controlSurfaceActive, in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
    }

    private func toolbarActionLabel(_ title: String, systemImage: String, prominent: Bool = false) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(prominent ? Color.white : AppTheme.primaryInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                prominent ? AppTheme.codexBlue : AppTheme.surface,
                in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                    .stroke(prominent ? AppTheme.codexBlue.opacity(0.65) : AppTheme.border, lineWidth: 1)
            )
    }

    private var selectedLanguageTitle: String {
        switch transcriber.localeIdentifier {
        case "mixed-zh-en":
            return "中英混合"
        case "zh-TW":
            return "繁中"
        case "en-US":
            return "英文"
        case "ja-JP":
            return "日文"
        default:
            return transcriber.localeIdentifier
        }
    }

    private var selectedMicrophoneTitle: String {
        transcriber.availableInputDevices.first { $0.id == transcriber.selectedInputDeviceID }?.name
            ?? AudioInputDevice.systemDefault.name
    }

    private var languagePicker: some View {
        toolbarControl(title: "語言", systemImage: "globe", width: 190) {
            Menu {
                Button("中英混合") { transcriber.localeIdentifier = "mixed-zh-en" }
                Button("繁中") { transcriber.localeIdentifier = "zh-TW" }
                Button("英文") { transcriber.localeIdentifier = "en-US" }
                Button("日文") { transcriber.localeIdentifier = "ja-JP" }
            } label: {
                selectionMenuLabel(selectedLanguageTitle)
            }
            .menuStyle(.borderlessButton)
        }
        .disabled(transcriber.isRecording || transcriber.isSessionTransitionInProgress)
        .help("選擇語音辨識語言")
    }

    private var microphonePicker: some View {
        toolbarControl(title: "麥克風", systemImage: "mic", width: 270) {
            Menu {
                ForEach(transcriber.availableInputDevices) { device in
                    Button(device.name) {
                        transcriber.selectedInputDeviceID = device.id
                    }
                }
            } label: {
                selectionMenuLabel(selectedMicrophoneTitle)
            }
            .menuStyle(.borderlessButton)
        }
        .disabled(
            transcriber.isRecording
                || transcriber.isSessionTransitionInProgress
                || !transcriber.audioCaptureMode.usesMicrophone
        )
        .help(transcriber.audioCaptureMode.usesMicrophone ? "選擇麥克風裝置" : "目前音訊來源不使用麥克風")
    }

    private var refreshDevicesButton: some View {
        Button {
            transcriber.refreshInputDevices()
        } label: {
            toolbarActionLabel("重整裝置", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(transcriber.isRecording || transcriber.isSessionTransitionInProgress)
        .help("重新整理麥克風清單")
    }

    private var audioCaptureModePicker: some View {
        toolbarControl(title: "音源", systemImage: "waveform.badge.magnifyingglass", width: 280) {
            Menu {
                ForEach(AudioCaptureMode.allCases) { mode in
                    Button(mode.displayName) {
                        transcriber.audioCaptureMode = mode
                    }
                }
            } label: {
                selectionMenuLabel(transcriber.audioCaptureMode.displayName)
            }
            .menuStyle(.borderlessButton)
        }
        .disabled(transcriber.isRecording || transcriber.isSessionTransitionInProgress)
        .help(transcriber.audioCaptureMode.helpText)
    }

    private var preflightCheckButton: some View {
        Button {
            Task { await transcriber.runPreMeetingHealthCheck() }
        } label: {
            toolbarActionLabel("會前檢查", systemImage: "checkmark.shield", prominent: true)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(transcriber.isRecording || transcriber.isSessionTransitionInProgress)
        .help(transcriber.preflightUpdatedAtText)
        .accessibilityLabel("會前檢查")
        .keyboardShortcut("p", modifiers: [.command, .shift])
    }

    private var systemAudioTestButton: some View {
        Button {
            Task { await transcriber.testSystemAudioCapture() }
        } label: {
            toolbarActionLabel("測試系統音訊", systemImage: "speaker.wave.2")
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(transcriber.isRecording || transcriber.isSessionTransitionInProgress)
        .help("單獨測試螢幕與系統錄音權限與系統音訊 buffer，不會開麥克風")
        .accessibilityLabel("測試系統音訊")
        .keyboardShortcut("u", modifiers: [.command, .shift])
    }

    private var recognitionEnginePicker: some View {
        toolbarControl(title: "辨識", systemImage: "text.bubble", width: 240) {
            Menu {
                ForEach(TranscriptionEngine.allCases) { engine in
                    Button(engine.displayName) {
                        transcriber.selectedTranscriptionEngine = engine
                    }
                    .disabled(!engine.isSupportedOnCurrentOS)
                }
            } label: {
                selectionMenuLabel(transcriber.selectedTranscriptionEngine.displayName)
            }
            .menuStyle(.borderlessButton)
        }
        .disabled(transcriber.isRecording || transcriber.isSessionTransitionInProgress)
        .help("SpeechAnalyzer 需要 macOS 26；較舊版本會使用 Apple Speech")
    }

    private var updateNotesButton: some View {
        Button {
            transcriber.refreshMeetingNotes()
        } label: {
            toolbarActionLabel("更新重點", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(
            !transcriber.hasContent
                || summaryReaderStatus.isHistorical
                || transcriber.isSessionTransitionInProgress
        )
        .help(summaryReaderStatus.isHistorical ? "歷史會議為唯讀；先明確續錄後才能更新重點" : "依目前逐字稿更新會議重點")
    }

    private var settingsButton: some View {
        Button {
            showingSettings = true
        } label: {
            toolbarActionLabel("整理設定", systemImage: "gearshape")
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("調整自動整理頻率、字數門檻與 API")
    }

    private var onboardingButton: some View {
        Button {
            showingOnboarding = true
        } label: {
            toolbarActionLabel("首次設定", systemImage: "person.crop.circle.badge.checkmark")
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(transcriber.isRecording || transcriber.isSessionTransitionInProgress)
        .help("重新檢查權限、麥克風與系統音訊")
    }

    private var historyButton: some View {
        Button {
            transcriber.refreshMeetingHistory()
            showingHistory = true
        } label: {
            toolbarActionLabel("歷史", systemImage: "clock.arrow.circlepath")
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(transcriber.isSessionTransitionInProgress)
        .help("搜尋、載入或開啟已自動保存的會議")
    }

    private var clearButton: some View {
        Button {
            Task {
                await transcriber.clear()
            }
        } label: {
            Label("清空", systemImage: "trash")
        }
        .disabled(
            !transcriber.hasContent
                || transcriber.isRecording
                || transcriber.isSessionTransitionInProgress
        )
        .help(
            transcriber.isRecording || transcriber.isSessionTransitionInProgress
                ? "請等待錄音停止或狀態切換完成後再清空"
                : "清空目前會議內容"
        )
    }

    private var copyTranscriptButton: some View {
        Button {
            copyTranscript()
        } label: {
            Label(copiedTranscript ? "已複製逐字稿" : "複製逐字稿", systemImage: "text.page")
        }
        .disabled(!transcriber.hasTranscriptContent)
    }

    private var copyMeetingNotesButton: some View {
        Button {
            copyMeetingNotes()
        } label: {
            Label(copiedMeetingNotes ? "已複製會議記錄" : "複製會議記錄", systemImage: "list.clipboard")
        }
        .disabled(!transcriber.hasMeetingNotesContent)
    }

    private var exportButton: some View {
        Button {
            saveMarkdown()
        } label: {
            Label("匯出", systemImage: "square.and.arrow.down")
        }
        .disabled(!transcriber.hasContent)
    }

    private var nextMeetingButton: some View {
        Button {
            Task {
                await transcriber.startNextMeeting()
            }
        } label: {
            toolbarActionLabel("下一場", systemImage: "forward.end.fill")
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(transcriber.isSessionTransitionInProgress)
        .help(transcriber.isRecording ? "停止並封存目前會議，建立下一場" : "封存目前會議，建立下一場")
        .accessibilityLabel("下一場會議")
        .keyboardShortcut("n", modifiers: [.command, .shift])
    }

    private var recordingButton: some View {
        Button {
            Task {
                await transcriber.toggleRecording()
            }
        } label: {
            Label(transcriber.isRecording ? "停止" : "開始", systemImage: transcriber.isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(minWidth: 82)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            paneHeader(
                title: "逐字稿",
                subtitle: transcriber.updatedAtText,
                systemImage: "text.alignleft"
            )

            transcriptEditor

            currentSegmentView
        }
        .padding(18)
    }

    @ViewBuilder
    private var transcriptEditor: some View {
        if transcriber.isViewingHistoricalSession {
            ScrollView {
                Text(transcriber.transcript.isEmpty ? "尚無逐字稿" : transcriber.transcript)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(transcriber.transcript.isEmpty ? AppTheme.textSecondary : AppTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
            .accessibilityLabel("歷史逐字稿，唯讀")
            .accessibilityHint("如需續錄請使用明確的續錄操作。")
        } else {
            TextEditor(text: Binding(
                get: { transcriber.transcript },
                set: { transcriber.updateTranscriptManually($0) }
            ))
                .font(.system(size: 15, design: .rounded))
                .foregroundColor(AppTheme.textPrimary)
                .tint(AppTheme.actionTeal)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(AppTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                )
                .disabled(transcriber.isSessionTransitionInProgress)
                .accessibilityHint("可人工修正目前會議的逐字稿。")
        }
    }

    private var summaryPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            paneHeader(
                title: "會議重點",
                subtitle: transcriber.summaryUpdatedAtText,
                systemImage: "list.bullet.clipboard"
            )

            summaryReader

            DisclosureGroup("技術狀態", isExpanded: $showingSummaryDiagnostics) {
                statusFooter
                    .padding(.top, 8)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(18)
    }

    private var summaryReader: some View {
        MeetingSummaryReaderView(
            document: transcriber.summaryDocument,
            status: summaryReaderStatus,
            rawMarkdown: transcriber.rawMeetingNotes,
            onCopy: copyMeetingSummaryPayload,
            onEditItem: summaryEditHandler
        )
    }

    private var summaryEditHandler: ((MeetingSummaryManualEditRequest) -> Void)? {
        guard !summaryReaderStatus.isHistorical,
              !transcriber.isSessionTransitionInProgress else { return nil }
        return updateMeetingSummaryItem
    }

    private var summaryReaderStatus: MeetingSummaryViewStatus {
        let document = transcriber.summaryDocument
        let hasStructuredContent = !document.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !document.items.isEmpty
        let phase: MeetingSummaryViewPhase
        if transcriber.isViewingHistoricalSession {
            phase = .historical
        } else if !hasStructuredContent, let message = document.processing.lastError {
            phase = .failed(message: message)
        } else if transcriber.isSummaryRequestActive {
            phase = .processing
        } else if hasStructuredContent || document.processing.totalUnits > 0 {
            phase = .ready
        } else {
            phase = .idle
        }

        return MeetingSummaryViewStatus(
            phase: phase,
            updatedAtText: transcriber.summaryUpdatedAtText
        )
    }

    private func copyMeetingSummaryPayload(_ payload: MeetingSummaryCopyPayload) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload.text, forType: .string)
        copiedMeetingNotes = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copiedMeetingNotes = false
        }
    }

    private func updateMeetingSummaryItem(_ request: MeetingSummaryManualEditRequest) {
        transcriber.updateSummaryItem(
            id: request.itemID,
            text: request.text,
            status: request.status,
            owner: request.owner,
            dueDate: request.dueDate
        )
        transcriber.setSummaryItemLocked(id: request.itemID, locked: request.lockAfterSaving)
    }

    private var currentSegmentView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("目前片段")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Text(transcriber.partialTranscript.isEmpty ? "尚無暫稿" : transcriber.partialTranscript)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(transcriber.partialTranscript.isEmpty ? AppTheme.textSecondary : AppTheme.textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(AppTheme.controlSurfaceActive, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow(systemImage: "cpu", text: "\(transcriber.engineDisplayName) · \(transcriber.sentenceBreakText)")
            statusRow(systemImage: "slider.horizontal.3", text: transcriber.audioSensitivityText)
            statusRow(systemImage: "waveform", text: transcriber.recognitionModeText)
            statusRow(systemImage: "checkmark.shield", text: transcriber.preflightUpdatedAtText)
            statusRow(systemImage: "mic", text: transcriber.microphoneInputStatusText)
            statusRow(systemImage: "speaker.wave.2", text: transcriber.systemAudioInputStatusText)
            statusRow(systemImage: "quote.bubble", text: transcriber.speechRecognitionStatusText)
            statusRow(systemImage: "externaldrive.connected.to.line.below", text: transcriber.deepSeekDiagnosticsText)
            statusRow(systemImage: "folder", text: transcriber.artifactStatusText)

            if let lastError = transcriber.lastError {
                errorStatusRow(lastError)
            }
        }
        .font(.system(size: 12))
    }

    private func paneHeader(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(AppTheme.actionTeal)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryInk)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
        }
    }

    private func statusRow(systemImage: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 16)
                .foregroundStyle(AppTheme.textSecondary)
            Text(text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func errorStatusRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .frame(width: 16)
                .foregroundStyle(.red)

            Text(message)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.red)

            if message.contains("系統音訊") {
                Button {
                    SpeechTranscriptionService.openSystemAudioPermissionSettings()
                } label: {
                    Label("開啟設定", systemImage: "gearshape")
                }
                .controlSize(.small)

                Button {
                    Task { await transcriber.testSystemAudioCapture() }
                } label: {
                    Label("重測", systemImage: "checkmark.shield")
                }
                .controlSize(.small)
                .disabled(transcriber.isRecording || transcriber.isSessionTransitionInProgress)
            }
        }
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriber.visibleTranscriptOutput(), forType: .string)
        copiedTranscript = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copiedTranscript = false
        }
    }

    private func copyMeetingNotes() {
        let document = transcriber.summaryDocument
        let hasStructuredContent = !document.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !document.items.isEmpty
        let text = hasStructuredContent
            ? MeetingSummaryRenderer.render(
                document,
                options: .init(
                    includeInactiveItems: true,
                    includeProcessing: true,
                    usesDenseTopicPreview: false
                )
            )
            : transcriber.meetingNotesOutput()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedMeetingNotes = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copiedMeetingNotes = false
        }
    }

    private func saveMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "會議紀錄.md"
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }

            do {
                try transcriber.markdownOutput().write(to: url, atomically: true, encoding: .utf8)
            } catch {
                transcriber.lastError = "匯出失敗：\(error.localizedDescription)"
            }
        }
    }
}

@MainActor
private struct MoMoWhisperOnboardingView: View {
    @EnvironmentObject private var transcriber: SpeechTranscriptionService
    @Environment(\.dismiss) private var dismiss
    let complete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    VerifiedWaveMark(size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("第一次使用 MoMoWhisper")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(AppTheme.primaryInk)
                        Text("依序完成權限、麥克風與系統音訊測試；之後可從「首次設定」重新開啟。")
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer()
                }

                onboardingStep(number: 1, title: "允許語音辨識與麥克風") {
                    HStack(spacing: 10) {
                        Button {
                            Task { await transcriber.requestOnboardingPermissions() }
                        } label: {
                            Label("檢查權限", systemImage: "lock.open")
                        }
                        .buttonStyle(.borderedProminent)

                        Text(transcriber.onboardingPermissionStatusText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }

                onboardingStep(number: 2, title: "選擇麥克風") {
                    HStack(spacing: 10) {
                        Picker("麥克風", selection: $transcriber.selectedInputDeviceID) {
                            ForEach(transcriber.availableInputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)

                        Button {
                            transcriber.refreshInputDevices()
                        } label: {
                            Label("重整", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }

                    Text("目前選擇：\(selectedMicrophoneName)")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }

                onboardingStep(number: 3, title: "選擇音源並測試系統音訊") {
                    Picker("音源", selection: $transcriber.audioCaptureMode) {
                        ForEach(AudioCaptureMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task { await transcriber.testSystemAudioCapture() }
                        } label: {
                            Label("測試系統音訊", systemImage: "speaker.wave.2")
                        }
                        .disabled(transcriber.isRecording || transcriber.isSessionTransitionInProgress)

                        Text(transcriber.systemAudioInputStatusText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }

                    Text("測試只檢查螢幕錄製權限與系統音訊 buffer，不會把麥克風與系統音訊硬混成單一路 ASR。")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }

                if let lastError = transcriber.lastError {
                    Label(lastError, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: AppTheme.controlRadius))
                }

                HStack {
                    Button("稍後") {
                        dismiss()
                    }
                    Spacer()
                    Button {
                        complete()
                    } label: {
                        Label("完成首次設定", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(width: 620, height: 590)
        .background(AppTheme.background)
        .onAppear {
            transcriber.refreshInputDevices()
        }
    }

    private var selectedMicrophoneName: String {
        transcriber.availableInputDevices.first { $0.id == transcriber.selectedInputDeviceID }?.name
            ?? AudioInputDevice.systemDefault.name
    }

    private func onboardingStep<Content: View>(
        number: Int,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(AppTheme.codexBlue, in: Circle())

            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }
}

@MainActor
private struct MeetingHistoryView: View {
    @EnvironmentObject private var transcriber: SpeechTranscriptionService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("會議歷史")
                        .font(.system(size: 22, weight: .semibold))
                    Text("自動保存的逐字稿、重點與 session metadata")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("關閉") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜尋標題、日期、來源或模式", text: $transcriber.meetingHistorySearchText)
                    .textFieldStyle(.roundedBorder)
                Button {
                    transcriber.meetingHistorySearchText = ""
                    transcriber.refreshMeetingHistory()
                } label: {
                    Label("清除", systemImage: "xmark.circle")
                }
                .disabled(transcriber.meetingHistorySearchText.isEmpty)
            }

            if let currentPath = transcriber.currentSessionFolderPath {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(currentPath)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }

            List {
                ForEach(transcriber.meetingHistory) { metadata in
                    MeetingHistoryRow(
                        metadata: metadata,
                        isMeaningfulForHandoff: transcriber.isMeetingMeaningfulForHandoff(metadata)
                    ) {
                        Task {
                            await transcriber.loadMeetingSession(metadata)
                            dismiss()
                        }
                    } resume: {
                        Task {
                            await transcriber.loadMeetingSession(metadata)
                            await transcriber.resumeCurrentMeetingSession()
                            dismiss()
                        }
                    } openFolder: {
                        transcriber.openMeetingSessionFolder(metadata)
                    } copyPath: {
                        transcriber.copyMeetingSessionFolderPath(metadata)
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if transcriber.meetingHistory.isEmpty {
                    ContentUnavailableView(
                        "沒有符合的會議",
                        systemImage: "tray",
                        description: Text("開始錄音後，MoMoWhisper 會自動建立會議資料夾。")
                    )
                }
            }
        }
        .padding(22)
        .frame(width: 780, height: 620)
        .onAppear {
            transcriber.refreshMeetingHistory()
        }
    }
}

@MainActor
private struct MeetingHistoryRow: View {
    let metadata: MeetingSessionMetadata
    let isMeaningfulForHandoff: Bool
    let load: () -> Void
    let resume: () -> Void
    let openFolder: () -> Void
    let copyPath: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(metadata.displayTitle)
                        .font(.system(size: 15, weight: .semibold))
                    Text(isMeaningfulForHandoff ? "有效" : "空/測試")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(validityTone.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            validityTone.color.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                        )
                }
                Text(MeetingSessionStore.displayDateFormatter.string(from: metadata.startedAt))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(metadata.transcriptCharacterCount) 字 / \(metadata.highlightCharacterCount) 字重點")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Label(metadata.transcriptionEngine.isEmpty ? "未記錄引擎" : metadata.transcriptionEngine, systemImage: "quote.bubble")
                Label(metadata.summaryProvider.isEmpty ? "未記錄整理" : metadata.summaryProvider, systemImage: "sparkles")
                Label(metadata.audioCaptureMode.isEmpty ? "未記錄來源" : metadata.audioCaptureMode, systemImage: "waveform")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("載入") {
                    load()
                }
                Button("續錄（新分段）") {
                    resume()
                }
                Button("開資料夾") {
                    openFolder()
                }
                Button("複製路徑") {
                    copyPath()
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }

    private var validityTone: TrustSignalTone {
        isMeaningfulForHandoff ? .ready : .warning
    }
}

@MainActor
private struct SummarySettingsView: View {
    @EnvironmentObject private var transcriber: SpeechTranscriptionService
    @Environment(\.dismiss) private var dismiss
    @State private var deepSeekAPIKey = ""
    @State private var lmStudioAPIKey = ""
    @State private var customAPIKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("整理設定")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            Form {
                Section("整理與資料傳送") {
                    Picker("整理方式", selection: $transcriber.summaryProvider) {
                        ForEach(MeetingSummaryProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }

                    Picker("觸發條件", selection: $transcriber.summaryTriggerMode) {
                        ForEach(MeetingSummaryTriggerMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    HStack {
                        Text("時間門檻")
                        Stepper(
                            "\(Int(transcriber.summaryIntervalSeconds)) 秒",
                            value: $transcriber.summaryIntervalSeconds,
                            in: 30...3_600,
                            step: 30
                        )
                    }

                    HStack {
                        Text("字數門檻")
                        TextField("字數", value: $transcriber.summaryCharacterThreshold, formatter: Self.integerFormatter)
                            .frame(width: 96)
                        Text("字")
                            .foregroundStyle(.secondary)
                    }

                    Text("預設只保留逐字稿。本機自動整理不連線第三方；只有明確選擇 DeepSeek、LM Studio 或其他 API 時，待整理逐字稿、最近上下文，以及既有重點目錄的 headline、主題 ID／標題／別名、項目 ID／主題／類型／狀態／文字／負責人／期限／鎖定狀態，才會送到你設定的 endpoint。原始音訊不會送出。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Section("收音與靈敏度") {
                    Picker("語音觸發", selection: $transcriber.voiceSensitivityMode) {
                        ForEach(VoiceSensitivityMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    HStack {
                        Text("輸入增益")
                        Slider(value: $transcriber.inputGainDecibels, in: -12...24, step: 1)
                        Text("\(Int(transcriber.inputGainDecibels)) dB")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }

                    HStack {
                        Text("手動門檻")
                        Slider(value: $transcriber.manualVoiceThresholdDecibels, in: -85 ... -20, step: 1)
                            .disabled(transcriber.voiceSensitivityMode != .manual)
                        Text("\(Int(transcriber.manualVoiceThresholdDecibels)) dB")
                            .monospacedDigit()
                            .frame(width: 58, alignment: .trailing)
                    }

                    HStack {
                        Text("備援定稿")
                        Slider(value: $transcriber.pauseCommitDelaySeconds, in: 0.15...2.0, step: 0.05)
                        Text("\(String(format: "%.2f", transcriber.pauseCommitDelaySeconds)) 秒")
                            .monospacedDigit()
                            .frame(width: 66, alignment: .trailing)
                    }

                    Text("像 Discord 一樣：手動門檻越低越靈敏。逐字稿會先即時顯示，備援定稿只決定多久後鎖定這段文字。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Section("輸出與 Codex") {
                    outputPathRow(
                        title: "錄音檔",
                        systemImage: "waveform",
                        path: transcriber.recordingOutputDirectoryPath,
                        choose: transcriber.chooseRecordingOutputDirectory,
                        reveal: transcriber.revealRecordingOutputDirectory
                    )

                    outputPathRow(
                        title: "會議重點",
                        systemImage: "list.bullet.clipboard",
                        path: transcriber.highlightsOutputDirectoryPath,
                        choose: transcriber.chooseHighlightsOutputDirectory,
                        reveal: transcriber.revealHighlightsOutputDirectory
                    )

                    Toggle("產生 Codex handoff", isOn: $transcriber.codexHandoffEnabled)

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Label("Codex handoff", systemImage: "terminal")
                            .frame(width: 126, alignment: .leading)
                        pathText(transcriber.codexHandoffDirectoryPath)
                        Button {
                            transcriber.revealCodexHandoffDirectory()
                        } label: {
                            Label("打開", systemImage: "arrow.up.right.square")
                        }
                        Button {
                            transcriber.copyLatestCodexHandoffPath()
                        } label: {
                            Label("複製", systemImage: "doc.on.doc")
                        }
                    }

                    HStack {
                        Button {
                            transcriber.resetArtifactOutputDirectories()
                        } label: {
                            Label("恢復預設位置", systemImage: "arrow.counterclockwise")
                        }

                        Spacer()

                        Text(transcriber.artifactStatusText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Section("DeepSeek") {
                    TextField("Endpoint（可填 https://api.deepseek.com）", text: $transcriber.deepSeekBaseURLText)
                    TextField("Model（deepseek-v4-flash）", text: $transcriber.deepSeekModel)
                    apiKeyRow(
                        title: "API Key",
                        key: $deepSeekAPIKey,
                        kind: .deepSeek
                    )
                }

                Section("本地 LM Studio") {
                    TextField("Endpoint（例如 http://127.0.0.1:1234/v1/chat/completions）", text: $transcriber.lmStudioBaseURLText)
                    TextField("Model", text: $transcriber.lmStudioModel)
                    apiKeyRow(
                        title: "API Token（可留空）",
                        key: $lmStudioAPIKey,
                        kind: .lmStudio
                    )
                }

                Section("其他 OpenAI 相容 API") {
                    TextField("Endpoint（base URL 或 /chat/completions）", text: $transcriber.customBaseURLText)
                    TextField("Model", text: $transcriber.customModel)
                    apiKeyRow(
                        title: "API Key",
                        key: $customAPIKey,
                        kind: .customOpenAI
                    )
                }
            }
            .formStyle(.grouped)
        }
        .padding(22)
        .frame(width: 680, height: 780)
    }

    private func outputPathRow(
        title: String,
        systemImage: String,
        path: String,
        choose: @escaping () -> Void,
        reveal: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(title, systemImage: systemImage)
                .frame(width: 126, alignment: .leading)

            pathText(path)

            Button {
                choose()
            } label: {
                Label("選擇", systemImage: "folder")
            }

            Button {
                reveal()
            } label: {
                Label("打開", systemImage: "arrow.up.right.square")
            }
        }
    }

    private func pathText(_ path: String) -> some View {
        Text(path)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func apiKeyRow(
        title: String,
        key: Binding<String>,
        kind: MeetingSummaryAPIKeyKind
    ) -> some View {
        HStack {
            SecureField(title, text: key)
            Button("儲存") {
                transcriber.saveSummaryAPIKey(key.wrappedValue, kind: kind)
                key.wrappedValue = ""
            }
            .disabled(key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Text(transcriber.hasSummaryAPIKey(kind: kind) ? "已儲存" : "未儲存")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
        }
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimum = 100
        formatter.maximum = 50_000
        formatter.allowsFloats = false
        return formatter
    }()
}
