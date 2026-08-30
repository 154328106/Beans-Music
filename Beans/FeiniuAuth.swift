import Foundation

/// 飞牛音乐服务器配置。凭据只保存在当前设备，用于 token 过期后重新登录。
struct FeiniuServer: Codable, Equatable {
    var name: String = "飞牛音乐"
    var server: String = ""
    var username: String = ""
    var password: String = ""
    var token: String = ""
    var deviceID: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var accessCode: String = ""
    var relayMode: Bool = false

    var displayName: String {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        return URL(string: server)?.host ?? "飞牛音乐"
    }
}

/// 飞牛音乐认证状态。服务端使用 `music-token` Cookie，而不是 Bearer Token。
final class FeiniuAuth: ObservableObject {
    static let shared = FeiniuAuth()

    @Published private(set) var config: FeiniuServer?

    private let defaults = UserDefaults.standard
    private let configKey = "beans.feiniu.server.v1"

    private init() {
        if let data = defaults.data(forKey: configKey),
           let saved = try? JSONDecoder().decode(FeiniuServer.self, from: data) {
            config = saved
            installCookies()
        }
    }

    var isConfigured: Bool {
        guard let config else { return false }
        return !config.server.isEmpty && !config.token.isEmpty
    }

    var serverName: String { config?.displayName ?? "" }
    var server: String { config?.server ?? "" }
    var username: String { config?.username ?? "" }
    var token: String { config?.token ?? "" }
    var accessCode: String { config?.accessCode ?? "" }
    var relayMode: Bool { config?.relayMode ?? false }

    @MainActor
    func save(_ server: FeiniuServer) {
        var item = server
        item.server = Self.normalizeURL(item.server)
        config = item
        persist()
        installCookies()
    }

    @MainActor
    func updateToken(_ token: String) {
        guard var item = config else { return }
        item.token = token
        config = item
        persist()
        installCookies()
    }

    @MainActor
    func remove() {
        removeCookies()
        config = nil
        defaults.removeObject(forKey: configKey)
    }

    func requestHeaders(includeJSON: Bool = false) -> [String: String] {
        var headers: [String: String] = [:]
        if !token.isEmpty {
            headers["Cookie"] = relayMode
                ? "music-token=\(token); mode=relay"
                : "music-token=\(token)"
        } else if relayMode {
            headers["Cookie"] = "mode=relay"
        }
        if !accessCode.isEmpty {
            headers["x-access-code"] = Data(accessCode.utf8).base64EncodedString()
            headers["x-access-source"] = "app"
        }
        if includeJSON { headers["Content-Type"] = "application/json" }
        return headers
    }

    private func persist() {
        guard let config, let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: configKey)
    }

    /// AsyncImage/URLSession 会从共享 Cookie 仓库读取认证信息，封面无需额外代理。
    func installCookies() {
        guard let config, let url = URL(string: config.server), let host = url.host else { return }
        removeCookies(for: host)
        let common: [HTTPCookiePropertyKey: Any] = [
            .domain: host,
            .path: "/",
            .secure: url.scheme?.lowercased() == "https" ? "TRUE" : "FALSE",
        ]
        if !config.token.isEmpty {
            var properties = common
            properties[.name] = "music-token"
            properties[.value] = config.token
            if let cookie = HTTPCookie(properties: properties) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
        if config.relayMode {
            var properties = common
            properties[.name] = "mode"
            properties[.value] = "relay"
            if let cookie = HTTPCookie(properties: properties) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }

    private func removeCookies() {
        guard let host = config.flatMap({ URL(string: $0.server)?.host }) else { return }
        removeCookies(for: host)
    }

    private func removeCookies(for host: String) {
        HTTPCookieStorage.shared.cookies?.filter {
            ($0.name == "music-token" || $0.name == "mode") &&
            (host == $0.domain || host.hasSuffix($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))))
        }.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
    }

    static func normalizeURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(
            of: #"/music/api/v1/*$"#,
            with: "",
            options: .regularExpression
        )
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "http://" + value
        }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
