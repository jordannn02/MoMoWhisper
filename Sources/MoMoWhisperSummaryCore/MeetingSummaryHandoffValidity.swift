import Foundation

/// Defines whether a meeting contains enough durable content to become the
/// `latest_valid` handoff. Rendered Markdown and unreviewed generated content
/// are intentionally excluded: neither is sufficient evidence of a trusted
/// meeting handoff for a very short transcript.
public enum MeetingSummaryHandoffValidity {
    public static let defaultMinimumTranscriptCharacters = 300

    public static func isValid(
        transcriptCharacterCount: Int,
        summaryDocument: MeetingSummaryDocument?,
        minimumTranscriptCharacters: Int = defaultMinimumTranscriptCharacters
    ) -> Bool {
        max(0, transcriptCharacterCount) >= max(0, minimumTranscriptCharacters)
            || hasSemanticContent(summaryDocument)
    }

    public static func hasSemanticContent(_ document: MeetingSummaryDocument?) -> Bool {
        guard let document else {
            return false
        }

        if document.headlineLockedByUser == true,
           !document.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        return document.items.contains { item in
            item.status != .resolved
                && item.status != .superseded
                && !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (item.source == .manual || item.lockedByUser)
        }
    }
}
