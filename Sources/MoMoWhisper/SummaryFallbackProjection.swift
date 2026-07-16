import Foundation
import MoMoWhisperSummaryCore

struct SummaryFallbackRange: Equatable {
    var id: String
    var transcript: String
    var rangeStart: Int
    var rangeEnd: Int
}

enum SummaryFallbackProjection {
    static func operation(
        from ranges: [SummaryFallbackRange],
        scopeID: String,
        topicID: String,
        topicTitle: String = "本機備援補充"
    ) -> MeetingSummaryDeltaOperation {
        let topic = MeetingSummaryTopic(id: topicID, title: topicTitle, order: Int.max - 1)
        let items = ranges
            .sorted {
                if $0.rangeStart != $1.rangeStart { return $0.rangeStart < $1.rangeStart }
                return $0.id < $1.id
            }
            .enumerated()
            .map { order, range in
                let excerpt = representativeText(from: range.transcript)
                let start = max(0, range.rangeStart)
                let end = max(start, range.rangeEnd)
                let rangeLabel = "逐字稿範圍 \(start)–\(end)"
                let text = excerpt.isEmpty ? rangeLabel : "\(excerpt)（\(rangeLabel)）"
                return MeetingSummaryItem(
                    id: "summary-local-fallback-item-\(MeetingSummaryFingerprint.make(parts: [range.id, text]))",
                    topicID: topic.id,
                    kind: .note,
                    status: .unknown,
                    text: text,
                    source: .localFallback,
                    order: order,
                    evidence: [.init(
                        segmentID: range.id,
                        startOffset: start,
                        endOffset: end,
                        excerpt: excerpt.isEmpty ? nil : excerpt
                    )],
                    fallbackScopeID: scopeID
                )
            }
        return .replaceFallback(scopeID: scopeID, topic: topic, items: items)
    }

    private static func representativeText(from transcript: String) -> String {
        let lines = transcript
            .components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(
                    of: #"^\[[^\]]+\]\s*(?:\[[^\]]+\]\s*)?"#,
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return "" }
        let indexes = Array(Set([0, lines.count / 2, lines.count - 1])).sorted()
        let combined = indexes.map { lines[$0] }.joined(separator: "；")
        return String(combined.prefix(600))
    }
}
