import Foundation
import Security

// MARK: - 数据目录
enum Store {
    static let dataDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("TraeSign", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func file(_ name: String) -> URL { dataDir.appendingPathComponent(name) }
}

// MARK: - 签到历史（按平台/日期记录成功日）
struct History {
    private static let path = Store.file("history.json")

    /// platform -> date(yyyy-MM-dd) -> success
    private(set) static var records: [String: [String: Bool]] = load()

    static func load() -> [String: [String: Bool]] {
        let url = Store.file("history.json")
        guard let d = try? Data(contentsOf: url) else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Bool]] else { return [:] }
        return obj
    }

    static func save() {
        guard let d = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted]) else { return }
        try? d.write(to: path, options: .atomic)
    }

    static func recordSuccess(_ platform: Platform, date: String = todayString()) {
        var byDate = records[platform.rawValue] ?? [:]
        byDate[date] = true
        records[platform.rawValue] = byDate
        save()
    }

    /// 指定月份的成功日集合（key: yyyy-MM-dd）
    static func successDays(_ platform: Platform, year: Int, month: Int) -> Set<String> {
        guard let byDate = records[platform.rawValue] else { return [] }
        return Set(byDate.filter { $0.value }.map { $0.key }.filter {
            $0.hasPrefix(String(format: "%04d-%02d-", year, month))
        })
    }
}

// MARK: - ZCode 本地状态（device_mid + 已领套餐去重）
struct ZcodeState {
    struct Claimed: Codable { var plan_id: String; var name: String; var units: Int; var ts: Int64 }
    struct Persisted: Codable { var device_mid: String? = nil; var claimed: [Claimed] = [] }

    private static let path = Store.file("zcode_state.json")
    private static var cached: Persisted = load()

    static func load() -> Persisted {
        let url = Store.file("zcode_state.json")
        guard let d = try? Data(contentsOf: url) else { return Persisted() }
        guard let obj = try? JSONDecoder().decode(Persisted.self, from: d) else { return Persisted() }
        return obj
    }

    static func save() {
        guard let d = try? JSONEncoder().encode(cached) else { return }
        try? d.write(to: path, options: .atomic)
    }

    static func getDeviceMid() -> String {
        if let mid = cached.device_mid, !mid.isEmpty { return mid }
        let mid = UUID().uuidString.lowercased()
        cached.device_mid = mid
        save()
        return mid
    }

    static func isClaimed(_ planId: String) -> Bool {
        cached.claimed.contains { $0.plan_id == planId }
    }

    static func markClaimed(_ planId: String, name: String, units: Int) {
        guard !isClaimed(planId) else { return }
        cached.claimed.append(Claimed(plan_id: planId, name: name, units: units,
                                      ts: Int64(Date().timeIntervalSince1970)))
        if cached.claimed.count > 200 { cached.claimed.removeFirst(cached.claimed.count - 200) }
        save()
    }
}

// MARK: - WorkBuddy Token（存于 macOS Keychain，等价于原版 DPAPI 绑定当前用户）
struct WbTokenStore {
    static let service = "com.traesign.macos"
    static let account = "workbuddy.token"

    struct Token: Codable {
        var uid: String?
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Int64        // ms epoch，0=未知
        var refreshExpiresAt: Int64  // ms epoch，0=未知
        var savedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    }

    static func save(_ t: Token) {
        guard let data = try? JSONEncoder().encode(t) else { return }
        _ = delete()
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load() -> Token? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let t = try? JSONDecoder().decode(Token.self, from: data) else { return nil }
        return t
    }

    @discardableResult
    static func delete() -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(q as CFDictionary) == errSecSuccess
    }
}
