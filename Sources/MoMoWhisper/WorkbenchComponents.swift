import SwiftUI
import MoMoWhisperSessionCore

struct VerifiedWaveMark: View {
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AppTheme.primaryInk, AppTheme.actionTeal],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: size * 0.11, style: .continuous)
                .fill(Color.white.opacity(0.92))
                .frame(width: size * 0.56, height: size * 0.66)
                .offset(x: -size * 0.03, y: size * 0.01)

            WaveformShape()
                .stroke(AppTheme.actionTeal, style: StrokeStyle(lineWidth: max(1.6, size * 0.055), lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.40, height: size * 0.22)
                .offset(x: -size * 0.03, y: size * 0.01)

            Circle()
                .fill(AppTheme.codexBlue)
                .frame(width: size * 0.28, height: size * 0.28)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.13, weight: .bold))
                        .foregroundStyle(.white)
                )
                .offset(x: size * 0.24, y: -size * 0.23)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct WaveformShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        let step = rect.width / 6
        let amplitudes: [CGFloat] = [0.18, 0.46, 0.28, 0.62, 0.30, 0.48, 0.18]

        path.move(to: CGPoint(x: rect.minX, y: midY))
        for index in amplitudes.indices {
            let x = rect.minX + CGFloat(index) * step
            let y = midY - (amplitudes[index] - 0.3) * rect.height
            path.addLine(to: CGPoint(x: x, y: y))
        }
        return path
    }
}

struct TrustPill: View {
    let title: String
    let value: String
    let systemImage: String
    let tone: TrustSignalTone

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tone.color)
                .frame(width: 7, height: 7)
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tone.color)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tone.color.opacity(0.10), in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                .stroke(tone.color.opacity(0.20), lineWidth: 1)
        )
        .help("\(title)：\(value)")
    }
}

struct NavigationRail: View {
    let selection: WorkspaceSection
    let select: (WorkspaceSection) -> Void
    let showHistory: () -> Void
    let showSettings: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(WorkspaceSection.allCases) { section in
                railButton(
                    title: section.title,
                    systemImage: section.systemImage,
                    isSelected: selection == section
                ) {
                    select(section)
                }
            }

            Divider()
                .padding(.vertical, 4)

            railButton(title: "歷史", systemImage: "clock.arrow.circlepath", isSelected: false, action: showHistory)
            railButton(title: "設定", systemImage: "slider.horizontal.3", isSelected: false, action: showSettings)

            Spacer()
        }
        .padding(.vertical, 14)
        .frame(width: 86)
        .background(AppTheme.chrome)
    }

    private func railButton(title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? AppTheme.primaryInk : AppTheme.textSecondary)
            .frame(width: 66, height: 58)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                    .fill(isSelected ? AppTheme.surface : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                    .stroke(isSelected ? AppTheme.border : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct TrustStatusStrip: View {
    @EnvironmentObject private var transcriber: SpeechTranscriptionService

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                TrustPill(
                    title: "會前檢查",
                    value: transcriber.preflightSummary.compactText,
                    systemImage: "checkmark.shield",
                    tone: preflightTone
                )
                .help(transcriber.preflightUpdatedAtText)
                TrustPill(
                    title: "麥克風",
                    value: condensed(transcriber.microphoneInputStatusText),
                    systemImage: "mic",
                    tone: tone(for: transcriber.microphoneInputStatusText)
                )
                TrustPill(
                    title: "系統音訊",
                    value: condensed(transcriber.systemAudioInputStatusText),
                    systemImage: "speaker.wave.2",
                    tone: tone(for: transcriber.systemAudioInputStatusText)
                )
                TrustPill(
                    title: "辨識",
                    value: condensed(transcriber.speechRecognitionStatusText),
                    systemImage: "text.bubble",
                    tone: tone(for: transcriber.speechRecognitionStatusText)
                )
                TrustPill(
                    title: "會後輸出",
                    value: condensed(transcriber.artifactStatusText),
                    systemImage: "folder.badge.gearshape",
                    tone: tone(for: transcriber.artifactStatusText)
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppTheme.controlSurface)
    }

    private func condensed(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 26 else { return trimmed }
        return String(trimmed.prefix(24)) + "..."
    }

    private func tone(for text: String) -> TrustSignalTone {
        if text.contains("失敗") || text.contains("拒絕") || text.contains("錯誤") {
            return .danger
        }
        if text.contains("靜音") || text.contains("未") || text.contains("待") {
            return .warning
        }
        if text.contains("中") || text.contains("完成") || text.contains("成功") || text.contains("準備") {
            return .ready
        }
        return .neutral
    }

    private var preflightTone: TrustSignalTone {
        switch transcriber.preflightSummary.level {
        case .pending:
            return .neutral
        case .running, .ready:
            return .ready
        case .warning:
            return .warning
        case .blocked:
            return .danger
        }
    }
}

struct SummaryCoveragePanel: View {
    @EnvironmentObject private var transcriber: SpeechTranscriptionService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("整理覆蓋", systemImage: "gauge.medium")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryInk)
                Spacer()
                Text(percentText)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(coverageTone.color)
            }

            ProgressView(value: transcriber.summaryCoverageRatio)
                .tint(coverageTone.color)

            HStack(spacing: 14) {
                metric("逐字稿", transcriber.transcriptCharacterCount)
                metric("已整理", transcriber.summarizedTranscriptCount)
                metric("未整理", transcriber.unsummarizedTranscriptCount)
            }

            Text(transcriber.summaryStatusText)
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(2)
        }
        .padding(12)
        .background(AppTheme.surfaceAlt, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private var percentText: String {
        "\(Int((transcriber.summaryCoverageRatio * 100).rounded()))%"
    }

    private var coverageTone: TrustSignalTone {
        if transcriber.summaryCoverageRatio >= 0.95 { return .ready }
        if transcriber.summaryCoverageRatio > 0 { return .warning }
        return .neutral
    }

    private func metric(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.textPrimary)
        }
    }
}

