import Foundation
import MoMoWhisperSummaryCore

final class RetryableURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedRequestCount = 0

    static var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    static func reset() {
        lock.withLock { storedRequestCount = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock { Self.storedRequestCount += 1 }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 503,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"retryable"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

func waitForFirstRequest() async {
    let deadline = ContinuousClock.now + .seconds(2)
    while RetryableURLProtocol.requestCount == 0, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    if RetryableURLProtocol.requestCount != 1 {
        fail("expected exactly one request before cancellation, got \(RetryableURLProtocol.requestCount)")
    }
}

RetryableURLProtocol.reset()
let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [RetryableURLProtocol.self]
let session = URLSession(configuration: configuration)
defer { session.invalidateAndCancel() }

let summarizer = DeepSeekMeetingSummarizer(
    configuration: .init(
        baseURL: URL(string: "https://summary-cancellation.invalid/v1")!,
        apiKey: "synthetic-test-key",
        model: "synthetic-test-model"
    ),
    session: session
)

let summaryTask = Task {
    try await summarizer.summarize(
        newTranscript: "Synthetic transcript",
        recentTranscript: "",
        currentCatalog: "",
        isFinal: false
    )
}

await waitForFirstRequest()
try? await Task.sleep(for: .milliseconds(50))
summaryTask.cancel()

do {
    _ = try await summaryTask.value
    fail("expected cancellation during retry backoff")
} catch is CancellationError {
} catch {
    fail("expected CancellationError, got \(error)")
}

try? await Task.sleep(for: .milliseconds(100))
if RetryableURLProtocol.requestCount != 1 {
    fail("cancellation must prevent a second request; got \(RetryableURLProtocol.requestCount)")
}

print("DeepSeek retry cancellation smoke test passed (requests: \(RetryableURLProtocol.requestCount))")
