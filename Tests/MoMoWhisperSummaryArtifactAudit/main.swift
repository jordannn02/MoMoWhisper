import Foundation
import MoMoWhisperSummaryCore

guard CommandLine.arguments.count == 2 else {
    fputs("usage: MoMoWhisperSummaryArtifactAudit <raw_summary_state.json>\n", stderr)
    exit(2)
}

let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let legacy = try JSONDecoder().decode(LegacyMeetingSummaryState.self, from: data)
let migrated = MeetingSummaryMigration.migrate(
    legacy,
    meetingID: "local-read-only-audit",
    title: "Local read-only audit"
)
try MeetingSummaryDocumentValidator.validate(migrated)

let readable = MeetingSummaryRenderer.render(migrated)
let fullAudit = MeetingSummaryRenderer.render(
    migrated,
    options: .init(usesDenseTopicPreview: false)
)
let readableBullets = readable.components(separatedBy: "- [").count - 1
let fullBullets = fullAudit.components(separatedBy: "- [").count - 1

print("legacy_topics\t\(legacy.topics.count)")
print("migrated_items\t\(migrated.items.count)")
print("readable_bullets\t\(readableBullets)")
print("full_audit_bullets\t\(fullBullets)")
print("has_full_audit_pointer\t\(readable.contains("summary_document.json"))")
