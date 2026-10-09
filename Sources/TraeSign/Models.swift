import Foundation

// MARK: - 平台
enum Platform: String, CaseIterable, Identifiable {
    case trae = "Trae"
    case workbuddy = "WorkBuddy"
    case zcode = "ZCode"
    var id: String { rawValue }

    /// 菜单栏图标/标题的显示名（中英混排更直观）
    var shortName: String {
        switch self {
        case .trae: return "Trae"
        case .workbuddy: return "WB"
        case .zcode: return "ZCode"
        }
    }
}

// MARK: - 账号信息
struct AccountInfo {
    var brand: String
    var username: String?
    var expiredAt: String?
    var hasToken: Bool
}

// MARK: - 签到结果
struct CheckinResult {
    var success: Bool
    var code: Int
    var checkedIn: Bool
    var already: Bool = false
    var username: String?
    var base: Int?
    var extra: Int?
    var message: String = ""
    var brand: String
    var displayText: String?   // ZCode 等自定义展示文案
    var hasClaimable: Bool = false
    var retryAfterAt: Int64 = 0  // ZCode 1005 补货时间（unix 秒）

    static func fail(_ code: Int, _ message: String, _ brand: String) -> CheckinResult {
        CheckinResult(success: false, code: code, checkedIn: false, already: false,
                      username: nil, base: nil, extra: nil, message: message, brand: brand)
    }
}

// MARK: - 聚合状态（供菜单栏图标着色）
enum AggregateStatus {
    case allDone    // 三平台全部完成
    case error      // 有平台异常/未授权
    case pending    // 进行中 / 待授权 / 未配置
    case idle       // 尚未运行
}
