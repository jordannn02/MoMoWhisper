import Foundation

public struct MeetingRecordingLifecycle: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case ready(UUID)
        case startingNewSession
        case startingRecordingPart(UUID)
        case recording(UUID)
        case stopping(UUID?)
        case ended(UUID)
        case loadedHistory(UUID)
    }

    public enum StartDecision: Equatable, Sendable {
        case createNewSession
        case startRecordingPart(UUID)
        case ignored
    }

    public enum StopDecision: Equatable, Sendable {
        case stopActiveRecording
        case abortStarting
        case ignored
    }

    public private(set) var state: State

    public init(state: State = .idle) {
        self.state = state
    }

    public var currentSessionID: UUID? {
        switch state {
        case let .ready(id), let .startingRecordingPart(id), let .recording(id), let .ended(id), let .loadedHistory(id):
            return id
        case let .stopping(id):
            return id
        case .idle, .startingNewSession:
            return nil
        }
    }

    public var isStartStillActive: Bool {
        if case .startingRecordingPart = state {
            return true
        }
        return false
    }

    public mutating func prepareNewSession(_ id: UUID) {
        state = .ready(id)
    }

    public mutating func markHistoryLoaded(_ id: UUID) {
        state = .loadedHistory(id)
    }

    public mutating func requestStart() -> StartDecision {
        switch state {
        case .idle, .ended, .loadedHistory:
            state = .startingNewSession
            return .createNewSession
        case let .ready(id):
            state = .startingRecordingPart(id)
            return .startRecordingPart(id)
        case .startingNewSession, .startingRecordingPart, .recording, .stopping:
            return .ignored
        }
    }

    public mutating func attachNewSession(_ id: UUID) -> StartDecision {
        guard case .startingNewSession = state else {
            return .ignored
        }
        state = .startingRecordingPart(id)
        return .startRecordingPart(id)
    }

    public mutating func requestExplicitResume() -> StartDecision {
        switch state {
        case let .ended(id), let .loadedHistory(id):
            state = .startingRecordingPart(id)
            return .startRecordingPart(id)
        case .idle, .ready, .startingNewSession, .startingRecordingPart, .recording, .stopping:
            return .ignored
        }
    }

    public mutating func markRecordingStarted() -> Bool {
        guard case let .startingRecordingPart(id) = state else {
            return false
        }
        state = .recording(id)
        return true
    }

    public mutating func requestStop() -> StopDecision {
        switch state {
        case let .recording(id):
            state = .stopping(id)
            return .stopActiveRecording
        case .startingNewSession:
            state = .stopping(nil)
            return .abortStarting
        case let .startingRecordingPart(id):
            state = .stopping(id)
            return .abortStarting
        case .idle, .ready, .stopping, .ended, .loadedHistory:
            return .ignored
        }
    }

    public mutating func finishStop() {
        guard case let .stopping(id) = state else {
            return
        }
        state = id.map(State.ended) ?? .idle
    }

    public mutating func failStart() {
        switch state {
        case .startingNewSession:
            state = .idle
        case let .startingRecordingPart(id):
            state = .ended(id)
        case .stopping:
            finishStop()
        case .idle, .ready, .recording, .ended, .loadedHistory:
            break
        }
    }

    public mutating func reset() {
        state = .idle
    }
}
