import Foundation

enum MeetingSummaryProvider: String, CaseIterable, Identifiable {
    case automatic
    case deepSeek
    case lmStudio
    case customOpenAI
    case disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return "本機自動整理"
        case .deepSeek:
            return "DeepSeek"
        case .lmStudio:
            return "本地 LM Studio"
        case .customOpenAI:
            return "其他 OpenAI 相容 API"
        case .disabled:
            return "只保留逐字稿"
        }
    }
}

enum MeetingSummaryTriggerMode: String, CaseIterable, Identifiable {
    case time
    case characters
    case either
    case both
    case manualOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .time:
            return "依時間"
        case .characters:
            return "依字數"
        case .either:
            return "時間或字數"
        case .both:
            return "時間且字數"
        case .manualOnly:
            return "只手動"
        }
    }
}

enum MeetingSummaryAPIKeyKind: String, CaseIterable, Identifiable {
    case deepSeek
    case lmStudio
    case customOpenAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepSeek:
            return "DeepSeek"
        case .lmStudio:
            return "本地 LM Studio"
        case .customOpenAI:
            return "其他 API"
        }
    }

    var primaryKeychainService: String {
        switch self {
        case .deepSeek:
            return "momo-whisper-deepseek-api-key"
        case .lmStudio:
            return "momo-whisper-lmstudio-api-key"
        case .customOpenAI:
            return "momo-whisper-custom-api-key"
        }
    }

    var keychainServices: [String] {
        [primaryKeychainService]
    }
}

enum VoiceSensitivityMode: String, CaseIterable, Identifiable {
    case off
    case automatic
    case manual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "不設門檻"
        case .automatic:
            return "自動靈敏度"
        case .manual:
            return "手動門檻"
        }
    }
}

enum AudioCaptureMode: String, CaseIterable, Identifiable {
    case microphoneOnly
    case systemAudioOnly
    case microphoneWithSystemMonitor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphoneOnly:
            return "麥克風"
        case .systemAudioOnly:
            return "系統音訊"
        case .microphoneWithSystemMonitor:
            return "麥克風 + 系統音訊"
        }
    }

    var statusName: String {
        switch self {
        case .microphoneOnly:
            return "麥克風"
        case .systemAudioOnly:
            return "系統音訊作為逐字稿來源"
        case .microphoneWithSystemMonitor:
            return "麥克風 + 系統音訊作為逐字稿來源"
        }
    }

    var helpText: String {
        switch self {
        case .microphoneOnly:
            return "只收麥克風，最穩定，不碰系統音訊權限。"
        case .systemAudioOnly:
            return "只收電腦播放音訊做逐字稿，停用麥克風，避免喇叭聲干擾麥克風。"
        case .microphoneWithSystemMonitor:
            return "同時收麥克風與電腦播放音訊做逐字稿；適合你和對方都要記錄的線上會議。"
        }
    }

    var usesMicrophone: Bool {
        switch self {
        case .microphoneOnly, .microphoneWithSystemMonitor:
            return true
        case .systemAudioOnly:
            return false
        }
    }

    var capturesSystemAudio: Bool {
        switch self {
        case .systemAudioOnly, .microphoneWithSystemMonitor:
            return true
        case .microphoneOnly:
            return false
        }
    }

    var routesSystemAudioToTranscript: Bool {
        self == .systemAudioOnly || self == .microphoneWithSystemMonitor
    }
}
