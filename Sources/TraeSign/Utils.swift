import Foundation
import CommonCrypto
import CryptoKit
import Security

// MARK: - 日志
/// 同时输出到 stdout 与 ~/Library/Application Support/TraeSign/selfcheck.log
enum Log {
    static var logFileURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TraeSign", isDirectory: true)
            .appendingPathComponent("selfcheck.log")
    }

    static func write(_ items: Any..., file: String = #file, function: String = #function) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let shortFile = (file as NSString).lastPathComponent
        let msg = items.map { "\($0)" }.joined(separator: " ")
        let line = "[\(ts)] [\(shortFile):\(function)] \(msg)"
        print(line)
        if let url = logFileURL {
            do {
                let dir = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { handle.closeFile() }
                    handle.seekToEndOfFile()
                    handle.write(Data((line + "\n").utf8))
                } else {
                    try line.write(to: url, atomically: true, encoding: .utf8)
                }
            } catch { /* 日志失败不应中断主流程 */ }
        }
    }
}

// MARK: - Base64 / Base64URL
enum Base64URL {
    static func decode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+")
                     .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b.count % 4) % 4
        if pad > 0 { b += String(repeating: "=", count: pad) }
        return Data(base64Encoded: b)
    }

    static func encode(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}

/// 标准 Base64 解码（Trae 存储值使用标准 base64）
func standardBase64(_ s: String) -> Data? {
    Data(base64Encoded: s)
}

// MARK: - 哈希
func sha512(_ d: Data) -> Data { Data(SHA512.hash(data: d)) }
func sha256(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }

// MARK: - 对称解密
/// AES-128-CBC / PKCS7 解密（CommonCrypto，macOS 全版本可用）
func aes128CBCDecrypt(data: Data, key: Data, iv: Data) -> Data? {
    guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
    var out = Data(count: data.count + kCCBlockSizeAES128)
    let outCapacity = out.count
    var outLen: size_t = 0
    var status: CCCryptorStatus = 0
    out.withUnsafeMutableBytes { ob in
        let s = data.withUnsafeBytes { db -> CCCryptorStatus in
            key.withUnsafeBytes { kb -> CCCryptorStatus in
                iv.withUnsafeBytes { ib -> CCCryptorStatus in
                    CCCrypt(CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            kb.baseAddress, key.count,
                            ib.baseAddress,
                            db.baseAddress, data.count,
                            ob.baseAddress, outCapacity,
                            &outLen)
                }
            }
        }
        status = s
    }
    guard status == kCCSuccess else { return nil }
    return out.prefix(Int(outLen))
}

/// AES-256-GCM 解密（CryptoKit）
func aes256GCMDecrypt(iv: Data, tag: Data, ciphertext: Data, key: SymmetricKey) -> Data? {
    guard iv.count == 12, tag.count == 16 else { return nil }
    guard let sealed = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                                             ciphertext: ciphertext,
                                             tag: tag) else { return nil }
    return try? AES.GCM.open(sealed, using: key)
}

// MARK: - JWT
enum JWT {
    /// 读取 JWT payload（第二段）为字典
    static func payload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let d = Base64URL.decode(String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d, options: [])) as? [String: Any]
    }

    static func subject(_ jwt: String) -> String? {
        guard let p = payload(jwt) else { return nil }
        if let s = p["sub"] as? String, !s.isEmpty { return s }
        if let s = p["user_id"] as? String, !s.isEmpty { return s }
        return nil
    }
}

// MARK: - JSON 取值辅助
enum J {
    static func dict(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }
    static func dict(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return dict(d)
    }
    static func str(_ d: [String: Any]?, _ key: String) -> String? {
        guard let d = d, let v = d[key] else { return nil }
        return "\(v)"
    }
    /// 依次尝试多个 key，返回第一个非空的字符串
    static func strAny(_ d: [String: Any]?, _ keys: String...) -> String? {
        guard let d = d else { return nil }
        for k in keys {
            if let v = d[k] { return "\(v)" }
        }
        return nil
    }
    static func int(_ d: [String: Any]?, _ key: String) -> Int {
        guard let d = d, let v = d[key] else { return -1 }
        return asInt(v) ?? -1
    }
    static func intAny(_ d: [String: Any]?, _ keys: String...) -> Int? {
        guard let d = d else { return nil }
        for k in keys {
            if let v = d[k], let i = asInt(v) { return i }
        }
        return nil
    }
    static func bool(_ d: [String: Any]?, _ key: String) -> Bool {
        guard let d = d, let v = d[key] else { return false }
        if let b = v as? Bool { return b }
        if let i = v as? Int { return i != 0 }
        if let s = v as? String { return s == "true" || s == "1" }
        return false
    }
    static func boolAny(_ d: [String: Any]?, _ keys: String...) -> Bool {
        guard let d = d else { return false }
        for k in keys { if d[k] != nil { return bool(d, k) } }
        return false
    }
    static func innerDict(_ d: [String: Any]?, _ key: String) -> [String: Any]? {
        guard let d = d, let v = d[key] else { return nil }
        return v as? [String: Any]
    }
    static func array(_ d: [String: Any]?, _ key: String) -> [[String: Any]]? {
        guard let d = d, let v = d[key] else { return nil }
        return v as? [[String: Any]]
    }
}

private func asInt(_ v: Any) -> Int? {
    if let i = v as? Int { return i }
    if let d = v as? Double { return Int(d) }
    if let s = v as? String, let i = Int(s) { return i }
    if let n = v as? NSNumber { return n.intValue }
    return nil
}

// MARK: - HTTP 便捷封装
struct HTTP {
    /// POST JSON，返回 (httpStatus, bodyString)。失败时 httpStatus=0
    static func post(_ url: String, headers: [String: String] = [:], body: [String: Any] = [:],
                     timeout: TimeInterval = 60) async -> (Int, String) {
        guard let u = URL(string: url) else { return (0, "") }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let data = try? JSONSerialization.data(withJSONObject: body) {
            req.httpBody = data
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (status, String(data: data, encoding: .utf8) ?? "")
        } catch {
            Log.write("HTTP POST 失败 \(url): \(error.localizedDescription)")
            return (0, "")
        }
    }

    static func get(_ url: String, headers: [String: String] = [:],
                    timeout: TimeInterval = 60) async -> (Int, String) {
        guard let u = URL(string: url) else { return (0, "") }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (status, String(data: data, encoding: .utf8) ?? "")
        } catch {
            Log.write("HTTP GET 失败 \(url): \(error.localizedDescription)")
            return (0, "")
        }
    }
}

// MARK: - 通用辅助
func formatUnits(_ units: Int) -> String {
    if units >= 100_000_000 && units % 100_000_000 == 0 { return "\(units / 100_000_000) 亿" }
    if units >= 10_000 && units % 10_000 == 0 { return "\(units / 10_000) 万" }
    return "\(units)"
}

func todayString(_ date: Date = Date()) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}
