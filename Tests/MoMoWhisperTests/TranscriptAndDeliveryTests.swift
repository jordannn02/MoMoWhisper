import Foundation
#if canImport(XCTest)
import XCTest
@testable import MoMoWhisperSessionCore

final class TranscriptAndDeliveryTests: XCTestCase {
    func testLegacyTranscriptSegmentDefaultsToUnknownSource() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "text": "legacy",
          "timestamp": "2026-07-11T00:00:00Z",
          "relativeTime": 2.5
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let segment = try decoder.decode(TranscriptSegment.self, from: Data(json.utf8))

        XCTAssertEqual(segment.source, .unknown)
    }

    func testTranscriptMarkdownIncludesItsAudioSource() {
        let segment = TranscriptSegment(
            id: UUID(),
            text: "system audio",
            timestamp: Date(),
            relativeTime: 1,
            source: .systemAudio
        )

        XCTAssertEqual(segment.markdownLine(timestampText: "10:30:00"), "[10:30:00] [SYS] system audio")
    }

    func testDeliveryInspectorSeparatesMissingShortAndReadyTextFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptAndDeliveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let path = directory.appendingPathComponent("transcript.md")
        XCTAssertEqual(
            DeliveryArtifactInspector.inspectTextFile(label: "Transcript", path: path.path, minimumCharacters: 5).state,
            .missing
        )

        try "1234".write(to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            DeliveryArtifactInspector.inspectTextFile(label: "Transcript", path: path.path, minimumCharacters: 5).state,
            .belowThreshold
        )

        try "12345".write(to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            DeliveryArtifactInspector.inspectTextFile(label: "Transcript", path: path.path, minimumCharacters: 5).state,
            .ready
        )
    }

    func testPreflightSummaryExcludesSkippedChecksFromItsCompactCount() {
        let summary = PreflightSummary.completed(outcomes: [.passed, .failed, .skipped])

        XCTAssertEqual(summary.level, .blocked)
        XCTAssertEqual(summary.compactText, "需處理 1/2")
    }

    func testBinaryInspectorUsesAFileSizeThreshold() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BinaryDeliveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let audioURL = directory.appendingPathComponent("recording.wav")
        try Data(repeating: 0, count: 44).write(to: audioURL)
        XCTAssertEqual(
            DeliveryArtifactInspector.inspectBinaryFile(label: "Recording", path: audioURL.path, minimumBytes: 45).state,
            .belowThreshold
        )

        try Data(repeating: 0, count: 45).write(to: audioURL)
        XCTAssertEqual(
            DeliveryArtifactInspector.inspectBinaryFile(label: "Recording", path: audioURL.path, minimumBytes: 45).state,
            .ready
        )
    }
}
#endif
