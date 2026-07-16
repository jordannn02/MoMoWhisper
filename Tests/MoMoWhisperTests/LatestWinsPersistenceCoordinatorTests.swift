#if canImport(XCTest)
import Foundation
import XCTest
@testable import MoMoWhisperSessionCore

private actor PersistenceWriterProbe {
    private(set) var revisions: [UInt64] = []
    private(set) var activeWriters = 0
    private(set) var maximumConcurrentWriters = 0
    var delayNanoseconds: UInt64 = 0
    private var startedRevisions: Set<UInt64> = []
    private var startWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
    private var blockedRevision: UInt64?
    private var blockedWriteContinuation: CheckedContinuation<Void, Never>?

    func write(token: PersistenceRevisionToken, payload: Int) async throws -> Int {
        activeWriters += 1
        maximumConcurrentWriters = max(maximumConcurrentWriters, activeWriters)
        revisions.append(token.revision)
        startedRevisions.insert(token.revision)
        let waiters = startWaiters.removeValue(forKey: token.revision) ?? []
        waiters.forEach { $0.resume() }
        if blockedRevision == token.revision {
            await withCheckedContinuation { continuation in
                blockedWriteContinuation = continuation
            }
        }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        activeWriters -= 1
        return payload
    }

    func snapshot() -> (revisions: [UInt64], maximumConcurrentWriters: Int) {
        (revisions, maximumConcurrentWriters)
    }

    func waitUntilStarted(revision: UInt64) async {
        guard !startedRevisions.contains(revision) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[revision, default: []].append(continuation)
        }
    }

    func blockWrite(revision: UInt64) {
        blockedRevision = revision
    }

    func releaseBlockedWrite() {
        blockedRevision = nil
        blockedWriteContinuation?.resume()
        blockedWriteContinuation = nil
    }
}

final class LatestWinsPersistenceCoordinatorTests: XCTestCase {
    func testRapidRequestsCoalesceToLatestRevision() async throws {
        let probe = PersistenceWriterProbe()
        let coordinator = LatestWinsPersistenceCoordinator<Int, Int> { token, payload in
            try await probe.write(token: token, payload: payload)
        }
        let sessionID = UUID()

        var tasks: [Task<LatestWinsPersistenceOutcome<Int>, Error>] = []
        for revision in 1...50 {
            let token = PersistenceRevisionToken(
                sessionID: sessionID,
                epoch: 1,
                revision: UInt64(revision)
            )
            tasks.append(Task {
                try await coordinator.submit(
                    token: token,
                    payload: revision,
                    debounceNanoseconds: 80_000_000
                )
            })
            await Task.yield()
        }

        for task in tasks {
            _ = try await task.value
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.revisions, [50])
        XCTAssertEqual(snapshot.maximumConcurrentWriters, 1)
    }

    func testWriterIsSerializedWhileNewestQueuedRevisionSurvives() async throws {
        let probe = PersistenceWriterProbe()
        await probe.blockWrite(revision: 1)
        let coordinator = LatestWinsPersistenceCoordinator<Int, Int> { token, payload in
            try await probe.write(token: token, payload: payload)
        }
        let sessionID = UUID()

        let first = Task {
            try await coordinator.submitAndFlush(
                token: .init(sessionID: sessionID, epoch: 1, revision: 1),
                payload: 1
            )
        }
        await probe.waitUntilStarted(revision: 1)

        var queued: [Task<LatestWinsPersistenceOutcome<Int>, Error>] = []
        var previous: Task<LatestWinsPersistenceOutcome<Int>, Error>?
        for revision in 2...20 {
            let current = Task {
                try await coordinator.submit(
                    token: .init(sessionID: sessionID, epoch: 1, revision: UInt64(revision)),
                    payload: revision,
                    debounceNanoseconds: 0
                )
            }
            queued.append(current)
            if let previous {
                _ = try await previous.value
            }
            previous = current
        }

        await probe.releaseBlockedWrite()
        _ = try await first.value
        for task in queued {
            _ = try await task.value
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.revisions, [1, 20])
        XCTAssertEqual(snapshot.maximumConcurrentWriters, 1)
    }

    func testStaleRevisionIsRejectedWithoutWriting() async throws {
        let probe = PersistenceWriterProbe()
        let coordinator = LatestWinsPersistenceCoordinator<Int, Int> { token, payload in
            try await probe.write(token: token, payload: payload)
        }
        let sessionID = UUID()

        _ = try await coordinator.submitAndFlush(
            token: .init(sessionID: sessionID, epoch: 3, revision: 10),
            payload: 10
        )
        let stale = try await coordinator.submitAndFlush(
            token: .init(sessionID: sessionID, epoch: 3, revision: 9),
            payload: 9
        )

        if case let .superseded(token) = stale {
            XCTAssertEqual(token.revision, 10)
        } else {
            XCTFail("stale revision unexpectedly reached the writer")
        }
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.revisions, [10])
    }

    func testFlushWaitsForWriterCompletion() async throws {
        let probe = PersistenceWriterProbe()
        await probe.setDelayForTesting(50_000_000)
        let coordinator = LatestWinsPersistenceCoordinator<Int, Int> { token, payload in
            try await probe.write(token: token, payload: payload)
        }
        let clock = ContinuousClock()
        let started = clock.now

        _ = try await coordinator.submitAndFlush(
            token: .init(sessionID: UUID(), epoch: 1, revision: 1),
            payload: 1
        )

        XCTAssertGreaterThanOrEqual(started.duration(to: clock.now), .milliseconds(40))
    }
}

private extension PersistenceWriterProbe {
    func setDelayForTesting(_ value: UInt64) {
        delayNanoseconds = value
    }
}
#endif
