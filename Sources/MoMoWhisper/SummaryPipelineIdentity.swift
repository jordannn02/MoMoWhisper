import Foundation

enum SummaryPipelineIdentity {
    static func rawOperationsFingerprint(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    static func providerDeltaID(
        meetingID: String,
        rangeStart: Int,
        rangeEnd: Int,
        isFinal: Bool,
        retryKey: String?,
        sourceFingerprint: String,
        operationsFingerprint: String
    ) -> String {
        let boundedStart = max(0, rangeStart)
        let boundedEnd = max(boundedStart, rangeEnd)
        let phase = isFinal ? "final" : "live"
        let retry = retryKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let retrySuffix = retry.isEmpty ? "" : "-retry-\(stableASCIIComponent(retry))"
        return "provider-\(stableASCIIComponent(meetingID))-\(boundedStart)-\(boundedEnd)-\(phase)\(retrySuffix)-src-\(stableASCIIComponent(sourceFingerprint))-ops-\(stableASCIIComponent(operationsFingerprint))"
    }

    private static func stableASCIIComponent(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> String in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return String(scalar)
            }
            return "_"
        }
        let compact = scalars.joined()
        return compact.isEmpty ? "unknown" : String(compact.prefix(120))
    }
}
