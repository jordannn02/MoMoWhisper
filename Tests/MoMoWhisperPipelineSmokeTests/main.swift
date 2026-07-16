import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let firstRange = SummaryPipelineIdentity.providerDeltaID(
    meetingID: "synthetic-meeting",
    rangeStart: 0,
    rangeEnd: 4_000,
    isFinal: false,
    retryKey: nil,
    sourceFingerprint: "source-a",
    operationsFingerprint: "ops-a"
)
let secondRange = SummaryPipelineIdentity.providerDeltaID(
    meetingID: "synthetic-meeting",
    rangeStart: 4_000,
    rangeEnd: 8_000,
    isFinal: false,
    retryKey: nil,
    sourceFingerprint: "source-b",
    operationsFingerprint: "ops-b"
)
let retry = SummaryPipelineIdentity.providerDeltaID(
    meetingID: "synthetic-meeting",
    rangeStart: 0,
    rangeEnd: 4_000,
    isFinal: false,
    retryKey: "retry-range-0-4000",
    sourceFingerprint: "source-a",
    operationsFingerprint: "ops-a"
)
let replayedRetry = SummaryPipelineIdentity.providerDeltaID(
    meetingID: "synthetic-meeting",
    rangeStart: 0,
    rangeEnd: 4_000,
    isFinal: false,
    retryKey: "retry-range-0-4000",
    sourceFingerprint: "source-a",
    operationsFingerprint: "ops-a"
)
let earlierFinal = SummaryPipelineIdentity.providerDeltaID(
    meetingID: "synthetic-meeting",
    rangeStart: 8_000,
    rangeEnd: 8_000,
    isFinal: true,
    retryKey: nil,
    sourceFingerprint: "source-final",
    operationsFingerprint: "ops-earlier"
)
let improvedFinal = SummaryPipelineIdentity.providerDeltaID(
    meetingID: "synthetic-meeting",
    rangeStart: 8_000,
    rangeEnd: 8_000,
    isFinal: true,
    retryKey: nil,
    sourceFingerprint: "source-final",
    operationsFingerprint: "ops-improved"
)
let changedSource = SummaryPipelineIdentity.providerDeltaID(
    meetingID: "synthetic-meeting",
    rangeStart: 8_000,
    rangeEnd: 8_000,
    isFinal: true,
    retryKey: nil,
    sourceFingerprint: "source-rewritten",
    operationsFingerprint: "ops-improved"
)
let punctuationFingerprint = SummaryPipelineIdentity.rawOperationsFingerprint(Data("Approve v1.".utf8))
let changedPunctuationFingerprint = SummaryPipelineIdentity.rawOperationsFingerprint(Data("Approve v1!".utf8))
let caseChangedFingerprint = SummaryPipelineIdentity.rawOperationsFingerprint(Data("approve v1.".utf8))
let replayedFingerprint = SummaryPipelineIdentity.rawOperationsFingerprint(Data("Approve v1.".utf8))

expect(firstRange != secondRange, "different transcript ranges must never share a reducer delta ID")
expect(retry == replayedRetry, "retries of the same range must reuse the app-owned delta ID")
expect(earlierFinal != improvedFinal, "changed final operations must not be dropped as a replay")
expect(improvedFinal != changedSource, "rewritten source ranges must receive a new reducer identity")
expect(punctuationFingerprint != changedPunctuationFingerprint, "punctuation-only operation changes must remain distinct")
expect(punctuationFingerprint != caseChangedFingerprint, "case-only operation changes must remain distinct")
expect(punctuationFingerprint == replayedFingerprint, "identical canonical operation bytes must remain idempotent")
expect(!firstRange.contains("batch-唯一值"), "provider delta_id literals must not enter reducer identity")
print("Summary pipeline identity smoke tests passed")
