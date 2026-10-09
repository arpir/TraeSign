import Foundation
import SwiftUI

// MARK: - 单平台状态
enum StatusLevel: Equatable {
    case idle      // 尚未运行
    case pending   // 进行中 / 待授权 / 未配置
    case done      // 今日已完成
    case error     // 异常 / 未授权 / 失败
}

struct PState: Equatable {
    var account: String? = nil
    var message: String = "未运行"
    var checkedIn: Bool = false
    var creditsText: String? = nil
    var enabled: Bool = true
    var lastRun: String? = nil
    var note: String? = nil
    var level: StatusLevel = .idle
}

// MARK: - 全局可观察状态
@MainActor
final class AppState: ObservableObject {
    @Published var trae = PState()
    @Published var workbuddy = PState()
    @Published var zcode = PState()

    @Published var traeBrand: String? = nil
    @Published var traeAccounts: [AccountInfo] = []
    @Published var busy: Bool = false
    /// 日历版本号：每次签到成功后自增，驱动日历视图重建
    @Published var calendarVersion: Int = 0

    func level(for p: Platform) -> StatusLevel {
        switch p {
        case .trae: return trae.level
        case .workbuddy: return workbuddy.level
        case .zcode: return zcode.level
        }
    }

    /// 聚合状态（托盘图标着色）
    var aggregate: AggregateStatus {
        let levels = Platform.allCases.map { level(for: $0) }
        if levels.contains(.error) { return .error }
        if levels.allSatisfy({ $0 == .done }) && !levels.contains(.idle) { return .allDone }
        if levels.contains(.idle) && levels.allSatisfy({ $0 == .idle || $0 == .pending }) { return .idle }
        return .pending
    }

    func formattedNow() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    // MARK: 供 Coordinator / View 取用
    func isEnabled(_ p: Platform) -> Bool {
        switch p { case .trae: return trae.enabled; case .workbuddy: return workbuddy.enabled; case .zcode: return zcode.enabled }
    }
    func currentAccount(_ p: Platform) -> String? {
        switch p { case .trae: return trae.account; case .workbuddy: return workbuddy.account; case .zcode: return zcode.account }
    }
}
