import Foundation

enum SummaryErrorSanitizer {
    static func sanitize(_ reason: String) -> String {
        let normalized = reason.lowercased()
        if normalized.contains("max_tokens")
            || normalized.contains("finish_reason") && normalized.contains("length")
            || normalized.contains("truncated") {
            return "AI 回覆因輸出長度限制而被截斷"
        }
        if normalized.contains("timed out") || normalized.contains("timeout") || normalized.contains("逾時") {
            return "AI 服務逾時"
        }
        if normalized.contains("401") || normalized.contains("unauthorized") || normalized.contains("authentication") {
            return "AI 服務驗證失敗"
        }
        if normalized.contains("403") || normalized.contains("forbidden") {
            return "AI 服務拒絕存取"
        }
        if normalized.contains("429") || normalized.contains("rate limit") {
            return "AI 服務使用量受限，請稍後重試"
        }
        if normalized.contains("network")
            || normalized.contains("internet")
            || normalized.contains("could not connect")
            || normalized.contains("connection refused") {
            return "無法連線到 AI 服務"
        }
        if normalized.contains("invalid response")
            || normalized.contains("schema")
            || normalized.contains("decode")
            || normalized.contains("json") {
            return "AI 回覆格式無法驗證"
        }
        return "AI 服務回傳未識別錯誤（詳細內容未顯示，以保護逐字稿）"
    }
}
