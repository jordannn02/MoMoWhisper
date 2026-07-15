import Foundation
#if canImport(XCTest)
import XCTest
@testable import MoMoWhisperSessionCore

final class MeetingAudioRecorderTests: XCTestCase {
    func testStartRejectsAnExistingRecordingPathInsteadOfReusingIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingAudioRecorderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existingFile = directory.appendingPathComponent("meeting.wav")
        try Data("existing recording must survive".utf8).write(to: existingFile)

        let recorder = MeetingAudioRecorder()

        XCTAssertThrowsError(
            try recorder.start(outputDirectory: directory, fileBaseName: "meeting")
        )
        XCTAssertEqual(try Data(contentsOf: existingFile), Data("existing recording must survive".utf8))
    }
}
#endif
