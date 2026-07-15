#if canImport(XCTest)
import XCTest
@testable import MoMoWhisperSessionCore

final class MeetingRecordingLifecycleTests: XCTestCase {
    func testStartStopStartCreatesNewSessionAfterEnd() {
        let sessionID = UUID()
        var lifecycle = MeetingRecordingLifecycle()
        lifecycle.prepareNewSession(sessionID)

        XCTAssertEqual(lifecycle.requestStart(), .startRecordingPart(sessionID))
        XCTAssertTrue(lifecycle.markRecordingStarted())
        XCTAssertEqual(lifecycle.requestStop(), .stopActiveRecording)
        lifecycle.finishStop()

        XCTAssertEqual(lifecycle.state, .ended(sessionID))
        XCTAssertEqual(lifecycle.requestStart(), .createNewSession)
    }

    func testLoadedHistoryNormalStartCreatesNewSession() {
        var lifecycle = MeetingRecordingLifecycle()
        lifecycle.markHistoryLoaded(UUID())

        XCTAssertEqual(lifecycle.requestStart(), .createNewSession)
        XCTAssertEqual(lifecycle.state, .startingNewSession)
    }

    func testRapidToggleAbortsStartingWithoutOpeningSecondWriter() {
        let sessionID = UUID()
        var lifecycle = MeetingRecordingLifecycle()

        XCTAssertEqual(lifecycle.requestStart(), .createNewSession)
        XCTAssertEqual(lifecycle.attachNewSession(sessionID), .startRecordingPart(sessionID))
        XCTAssertEqual(lifecycle.requestStop(), .abortStarting)
        XCTAssertFalse(lifecycle.markRecordingStarted())
        lifecycle.finishStop()

        XCTAssertEqual(lifecycle.state, .ended(sessionID))
        XCTAssertEqual(lifecycle.requestStart(), .createNewSession)
    }

    func testExplicitResumeStartsANewPartForTheLoadedSession() {
        let sessionID = UUID()
        var lifecycle = MeetingRecordingLifecycle(state: .loadedHistory(sessionID))

        XCTAssertEqual(lifecycle.requestExplicitResume(), .startRecordingPart(sessionID))
    }
}
#endif
