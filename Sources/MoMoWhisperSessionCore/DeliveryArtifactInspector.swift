import Foundation

public enum DeliveryArtifactState: String, Codable, Equatable, Sendable {
    case missing
    case unreadable
    case belowThreshold
    case ready
}

public struct DeliveryArtifactCheck: Equatable, Sendable, Identifiable {
    public var id: String { "\(label)|\(path)" }
    public var label: String
    public var path: String
    public var state: DeliveryArtifactState
    public var exists: Bool
    public var isReadable: Bool
    public var measuredCount: Int
    public var requiredCount: Int
    public var unit: String

    public init(
        label: String,
        path: String,
        state: DeliveryArtifactState,
        exists: Bool,
        isReadable: Bool,
        measuredCount: Int,
        requiredCount: Int,
        unit: String
    ) {
        self.label = label
        self.path = path
        self.state = state
        self.exists = exists
        self.isReadable = isReadable
        self.measuredCount = measuredCount
        self.requiredCount = requiredCount
        self.unit = unit
    }

    public var meetsRequirement: Bool {
        state == .ready
    }
}

public enum DeliveryArtifactInspector {
    public static func inspectTextContent(
        label: String,
        text: String,
        sourcePath: String,
        minimumCharacters: Int
    ) -> DeliveryArtifactCheck {
        let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        return result(
            label: label,
            path: sourcePath,
            state: count >= minimumCharacters ? .ready : .belowThreshold,
            exists: true,
            isReadable: true,
            measuredCount: count,
            requiredCount: minimumCharacters,
            unit: "字"
        )
    }

    public static func inspectTextFile(
        label: String,
        path: String,
        minimumCharacters: Int
    ) -> DeliveryArtifactCheck {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            return result(label: label, path: path, state: .missing, measuredCount: 0, requiredCount: minimumCharacters, unit: "字")
        }

        guard fileManager.isReadableFile(atPath: path),
              let data = fileManager.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            return result(
                label: label,
                path: path,
                state: .unreadable,
                exists: true,
                measuredCount: 0,
                requiredCount: minimumCharacters,
                unit: "字"
            )
        }

        let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        return result(
            label: label,
            path: path,
            state: count >= minimumCharacters ? .ready : .belowThreshold,
            exists: true,
            isReadable: true,
            measuredCount: count,
            requiredCount: minimumCharacters,
            unit: "字"
        )
    }

    public static func inspectBinaryFile(
        label: String,
        path: String,
        minimumBytes: Int = 1
    ) -> DeliveryArtifactCheck {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            return result(label: label, path: path, state: .missing, measuredCount: 0, requiredCount: minimumBytes, unit: "bytes")
        }

        guard fileManager.isReadableFile(atPath: path),
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              let fileSize = attributes[.size] as? NSNumber else {
            return result(
                label: label,
                path: path,
                state: .unreadable,
                exists: true,
                measuredCount: 0,
                requiredCount: minimumBytes,
                unit: "bytes"
            )
        }

        let byteCount = fileSize.intValue
        return result(
            label: label,
            path: path,
            state: byteCount >= minimumBytes ? .ready : .belowThreshold,
            exists: true,
            isReadable: true,
            measuredCount: byteCount,
            requiredCount: minimumBytes,
            unit: "bytes"
        )
    }

    private static func result(
        label: String,
        path: String,
        state: DeliveryArtifactState,
        exists: Bool = false,
        isReadable: Bool = false,
        measuredCount: Int,
        requiredCount: Int,
        unit: String
    ) -> DeliveryArtifactCheck {
        DeliveryArtifactCheck(
            label: label,
            path: path,
            state: state,
            exists: exists,
            isReadable: isReadable,
            measuredCount: measuredCount,
            requiredCount: requiredCount,
            unit: unit
        )
    }
}
