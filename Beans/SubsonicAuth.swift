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

    /// 每次请求现算一组 salt/token；salt 不复用，避免抓包重放
    func signedQuery() -> [URLQueryItem] {
        let salt = Self.randomSalt()
        let token = Data((password + salt).utf8).md5Hex()
        return [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "Beans"),
            URLQueryItem(name: "f", value: "json"),
        ]
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
