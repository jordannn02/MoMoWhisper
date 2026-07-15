import Foundation

enum MeetingVocabulary {
    static let contextualStrings = mergedContextualStrings(customTerms: [])

    static func mergedContextualStrings(customTerms: [String]) -> [String] {
        let groups = [
            meetingTerms,
            projectTerms,
            businessTerms,
            technicalTerms,
            customTerms
        ]

        var seen = Set<String>()
        return groups
            .flatMap { $0 }
            .compactMap { term in
                let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                    return nil
                }
                return normalized
            }
    }

    private static let meetingTerms = [
        "MoMoWhisper", "逐字稿", "會議記錄", "會議重點", "討論主題", "討論時間",
        "決議事項", "行動項目", "待確認", "負責人", "議程", "結論", "風險",
        "下一步", "截止日期", "里程碑", "追蹤事項"
    ]

    private static let projectTerms = [
        "需求訪談", "需求確認", "流程盤點", "流程設計", "現行流程", "未來流程",
        "測試案例", "驗收條件", "使用者測試", "教育訓練", "正式上線", "版本發布",
        "優先級", "依賴項目", "阻礙事項", "變更管理"
    ]

    private static let businessTerms = [
        "客戶", "供應商", "報價", "訂單", "採購", "交期", "付款條件", "庫存",
        "成本", "預算", "發票", "合約", "品質", "審核", "簽核", "匯入", "匯出"
    ]

    private static let technicalTerms = [
        "API", "資料庫", "資料表", "欄位", "索引", "SQL", "Schema", "Source Code",
        "部署", "回歸測試", "權限", "設定", "錯誤訊息", "效能", "可觀測性", "備份"
    ]
}
