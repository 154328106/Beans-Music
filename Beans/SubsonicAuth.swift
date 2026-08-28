import Foundation

/// 一台 Subsonic 服务器的配置。
struct SubsonicServer: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    /// 形如 http://192.168.1.10:4000，末尾不带斜杠
    var server: String = ""
    var username: String = ""
    var password: String = ""
    /// 认证方式，见 SubsonicAuth.Mode；空串表示还没探测过
    var mode: String = ""
    /// 该服务器的封面接口是否可用（实测有的实现会对已认证请求回 403）
    var coversSupported: Bool = true

    var displayName: String {
        if !name.isEmpty { return name }
        if let host = URL(string: server)?.host { return host }
        return server
    }
}

/// 多台 Subsonic 服务器的管理（Navidrome / 道理鱼音乐 / gonic / Airsonic…）。
///
/// 与网易云那三家不同：这里连的是**用户自己的服务器**，没有第三方登录流程，
/// 就是「地址 + 用户名 + 密码」，而且可以存多台随时切换。
/// 明文密码只留在本机 UserDefaults。
final class SubsonicAuth: ObservableObject {
    static let shared = SubsonicAuth()

    @Published private(set) var servers: [SubsonicServer] = []
    @Published private(set) var currentID: String = ""

    private let defaults = UserDefaults.standard
    private let listKey = "beans.subsonic.servers.v2"
    private let currentKey = "beans.subsonic.current.v2"
    private let legacyKey = "beans.subsonic.auth.v1"

    enum Mode: String {
        /// `t=md5(密码+salt)` + `s=salt`，密码不上网，官方推荐（Navidrome 支持）
        case token
        /// `p=enc:<hex>`，老式；实测「道理鱼音乐」只认这套，用 token 会回
        /// `code 41: Token-based authentication is not supported`
        case password
    }

    private init() {
        load()
        migrateLegacyIfNeeded()
    }

    // MARK: - 当前服务器

    var current: SubsonicServer? {
        servers.first { $0.id == currentID } ?? servers.first
    }

    var isLoggedIn: Bool { current != nil }
    var serverName: String { current?.displayName ?? "" }
    var server: String { current?.server ?? "" }
    var username: String { current?.username ?? "" }
    var password: String { current?.password ?? "" }
    var mode: Mode { Mode(rawValue: current?.mode ?? "") ?? .token }
    var coversSupported: Bool { current?.coversSupported ?? true }

    // MARK: - 增删改切

    @MainActor
    @discardableResult
    func upsert(_ input: SubsonicServer) -> SubsonicServer {
        var item = input
        item.server = Self.normalizeURL(item.server)
        if let idx = servers.firstIndex(where: { $0.id == item.id }) {
            // 改了地址或账号就重新探测认证方式与封面
            if servers[idx].server != item.server || servers[idx].username != item.username {
                item.mode = ""
                item.coversSupported = true
            }
            servers[idx] = item
        } else {
            servers.append(item)
        }
        if currentID.isEmpty { currentID = item.id }
        save()
        BeansLogger.shared.log("Subsonic 服务器已保存：\(item.displayName)", level: .info)
        return item
    }

    @MainActor
    func remove(id: String) {
        servers.removeAll { $0.id == id }
        if currentID == id { currentID = servers.first?.id ?? "" }
        save()
    }

    @MainActor
    func select(id: String) {
        guard servers.contains(where: { $0.id == id }) else { return }
        currentID = id
        save()
        BeansLogger.shared.log("已切换音乐服务器：\(serverName)", level: .info)
    }

    // MARK: - 运行时探测结果（后台线程也会调）

    /// 撞到 code 41：记住这台服务器只能用老式密码认证
    func fallbackToPasswordMode() {
        guard mode != .password, let id = current?.id else { return }
        updateCurrent(id: id) { $0.mode = Mode.password.rawValue }
        BeansLogger.shared.log("服务器不支持 token 认证，已切换为密码模式", level: .info)
    }

    func setCoversSupported(_ ok: Bool) {
        guard let cur = current, cur.coversSupported != ok else { return }
        updateCurrent(id: cur.id) { $0.coversSupported = ok }
        BeansLogger.shared.log("服务器封面接口\(ok ? "可用" : "不可用，已停用封面请求")", level: .info)
    }

    private func updateCurrent(id: String, _ mutate: @escaping (inout SubsonicServer) -> Void) {
        // @Published 必须在主线程改，否则 SwiftUI 会告警
        Task { @MainActor in
            guard let i = self.servers.firstIndex(where: { $0.id == id }) else { return }
            var item = self.servers[i]
            mutate(&item)
            self.servers[i] = item
            self.save()
        }
    }

    // MARK: - 签名

    /// token 模式每次现算一组 salt，不复用，避免抓包重放
    func signedQuery() -> [URLQueryItem] {
        var items: [URLQueryItem] = [URLQueryItem(name: "u", value: username)]
        switch mode {
        case .token:
            let salt = Self.randomSalt()
            items.append(URLQueryItem(name: "t", value: Data((password + salt).utf8).md5Hex()))
            items.append(URLQueryItem(name: "s", value: salt))
        case .password:
            // enc: + 十六进制，避免密码里的特殊字符把 query 打乱
            let hex = password.utf8.map { String(format: "%02x", $0) }.joined()
            items.append(URLQueryItem(name: "p", value: "enc:" + hex))
        }
        items += [
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "Beans"),
            URLQueryItem(name: "f", value: "json"),
        ]
        return items
    }

    // MARK: - 持久化

    private func load() {
        if let data = defaults.data(forKey: listKey),
           let list = try? JSONDecoder().decode([SubsonicServer].self, from: data) {
            servers = list
        }
        currentID = defaults.string(forKey: currentKey) ?? servers.first?.id ?? ""
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: listKey)
        }
        defaults.set(currentID, forKey: currentKey)
    }

    /// 把 v1 的单服务器配置搬进列表，搬完删掉旧键
    private func migrateLegacyIfNeeded() {
        guard servers.isEmpty,
              let old = defaults.dictionary(forKey: legacyKey) as? [String: String],
              let addr = old["server"], !addr.isEmpty else { return }
        let item = SubsonicServer(
            name: old["serverName"] ?? "",
            server: addr,
            username: old["username"] ?? "",
            password: old["password"] ?? "",
            mode: old["mode"] ?? "",
            coversSupported: (old["covers"] ?? "1") != "0"
        )
        servers = [item]
        currentID = item.id
        save()
        defaults.removeObject(forKey: legacyKey)
        BeansLogger.shared.log("已把旧的单服务器配置迁移到服务器列表", level: .info)
    }

    // MARK: - 小工具

    static func normalizeURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func randomSalt() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<12).map { _ in chars.randomElement() ?? "0" })
    }
}
