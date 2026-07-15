@preconcurrency import AVFoundation
import Foundation
import Speech

protocol SpeechAnalyzerSessionHandling: AnyObject, Sendable {
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async
    func cancel()
}

@available(macOS 26.0, *)
final class SpeechAnalyzerTranscriptionSession: SpeechAnalyzerSessionHandling, @unchecked Sendable {
    typealias ResultHandler = @MainActor @Sendable (_ text: String, _ isFinal: Bool) -> Void
    typealias StatusHandler = @MainActor @Sendable (_ status: String) -> Void

    private struct ActiveSession {
        var analyzer: SpeechAnalyzer
        var analyzerFormat: AVAudioFormat
        var inputBuilder: AsyncStream<AnalyzerInput>.Continuation
        var resultTask: Task<Void, Never>
        var statusHandler: StatusHandler
    }

    private let lock = NSLock()
    private var activeSession: ActiveSession?
    private var converter = SpeechAnalyzerBufferConverter()

    func start(
        locale: Locale,
        contextualStrings: [String],
        onResult: @escaping ResultHandler,
        onStatus: @escaping StatusHandler
    ) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechAnalyzerSessionError.notAvailable
        }

        await onStatus("SpeechAnalyzer 準備中")

        let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        try await ensureAssets(for: transcriber, onStatus: onStatus)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        context.contextualStrings[.general] = contextualStrings
        try await analyzer.setContext(context)

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechAnalyzerSessionError.noCompatibleAudioFormat
        }

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        let resultTask = Task { [transcriber, onResult, onStatus] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await onResult(text, result.isFinal)
                }
            } catch {
                if !Task.isCancelled {
                    await onStatus("SpeechAnalyzer 辨識中斷")
                }
            }
        }

        setActiveSession(
            ActiveSession(
                analyzer: analyzer,
                analyzerFormat: analyzerFormat,
                inputBuilder: inputBuilder,
                resultTask: resultTask,
                statusHandler: onStatus
            )
        )

        do {
            try await analyzer.start(inputSequence: inputSequence)
            await onStatus("SpeechAnalyzer 辨識中")
        } catch {
            resultTask.cancel()
            clearActiveSession()
            throw error
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let activeSession else {
            lock.unlock()
            return
        }

        do {
            let converted = try converter.convertBuffer(buffer, to: activeSession.analyzerFormat)
            activeSession.inputBuilder.yield(AnalyzerInput(buffer: converted))
            lock.unlock()
        } catch {
            let statusHandler = activeSession.statusHandler
            lock.unlock()
            Task { @MainActor in
                statusHandler("SpeechAnalyzer 音訊轉換失敗")
            }
        }
    }

    func finish() async {
        guard let activeSession = takeActiveSession(finishInput: true) else {
            return
        }

        do {
            try await activeSession.analyzer.finalizeAndFinishThroughEndOfInput()
            await activeSession.resultTask.value
        } catch {
            await activeSession.statusHandler("SpeechAnalyzer 結束失敗")
        }
    }

    func cancel() {
        guard let activeSession = takeActiveSession(finishInput: true) else {
            return
        }

        activeSession.resultTask.cancel()
        Task {
            await activeSession.analyzer.cancelAndFinishNow()
        }
    }

    private func setActiveSession(_ session: ActiveSession) {
        lock.lock()
        activeSession = session
        converter.reset()
        lock.unlock()
    }

    private func takeActiveSession(finishInput: Bool) -> ActiveSession? {
        lock.lock()
        let session = activeSession
        if finishInput {
            session?.inputBuilder.finish()
        }
        activeSession = nil
        converter.reset()
        lock.unlock()

        return session
    }

    private func clearActiveSession() {
        lock.lock()
        activeSession?.inputBuilder.finish()
        activeSession = nil
        converter.reset()
        lock.unlock()
    }

    private func ensureAssets(
        for transcriber: SpeechTranscriber,
        onStatus: StatusHandler
    ) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])

        guard status != .unsupported else {
            throw SpeechAnalyzerSessionError.localeNotSupported
        }

        guard status != .installed else {
            return
        }

        await onStatus("SpeechAnalyzer 模型下載中")

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }
}

private final class SpeechAnalyzerBufferConverter: @unchecked Sendable {
    enum Error: Swift.Error {
        case failedToCreateConverter
        case failedToCreateConversionBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func reset() {
        converter = nil
    }

    func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else {
            return buffer
        }

        if converter == nil || converter?.inputFormat != inputFormat || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none
        }

        guard let converter else {
            throw Error.failedToCreateConverter
        }

        let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let scaledInputFrameLength = Double(buffer.frameLength) * sampleRateRatio
        let frameCapacity = max(1, AVAudioFrameCount(scaledInputFrameLength.rounded(.up)))

        guard let conversionBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: frameCapacity
        ) else {
            throw Error.failedToCreateConversionBuffer
        }

        var nsError: NSError?
        let provider = SpeechAnalyzerBufferInputProvider(buffer: buffer)
        let status = converter.convert(to: conversionBuffer, error: &nsError) { _, inputStatusPointer in
            provider.nextBuffer(inputStatusPointer)
        }

        guard status != .error else {
            throw Error.conversionFailed(nsError)
        }

        return conversionBuffer
    }
}

private final class SpeechAnalyzerBufferInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var didProvideBuffer = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer(_ inputStatusPointer: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !didProvideBuffer else {
            inputStatusPointer.pointee = .noDataNow
            return nil
        }

        didProvideBuffer = true
        inputStatusPointer.pointee = .haveData
        return buffer
    }
}

private enum SpeechAnalyzerSessionError: LocalizedError {
    case notAvailable
    case localeNotSupported
    case noCompatibleAudioFormat

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "SpeechAnalyzer 目前不可用。"
        case .localeNotSupported:
            return "SpeechAnalyzer 不支援目前選擇的語言。"
        case .noCompatibleAudioFormat:
            return "SpeechAnalyzer 找不到可用的音訊格式。"
        }
    }
}
