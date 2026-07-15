import Foundation
import MoMoWhisperSessionCore

enum MoMoWhisperStorage {
    static var rootDirectory: URL {
        let fileManager = FileManager.default
        let applicationSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return StorageLocationPolicy.defaultRoot(
            applicationSupportDirectory: applicationSupportDirectory
        )
    }

    static var meetingsDirectory: URL {
        rootDirectory.appendingPathComponent("Meetings", isDirectory: true)
    }

    static var recordingsDirectory: URL {
        rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    static var highlightsDirectory: URL {
        rootDirectory.appendingPathComponent("Highlights", isDirectory: true)
    }

    static var codexHandoffDirectory: URL {
        rootDirectory.appendingPathComponent("CodexHandoff", isDirectory: true)
    }

    static var diagnosticsDirectory: URL {
        rootDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
    }
}
