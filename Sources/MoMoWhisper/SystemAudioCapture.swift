@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let outputQueue = DispatchQueue(label: "local.codex.momo-whisper.system-audio")
    private let levelMeter = SpeechAudioLevelMeter()
    private let lock = NSLock()

    private var stream: SCStream?
    private var audioRouter: SpeechAudioBufferRouter?
    private var audioProcessor: AudioInputProcessor?
    private var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var onAudioLevel: (@MainActor @Sendable (Float, Int, AVAudioFormat) -> Void)?
    private var onError: (@MainActor @Sendable (String) -> Void)?

    func start(
        audioRouter: SpeechAudioBufferRouter?,
        audioProcessor: AudioInputProcessor? = nil,
        onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil,
        onAudioLevel: @escaping @MainActor @Sendable (Float, Int, AVAudioFormat) -> Void,
        onError: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        stop()
        levelMeter.reset()

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)

        setActiveStream(
            stream,
            audioRouter: audioRouter,
            audioProcessor: audioProcessor,
            onAudioBuffer: onAudioBuffer,
            onAudioLevel: onAudioLevel,
            onError: onError
        )

        try await stream.startCapture()
    }

    func stop() {
        lock.lock()
        let activeStream = stream
        stream = nil
        audioRouter = nil
        audioProcessor = nil
        onAudioBuffer = nil
        onAudioLevel = nil
        onError = nil
        lock.unlock()

        if let activeStream {
            Task {
                try? await activeStream.stopCapture()
            }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else {
            return
        }

        guard let buffer = Self.makePCMBuffer(from: sampleBuffer) else {
            return
        }

        lock.lock()
        let currentRouter = audioRouter
        let currentProcessor = audioProcessor
        let bufferHandler = onAudioBuffer
        let levelHandler = onAudioLevel
        lock.unlock()

        if let levelHandler {
            let format = buffer.format
            levelMeter.observe(buffer) { decibels, bufferCount in
                levelHandler(decibels, bufferCount, format)
            }
        }

        let processedBuffer: AVAudioPCMBuffer
        if let currentProcessor {
            guard let routedBuffer = currentProcessor.process(buffer) else {
                return
            }
            processedBuffer = routedBuffer
        } else {
            processedBuffer = buffer
        }

        currentRouter?.append(processedBuffer)
        bufferHandler?(processedBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        let errorHandler = onError
        lock.unlock()

        Task { @MainActor in
            errorHandler?("系統音訊中斷：\(error.localizedDescription)")
        }
    }

    private func setActiveStream(
        _ stream: SCStream,
        audioRouter: SpeechAudioBufferRouter?,
        audioProcessor: AudioInputProcessor?,
        onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?,
        onAudioLevel: @escaping @MainActor @Sendable (Float, Int, AVAudioFormat) -> Void,
        onError: @escaping @MainActor @Sendable (String) -> Void
    ) {
        lock.lock()
        self.stream = stream
        self.audioRouter = audioRouter
        self.audioProcessor = audioProcessor
        self.onAudioBuffer = onAudioBuffer
        self.onAudioLevel = onAudioLevel
        self.onError = onError
        lock.unlock()
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              var streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let format = AVAudioFormat(streamDescription: &streamDescription) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            return nil
        }

        buffer.frameLength = buffer.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )

        guard status == noErr else {
            return nil
        }

        return buffer
    }
}

private enum SystemAudioCaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "找不到可用螢幕，無法擷取系統音訊。"
        }
    }
}
