@preconcurrency import AVFoundation
import Foundation

final class SpeechAudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmission = Date.distantPast
    private var observedBufferCount = 0

    func reset() {
        lock.lock()
        observedBufferCount = 0
        lastEmission = .distantPast
        lock.unlock()
    }

    func observe(
        _ buffer: AVAudioPCMBuffer,
        onUpdate: @escaping @MainActor @Sendable (Float, Int) -> Void
    ) {
        guard let channelData = buffer.floatChannelData?[0] else {
            return
        }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            return
        }

        var sum: Float = 0
        for index in 0..<frameLength {
            let sample = channelData[index]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))
        let decibels = 20 * log10(max(rms, 0.000_001))
        let now = Date()
        let count: Int

        lock.lock()
        observedBufferCount += 1
        guard now.timeIntervalSince(lastEmission) >= 0.5 else {
            lock.unlock()
            return
        }
        lastEmission = now
        count = observedBufferCount
        lock.unlock()

        Task { @MainActor in
            onUpdate(decibels, count)
        }
    }
}
