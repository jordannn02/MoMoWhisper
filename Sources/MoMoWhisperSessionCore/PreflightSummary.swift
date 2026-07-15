import Foundation

public enum PreflightCheckOutcome: String, Codable, Equatable, Sendable {
    case passed
    case warning
    case failed
    case skipped
}

public enum PreflightSummaryLevel: String, Codable, Equatable, Sendable {
    case pending
    case running
    case ready
    case warning
    case blocked
}

public struct PreflightSummary: Equatable, Sendable {
    public var level: PreflightSummaryLevel
    public var outcomes: [PreflightCheckOutcome]

    public init(level: PreflightSummaryLevel, outcomes: [PreflightCheckOutcome] = []) {
        self.level = level
        self.outcomes = outcomes
    }

    public static let pending = PreflightSummary(level: .pending)
    public static let running = PreflightSummary(level: .running)

    public static func completed(outcomes: [PreflightCheckOutcome]) -> PreflightSummary {
        let level: PreflightSummaryLevel
        if outcomes.contains(.failed) {
            level = .blocked
        } else if outcomes.contains(.warning) {
            level = .warning
        } else {
            level = .ready
        }
        return PreflightSummary(level: level, outcomes: outcomes)
    }

    public var requiredCount: Int {
        outcomes.filter { $0 != .skipped }.count
    }

    public var passedCount: Int {
        outcomes.filter { $0 == .passed }.count
    }

    public var compactText: String {
        switch level {
        case .pending:
            return "待檢查"
        case .running:
            return "檢查中"
        case .ready:
            return "通過 \(passedCount)/\(requiredCount)"
        case .warning:
            return "提醒 \(passedCount)/\(requiredCount)"
        case .blocked:
            return "需處理 \(passedCount)/\(requiredCount)"
        }
    }
}
