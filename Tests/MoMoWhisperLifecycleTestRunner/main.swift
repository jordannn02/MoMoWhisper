import Foundation
import Darwin
import MoMoWhisperSessionCore

enum LifecycleTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw LifecycleTestFailure.failed(message)
    }
}

func recorderDoesNotReuseAnExistingPath() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingAudioRecorderRunner-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let existingFile = directory.appendingPathComponent("meeting.wav")
    let expectedData = Data("existing recording must survive".utf8)
    try expectedData.write(to: existingFile)

    let recorder = MeetingAudioRecorder()
    var didThrow = false
    do {
        _ = try recorder.start(outputDirectory: directory, fileBaseName: "meeting")
    } catch {
        didThrow = true
    }

    try expect(didThrow, "existing WAV path must be rejected")
    let actualData = try Data(contentsOf: existingFile)
    try expect(actualData == expectedData, "existing WAV content must survive")
}

func startStopStartCreatesANewSessionInsteadOfReusingTheEndedSession() throws {
    let firstSessionID = UUID()
    var lifecycle = MeetingRecordingLifecycle()
    lifecycle.prepareNewSession(firstSessionID)

    try expect(lifecycle.requestStart() == .startRecordingPart(firstSessionID), "first Start must prepare a recording part")
    try expect(lifecycle.markRecordingStarted(), "first recording must enter recording state")
    try expect(lifecycle.requestStop() == .stopActiveRecording, "Stop must finish the active recording")
    lifecycle.finishStop()
    try expect(lifecycle.state == .ended(firstSessionID), "Stop must end the first session")
    try expect(lifecycle.requestStart() == .createNewSession, "Start after an ended session must create a new session")
}

func normalStartFromLoadedHistoryCreatesANewSession() throws {
    let historyID = UUID()
    var lifecycle = MeetingRecordingLifecycle()
    lifecycle.markHistoryLoaded(historyID)

    try expect(lifecycle.requestStart() == .createNewSession, "normal Start from loaded history must not reopen its recording")
    try expect(lifecycle.state == .startingNewSession, "loaded history Start must wait for a new session")
}

func rapidStartStopDoesNotCreateASecondWriter() throws {
    let sessionID = UUID()
    var lifecycle = MeetingRecordingLifecycle()

    try expect(lifecycle.requestStart() == .createNewSession, "first tap must request one new session")
    try expect(lifecycle.attachNewSession(sessionID) == .startRecordingPart(sessionID), "new session must create one recording part")
    try expect(lifecycle.requestStop() == .abortStarting, "rapid Stop must abort the in-flight start")
    try expect(!lifecycle.markRecordingStarted(), "aborted start must not become recording")
    lifecycle.finishStop()
    try expect(lifecycle.state == .ended(sessionID), "aborted start must end the new session cleanly")
    try expect(lifecycle.requestStart() == .createNewSession, "next Start must allocate another session, not a second writer")
}

func explicitResumeAddsAPartToTheExistingSession() throws {
    let sessionID = UUID()
    var lifecycle = MeetingRecordingLifecycle(state: .ended(sessionID))

    try expect(lifecycle.requestExplicitResume() == .startRecordingPart(sessionID), "explicit Resume must create a new recording part")
    try expect(lifecycle.currentSessionID == sessionID, "Resume must retain the chosen session identity")
}

