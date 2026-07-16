import Foundation

/// Monotonic identity attached to one persistence request. The epoch prevents
/// completions from an older UI session from being applied after a boundary;
/// revision prevents out-of-order tasks from publishing stale state.
public struct PersistenceRevisionToken: Hashable, Sendable {
    public var sessionID: UUID
    public var epoch: UInt64
    public var revision: UInt64

    public init(sessionID: UUID, epoch: UInt64, revision: UInt64) {
        self.sessionID = sessionID
        self.epoch = epoch
        self.revision = revision
    }
}

public enum LatestWinsPersistenceOutcome<Output: Sendable>: Sendable {
    case committed(Output)
    case superseded(by: PersistenceRevisionToken)
}

/// A single-writer, latest-wins persistence queue.
///
/// Requests for the same session that have not started are coalesced to the
/// newest epoch/revision. Requests for different sessions remain ordered. A
/// writer that has already started is never cancelled, so an atomic file commit
/// cannot be interrupted midway; the newest queued revision runs immediately
/// after it.
public actor LatestWinsPersistenceCoordinator<Payload: Sendable, Output: Sendable> {
    public typealias Writer = @Sendable (PersistenceRevisionToken, Payload) async throws -> Output

    private struct PendingRequest {
        var token: PersistenceRevisionToken
        var payload: Payload
        var debounceNanoseconds: UInt64
        var continuation: CheckedContinuation<LatestWinsPersistenceOutcome<Output>, Error>
    }

    private let writer: Writer
    private var queued: [PendingRequest] = []
    private var highestSeenBySession: [UUID: PersistenceRevisionToken] = [:]
    private var isWriting = false
    private var timerTask: Task<Void, Never>?

    public init(writer: @escaping Writer) {
        self.writer = writer
    }

    public func submit(
        token: PersistenceRevisionToken,
        payload: Payload,
        debounceNanoseconds: UInt64
    ) async throws -> LatestWinsPersistenceOutcome<Output> {
        if let highest = highestSeenBySession[token.sessionID], !Self.isNewer(token, than: highest) {
            return .superseded(by: highest)
        }
        highestSeenBySession[token.sessionID] = token

        return try await withCheckedThrowingContinuation { continuation in
            let pending = PendingRequest(
                token: token,
                payload: payload,
                debounceNanoseconds: debounceNanoseconds,
                continuation: continuation
            )

            if let existingIndex = queued.firstIndex(where: { $0.token.sessionID == token.sessionID }) {
                let superseded = queued.remove(at: existingIndex)
                superseded.continuation.resume(returning: .superseded(by: token))
                queued.insert(pending, at: existingIndex)
                if existingIndex == 0, !isWriting {
                    scheduleFrontRequest()
                }
            } else {
                queued.append(pending)
                if queued.count == 1, !isWriting {
                    scheduleFrontRequest()
                }
            }
        }
    }

    public func submitAndFlush(
        token: PersistenceRevisionToken,
        payload: Payload
    ) async throws -> LatestWinsPersistenceOutcome<Output> {
        try await submit(token: token, payload: payload, debounceNanoseconds: 0)
    }

    private func scheduleFrontRequest() {
        timerTask?.cancel()
        guard !queued.isEmpty, !isWriting else {
            timerTask = nil
            return
        }

        let delay = queued[0].debounceNanoseconds
        timerTask = Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await self?.drainFrontRequest()
        }
    }

    private func drainFrontRequest() async {
        guard !isWriting, !queued.isEmpty else { return }
        timerTask = nil
        isWriting = true
        let request = queued.removeFirst()

        do {
            let output = try await writer(request.token, request.payload)
            request.continuation.resume(returning: .committed(output))
        } catch {
            request.continuation.resume(throwing: error)
        }

        isWriting = false
        scheduleFrontRequest()
    }

    private static func isNewer(
        _ candidate: PersistenceRevisionToken,
        than existing: PersistenceRevisionToken
    ) -> Bool {
        if candidate.epoch != existing.epoch {
            return candidate.epoch > existing.epoch
        }
        return candidate.revision > existing.revision
    }
}
