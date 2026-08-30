import Foundation

struct FeiniuAlbum: Identifiable, Equatable {
    let id: String
    let name: String
    let coverURL: URL?
    let trackCount: Int
}

struct FeiniuPlaylist: Identifiable, Equatable {
    let id: String
    let name: String
    let coverURL: URL?
    let trackCount: Int
}

final class FeiniuAPI {
    static let shared = FeiniuAPI()
    private init() {}

    private var auth: FeiniuAuth { .shared }
    private let prefix = "/music/api/v1"

    enum APIError: LocalizedError {
        case notConfigured
        case invalidURL
        case invalidResponse
        case unauthorized
        case server(code: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "尚未配置飞牛音乐服务器"
            case .invalidURL: return "服务器地址无效"
            case .invalidResponse: return "飞牛音乐返回了无法解析的内容"
            case .unauthorized: return "登录已失效，请重新登录"
            case .server(let code, let message): return "飞牛音乐错误 \(code)：\(message)"
            }
        }
    }

    private func url(_ path: String, query: [URLQueryItem] = [], server: String? = nil) throws -> URL {
        let base = server ?? auth.server
        guard !base.isEmpty else { throw APIError.notConfigured }
        let cleanPath = path.hasPrefix("/") ? path : "/" + path
        guard var components = URLComponents(string: base + prefix + cleanPath) else { throw APIError.invalidURL }
        if !query.isEmpty { components.queryItems = query }
        guard let result = components.url else { throw APIError.invalidURL }
        return result
    }

    private func send(
        _ method: String = "GET",
        path: String,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil,
        authenticated: Bool = true,
        server: String? = nil,
        relayMode: Bool? = nil,
        accessCode: String? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: try url(path, query: query, server: server))
        request.httpMethod = method
        request.timeoutInterval = 20

        var headers = authenticated ? auth.requestHeaders(includeJSON: body != nil) : [:]
        if !authenticated {
            if relayMode == true { headers["Cookie"] = "mode=relay" }
            if let accessCode, !accessCode.isEmpty {
                headers["x-access-code"] = Data(accessCode.utf8).base64EncodedString()
                headers["x-access-source"] = "app"
            }
            if body != nil { headers["Content-Type"] = "application/json" }
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        let code = Self.int(json["code"], fallback: -1)
        if code == 401 { throw APIError.unauthorized }
        guard code == 0 else {
            let message = json["msg"] as? String ?? "未知错误"
            throw APIError.server(code: code, message: message)
        }
        return json
    }

    @discardableResult
    func login(_ input: FeiniuServer) async throws -> FeiniuServer {
        let normalized = FeiniuAuth.normalizeURL(input.server)
        var item = input
        item.server = normalized
        if item.deviceID.count != 32 {
            item.deviceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        let json = try await send(
            "POST",
            path: "/user/password-login",
            body: [
                "username": item.username,
                "password": Self.sha256(item.password),
                "deviceId": item.deviceID,
            ],
            authenticated: false,
            server: normalized,
            relayMode: item.relayMode,
            accessCode: item.accessCode
        )
        guard let data = json["data"] as? [String: Any],
              let token = data["userToken"] as? String, !token.isEmpty else {
            throw APIError.invalidResponse
        }
        item.token = token
        return item
    }

    func testConnection() async throws -> Int {
        let json = try await send(path: "/track/list", query: [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "size", value: "1"),
        ])
        return page(json).total
    }

    func tracks(page pageNumber: Int = 1, size: Int = 100) async throws -> [Song] {
        let json = try await send(path: "/track/list", query: pageQuery(pageNumber, size))
        return page(json).list.map(mapSong)
    }

    func search(_ keyword: String, page pageNumber: Int = 1, size: Int = 50) async throws -> [Song] {
        let json = try await send(path: "/search/track", query: [
            URLQueryItem(name: "q", value: keyword),
            URLQueryItem(name: "page", value: String(pageNumber)),
            URLQueryItem(name: "size", value: String(size)),
        ])
        return page(json).list.map(mapSong)
    }

    func albums(page pageNumber: Int = 1, size: Int = 60) async throws -> [FeiniuAlbum] {
        let json = try await send(path: "/album/list", query: pageQuery(pageNumber, size))
        return page(json).list.map { item in
            let coverID = Self.string(item["coverId"])
            return FeiniuAlbum(
                id: Self.string(item["guid"]),
                name: Self.string(item["name"], fallback: "未知专辑"),
                coverURL: coverID.isEmpty ? nil : coverURL(id: coverID),
                trackCount: Self.int(item["trackCount"])
            )
        }
    }

    func albumSongs(id: String, page pageNumber: Int = 1, size: Int = 300) async throws -> [Song] {
        let json = try await send(path: "/track/album-detail/list", query: [
            URLQueryItem(name: "albumGUID", value: id),
            URLQueryItem(name: "page", value: String(pageNumber)),
            URLQueryItem(name: "size", value: String(size)),
        ])
        return page(json).list.map(mapSong)
    }

    func playlists(page pageNumber: Int = 1, size: Int = 100) async throws -> [FeiniuPlaylist] {
        let json = try await send(path: "/playlist/list", query: pageQuery(pageNumber, size))
        return page(json).list.map { item in
            let coverID = Self.string(item["coverId"])
            return FeiniuPlaylist(
                id: Self.string(item["guid"]),
                name: Self.string(item["name"], fallback: "未知歌单"),
                coverURL: coverID.isEmpty ? nil : coverURL(id: coverID),
                trackCount: Self.int(item["trackCount"])
            )
        }
    }

    func playlistSongs(id: String, page pageNumber: Int = 1, size: Int = 300) async throws -> [Song] {
        let json = try await send(path: "/track/playlist-detail/list", query: [
            URLQueryItem(name: "playlistGUID", value: id),
            URLQueryItem(name: "page", value: String(pageNumber)),
            URLQueryItem(name: "size", value: String(size)),
        ])
        return page(json).list.map(mapSong)
    }

    func favoriteSongs(size: Int = 100) async throws -> [Song] {
        let json = try await send(path: "/favorite-track/list", query: pageQuery(1, size))
        return page(json).list.map(mapSong)
    }

    func lyrics(trackID: String) async throws -> String? {
        let json = try await send(path: "/lyric/list", query: [URLQueryItem(name: "trackGUID", value: trackID)])
        guard let data = json["data"] as? [String: Any],
              let list = data["list"] as? [[String: Any]], !list.isEmpty else { return nil }
        let preferred = data["preferred"] as? String
        let selected = preferred.flatMap { id in list.first { Self.string($0["guid"]) == id } } ?? list[0]
        return selected["content"] as? String
    }

    func reportPlay(trackID: String) async {
        _ = try? await send("POST", path: "/event/report", body: [
            "events": [[
                "eventType": "track_play",
                "occurredAt": Int(Date().timeIntervalSince1970 * 1000),
                "payload": ["trackGUID": trackID],
            ]],
        ])
    }

    func streamURL(id: String) -> URL? { try? url("/track/stream", query: [URLQueryItem(name: "guid", value: id)]) }

    func coverURL(id: String, size: Int = 800) -> URL? {
        try? url("/static/cover", query: [
            URLQueryItem(name: "coverId", value: id),
            URLQueryItem(name: "size", value: String(size)),
        ])
    }

    func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        for (field, value) in auth.requestHeaders() {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    func isFeiniuResource(_ url: URL) -> Bool {
        guard let base = URL(string: auth.server) else { return false }
        let samePort = (base.port ?? Self.defaultPort(for: base.scheme)) ==
            (url.port ?? Self.defaultPort(for: url.scheme))
        return base.scheme?.lowercased() == url.scheme?.lowercased() &&
            base.host?.lowercased() == url.host?.lowercased() &&
            samePort && url.path.hasPrefix(prefix)
    }

    private struct Page {
        let list: [[String: Any]]
        let total: Int
    }

    private func page(_ json: [String: Any]) -> Page {
        let data = json["data"] as? [String: Any] ?? [:]
        return Page(list: data["list"] as? [[String: Any]] ?? [], total: Self.int(data["total"]))
    }

    private func pageQuery(_ page: Int, _ size: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "size", value: String(size))]
    }

    private func mapSong(_ item: [String: Any]) -> Song {
        let guid = Self.string(item["guid"])
        let album = item["album"] as? [String: Any] ?? [:]
        let artists = (item["artists"] as? [[String: Any]] ?? [])
            .map { Self.string($0["name"]) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
        let coverID = Self.string(item["coverId"])
        let durationMS = Self.int(item["duration"])
        return Song(
            id: Self.stableHash(guid),
            name: Self.string(item["title"], fallback: "未知标题"),
            artists: artists,
            album: Self.string(album["name"]),
            coverURL: coverID.isEmpty ? nil : coverURL(id: coverID),
            duration: Double(durationMS) / 1000.0,
            source: .feiniu,
            fee: 0,
            feiniuId: guid
        )
    }

    private static func string(_ value: Any?, fallback: String = "") -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return fallback
    }

    private static func int(_ value: Any?, fallback: Int = 0) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? fallback }
        return fallback
    }

    private static func stableHash(_ value: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash & 0x7fff_ffff)
    }

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func sha256(_ value: String) -> String {
        let data = Data(value.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
