import Foundation
import AppKit

// MARK: - WorkBuddy 凭证与签到引擎
/// 采用官方插件 OAuth 授权流获取签到凭证（macOS 无 DPAPI，token 存于 Keychain）
enum WorkbuddyEngine {
    static let platform = "WorkBuddy"
    static let domains = ["https://www.workbuddy.cn", "https://www.codebuddy.cn"]
    static let statePath = "/v2/plugin/auth/state?platform=workbuddy"
    static let tokenPath = "/v2/plugin/auth/token?state="
    static let refreshURL = "https://copilot.tencent.com/v2/plugin/auth/token/refresh"
    static let statusPath = "/v2/billing/meter/checkin-activity-status"
    static let claimPath  = "/v2/billing/meter/daily-checkin"

    struct Token {
        var uid: String?
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Int64
        var refreshExpiresAt: Int64
    }

    // MARK: 取可用 token（Keychain 优先，过期自动续期）
    static func getWorkingToken() async -> Token? {
        guard let t = WbTokenStore.load() else { return nil }
        if !isExpired(t.expiresAt) { return fromStore(t) }
        if t.refreshToken != nil, !isExpired(t.refreshExpiresAt),
           let nr = await tryRefresh(fromStore(t)) {
            return nr
        }
        return nil
    }

    private static func fromStore(_ t: WbTokenStore.Token) -> Token {
        Token(uid: t.uid, accessToken: t.accessToken, refreshToken: t.refreshToken,
              expiresAt: t.expiresAt, refreshExpiresAt: t.refreshExpiresAt)
    }

    static func isExpired(_ ms: Int64) -> Bool {
        guard ms > 0 else { return false }
        return Date().timeIntervalSince1970 * 1000 >= Double(ms)
    }

    /// refreshToken 滚动轮换，成功后回写 Keychain
    static func tryRefresh(_ current: Token) async -> Token? {
        guard let rt = current.refreshToken else { return nil }
        var headers = [
            "X-Refresh-Token": rt,
            "X-Auth-Refresh-Source": "plugin"
        ]
        if !current.accessToken.isEmpty { headers["Authorization"] = "Bearer \(current.accessToken)" }
        if let uid = current.uid { headers["X-User-Id"] = uid }

        let (status, body) = await HTTP.post(refreshURL, headers: headers, body: [:])
        guard status != 0, let d = J.dict(body), J.int(d, "code") == 0,
              let data = J.innerDict(d, "data"),
              let at = J.strAny(data, "accessToken", "access_token"), !at.isEmpty else { return nil }
        let rt2 = J.strAny(data, "refreshToken", "refresh_token") ?? current.refreshToken
        var nr = Token(uid: current.uid ?? JWT.subject(at), accessToken: at, refreshToken: rt2,
                       expiresAt: 0, refreshExpiresAt: current.refreshExpiresAt)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // 兼容 expiresIn / expires_in 两种命名
        let expIn = J.intAny(data, "expiresIn") ?? (J.intAny(data, "expires_in") ?? 0)
        nr.expiresAt = expIn > 0 ? now + Int64(expIn) * 1000 : 0
        let rExpIn = J.intAny(data, "refreshExpiresIn") ?? (J.intAny(data, "refresh_expires_in") ?? 0)
        nr.refreshExpiresAt = rExpIn > 0 ? now + Int64(rExpIn) * 1000 : current.refreshExpiresAt
        WbTokenStore.save(WbTokenStore.Token(uid: nr.uid, accessToken: nr.accessToken,
                                             refreshToken: nr.refreshToken,
                                             expiresAt: nr.expiresAt, refreshExpiresAt: nr.refreshExpiresAt))
        return nr
    }