func legacyTranscriptSegmentsDecodeWithUnknownSource() throws {
    let id = UUID()
    let json = """
    {
      "id": "\(id.uuidString)",
      "text": "legacy",
      "timestamp": "2026-07-11T00:00:00Z",
      "relativeTime": 3.5
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let segment = try decoder.decode(TranscriptSegment.self, from: Data(json.utf8))

    try expect(segment.source == .unknown, "legacy transcript segment must decode with unknown source")
}

func transcriptSourceProducesDurableMarkdownLabel() throws {
    let segment = TranscriptSegment(
        id: UUID(),
        text: "system audio text",
        timestamp: Date(),
        relativeTime: 1,
        source: .systemAudio
    )

    try expect(segment.markdownLine(timestampText: "10:30:00") == "[10:30:00] [SYS] system audio text", "system transcript must preserve a source label")
}

func deliveryArtifactChecksExistenceReadabilityAndThreshold() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeliveryArtifactRunner-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let missing = DeliveryArtifactInspector.inspectTextFile(
        label: "Transcript",
        path: directory.appendingPathComponent("missing.md").path,
        minimumCharacters: 5
    )
    try expect(missing.state == .missing, "missing artifact must be reported as missing")

    let textURL = directory.appendingPathComponent("transcript.md")
    try "1234".write(to: textURL, atomically: true, encoding: .utf8)
    let short = DeliveryArtifactInspector.inspectTextFile(label: "Transcript", path: textURL.path, minimumCharacters: 5)
    try expect(short.exists && short.isReadable, "existing UTF-8 artifact must be readable")
    try expect(short.state == .belowThreshold, "short artifact must fail the character threshold")

    try "12345".write(to: textURL, atomically: true, encoding: .utf8)
    let ready = DeliveryArtifactInspector.inspectTextFile(label: "Transcript", path: textURL.path, minimumCharacters: 5)
    try expect(ready.state == .ready, "artifact at threshold must be ready")

    let audioURL = directory.appendingPathComponent("recording.wav")
    try Data(repeating: 0, count: 44).write(to: audioURL)
    let headerOnly = DeliveryArtifactInspector.inspectBinaryFile(label: "Recording", path: audioURL.path, minimumBytes: 45)
    try expect(headerOnly.state == .belowThreshold, "header-only WAV must not pass the recording size threshold")

    try Data(repeating: 0, count: 45).write(to: audioURL)
    let nonEmptyAudio = DeliveryArtifactInspector.inspectBinaryFile(label: "Recording", path: audioURL.path, minimumBytes: 45)
    try expect(nonEmptyAudio.state == .ready, "recording above its minimum size must pass the file-level threshold")
}

func preflightSummaryStaysCompactAndTyped() throws {
    let ready = PreflightSummary.completed(outcomes: [.passed, .passed, .passed])
    try expect(ready.level == .ready, "all passed preflight checks must be ready")
    try expect(ready.compactText == "通過 3/3", "ready preflight text must stay compact")

    let blocked = PreflightSummary.completed(outcomes: [.passed, .failed, .skipped])
    try expect(blocked.level == .blocked, "failed preflight check must block readiness")
    try expect(blocked.compactText == "需處理 1/2", "blocked preflight must exclude skipped checks")
}

func transcriptionEngineSelectionRespectsMacOSAvailability() throws {
    try expect(
        TranscriptionEnginePolicy.preferredEngine(macOSMajorVersion: 14) == .appleSpeech,
        "macOS 14 must default to Apple Speech"
    )
    try expect(
        TranscriptionEnginePolicy.preferredEngine(macOSMajorVersion: 25) == .appleSpeech,
        "macOS 25 must default to Apple Speech"
    )
    try expect(
        TranscriptionEnginePolicy.preferredEngine(macOSMajorVersion: 26) == .speechAnalyzer,
        "macOS 26 must default to SpeechAnalyzer"
    )
    try expect(
        TranscriptionEnginePolicy.resolvedEngine(
            requested: .speechAnalyzer,
            macOSMajorVersion: 25
        ) == .appleSpeech,
        "unsupported SpeechAnalyzer requests must fall back to Apple Speech"
    )
}

func defaultStorageStaysLocalUnlessTheUserChoosesOtherwise() throws {
    let applicationSupport = URL(fileURLWithPath: "/Users/example/Library/Application Support")
    let root = StorageLocationPolicy.defaultRoot(applicationSupportDirectory: applicationSupport)

    try expect(
        root.path == "/Users/example/Library/Application Support/MoMoWhisper",
        "default storage root must live under Application Support"
    )
    try expect(
        !root.path.contains("Mobile Documents"),
        "default storage root must not silently opt into iCloud"
    )
}

do {
    try recorderDoesNotReuseAnExistingPath()
    try startStopStartCreatesANewSessionInsteadOfReusingTheEndedSession()
    try normalStartFromLoadedHistoryCreatesANewSession()
    try rapidStartStopDoesNotCreateASecondWriter()
    try explicitResumeAddsAPartToTheExistingSession()
    try legacyTranscriptSegmentsDecodeWithUnknownSource()
    try transcriptSourceProducesDurableMarkdownLabel()
    try deliveryArtifactChecksExistenceReadabilityAndThreshold()
    try preflightSummaryStaysCompactAndTyped()
    try transcriptionEngineSelectionRespectsMacOSAvailability()
    try defaultStorageStaysLocalUnlessTheUserChoosesOtherwise()
    print("MoMoWhisper lifecycle regression runner passed")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
