import Foundation

final class KugouMusicAPI {
    static let shared = KugouMusicAPI()

    private let session: URLSession
    private let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 18
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    func searchSongs(keyword: String, limit: Int = 30) async throws -> [Song] {
        var comps = URLComponents(string: "http://songsearch.kugou.com/song_search_v2")!
        comps.queryItems = [
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "platform", value: "WebFilter"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "pagesize", value: "\(limit)")
        ]
        let json = try await get(comps.url!.absoluteString)
        let data = json["data"] as? [String: Any] ?? [:]
        let list = data["lists"] as? [[String: Any]] ?? []
        return list.compactMap { song(from: $0) }
    }

    func searchArtists(keyword: String, limit: Int = 20) async throws -> [Artist] {
        let songs = try await searchSongs(keyword: keyword, limit: limit)
        var seen = Set<String>()
        return songs.compactMap { song in
            let name = song.artists.components(separatedBy: " / ").first ?? song.artists
            guard !name.isEmpty, !seen.contains(name) else { return nil }
            seen.insert(name)
            return Artist(id: "kugou-artist-\(name)", name: name, coverURL: song.coverURL, source: .kugou)
        }
    }

    func searchAlbums(keyword: String, limit: Int = 30) async throws -> [Album] {
        var comps = URLComponents(string: "http://mobilecdn.kugou.com/api/v3/search/album")!
        comps.queryItems = [
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "pagesize", value: "\(limit)")
        ]
        let json = try await get(comps.url!.absoluteString)
        let data = json["data"] as? [String: Any] ?? [:]
        let list = data["info"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            let id = Self.string(item["albumid"])
            let name = item["albumname"] as? String ?? ""
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return Album(
                id: "kugou-album-\(id)",
                name: name,
                artistName: item["singername"] as? String ?? "",
                coverURL: Self.imageURL(item["imgurl"]),
                source: .kugou,
                trackCount: item["songcount"] as? Int
            )
        }
    }

    func searchPlaylists(keyword: String, limit: Int = 30) async throws -> [Playlist] {
        var comps = URLComponents(string: "http://mobilecdn.kugou.com/api/v3/search/special")!
        comps.queryItems = [
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "platform", value: "WebFilter"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "pagesize", value: "\(limit)"),
            URLQueryItem(name: "filter", value: "0")
        ]
        let json = try await get(comps.url!.absoluteString)
        let data = json["data"] as? [String: Any] ?? [:]
        let list = data["info"] as? [[String: Any]] ?? []
        return list.compactMap { playlist(fromSpecial: $0) }
    }

    func hotKeys() async throws -> [String] {
        if let json = try? await get("http://msearch.kugou.com/api/v3/search/hot_tab?format=json"),
           let data = json["data"] as? [String: Any] {
            let list = data["info"] as? [[String: Any]] ?? data["list"] as? [[String: Any]] ?? []
            let words = list.compactMap { $0["keyword"] as? String ?? $0["word"] as? String ?? $0["name"] as? String }
            if !words.isEmpty { return Array(words.prefix(12)) }
        }
        return ["稻香", "晴天", "唯一", "他只是经过", "我们的歌", "后来", "夜曲", "起风了"]
    }

    func albumSongs(albumID: String) async throws -> [Song] {
        let cleanID = albumID.replacingOccurrences(of: "kugou-album-", with: "")
        var comps = URLComponents(string: "http://mobilecdn.kugou.com/api/v3/album/song")!
        comps.queryItems = [
            URLQueryItem(name: "albumid", value: cleanID),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "pagesize", value: "300"),
            URLQueryItem(name: "version", value: "9108"),
            URLQueryItem(name: "area_code", value: "1")
        ]
        let json = try await get(comps.url!.absoluteString)
        let data = json["data"] as? [String: Any] ?? [:]
        let list = data["info"] as? [[String: Any]] ?? []
        return list.compactMap { song(fromMobileItem: $0) }
    }

    func playlistSongs(listID: Int) async throws -> [Song] {
        var comps = URLComponents(string: "http://mobilecdn.kugou.com/api/v3/special/song")!
        comps.queryItems = [
            URLQueryItem(name: "specialid", value: "\(listID)"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "pagesize", value: "500")
        ]
        let json = try await get(comps.url!.absoluteString)
        let data = json["data"] as? [String: Any] ?? [:]
        let list = data["info"] as? [[String: Any]] ?? []
        return list.compactMap { song(fromMobileItem: $0) }
    }

    func userPlaylists() async throws -> [Playlist] {
        let auth = KugouMusicAuth.shared
        guard auth.isLoggedIn else { return [] }
        guard auth.userid > 0, !auth.token.isEmpty else {
            BeansLogger.shared.log("酷狗歌单同步跳过：登录态缺少 userid 或 token", level: .error)
            return []
        }
        BeansLogger.shared.log("酷狗歌单同步开始：userid=\(auth.userid) token=有", level: .debug)
        let requests = userPlaylistRequests(auth: auth)
        var lastError: Error?
        for req in requests {
            do {
                let json = try await json(for: req)
                let playlists = parseUserPlaylists(from: json)
                BeansLogger.shared.log("酷狗歌单同步：返回 \(playlists.count) 个", level: playlists.isEmpty ? .debug : .info)
                if !playlists.isEmpty { return playlists }
            } catch {
                lastError = error
                BeansLogger.shared.log("酷狗歌单同步接口失败：\(error.localizedDescription)", level: .debug)
            }
        }
        if let lastError { throw lastError }
        return []
    }

    private func userPlaylistRequests(auth: KugouMusicAuth) -> [URLRequest] {
        let baseItems = [
            "userid": "\(auth.userid)",
            "token": auth.token,
            "page": "1",
            "pagesize": "200",
            "total_ver": "979",
            "appid": "1005",
            "clientver": "12029",
            "clienttime": "\(Int(Date().timeIntervalSince1970))"
        ]
        let types = ["2", "1", "0"]
        return types.compactMap { type in
            var items = baseItems
            items["type"] = type
            var comps = URLComponents(string: "http://cloudlist.service.kugou.com/v7/get_all_list")!
            comps.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = comps.url else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 18
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            req.setValue("cloudlist.service.kugou.com", forHTTPHeaderField: "x-router")
            req.setValue(auth.cookieHeader, forHTTPHeaderField: "Cookie")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: items)
            return req
        }
    }

    private func parseUserPlaylists(from json: [String: Any]) -> [Playlist] {
        let root = json["data"] as? [String: Any] ?? json
        var seen = Set<Int>()
        let directKeys = [
            "info", "list", "lists", "list_info", "cloudlist", "plist",
            "list_create_list", "list_collect_list", "create_list", "collect_list",
            "special", "specials", "playlist", "playlists"
        ]
        var candidates: [[String: Any]] = []
        for key in directKeys {
            if let array = root[key] as? [[String: Any]] {
                candidates.append(contentsOf: array)
            }
        }
        candidates.append(contentsOf: Self.findArrays(in: root).flatMap { $0 })
        return candidates.compactMap { item in
            guard let playlist = playlist(fromUserItem: item), !seen.contains(playlist.id) else { return nil }
            seen.insert(playlist.id)
            return playlist
        }
    }

    func songURL(song: Song, quality: BeansAudioQuality = .current) async throws -> String? {
        let candidates = hashCandidates(for: song, quality: quality)
        for hash in candidates {
            if let url = try? await mobileSongURL(hash: hash), !url.isEmpty { return url }
            if let url = try? await trackerURL(hash: hash), !url.isEmpty { return url }
        }
        return nil
    }

    func lyric(song: Song) async throws -> String? {
        guard let hash = song.kugouHash, !hash.isEmpty else { return nil }
        var search = URLComponents(string: "http://krcs.kugou.com/search")!
        search.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "client", value: "mobi"),
            URLQueryItem(name: "duration", value: "\(Int(song.duration * 1000))"),
            URLQueryItem(name: "hash", value: hash),
            URLQueryItem(name: "album_audio_id", value: song.kugouAudioID.map(String.init) ?? "")
        ]
        let json = try await get(search.url!.absoluteString)
        let candidates = json["candidates"] as? [[String: Any]] ?? []
        guard let first = candidates.first,
              let id = first["id"],
              let accesskey = first["accesskey"] as? String else { return nil }
        var download = URLComponents(string: "http://lyrics.kugou.com/download")!
        download.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "id", value: Self.string(id)),
            URLQueryItem(name: "accesskey", value: accesskey),
            URLQueryItem(name: "fmt", value: "lrc"),
            URLQueryItem(name: "charset", value: "utf8")
        ]
        let lyricJson = try await get(download.url!.absoluteString)
        guard let encoded = lyricJson["content"] as? String,
              let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func mobileSongURL(hash: String) async throws -> String? {
        var comps = URLComponents(string: "http://m.kugou.com/app/i/getSongInfo.php")!
        comps.queryItems = [
            URLQueryItem(name: "cmd", value: "playInfo"),
            URLQueryItem(name: "hash", value: hash)
        ]
        let json = try await get(comps.url!.absoluteString, mobile: true, cookie: KugouMusicAuth.shared.cookieHeader)
        return Self.firstURL(in: json)
    }

    private func trackerURL(hash: String) async throws -> String? {
        let key = Self.md5(hash + "kgcloudv2")
        var comps = URLComponents(string: "http://trackercdn.kugou.com/i/v2/")!
        comps.queryItems = [
            URLQueryItem(name: "cdnBackup", value: "1"),
            URLQueryItem(name: "behavior", value: "download"),
            URLQueryItem(name: "pid", value: "1"),
            URLQueryItem(name: "cmd", value: "21"),
            URLQueryItem(name: "appid", value: "1001"),
            URLQueryItem(name: "hash", value: hash),
            URLQueryItem(name: "key", value: key)
        ]
        let json = try await get(comps.url!.absoluteString, mobile: true, cookie: KugouMusicAuth.shared.cookieHeader)
        return Self.firstURL(in: json)
    }

    private func hashCandidates(for song: Song, quality: BeansAudioQuality) -> [String] {
        var hashes: [String?]
        switch quality {
        case .lossless, .hires:
            hashes = [song.kugouSQHash, song.kugouHQHash, song.kugouHash]
        case .exhigh, .higher:
            hashes = [song.kugouHQHash, song.kugouHash, song.kugouSQHash]
        case .standard:
            hashes = [song.kugouHash, song.kugouHQHash, song.kugouSQHash]
        }
        var seen = Set<String>()
        return hashes.compactMap { raw in
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !value.isEmpty, !seen.contains(value) else { return nil }
            seen.insert(value)
            return value
        }
    }

    private func get(_ url: String, mobile: Bool = false, cookie: String = "") async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 18
        request.setValue(mobile ? ua : "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue(mobile ? "http://m.kugou.com/" : "https://www.kugou.com/", forHTTPHeaderField: "Referer")
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        return try await json(for: request)
    }

    private func json(for request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NetEaseError.httpStatus(http.statusCode, String(data: data.prefix(160), encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetEaseError.decoding(String(data: data.prefix(160), encoding: .utf8) ?? "")
        }
        return json
    }

    private func song(from item: [String: Any]) -> Song? {
        let hash = item["FileHash"] as? String ?? item["hash"] as? String
        guard let hash, !hash.isEmpty else { return nil }
        let id = Self.int(item["MixSongID"]) ?? Self.int(item["ID"]) ?? Self.int(item["Audioid"]) ?? abs(hash.hashValue)
        let cover = Self.imageURL(item["Image"]) ?? Self.imageURL((item["trans_param"] as? [String: Any])?["union_cover"])
        return Song(
            id: id,
            name: item["SongName"] as? String ?? item["OriSongName"] as? String ?? "",
            artists: item["SingerName"] as? String ?? "",
            album: item["AlbumName"] as? String ?? "",
            coverURL: cover,
            duration: TimeInterval(Self.int(item["Duration"]) ?? 0),
            source: .kugou,
            kugouHash: hash,
            kugouHQHash: item["HQFileHash"] as? String,
            kugouSQHash: item["SQFileHash"] as? String,
            kugouAlbumID: Self.string(item["AlbumID"]),
            kugouAudioID: Self.int(item["Audioid"]),
            fee: Self.int(item["PayType"]) ?? Self.int(item["Privilege"]) ?? 0
        )
    }

    private func song(fromMobileItem item: [String: Any]) -> Song? {
        let hash = item["hash"] as? String ?? item["FileHash"] as? String
        guard let hash, !hash.isEmpty else { return nil }
        let filename = item["filename"] as? String ?? ""
        let parts = filename.components(separatedBy: " - ")
        let artist = parts.count > 1 ? parts.dropLast().joined(separator: " - ") : ""
        let name = parts.count > 1 ? parts.last ?? filename : filename
        let trans = item["trans_param"] as? [String: Any]
        let id = Self.int(item["album_audio_id"]) ?? Self.int(item["audio_id"]) ?? abs(hash.hashValue)
        return Song(
            id: id,
            name: name,
            artists: artist,
            album: item["remark"] as? String ?? "",
            coverURL: Self.imageURL(trans?["union_cover"]),
            duration: TimeInterval(Self.int(item["duration"]) ?? 0),
            source: .kugou,
            kugouHash: hash,
            kugouHQHash: item["320hash"] as? String,
            kugouSQHash: item["sqhash"] as? String,
            kugouAlbumID: Self.string(item["album_id"]),
            kugouAudioID: Self.int(item["album_audio_id"]) ?? Self.int(item["audio_id"]),
            fee: Self.int(item["pay_type"]) ?? Self.int(item["privilege"]) ?? 0
        )
    }

    private func playlist(fromSpecial item: [String: Any]) -> Playlist? {
        guard let id = Self.int(item["specialid"]), id > 0 else { return nil }
        let name = item["specialname"] as? String ?? ""
        guard !name.isEmpty else { return nil }
        return Playlist(id: id, name: name, coverURL: Self.imageURL(item["imgurl"]), trackCount: Self.int(item["songcount"]) ?? 0, source: .kugou)
    }

    private func playlist(fromUserItem item: [String: Any]) -> Playlist? {
        let id = Self.int(item["listid"])
            ?? Self.int(item["list_id"])
            ?? Self.int(item["id"])
            ?? Self.int(item["specialid"])
            ?? Self.int(item["special_id"])
            ?? Self.int(item["global_collection_id"])
            ?? Self.int(item["collect_id"])
            ?? Self.int(item["gid"])
        guard let id, id > 0 else { return nil }
        let name = item["name"] as? String
            ?? item["listname"] as? String
            ?? item["list_name"] as? String
            ?? item["specialname"] as? String
            ?? item["special_name"] as? String
            ?? item["title"] as? String
            ?? item["filename"] as? String
            ?? ""
        guard !name.isEmpty else { return nil }
        let count = Self.int(item["count"])
            ?? Self.int(item["songcount"])
            ?? Self.int(item["song_count"])
            ?? Self.int(item["total"])
            ?? Self.int(item["songs"])
            ?? 0
        let cover = Self.imageURL(item["pic"])
            ?? Self.imageURL(item["picurl"])
            ?? Self.imageURL(item["imgurl"])
            ?? Self.imageURL(item["image"])
            ?? Self.imageURL(item["cover"])
            ?? Self.imageURL(item["cover_url"])
        return Playlist(id: id, name: name, coverURL: cover, trackCount: count, source: .kugou)
    }

    private static func imageURL(_ value: Any?) -> URL? {
        guard var text = value as? String, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "{size}", with: "400")
        text = text.replacingOccurrences(of: "/150/", with: "/400/")
        if text.hasPrefix("//") { text = "http:" + text }
        return URL(string: text)
    }

    private static func string(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let i = value as? Int { return "\(i)" }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    private static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func firstURL(in root: Any) -> String? {
        if let text = root as? String, text.hasPrefix("http") { return text }
        if let array = root as? [Any] {
            for item in array {
                if let url = firstURL(in: item) { return url }
            }
        }
        if let dict = root as? [String: Any] {
            for key in ["url", "play_url", "backup_url", "song_url", "sq_url", "hq_url"] {
                if let url = firstURL(in: dict[key] as Any), !url.isEmpty { return url }
            }
            for value in dict.values {
                if let url = firstURL(in: value) { return url }
            }
        }
        return nil
    }

    private static func findArrays(in root: Any) -> [[[String: Any]]] {
        var arrays: [[[String: Any]]] = []
        if let arr = root as? [[String: Any]] {
            arrays.append(arr)
            for item in arr {
                arrays.append(contentsOf: findArrays(in: item))
            }
        } else if let dict = root as? [String: Any] {
            for value in dict.values {
                arrays.append(contentsOf: findArrays(in: value))
            }
        }
        return arrays
    }

    private static func md5(_ text: String) -> String {
        let data = Data(text.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_MD5(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
