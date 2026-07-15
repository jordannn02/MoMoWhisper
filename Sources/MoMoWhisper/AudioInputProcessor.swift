@preconcurrency import AVFoundation
import Foundation

struct AudioInputProcessingConfiguration: Sendable {
    var gainDecibels: Double
    var sensitivityMode: VoiceSensitivityMode
    var manualThresholdDecibels: Double

    static let defaultAutomaticMarginDecibels = 12.0
}

final class AudioInputProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: AudioInputProcessingConfiguration
    private var noiseFloorDecibels: Double = -70

    init(configuration: AudioInputProcessingConfiguration) {
        self.configuration = configuration
    }

    func process(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let decibels = Self.decibels(for: buffer)
        guard shouldForwardAudio(decibels: decibels) else {
            return nil
        }

        return applyGain(to: buffer)
    }

    private func shouldForwardAudio(decibels: Double) -> Bool {
        switch configuration.sensitivityMode {
        case .off:
            return true
        case .manual:
            return decibels >= configuration.manualThresholdDecibels
        case .automatic:
            return shouldForwardWithAutomaticSensitivity(decibels: decibels)
        }
    }

    private func shouldForwardWithAutomaticSensitivity(decibels: Double) -> Bool {
        lock.lock()
        let threshold = noiseFloorDecibels + AudioInputProcessingConfiguration.defaultAutomaticMarginDecibels
        let shouldForward = decibels >= threshold

        if !shouldForward || decibels < noiseFloorDecibels + 6 {
            noiseFloorDecibels = min(-35, max(-85, (noiseFloorDecibels * 0.95) + (decibels * 0.05)))
        }

        lock.unlock()
        return shouldForward
    }

    private func applyGain(to buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard abs(configuration.gainDecibels) >= 0.1,
              let sourceData = buffer.floatChannelData,
              let outputBuffer = AVAudioPCMBuffer(
                  pcmFormat: buffer.format,
                  frameCapacity: buffer.frameCapacity
              ),
              let outputData = outputBuffer.floatChannelData else {
            return buffer
        }

        let multiplier = Float(pow(10, configuration.gainDecibels / 20))
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        outputBuffer.frameLength = buffer.frameLength

        for channel in 0..<channelCount {
            for frame in 0..<frameLength {
                let amplified = sourceData[channel][frame] * multiplier
                outputData[channel][frame] = min(1, max(-1, amplified))
            }
        }

        return outputBuffer
    }

    private static func decibels(for buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData?[0] else {
            return -120
        }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            return -120
        }

        var sum: Float = 0
        for index in 0..<frameLength {
            let sample = channelData[index]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))
        return Double(20 * log10(max(rms, 0.000_001)))
    }
}
