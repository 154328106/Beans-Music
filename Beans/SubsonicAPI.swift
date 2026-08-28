import Foundation

/// Subsonic 协议客户端（Navidrome / 道理鱼音乐 / gonic / Airsonic 等自建服务通用）。
///
/// 与其他三家平台的关键差异：
/// 1. **播放地址是直链**——`/rest/stream.view?id=xxx` 直接出音频流，
///    不需要像 QQ/酷狗那样先异步换 vkey，所以 PlayerManager 里那条分支是最简单的。
/// 2. **id 是字符串**（如 `ec6ae4c0…`），而 `Song.id` 是 Int，
///    所以真实 id 存在 `subsonicId` 字段里，`Song.id` 用稳定哈希填（见 `stableHash`）。
///
/// ⚠️ JSON 形状有两种：标准 Subsonic 是属性平铺
/// `{"subsonic-response":{"status":"ok",…}}`，
/// 而某些实现（实测「道理鱼音乐」）是 XML→JSON 转换出来的嵌套形状
/// `{"subsonic-response":{"_attributes":{"status":"ok",…}}}`。
/// `normalize(_:)` 会把后者拍平，两种都能吃。
final class SubsonicAPI {
    static let shared = SubsonicAPI()
    private init() {}

    private var auth: SubsonicAuth { SubsonicAuth.shared }