    // MARK: OAuth 授权（一次性，浏览器确认）
    /// 打开浏览器并轮询换 token（最长约 3 分钟）。完成后写入 Keychain。
    static func startOAuth() async throws -> Token {
        let (sStatus, sBody) = await HTTP.post(domains[0] + statePath, body: [:])
        guard sStatus != 0, let d = J.dict(sBody), let data = J.innerDict(d, "data"),
              let state = J.str(data, "state"), let authUrl = J.str(data, "authUrl"),
              !state.isEmpty, !authUrl.isEmpty else {
            throw NSError(domain: "WorkbuddyEngine", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "授权服务响应异常（HTTP \(sStatus)）"])
        }
        if let url = URL(string: authUrl) { NSWorkspace.shared.open(url) }

        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let (tStatus, tBody) = await HTTP.get(domains[0] + tokenPath + state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)
            guard tStatus != 0, let td = J.dict(tBody) else { continue }
            let code = J.int(td, "code")
            if code == 11217 { continue } // 等待用户在浏览器确认
            if code != 0 {
                throw NSError(domain: "WorkbuddyEngine", code: code,
                              userInfo: [NSLocalizedDescriptionKey: "授权失败(\(code))：\(J.strAny(td, "msg", "message") ?? "")"])
            }
            guard let tdata = J.innerDict(td, "data"),
                  let at = J.strAny(tdata, "accessToken", "access_token"), !at.isEmpty else { continue }
            let rt = J.strAny(tdata, "refreshToken", "refresh_token")
            let nested = J.innerDict(tdata, "auth") ?? J.innerDict(tdata, "token")
            let at2 = at.count > 0 ? at : (nested.flatMap { J.strAny($0, "accessToken", "access_token") } ?? "")
            let rt2 = rt ?? nested.flatMap { J.strAny($0, "refreshToken", "refresh_token") }
            let uid = J.strAny(tdata, "uid", "userId") ?? JWT.subject(at2)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let expIn = J.intAny(tdata, "expiresIn") ?? (J.intAny(tdata, "expires_in") ?? 0)
            let rExpIn = J.intAny(tdata, "refreshExpiresIn") ?? (J.intAny(tdata, "refresh_expires_in") ?? 0)
            let token = Token(uid: uid, accessToken: at2, refreshToken: rt2,
                             expiresAt: expIn > 0 ? now + Int64(expIn) * 1000 : 0,
                             refreshExpiresAt: rExpIn > 0 ? now + Int64(rExpIn) * 1000 : 0)
            WbTokenStore.save(WbTokenStore.Token(uid: token.uid, accessToken: token.accessToken,
                                                refreshToken: token.refreshToken,
                                                expiresAt: token.expiresAt, refreshExpiresAt: token.refreshExpiresAt))
            return token
        }
        throw NSError(domain: "WorkbuddyEngine", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "授权超时：未在 3 分钟内完成浏览器确认"])
    }

    // MARK: 签到
    static func run(queryOnly: Bool) async -> CheckinResult {
        guard var auth = await getWorkingToken() else {
            return .fail(-1, "未授权：请在 WorkBuddy 页签点击“登录授权”完成一次浏览器登录", platform)
        }
        let (sStatus, sBody) = await postBilling(statusPath, token: &auth)
        guard sStatus != 0 else { return .fail(-3, "网络异常：主备域名均不可达", platform) }
        guard let status = J.dict(sBody) else { return .fail(-3, "响应解析失败", platform) }
        let code = J.int(status, "code")
        if sStatus == 401 || isAuthCode(code) {
            return .fail(-6, "登录已失效且自动续期失败，请重新授权", platform)
        }
        if code != 0 {
            return .fail(code, J.strAny(status, "msg", "message") ?? "状态查询失败", platform)
        }
        guard let data = J.innerDict(status, "data") else {
            return .fail(-6, "状态响应异常（可能未授权或接口已变化）", platform)
        }
        let checkedIn = J.boolAny(data, "todayCheckedIn", "today_checked_in")
        let todayCredit = J.intAny(data, "todayCredit", "today_credit", "dailyCredit", "daily_credit")

        if queryOnly || checkedIn {
            return CheckinResult(success: checkedIn, code: 0, checkedIn: checkedIn, already: checkedIn,
                                 username: auth.uid, base: todayCredit, extra: nil,
                                 message: checkedIn ? "今日已签到" : "今日未签到", brand: platform)
        }

        let (cStatus, cBody) = await postBilling(claimPath, token: &auth)
        guard cStatus != 0 else { return .fail(-3, "网络异常：主备域名均不可达", platform) }
        guard let claim = J.dict(cBody) else { return .fail(-3, "响应解析失败", platform) }
        let ccode = J.int(claim, "code")
        let cmsg = J.strAny(claim, "msg", "message")
        if cStatus == 401 || isAuthCode(ccode) {
            return .fail(-6, "登录已失效且自动续期失败，请重新授权", platform)
        }
            if ccode == 0 || ccode == 10001 || (cmsg?.contains("已签到") ?? false) {
                let cdata = J.innerDict(claim, "data")
                let credit = cdata.flatMap { J.intAny($0, "credit", "todayCredit", "today_credit") }
                let (cStatus, cBody) = await postBilling(statusPath, token: &auth)
                let confirm = (cStatus != 0) ? J.dict(cBody) : nil
                let cdata2 = (J.int(confirm, "code") == 0) ? J.innerDict(confirm, "data") : nil
            let confirmed = cdata2.map { J.boolAny($0, "todayCheckedIn", "today_checked_in") } ?? false
            if !confirmed && ccode != 10001 {
                return .fail(-6, "签到结果异常（未确认到已签到状态）", platform)
            }
            let finalCredit = credit ?? cdata2.flatMap { J.intAny($0, "todayCredit", "today_credit", "dailyCredit", "daily_credit") } ?? todayCredit
            History.recordSuccess(.workbuddy)
            return CheckinResult(success: true, code: 0, checkedIn: true, already: ccode == 10001,
                                 username: auth.uid, base: finalCredit, extra: nil,
                                 message: ccode == 10001 ? "今日已签到" : "签到成功", brand: platform)
        }
        if ccode == 41000 { return .fail(41000, "签到活动未开始或已结束", platform) }
        return .fail(ccode, cmsg ?? "签到失败", platform)
    }

    // MARK: 主备域名回退（带 X-Domain 头）
    private static func postBilling(_ path: String, token: inout Token) async -> (Int, String) {
        for domain in domains {
            var headers = ["Authorization": "Bearer \(token.accessToken)",
                           "X-Domain": domain.replacingOccurrences(of: "https://", with: "")]
            if let uid = token.uid { headers["X-User-Id"] = uid }
            let (status, body) = await HTTP.post(domain + path, headers: headers, body: [:])
            if status != 0 { return (status, body) }
        }
        return (0, "")
    }

    private static func isAuthCode(_ code: Int) -> Bool {
        code == 401 || code == 40100 || code == 12153
    }
}
