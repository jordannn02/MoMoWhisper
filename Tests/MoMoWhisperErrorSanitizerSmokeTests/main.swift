import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let hostile = "HTTP 500 Bearer sk-private-token request=confidential transcript sentence"
let sanitized = SummaryErrorSanitizer.sanitize(hostile)
expect(!sanitized.contains("sk-private-token"), "secret leaked into persisted summary error")
expect(!sanitized.contains("confidential transcript sentence"), "transcript leaked into persisted summary error")
expect(SummaryErrorSanitizer.sanitize("finish_reason=length max_tokens") == "AI 回覆因輸出長度限制而被截斷", "max_tokens category was lost")
expect(SummaryErrorSanitizer.sanitize("HTTP 429 rate limit") == "AI 服務使用量受限，請稍後重試", "rate-limit category was lost")
print("Summary error sanitizer smoke tests passed")
