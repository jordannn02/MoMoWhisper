import Foundation
import MoMoWhisperSummaryCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let ranges = (0..<20).map { index in
    SummaryFallbackRange(
        id: "retry-\(index)",
        transcript: "[00:00] [MIC] early-\(index)\nmid-\(index)\nlate-\(index)",
        rangeStart: index * 1_000,
        rangeEnd: (index + 1) * 1_000
    )
}
var document = MeetingSummaryReducer.applying(
    .init(
        id: "fallback-20",
        operations: [SummaryFallbackProjection.operation(
            from: ranges,
            scopeID: "fallback",
            topicID: "fallback-topic"
        )]
    ),
    to: .empty(id: "synthetic", title: "Synthetic")
)
let firstItems = document.items.filter { $0.fallbackScopeID == "fallback" }
expect(firstItems.count == 20, "not every failed range was represented")
expect(firstItems.first?.text.contains("early-0") == true, "early range was lost")
expect(firstItems[10].text.contains("mid-10") == true, "middle range was lost")
expect(firstItems.last?.text.contains("late-19") == true, "late range was lost")
expect(Set(firstItems.compactMap { $0.evidence.first?.segmentID }).count == 20, "range evidence is not unique")

let additionalRange = SummaryFallbackRange(
    id: "retry-20",
    transcript: "new-failure",
    rangeStart: 20_000,
    rangeEnd: 21_000
)
document = MeetingSummaryReducer.applying(
    .init(
        id: "fallback-21",
        operations: [SummaryFallbackProjection.operation(
            from: ranges + [additionalRange],
            scopeID: "fallback",
            topicID: "fallback-topic"
        )]
    ),
    to: document
)
expect(document.items.filter { $0.fallbackScopeID == "fallback" }.count == 21, "new failure replaced earlier ranges")
print("Summary fallback projection smoke tests passed")