struct LatestValidHandoffCard: View {
    @EnvironmentObject private var transcriber: SpeechTranscriptionService

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transcriber.latestValidCodexHandoffReady ? "checkmark.seal" : "exclamationmark.triangle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tone.color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(12)
        .background(tone.color.opacity(0.10), in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                .stroke(tone.color.opacity(0.20), lineWidth: 1)
        )
    }

    private var title: String {
        if transcriber.latestValidCodexHandoffReady {
            return "latest_valid handoff 可讀且內容達門檻"
        }
        return transcriber.latestValidMeetingMetadata == nil ? "尚未找到內容達門檻的 handoff" : "latest_valid handoff 待驗證"
    }

    private var detail: String {
        guard let metadata = transcriber.latestValidMeetingMetadata else {
            return "目前只看到空會議或測試會議；這會避免 Codex 誤讀 0 字最新會議。"
        }
        let fileState = transcriber.latestValidCodexHandoffReady
            ? "會議 ID 相符，逐字稿或重點檔可讀且達門檻"
            : "檔案存在本身不等於可交付，請看下方檢查"
        return "\(metadata.displayTitle) · \(metadata.transcriptCharacterCount) 字逐字稿 · \(metadata.highlightCharacterCount) 字重點 · \(fileState)"
    }

    private var tone: TrustSignalTone {
        transcriber.latestValidCodexHandoffReady ? .ready : .warning
    }
}

