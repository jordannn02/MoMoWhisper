@preconcurrency import AVFoundation
import Foundation
import Speech

final class SpeechAudioBufferRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func route(to request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let oldRequest = self.request
        self.request = request
        lock.unlock()

        if oldRequest !== request {
            oldRequest?.endAudio()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let currentRequest = request
        lock.unlock()

        currentRequest?.append(buffer)
    }

    func close() {
        route(to: nil)
    }
}
