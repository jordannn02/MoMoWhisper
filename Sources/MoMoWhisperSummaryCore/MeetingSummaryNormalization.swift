import Foundation

public enum MeetingSummaryNormalization {
    public static func normalizedText(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()

        var scalarBuffer = String.UnicodeScalarView()
        var needsSeparator = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if needsSeparator, !scalarBuffer.isEmpty {
                    scalarBuffer.append(" ")
                }
                scalarBuffer.append(scalar)
                needsSeparator = false
            } else {
                needsSeparator = true
            }
        }

        return String(scalarBuffer)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    public static func compactText(_ value: String) -> String {
        normalizedText(value).replacingOccurrences(of: " ", with: "")
    }
}

public enum MeetingSummaryFingerprint {
    public static func make(_ value: String) -> String {
        make(parts: [value])
    }

    public static func make(parts: [String]) -> String {
        let normalized = parts.map(MeetingSummaryNormalization.normalizedText).joined(separator: "\u{1f}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

public struct MeetingSummaryDuplicateCandidate: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case exact
        case conservativeNearSynonym
    }

    public var firstID: String
    public var secondID: String
    public var kind: Kind
    public var score: Double

    public init(firstID: String, secondID: String, kind: Kind, score: Double) {
        self.firstID = firstID
        self.secondID = secondID
        self.kind = kind
        self.score = score
    }
}

public enum MeetingSummaryDuplicateAnalyzer {
    public static let conservativeNearSynonymThreshold = 0.88

    public static func topicCandidates(
        in topics: [MeetingSummaryTopic]
    ) -> [MeetingSummaryDuplicateCandidate] {
        candidates(topics.map { ($0.id, $0.title) }, restrictNearPairs: nil)
    }

    public static func itemCandidates(
        in items: [MeetingSummaryItem]
    ) -> [MeetingSummaryDuplicateCandidate] {
        var result: [MeetingSummaryDuplicateCandidate] = []
        guard items.count > 1 else {
            return result
        }

        for firstIndex in 0..<(items.count - 1) {
            for secondIndex in (firstIndex + 1)..<items.count {
                let first = items[firstIndex]
                let second = items[secondIndex]
                guard first.topicID == second.topicID, first.kind == second.kind else {
                    continue
                }
                if let candidate = candidate(
                    firstID: first.id,
                    firstText: first.text,
                    secondID: second.id,
                    secondText: second.text
                ) {
                    result.append(candidate)
                }
            }
        }
        return result
    }

    private static func candidates(
        _ values: [(id: String, text: String)],
        restrictNearPairs: ((String, String) -> Bool)?
    ) -> [MeetingSummaryDuplicateCandidate] {
        guard values.count > 1 else {
            return []
        }
        var result: [MeetingSummaryDuplicateCandidate] = []
        for firstIndex in 0..<(values.count - 1) {
            for secondIndex in (firstIndex + 1)..<values.count {
                let first = values[firstIndex]
                let second = values[secondIndex]
                if let restrictNearPairs,
                   !restrictNearPairs(first.id, second.id),
                   MeetingSummaryNormalization.normalizedText(first.text) != MeetingSummaryNormalization.normalizedText(second.text) {
                    continue
                }
                if let candidate = candidate(
                    firstID: first.id,
                    firstText: first.text,
                    secondID: second.id,
                    secondText: second.text
                ) {
                    result.append(candidate)
                }
            }
        }
        return result
    }

    private static func candidate(
        firstID: String,
        firstText: String,
        secondID: String,
        secondText: String
    ) -> MeetingSummaryDuplicateCandidate? {
        let first = MeetingSummaryNormalization.normalizedText(firstText)
        let second = MeetingSummaryNormalization.normalizedText(secondText)
        guard !first.isEmpty, !second.isEmpty else {
            return nil
        }
        if first == second {
            return .init(firstID: firstID, secondID: secondID, kind: .exact, score: 1)
        }

        let firstCharacters = Array(first)
        let secondCharacters = Array(second)
        guard min(firstCharacters.count, secondCharacters.count) >= 12 else {
            return nil
        }
        let lengthRatio = Double(min(firstCharacters.count, secondCharacters.count)) /
            Double(max(firstCharacters.count, secondCharacters.count))
        guard lengthRatio >= 0.8 else {
            return nil
        }

        let score = bigramDice(firstCharacters, secondCharacters)
        guard score >= conservativeNearSynonymThreshold else {
            return nil
        }
        return .init(
            firstID: firstID,
            secondID: secondID,
            kind: .conservativeNearSynonym,
            score: score
        )
    }

    private static func bigramDice(_ lhs: [Character], _ rhs: [Character]) -> Double {
        func bigrams(_ characters: [Character]) -> Set<String> {
            guard characters.count > 1 else {
                return Set([String(characters)])
            }
            return Set((0..<(characters.count - 1)).map { index in
                String(characters[index...index + 1])
            })
        }

        let lhsBigrams = bigrams(lhs)
        let rhsBigrams = bigrams(rhs)
        let denominator = lhsBigrams.count + rhsBigrams.count
        guard denominator > 0 else {
            return 0
        }
        return Double(2 * lhsBigrams.intersection(rhsBigrams).count) / Double(denominator)
    }
}
