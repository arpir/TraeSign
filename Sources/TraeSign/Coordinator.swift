import Foundation
import UserNotifications

// MARK: - 调度协调器
/// 负责调用各平台引擎、把结果落到 AppState、发送通知。
/// 引擎调用可在后台执行；所有对 AppState 的写入都切回主线程。
final class Coordinator: ObservableObject {
    let state: AppState

    init(state: AppState) {
        self.state = state
        requestNotificationAuth()
    }

    // MARK: 手动 / 自动 签到
    @discardableResult
    func refresh(_ platform: Platform, queryOnly: Bool = false) async -> CheckinResult {
        await MainActor.run { state.busy = true }
        let result: CheckinResult
        switch platform {
        case .trae:
            result = await TraeEngine.run(queryOnly: queryOnly, brand: state.traeBrand)
        case .workbuddy:
            result = await WorkbuddyEngine.run(queryOnly: queryOnly)
        case .zcode:
            result = await ZcodeEngine.run(queryOnly: queryOnly)
        }
        await MainActor.run { apply(platform, result) }
        await MainActor.run { state.busy = false }
        return result
    }

    func refreshAll(queryOnly: Bool = false) async {
        for p in Platform.allCases {
            _ = await refresh(p, queryOnly: queryOnly)
        }
    }

    // MARK: WorkBuddy 授权（OAuth）
    func authorizeWorkbuddy() async {
        await MainActor.run {
            state.workbuddy.message = "请在浏览器中完成腾讯 SSO 确认…"
            state.workbuddy.level = .pending
        }
        do {
            let token = try await WorkbuddyEngine.startOAuth()
            let uid = token.uid ?? "已授权"
            await MainActor.run {
                state.workbuddy.account = uid
                state.workbuddy.message = "授权成功，可开始签到"
                state.workbuddy.level = .pending
            }
            notify(title: "WorkBuddy 授权成功", body: "已获取签到凭证，将自动每日签到")
            _ = await refresh(.workbuddy)
        } catch {
            await MainActor.run {
                state.workbuddy.message = "授权失败：\(error.localizedDescription)"
                state.workbuddy.level = .error
            }
            notify(title: "WorkBuddy 授权失败", body: error.localizedDescription)
        }
    }

    // MARK: 启动时扫描（仅查询状态）
    func initialScan() async {
        await MainActor.run {
            state.traeAccounts = TraeEngine.listAccounts()
            if let first = state.traeAccounts.first { state.traeBrand = first.brand }
        }
        _ = await refresh(.trae, queryOnly: true)
        _ = await refresh(.workbuddy, queryOnly: true)
        _ = await refresh(.zcode, queryOnly: true)
    }

    // MARK: 结果映射
    @MainActor private func apply(_ platform: Platform, _ r: CheckinResult) {
        let now = state.formattedNow()
        let s = PState(
            account: r.username ?? state.currentAccount(platform),
            message: r.displayText ?? r.message,
            checkedIn: r.checkedIn,
            creditsText: creditsText(r),
            enabled: state.isEnabled(platform),
            lastRun: now,
            note: noteText(r),
            level: levelOf(r)
        )
        switch platform {
        case .trae: state.trae = s
        case .workbuddy: state.workbuddy = s
        case .zcode: state.zcode = s
        }
        state.calendarVersion += 1

        // 通知：仅对“成功领取/签到”与“异常”做提示，避免刷屏
        if r.success {
            notify(title: "\(platform.rawValue) 成功", body: r.displayText ?? r.message)
        } else if r.code == -6 || r.code == -1 {
            notify(title: "\(platform.rawValue) 需要关注", body: r.message)
        }
    }

    private func creditsText(_ r: CheckinResult) -> String? {
        switch r.brand {
        case "Trae":
            if let b = r.base, let e = r.extra {
                return "积分 \(b) / 额外 \(e)"
            } else if let b = r.base { return "积分 \(b)" }
            return nil
        case "WorkBuddy":
            if let c = r.base { return "今日积分 \(c)" }
            return nil
        case "ZCode":
            if let d = r.displayText { return d }
            return nil
        default: return nil
        }
    }

    private func noteText(_ r: CheckinResult) -> String? {
        if r.retryAfterAt > 0 {
            return "名额领完，将于补货后自动重试"
        }
        return nil
    }

    private func levelOf(_ r: CheckinResult) -> StatusLevel {
        if r.code == -1 || r.code == -6 { return .error }
        if r.success || r.checkedIn { return .done }
        if r.code == 1005 || r.code == 1003 || r.code == 1002 || r.code == 1004 { return .pending }
        if r.code != 0 { return .error }
        return .pending
    }

    // MARK: 通知
    private func requestNotificationAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
