import Foundation

public enum TranscriptionEngineKind: String, Equatable, Sendable {
    case appleSpeech
    case speechAnalyzer
}

public enum TranscriptionEnginePolicy {
    public static let speechAnalyzerMinimumMacOSMajorVersion = 26

    public static func preferredEngine(macOSMajorVersion: Int) -> TranscriptionEngineKind {
        macOSMajorVersion >= speechAnalyzerMinimumMacOSMajorVersion
            ? .speechAnalyzer
            : .appleSpeech
    }

    public static func resolvedEngine(
        requested: TranscriptionEngineKind,
        macOSMajorVersion: Int
    ) -> TranscriptionEngineKind {
        guard requested == .speechAnalyzer,
              macOSMajorVersion < speechAnalyzerMinimumMacOSMajorVersion else {
            return requested
        }
        return .appleSpeech
    }
}
