import Foundation

public enum StorageLocationPolicy {
    public static func defaultRoot(applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory.appendingPathComponent("MoMoWhisper", isDirectory: true)
    }
}
