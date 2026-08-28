import Foundation

/// Subsonic 服务器凭据（Navidrome / 道理鱼音乐 / gonic 等自建音乐服务通用）。
///
/// 与网易云/QQ/酷狗那三家不同：这里连的是**用户自己的服务器**，
/// 没有第三方登录流程，只保存「地址 + 用户名 + 密码」三件套。
///
/// 认证走 Subsonic 官方的 salt+token 方案（`u` / `t=md5(密码+salt)` / `s=salt`），
/// 明文密码只留在本机 UserDefaults，不随请求上网。
final class SubsonicAuth: ObservableObject {
    static let shared = SubsonicAuth()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var serverName = ""

    private let defaults = UserDefaults.standard
    private let key = "beans.subsonic.auth.v1"
    private var auth: [String: String] = [:]

    private init() {
        if let saved = defaults.dictionary(forKey: key) as? [String: String] {
            auth = saved
            isLoggedIn = !(auth["server"] ?? "").isEmpty && !(auth["username"] ?? "").isEmpty
            serverName = auth["serverName"] ?? Self.hostLabel(auth["server"] ?? "")
        }
    }

    /// 形如 http://192.168.1.10:4000，末尾不带斜杠
    var server: String { (auth["server"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    var username: String { auth["username"] ?? "" }
    var password: String { auth["password"] ?? "" }

    /// 认证方式。Subsonic 有两套，服务端支持哪套并不统一：
    ///   · token    —— `t=md5(密码+salt)` + `s=salt`，密码不上网，官方推荐（Navidrome 支持）
    ///   · password —— `p=enc:<hex>`，老式，密码等于明送（实测「道理鱼音乐」只认这套，
    ///                 用 token 会回 `code 41: Token-based authentication is not supported`）
    /// 先试 token，撞 41 再自动降级并记住，避免每次都白撞一次。
    enum Mode: String {
        case token
        case password
    }

    var mode: Mode { Mode(rawValue: auth["mode"] ?? "") ?? .token }

    /// 服务器的封面接口是否可用。实测「道理鱼音乐」的 `getCoverArt` 对**已认证**请求
    /// 一律回 403（它自己的实现缺陷，Navidrome 没这问题）。连接测试时探一次，
    /// 不支持就不再为每首歌拼封面 URL，省掉一堆注定失败的请求。
    var coversSupported: Bool { (auth["covers"] ?? "1") != "0" }

    func setCoversSupported(_ ok: Bool) {
        guard coversSupported != ok else { return }
        auth["covers"] = ok ? "1" : "0"
        defaults.set(auth, forKey: key)
        BeansLogger.shared.log("Subsonic 封面接口\(ok ? "可用" : "不可用，已停用封面请求")", level: .info)
    }

    /// 撞到 code 41 时调用：记住这台服务器只能用老式密码认证
    func fallbackToPasswordMode() {
        guard mode != .password else { return }
        auth["mode"] = Mode.password.rawValue
        defaults.set(auth, forKey: key)
        BeansLogger.shared.log("Subsonic 服务器不支持 token 认证，已切换为密码模式", level: .info)
    }

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

    @MainActor
    func save(server: String, username: String, password: String, serverName: String = "") {
        var normalized = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.lowercased().hasPrefix("http://") && !normalized.lowercased().hasPrefix("https://") {
            normalized = "http://" + normalized
        }
        while normalized.hasSuffix("/") { normalized.removeLast() }
        let label = serverName.isEmpty ? Self.hostLabel(normalized) : serverName
        auth = [
            "server": normalized,
            "username": username,
            "password": password,
            "serverName": label,
            // 换服务器要重新探测认证方式与封面可用性
            "mode": Mode.token.rawValue,
            "covers": "1",
        ]
        defaults.set(auth, forKey: key)
        self.serverName = label
        isLoggedIn = !normalized.isEmpty && !username.isEmpty
        BeansLogger.shared.log("Subsonic 服务器已保存：\(label)", level: .info)
    }

    @MainActor
    func logout() {
        auth = [:]
        defaults.removeObject(forKey: key)
        isLoggedIn = false
        serverName = ""
        BeansLogger.shared.log("Subsonic 服务器已断开", level: .info)
    }

    private static func randomSalt() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<12).map { _ in chars.randomElement() ?? "0" })
    }

    /// 从 URL 里抠一个能显示的名字（拿不到就退回原串）
    private static func hostLabel(_ urlString: String) -> String {
        guard let host = URL(string: urlString)?.host else { return urlString }
        return host
    }
}
