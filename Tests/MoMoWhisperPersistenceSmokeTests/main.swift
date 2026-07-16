import Foundation
import MoMoWhisperSessionCore

enum PersistenceSmokeFailure: Error {
    case failed(String)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw PersistenceSmokeFailure.failed(message) }
}

actor PersistenceSmokeProbe {
    private var revisions: [UInt64] = []
    private var active = 0
    private var maximumActive = 0
    private var delayNanoseconds: UInt64 = 0
    private var startedRevisions: Set<UInt64> = []
    private var startWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
    private var blockedRevision: UInt64?
    private var blockedWriteContinuation: CheckedContinuation<Void, Never>?

    func setDelay(_ value: UInt64) {
        delayNanoseconds = value
    }

    func write(token: PersistenceRevisionToken, payload: Int) async throws -> Int {
        active += 1
        maximumActive = max(maximumActive, active)
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
        active -= 1
        return payload
    }

    func snapshot() -> ([UInt64], Int) {
        (revisions, maximumActive)
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

actor LongPayloadProbe {
    private var writes: [(revision: UInt64, characters: Int)] = []

    func write(token: PersistenceRevisionToken, payload: String) async throws -> Int {
        writes.append((token.revision, payload.count))
        return payload.count
    }

    func snapshot() -> [(UInt64, Int)] {
        writes.map { ($0.revision, $0.characters) }
    }
}

@main
enum PersistenceSmokeRunner {
    static func main() async throws {
        try await coalescesRapidSubmissions()
        try await serializesActiveAndQueuedWrites()
        try await rejectsStaleRevisions()
        try await flushWaitsForCompletion()
        try await boundaryFlushSupersedesPendingDebounce()
        try await coalescesLongMeetingSnapshots()
        print("Latest-wins background persistence smoke tests passed")
    }

    private static func coalescesRapidSubmissions() async throws {
        let probe = PersistenceSmokeProbe()
        let coordinator = LatestWinsPersistenceCoordinator<Int, Int> { token, payload in
            try await probe.write(token: token, payload: payload)
        }
        let sessionID = UUID()
        var tasks: [Task<LatestWinsPersistenceOutcome<Int>, Error>] = []
        for revision in 1...50 {
            tasks.append(Task {
                try await coordinator.submit(
                    token: .init(sessionID: sessionID, epoch: 1, revision: UInt64(revision)),
                    payload: revision,
                    debounceNanoseconds: 80_000_000
                )
            })
            try await Task.sleep(nanoseconds: 500_000)
        }
        for task in tasks { _ = try await task.value }
        let result = await probe.snapshot()
        try expect(result.0 == [50], "rapid submissions were not coalesced to revision 50: \(result.0)")
        try expect(result.1 == 1, "coalesced writer concurrency exceeded one")
    }

    private static func serializesActiveAndQueuedWrites() async throws {
        let probe = PersistenceSmokeProbe()
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
        for task in queued { _ = try await task.value }
        let result = await probe.snapshot()
        try expect(result.0 == [1, 20], "active/latest serialized writes were \(result.0)")
        try expect(result.1 == 1, "writer ran concurrently")
    }

    private static func rejectsStaleRevisions() async throws {
        let probe = PersistenceSmokeProbe()
        let coordinator = LatestWinsPersistenceCoordinator<Int, Int> { token, payload in
            try await probe.write(token: token, payload: payload)
        }
        let sessionID = UUID()
        _ = try await coordinator.submitAndFlush(
            token: .init(sessionID: sessionID, epoch: 2, revision: 10),
            payload: 10
        )
        let stale = try await coordinator.submitAndFlush(
            token: .init(sessionID: sessionID, epoch: 2, revision: 9),
            payload: 9
        )
        guard case let .superseded(by) = stale else {
            throw PersistenceSmokeFailure.failed("stale revision reached writer")
        }
        try expect(by.revision == 10, "wrong superseding revision")
        let result = await probe.snapshot()
        try expect(result.0 == [10], "stale revision wrote to backend")
    }

    private static func flushWaitsForCompletion() async throws {
        let probe = PersistenceSmokeProbe()
        await probe.setDelay(50_000_000)
        let coordinator = LatestWinsPersistenceCoordinator<Int, Int> { token, payload in
            try await probe.write(token: token, payload: payload)
        }
        let clock = ContinuousClock()
        let started = clock.now
        _ = try await coordinator.submitAndFlush(
            token: .init(sessionID: UUID(), epoch: 1, revision: 1),
            payload: 1
        )
        try expect(
            started.duration(to: clock.now) >= .milliseconds(40),
            "flush returned before writer completion"
        )
    }

    /// Models Cmd-Q/session-boundary behavior: the zero-delay revision must
    /// replace a pending UI debounce and must not return until it is durable.
    private static func boundaryFlushSupersedesPendingDebounce() async throws {
        let probe = PersistenceSmokeProbe()
        await probe.setDelay(45_000_000)
        let coordinator = LatestWinsPersistenceCoordinator<Int, Int> { token, payload in
            try await probe.write(token: token, payload: payload)
        }
        let sessionID = UUID()
        let debounced = Task {
            try await coordinator.submit(
                token: .init(sessionID: sessionID, epoch: 7, revision: 41),
                payload: 41,
                debounceNanoseconds: 250_000_000
            )
        }
        try await Task.sleep(nanoseconds: 5_000_000)

        let clock = ContinuousClock()
        let started = clock.now
        let flushed = try await coordinator.submitAndFlush(
            token: .init(sessionID: sessionID, epoch: 7, revision: 42),
            payload: 42
        )
        guard case let .committed(value) = flushed else {
            throw PersistenceSmokeFailure.failed("boundary revision was not committed")
        }
        try expect(value == 42, "boundary flush committed the wrong payload")
        try expect(
            started.duration(to: clock.now) >= .milliseconds(35),
            "boundary flush returned before durable writer completion"
        )

        guard case let .superseded(by) = try await debounced.value else {
            throw PersistenceSmokeFailure.failed("pending debounce was not superseded")
        }
        try expect(by.revision == 42, "pending debounce reported wrong replacement")
        let result = await probe.snapshot()
        try expect(result.0 == [42], "stale debounced revision reached writer: \(result.0)")
    }

    private static func coalescesLongMeetingSnapshots() async throws {
        let probe = LongPayloadProbe()
        let coordinator = LatestWinsPersistenceCoordinator<String, Int> { token, payload in
            try await probe.write(token: token, payload: payload)
        }
        let sessionID = UUID()
        let transcript = String(repeating: "長會議 mixed-language transcript segment. ", count: 7_500)
        let clock = ContinuousClock()
        let enqueueStarted = clock.now
        var tasks: [Task<LatestWinsPersistenceOutcome<Int>, Error>] = []

        for revision in 1...30 {
            tasks.append(Task {
                try await coordinator.submit(
                    token: .init(sessionID: sessionID, epoch: 1, revision: UInt64(revision)),
                    payload: transcript + " revision=\(revision)",
                    debounceNanoseconds: 80_000_000
                )
            })
            await Task.yield()
        }
        let enqueueDuration = enqueueStarted.duration(to: clock.now)
        for task in tasks { _ = try await task.value }

        let writes = await probe.snapshot()
        try expect(writes.count == 1, "long meeting snapshots were written \(writes.count) times")
        try expect(writes.first?.0 == 30, "long meeting did not retain latest revision")
        try expect((writes.first?.1 ?? 0) > 250_000, "long meeting fixture was too small")
        try expect(enqueueDuration < .seconds(1), "long meeting enqueue blocked for \(enqueueDuration)")
    }
}