struct DeliveryArtifactChecklist: View {
    @EnvironmentObject private var transcriber: SpeechTranscriptionService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("交付檔案檢查", systemImage: "checklist.checked")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryInk)
                Spacer()
                Text("存在 · 可讀 · 門檻")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            ForEach(transcriber.deliveryArtifactChecks) { check in
                HStack(spacing: 10) {
                    Image(systemName: icon(for: check.state))
                        .foregroundStyle(tone(for: check.state).color)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(check.path.isEmpty ? "尚未產生" : check.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text(statusText(for: check))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(tone(for: check.state).color)
                }
                .help(check.path.isEmpty ? check.label : check.path)
            }

            Text("錄音列只驗證檔案可讀與最小大小；是否完整、可播放及時長相符，仍以 metadata recording readiness 與後續音訊驗證為準。")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(12)
        .background(AppTheme.surfaceAlt, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private func statusText(for check: DeliveryArtifactCheck) -> String {
        switch check.state {
        case .missing:
            return "缺少"
        case .unreadable:
            return "無法讀取"
        case .belowThreshold:
            return "\(check.measuredCount)/\(check.requiredCount) \(check.unit)"
        case .ready:
            return "門檻通過 · \(check.measuredCount) \(check.unit)"
        }
    }

    private func icon(for state: DeliveryArtifactState) -> String {
        switch state {
        case .missing:
            return "minus.circle"
        case .unreadable:
            return "xmark.octagon"
        case .belowThreshold:
            return "exclamationmark.triangle"
        case .ready:
            return "checkmark.circle"
        }
    }

    private func tone(for state: DeliveryArtifactState) -> TrustSignalTone {
        switch state {
        case .missing, .belowThreshold:
            return .warning
        case .unreadable:
            return .danger
        case .ready:
            return .ready
        }
    }
}

struct EvidenceCommandBar: View {
    @EnvironmentObject private var transcriber: SpeechTranscriptionService
    let copyTranscript: () -> Void
    let copyNotes: () -> Void
    let exportMarkdown: () -> Void
    let showCommandCenter: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Label("\(transcriber.transcriptCharacterCount) 字逐字稿", systemImage: "text.alignleft")
                Label("\(transcriber.meetingNotesCharacterCount) 字重點", systemImage: "list.bullet.clipboard")
                Label(transcriber.latestValidCodexHandoffReady ? "latest valid 已驗證" : "handoff 待驗證", systemImage: "checkmark.seal")

                Button(action: showCommandCenter) {
                    Label("交付中心", systemImage: "paperplane")
                }
                .buttonStyle(.bordered)
                Button(action: copyTranscript) {
                    Label("複製逐字稿", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(!transcriber.hasTranscriptContent)
                Button(action: copyNotes) {
                    Label("複製重點", systemImage: "list.clipboard")
                }
                .buttonStyle(.bordered)
                .disabled(!transcriber.hasMeetingNotesContent)
                Button(action: exportMarkdown) {
                    Label("匯出", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(!transcriber.hasContent)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(AppTheme.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppTheme.chrome)
    }
}

struct PostMeetingCommandCenter: View {
    @EnvironmentObject private var transcriber: SpeechTranscriptionService
    let copyTranscript: () -> Void
    let copyNotes: () -> Void
    let exportMarkdown: () -> Void
    let openRecordings: () -> Void
    let openHighlights: () -> Void
    let openHandoff: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("交付中心")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(AppTheme.primaryInk)
                        Text("錄完後把逐字稿、重點、錄音與 Codex handoff 變成可追溯交付。")
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer()
                }

                LatestValidHandoffCard()
                DeliveryArtifactChecklist()

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    commandCard(
                        title: "複製逐字稿",
                        detail: "\(transcriber.transcriptCharacterCount) 字，可貼到 Codex 或文件。",
                        systemImage: "doc.on.doc",
                        isEnabled: transcriber.hasTranscriptContent,
                        action: copyTranscript
                    )
                    commandCard(
                        title: "複製會議重點",
                        detail: "\(transcriber.meetingNotesCharacterCount) 字，適合快速回覆與交辦。",
                        systemImage: "list.clipboard",
                        isEnabled: transcriber.hasMeetingNotesContent,
                        action: copyNotes
                    )
                    commandCard(
                        title: "匯出 Markdown",
                        detail: "保留逐字稿、重點與來源資訊。",
                        systemImage: "square.and.arrow.down",
                        isEnabled: transcriber.hasContent,
                        action: exportMarkdown
                    )
                    commandCard(
                        title: "開錄音資料夾",
                        detail: "檢查 WAV 錄音檔與保留策略。",
                        systemImage: "waveform.badge.mic",
                        isEnabled: true,
                        action: openRecordings
                    )
                    commandCard(
                        title: "開重點資料夾",
                        detail: "查看會議 highlights Markdown。",
                        systemImage: "folder",
                        isEnabled: true,
                        action: openHighlights
                    )
                    commandCard(
                        title: "開 Codex Handoff",
                        detail: "確認 current/latest handoff 檔案位置。",
                        systemImage: "paperplane",
                        isEnabled: true,
                        action: openHandoff
                    )
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background)
    }

    private func commandCard(
        title: String,
        detail: String,
        systemImage: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isEnabled ? AppTheme.codexBlue : AppTheme.textSecondary)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .padding(14)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