    enum SubsonicError: LocalizedError {
        case notConfigured
        case badResponse
        case server(code: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "尚未配置音乐服务器"
            case .badResponse: return "服务器返回了无法解析的内容"
            case .server(let code, let message): return "服务器错误 \(code)：\(message)"
            }
        }
    }

    // MARK: - 请求

    private func makeURL(_ endpoint: String, _ extra: [URLQueryItem] = []) -> URL? {
        guard !auth.server.isEmpty else { return nil }
        guard var comps = URLComponents(string: auth.server + "/rest/" + endpoint) else { return nil }
        comps.queryItems = auth.signedQuery() + extra
        return comps.url
    }

    /// 发一次请求并返回**已拍平**的 `subsonic-response` 字典
    private func request(_ endpoint: String, _ extra: [URLQueryItem] = []) async throws -> [String: Any] {
        guard let url = makeURL(endpoint, extra) else { throw SubsonicError.notConfigured }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = raw["subsonic-response"] as? [String: Any],
              let flat = Self.normalize(body) as? [String: Any] else {
            throw SubsonicError.badResponse
        }
        if (flat["status"] as? String) == "failed" {
            let err = flat["error"] as? [String: Any] ?? [:]
            let code = (err["code"] as? Int) ?? Int((err["code"] as? String) ?? "") ?? -1
            let msg = (err["message"] as? String) ?? "未知错误"
            throw SubsonicError.server(code: code, message: msg)
        }
        return flat
    }

    /// 把 `_attributes` / `_text` 这类 XML→JSON 包装递归拍平；标准形状原样返回
    private static func normalize(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict where k != "_attributes" && k != "_text" {
                out[k] = normalize(v)
            }
            if let attrs = dict["_attributes"] as? [String: Any] {
                for (k, v) in attrs { out[k] = normalize(v) }
            }
            if let text = dict["_text"], out.isEmpty { return text }
            return out
        }
        if let arr = value as? [Any] { return arr.map { normalize($0) } }
        return value
    }

    /// 某些实现单元素时给对象、多元素时给数组，统一成数组
    private static func asArray(_ value: Any?) -> [[String: Any]] {
        if let arr = value as? [[String: Any]] { return arr }
        if let one = value as? [String: Any] { return [one] }
        return []
    }

    private static func int(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) ?? 0 }
        if let d = v as? Double { return Int(d) }
        return 0
    }

    private static func str(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let i = v as? Int { return String(i) }
        return ""
    }

    /// 进程间稳定的哈希（FNV-1a）。**不能用 Swift 的 hashValue**——它每次启动加盐，
    /// 会导致收藏/历史里的 Song.id 换一次进程就对不上。
    static func stableHash(_ s: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return Int(h & 0x7fff_ffff)
    }

    // MARK: - 直链（不需要请求，拼出来就能用）

    /// 播放直链：AVPlayer 直接吃这个 URL
    func streamURL(id: String) -> URL? {
        makeURL("stream.view", [URLQueryItem(name: "id", value: id)])
    }

    /// 封面直链
    func coverURL(id: String, size: Int = 512) -> URL? {
        guard !id.isEmpty else { return nil }
        return makeURL("getCoverArt.view", [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "size", value: String(size)),
        ])
    }

    // MARK: - 映射

    private func mapSong(_ d: [String: Any]) -> Song {
        let sid = Self.str(d["id"])
        let coverId = Self.str(d["coverArt"]).isEmpty ? sid : Self.str(d["coverArt"])
        return Song(
            id: Self.stableHash(sid),
            name: Self.str(d["title"]),
            artists: Self.str(d["artist"]),
            album: Self.str(d["album"]),
            coverURL: coverURL(id: coverId),
            duration: TimeInterval(Self.int(d["duration"])),
            source: .subsonic,
            fee: 0,
            subsonicId: sid
        )
    }

    // MARK: - 接口

    /// 连通性 + 凭据校验；失败会抛出带原因的错误，供设置页直接展示
    func ping() async throws -> String {
        let r = try await request("ping.view")
        return Self.str(r["version"])
    }

    /// 搜索（歌曲）
    func search(_ keyword: String, count: Int = 50, offset: Int = 0) async throws -> [Song] {
        let r = try await request("search3.view", [
            URLQueryItem(name: "query", value: keyword),
            URLQueryItem(name: "songCount", value: String(count)),
            URLQueryItem(name: "songOffset", value: String(offset)),
            URLQueryItem(name: "artistCount", value: "0"),
            URLQueryItem(name: "albumCount", value: "0"),
        ])
        let result = r["searchResult3"] as? [String: Any] ?? [:]
        return Self.asArray(result["song"]).map(mapSong)
    }

    /// 服务器上的歌单列表
    func playlists() async throws -> [(id: String, name: String, count: Int, coverURL: URL?)] {
        let r = try await request("getPlaylists.view")
        let box = r["playlists"] as? [String: Any] ?? [:]
        return Self.asArray(box["playlist"]).map {
            let pid = Self.str($0["id"])
            let coverId = Self.str($0["coverArt"])
            return (
                id: pid,
                name: Self.str($0["name"]),
                count: Self.int($0["songCount"]),
                coverURL: coverId.isEmpty ? nil : coverURL(id: coverId)
            )
        }
    }

    /// 歌单内的曲目
    func playlistSongs(id: String) async throws -> [Song] {
        let r = try await request("getPlaylist.view", [URLQueryItem(name: "id", value: id)])
        let box = r["playlist"] as? [String: Any] ?? [:]
        return Self.asArray(box["entry"]).map(mapSong)
    }

    /// 专辑列表：type = newest / frequent / recent / random / alphabeticalByName
    func albums(type: String = "newest", size: Int = 50, offset: Int = 0) async throws
        -> [(id: String, name: String, artist: String, coverURL: URL?)] {
        let r = try await request("getAlbumList2.view", [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "size", value: String(size)),
            URLQueryItem(name: "offset", value: String(offset)),
        ])
        let box = r["albumList2"] as? [String: Any] ?? [:]
        return Self.asArray(box["album"]).map {
            let aid = Self.str($0["id"])
            let coverId = Self.str($0["coverArt"]).isEmpty ? aid : Self.str($0["coverArt"])
            return (
                id: aid,
                name: Self.str($0["name"]),
                artist: Self.str($0["artist"]),
                coverURL: coverURL(id: coverId)
            )
        }
    }

    /// 专辑内的曲目
    func albumSongs(id: String) async throws -> [Song] {
        let r = try await request("getAlbum.view", [URLQueryItem(name: "id", value: id)])
        let box = r["album"] as? [String: Any] ?? [:]
        return Self.asArray(box["song"]).map(mapSong)
    }

    /// 随机曲目（首页「随便听听」用）
    func randomSongs(count: Int = 50) async throws -> [Song] {
        let r = try await request("getRandomSongs.view", [URLQueryItem(name: "size", value: String(count))])
        let box = r["randomSongs"] as? [String: Any] ?? [:]
        return Self.asArray(box["song"]).map(mapSong)
    }

    /// 歌词（Subsonic 的 getLyrics 只认歌名+歌手，拿不到就返回空串）
    func lyrics(artist: String, title: String) async throws -> String {
        let r = try await request("getLyrics.view", [
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "title", value: title),
        ])
        guard let box = r["lyrics"] else { return "" }
        if let s = box as? String { return s }
        if let d = box as? [String: Any] { return Self.str(d["value"]) }
        return ""
    }
}
