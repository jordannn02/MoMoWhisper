import AVFoundation
import Foundation

public enum MeetingAudioRecorderError: LocalizedError, Equatable {
    case outputPathAlreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case let .outputPathAlreadyExists(path):
            return "錄音檔已存在，拒絕覆寫：\(path)"
        }
    }
}

public final class MeetingAudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var outputURL: URL?
    private var audioFile: AVAudioFile?
    private var isActive = false
    private var lastErrorMessage: String?

    public init() {}

    public var currentOutputURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return outputURL
    }

    public func start(outputDirectory: URL, fileBaseName: String) throws -> URL {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let fileName = "\(Self.safeFileName(fileBaseName)).wav"
        let url = outputDirectory.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw MeetingAudioRecorderError.outputPathAlreadyExists(url.path)
        }

        lock.lock()
        audioFile = nil
        outputURL = url
        isActive = true
        lastErrorMessage = nil
        lock.unlock()

        return url
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        guard isActive, let outputURL else {
            return
        }

        do {
            if audioFile == nil {
                audioFile = try AVAudioFile(
                    forWriting: outputURL,
                    settings: buffer.format.settings,
                    commonFormat: buffer.format.commonFormat,
                    interleaved: buffer.format.isInterleaved
                )
            }

            try audioFile?.write(from: buffer)
        } catch {
            lastErrorMessage = error.localizedDescription
            isActive = false
            audioFile = nil
        }
    }

    public func stop() -> URL? {
        lock.lock()
        defer { lock.unlock() }

        isActive = false
        audioFile = nil
        return outputURL
    }

    public func consumeLastErrorMessage() -> String? {
        lock.lock()
        defer { lock.unlock() }

        let message = lastErrorMessage
        lastErrorMessage = nil
        return message
    }

    private static func safeFileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "MoMoWhisper-Recording" : trimmed
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)

        return fallback
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .replacingOccurrences(of: "  ", with: " ")
    }
}
