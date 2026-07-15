import Foundation
#if canImport(XCTest)
import XCTest
@testable import MoMoWhisperSessionCore

final class TranscriptionEnginePolicyTests: XCTestCase {
    func testPreferredEngineUsesAppleSpeechBeforeMacOS26() {
        XCTAssertEqual(
            TranscriptionEnginePolicy.preferredEngine(macOSMajorVersion: 14),
            .appleSpeech
        )
        XCTAssertEqual(
            TranscriptionEnginePolicy.preferredEngine(macOSMajorVersion: 25),
            .appleSpeech
        )
    }

    func testPreferredEngineUsesSpeechAnalyzerOnMacOS26OrLater() {
        XCTAssertEqual(
            TranscriptionEnginePolicy.preferredEngine(macOSMajorVersion: 26),
            .speechAnalyzer
        )
        XCTAssertEqual(
            TranscriptionEnginePolicy.preferredEngine(macOSMajorVersion: 27),
            .speechAnalyzer
        )
    }

    func testUnsupportedSpeechAnalyzerRequestFallsBackToAppleSpeech() {
        XCTAssertEqual(
            TranscriptionEnginePolicy.resolvedEngine(
                requested: .speechAnalyzer,
                macOSMajorVersion: 25
            ),
            .appleSpeech
        )
        XCTAssertEqual(
            TranscriptionEnginePolicy.resolvedEngine(
                requested: .speechAnalyzer,
                macOSMajorVersion: 26
            ),
            .speechAnalyzer
        )
    }

    func testDefaultStorageRootLivesUnderApplicationSupport() {
        let applicationSupport = URL(fileURLWithPath: "/Users/example/Library/Application Support")

        XCTAssertEqual(
            StorageLocationPolicy.defaultRoot(applicationSupportDirectory: applicationSupport).path,
            "/Users/example/Library/Application Support/MoMoWhisper"
        )
    }
}
#endif
