import Foundation
import CryptoKit

// MARK: - ZCode 凭证与活动套餐领取引擎
enum ZcodeEngine {
    static let platform = "ZCode"
    static let baseURL = "https://zcode.z.ai/api/v1"
    static let appVersion = "3.14.3"
    static let encPrefix = "enc:v1:"

    static var credentialsPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".zcode/v2/credentials.json")
    }

    // MARK: 凭证解密
    /// 与 zcode CLI 一致的密钥种子：优先环境变量，否则机器信息回退
    static func resolveSecret() -> String {
        if let env = ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"], !env.isEmpty {
            return env.trimmingCharacters(in: .whitespaces)
        }
        let user = NSUserName()
        return "zcode-credential-fallback:win32:\(NSHomeDirectory()):\(user)"
    }

    /// 解密 enc:v1:<iv>.<tag>.<ct>（base64url）
    static func decrypt(_ enc: String) -> String? {
        guard enc.hasPrefix(encPrefix) else { return nil }
        let parts = enc.dropFirst(encPrefix.count).split(separator: ".")
        guard parts.count == 3 else { return nil }
        guard let iv = Base64URL.decode(String(parts[0])), iv.count == 12,
              let tag = Base64URL.decode(String(parts[1])), tag.count == 16,
              let ct = Base64URL.decode(String(parts[2])), !ct.isEmpty else { return nil }
        let key = SymmetricKey(data: sha256(Data(resolveSecret().utf8)))
        guard let plain = aes256GCMDecrypt(iv: iv, tag: tag, ciphertext: ct, key: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    static func getJwt() -> String? {
        guard let text = try? String(contentsOfFile: credentialsPath, encoding: .utf8),
              let s = J.dict(text),
              let enc = J.str(s, "zcodejwttoken"), enc.hasPrefix(encPrefix) else { return nil }
        return decrypt(enc)
    }

    static func jwtUserId(_ jwt: String) -> String? { JWT.subject(jwt) }

    // MARK: 请求头（billing 全家桶）
    static func buildHeaders(deviceMid: String, jwt: String) -> [String: String] {
        [
            "Authorization": "Bearer \(jwt)",
            "User-Agent": "ZCode/\(appVersion)",
            "X-Title": "Z Code@electron",
            "X-ZCode-App-Version": appVersion,
            "X-Platform": "win32-x64",
            "X-Release-Channel": "stable",
            "X-Client-Language": "zh-CN",
            "X-Client-Timezone": "Asia/Shanghai",
            "X-Os-Category": "windows",
            "X-Os-Version": ProcessInfo.processInfo.operatingSystemVersionString,
            "X-Device-Mid": deviceMid,
            "x-request-id": UUID().uuidString.lowercased()
        ]
    }

    // MARK: 活动套餐预览
    struct Plan {
        var planId: String
        var name: String?
        var units: Int
        var showName: String?
    }

    static func parsePreviewPlans(_ json: String) -> [Plan] {
        guard let root = J.dict(json), J.int(root, "code") == 0,
              let data = J.innerDict(root, "data"),
              let plans = J.array(data, "plans") else { return [] }
        return plans.compactMap { p -> Plan? in
            guard let id = J.str(p, "plan_id"), !id.isEmpty else { return nil }
            var plan = Plan(planId: id, name: J.str(p, "name"), units: 0, showName: nil)
            if let ents = J.array(p, "entitlements"), let e0 = ents.first {
                plan.units = J.int(ents.first != nil ? e0 : p, "grant_units")
                plan.showName = J.str(e0, "show_name")
                if plan.units == 0 { plan.units = J.int(e0, "grant_units") }
            }
            if plan.units == 0, let u = J.intAny(p, "units") { plan.units = u }
            return plan
        }
    }

    // MARK: 领取
    static func run(queryOnly: Bool) async -> CheckinResult {
        guard let jwt = getJwt() else {
            return .fail(-1, "未找到 ZCode 登录态，请先登录 ZCode 客户端或 CLI", platform)
        }
        let userId = jwtUserId(jwt)
        let deviceMid = ZcodeState.getDeviceMid()

        reportActivation(deviceMid)

        let (pStatus, pBody) = await preview(deviceMid: deviceMid, jwt: jwt)
        guard pStatus != 0 else { return .fail(-3, "网络异常：ZCode 服务不可达", platform) }
        let pCode = J.int(J.dict(pBody), "code")
        if pStatus == 401 || pCode == 401 {
            return .fail(-6, "ZCode 登录已失效，请重新登录 ZCode 客户端", platform)
        }
        if pCode != 0 { return .fail(pCode, "ZCode 服务返回错误(\(pCode))", platform) }

        let plans = parsePreviewPlans(pBody)
        let target = plans.first { !ZcodeState.isClaimed($0.planId) }

        if queryOnly {
            if target == nil {
                return CheckinResult(success: false, code: 0, checkedIn: false, already: true,
                                     username: userId, base: nil, extra: nil,
                                     message: plans.isEmpty ? "暂无可领套餐" : "暂无可领新套餐", brand: platform)
            }
            return CheckinResult(success: false, code: 0, checkedIn: false, already: false,
                                 username: userId, brand: platform,
                                 displayText: "发现可领套餐：\(target!.name ?? target!.planId)（\(formatUnits(target!.units))）",
                                 hasClaimable: true)
        }

        guard let target = target else {
            return CheckinResult(success: false, code: 0, checkedIn: false, already: true,
                                 username: userId, brand: platform, displayText: "当前无可领新套餐，无需领取")
        }
        return await claimPlan(deviceMid: deviceMid, jwt: jwt, userId: userId, plan: target)
    }

    private static func claimPlan(deviceMid: String, jwt: String, userId: String?, plan: Plan) async -> CheckinResult {
        for (idx, region) in ["sgp", "cn"].enumerated() {
            let vp: String
            do {
                vp = try await ZcodeCaptcha.shared.solve(region: region)
            } catch {
                if idx == 1 { return .fail(-4, "验证码未通过：\(error.localizedDescription)", platform) }
                continue
            }
            var headers = buildHeaders(deviceMid: deviceMid, jwt: jwt)
            headers["X-Aliyun-Captcha-Verify-Param"] = vp
            headers["Verify-Region"] = region

            let (status, body) = await HTTP.post(baseURL + "/zcode-plan/billing/claim",
                                                 headers: headers, body: ["plan_id": plan.planId])
            guard status != 0 else { return .fail(-3, "网络异常：领取请求不可达", platform) }
            guard let resp = J.dict(body) else { return .fail(-3, "响应解析失败", platform) }
            let code = J.int(resp, "code")
            let msg = J.strAny(resp, "msg", "message")

            if status == 401 || code == 401 {
                return .fail(-6, "ZCode 登录已失效，请重新登录 ZCode 客户端", platform)
            }
            if code == 0 {
                ZcodeState.markClaimed(plan.planId, name: plan.name ?? plan.planId, units: plan.units)
                History.recordSuccess(.zcode)
                return CheckinResult(success: true, code: 0, checkedIn: true,
                                     username: userId, base: plan.units, extra: nil,
                                     brand: platform,
                                     displayText: "领取成功：\(plan.name ?? plan.planId) +\(formatUnits(plan.units)) token")
            }
            if code == 3007 {
                if idx == 1 { return .fail(3007, "验证码校验失败（sgp/cn 两区均已重试）", platform) }
                continue // 换区 + 换新验证码重试
            }
            if code == 1003 {
                ZcodeState.markClaimed(plan.planId, name: plan.name ?? plan.planId, units: plan.units)
                return CheckinResult(success: false, code: 1003, checkedIn: false, already: true,
                                     username: userId, brand: platform, displayText: "该套餐已领取过")
            }
            if code == 1005 {
                let data = J.innerDict(resp, "data")
                let planData = data.flatMap { J.innerDict($0, "plan") }
                let endsAt = planData.flatMap { J.intAny($0, "ends_at") } ?? 0
                return CheckinResult(success: false, code: 1005, checkedIn: false,
                                     username: userId, brand: platform,
                                     displayText: "名额已领完" + (endsAt > 0 ? "，服务端将于补货后重试" : ""),
                                     retryAfterAt: Int64(endsAt))
            }
            if code == 1002 {
                ZcodeState.markClaimed(plan.planId, name: plan.name ?? plan.planId, units: plan.units)
                return .fail(1002, "该活动已结束", platform)
            }
            if code == 1004 {
                ZcodeState.markClaimed(plan.planId, name: plan.name ?? plan.planId, units: plan.units)
                return .fail(1004, "不符合领取条件", platform)
            }
            return .fail(code, msg ?? "领取失败", platform)
        }
        return .fail(-4, "验证码未通过", platform)
    }

    private static func preview(deviceMid: String, jwt: String) async -> (Int, String) {
        let url = baseURL + "/zcode-plan/billing/preview?app_version=\(appVersion)&platform=win32-x64"
        return await HTTP.get(url, headers: buildHeaders(deviceMid: deviceMid, jwt: jwt))
    }

    private static func reportActivation(_ deviceMid: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let body: [String: Any] = ["events": [
            ["event": "app_launch", "ts": now],
            ["event": "app_daily_active", "ts": now]
        ]]
        Task { _ = await HTTP.post(baseURL + "/event/report",
                                  headers: ["X-Device-Mid": deviceMid, "x-request-id": UUID().uuidString.lowercased()],
                                  body: body) }
    }
}
