import Foundation
import MoMoWhisperSessionCore

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case appleSpeech = "apple-speech"
    case speechAnalyzer = "speech-analyzer"

    var id: String { rawValue }

    static var preferredForCurrentOS: TranscriptionEngine {
        fromPolicyKind(
            TranscriptionEnginePolicy.preferredEngine(
                macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            )
        )
    }

    var resolvedForCurrentOS: TranscriptionEngine {
        Self.fromPolicyKind(
            TranscriptionEnginePolicy.resolvedEngine(
                requested: policyKind,
                macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            )
        )
    }

    var isSupportedOnCurrentOS: Bool {
        resolvedForCurrentOS == self
    }

    var displayName: String {
        switch self {
        case .appleSpeech:
            return "Apple Speech"
        case .speechAnalyzer:
            return "SpeechAnalyzer 實驗"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .appleSpeech:
            return "Apple Speech"
        case .speechAnalyzer:
            return "SpeechAnalyzer"
        }
    }

    private var policyKind: TranscriptionEngineKind {
        switch self {
        case .appleSpeech:
            return .appleSpeech
        case .speechAnalyzer:
            return .speechAnalyzer
        }
    }

    private static func fromPolicyKind(_ kind: TranscriptionEngineKind) -> TranscriptionEngine {
        switch kind {
        case .appleSpeech:
            return .appleSpeech
        case .speechAnalyzer:
            return .speechAnalyzer
        }
    }
}
