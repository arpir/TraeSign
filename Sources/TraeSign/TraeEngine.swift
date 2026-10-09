import Foundation

// MARK: - Trae 凭证与签到引擎
/// 原版 AES-128-CBC 解密（派生逻辑与官方客户端一致，从 Node/C# 原样移植）
enum TraeEngine {
    static let statusURL = "https://api.trae.cn/trae/api/v2/ug/checkin_credits/status"
    static let claimURL  = "https://api.trae.cn/trae/api/v2/ug/checkin_credits/claim"
    static let brands = ["TRAE SOLO CN", "Trae CN", "TraeWork"]

    // 解密常量（源自官方客户端派生逻辑，无需修改）
    private static let ure: [UInt8] = [82,9,106,213,48,54,165,56,191,64,163,158,129,243,215,251,124,227,57,130,155,47,255,135,52,142,67,68,196,222,233,203,84,123,148,50,166,194,35,61,238,76,149,11,66,250,195,78,8,46,161,102,40,217,36,178,118,91,162,73,109,139,209,37]
    private static let dre: [UInt8] = [31,221,168,51,136,7,199,49,177,18,16,89,39,128,236,95,96,81,127,169,25,181,74,13,45,229,122,159,147,201,156,239,160,224,59,77,174,42,245,176,200,235,187,60,131,83,153,97,23,43,4,126,186,119,214,38,225,105,20,99,85,33,12,125]

    struct Auth {
        var brand: String
        var token: String
        var devId: String
        var username: String?
        var expiredAt: String?
        var region: String?
    }

    /// 解密 storage.json 中的 iCubeAuthInfo 加密值
    static func decrypt(_ enc: String) -> String? {
        guard let t = standardBase64(enc), t.count > 38 else { return nil }
        let key = t.subdata(in: 6..<38)                 // 32 字节
        let sha = sha512(key)                           // 64 字节
        var xor = Data(count: 64)
        for i in 0..<64 { xor[i] = ure[i] ^ dre[i] }
        var comb = Data(capacity: 128)
        comb.append(sha[0..<64])
        comb.append(xor)
        let hash = sha512(comb)                         // 64 字节
        let aesKey = hash.subdata(in: 0..<16)
        let iv = hash.subdata(in: 16..<32)
        let ct = t.subdata(in: 38..<t.count)
        guard let dec = aes128CBCDecrypt(data: ct, key: aesKey, iv: iv), dec.count >= 64 else { return nil }
        return String(data: dec.subdata(in: 64..<dec.count), encoding: .utf8)
    }

    /// 读取单个品牌的登录态文件
    static func readAuth(brand: String) -> Auth? {
        let home = NSHomeDirectory()
        let file = (home as NSString).appendingPathComponent(
            "Library/Application Support/\(brand)/User/globalStorage/storage.json")
        guard let text = try? String(contentsOfFile: file, encoding: .utf8),
              let s = J.dict(text) else { return nil }

        // 设备 ID（icube-dc）
        var dcId = ""
        for k in s.keys {
            if let r = k.range(of: #"(?<=icube-dc:)\d+$"#, options: .regularExpression) {
                dcId = String(k[r]); break
            }
        }

        var enc: String?
        for k in s.keys where k.hasPrefix("iCubeAuthInfo://icube.cloudide") { enc = s[k] as? String; break }
        guard let enc = enc else { return nil }

        if dcId.isEmpty {
            if let v = s["telemetry.devDeviceId"] as? String { dcId = v }
            else if let v = s["telemetry.machineId"] as? String { dcId = v }
        }

        guard let jsonStr = decrypt(enc),
              let parsed = J.dict(jsonStr) else { return nil }
        let token = J.str(parsed, "token") ?? ""
        guard !token.isEmpty else { return nil }

        var auth = Auth(brand: brand, token: token, devId: dcId, username: nil, expiredAt: nil, region: nil)
        if let acc = J.innerDict(parsed, "account") { auth.username = J.str(acc, "username") }
        auth.expiredAt = J.str(parsed, "expiredAt")
        if let ur = J.innerDict(parsed, "userRegion") { auth.region = J.str(ur, "region") }
        return auth
    }

    static func findAll() -> [Auth] {
        brands.compactMap { readAuth(brand: $0) }
    }

    static func find(brand: String? = nil) -> Auth? {
        if let b = brand, let a = readAuth(brand: b) { return a }
        return findAll().first
    }

    static func listAccounts() -> [AccountInfo] {
        findAll().map {
            AccountInfo(brand: $0.brand, username: $0.username, expiredAt: $0.expiredAt, hasToken: true)
        }
    }

    // MARK: 签到
    static func run(queryOnly: Bool, brand: String? = nil) async -> CheckinResult {
        guard let auth = find(brand: brand) else {
            return .fail(-1, "未找到登录态，请先运行 Trae 桌面端登录", "Trae")
        }
        var headers = [
            "Authorization": "Cloud-IDE-JWT \(auth.token)",
            "x-device-id": auth.devId
        ]
        if let region = auth.region { headers["X-User-Region"] = region }

        let (sStatus, sBody) = await HTTP.post(statusURL, headers: headers, body: [:])
        guard sStatus != 0 else { return .fail(-3, "网络异常", "Trae") }
        guard let status = J.dict(sBody) else { return .fail(-3, "响应解析失败", "Trae") }

        let base = J.intAny(status, "credits")
        let extra = J.intAny(status, "extra_credits")
        if base == nil && extra == nil {
            return .fail(-6, "账号状态异常（token 可能已过期），请重新登录该软件", "Trae")
        }
        let checkedIn = J.bool(status, "checked_in")
        if queryOnly {
            return CheckinResult(success: checkedIn, code: 0, checkedIn: checkedIn, already: checkedIn,
                                 username: auth.username, base: base, extra: extra,
                                 message: checkedIn ? "今日已签到" : "今日未签到", brand: "Trae")
        }
        if checkedIn {
            return CheckinResult(success: true, code: 0, checkedIn: true, already: true,
                                 username: auth.username, base: base, extra: extra,
                                 message: "今日已签到", brand: "Trae")
        }
        if !J.bool(status, "enable") {
            return .fail(J.int(status, "code"), "签到未开启", "Trae")
        }

        let (cStatus, cBody) = await HTTP.post(claimURL, headers: headers, body: ["req_source": 1])
        guard cStatus != 0, let claim = J.dict(cBody) else { return .fail(-3, "网络异常", "Trae") }
        let code = J.int(claim, "code")
        if code == 0 || J.bool(claim, "checked_in") {
            // 二次确认：复查状态，防 token 过期假成功
            let (_, cfBody) = await HTTP.post(statusURL, headers: headers, body: [:])
            if let confirm = J.dict(cfBody), J.bool(confirm, "checked_in") {
                History.recordSuccess(.trae)
                let cB = J.intAny(confirm, "credits") ?? base
                let cE = J.intAny(confirm, "extra_credits") ?? extra
                return CheckinResult(success: true, code: 0, checkedIn: true, already: false,
                                     username: auth.username, base: cB, extra: cE,
                                     message: "签到成功", brand: "Trae")
            }
            return .fail(-6, "签到结果异常（token 可能已过期），请重新登录该软件", "Trae")
        }
        if code == 9095 {
            return .fail(9095, "本设备今日已有账号签到（服务端限制每机每日一个账号）", "Trae")
        }
        return .fail(code, J.strAny(claim, "message") ?? "签到失败", "Trae")
    }
}
