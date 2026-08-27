import Foundation
import Security
import UIKit

final class KugouMusicAPI {
    static let shared = KugouMusicAPI()

    private let gateway = "https://gateway.kugou.com"
    private let loginBase = "https://login-user.kugou.com"
    private let userService = "https://userservice.kugou.com"
    private let appid = "3116"
    private let clientver = "11440"
    private let qrAppid = "1001"
    private let qrSrcAppid = "2919"
    private let androidSignKey = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
    private let webSignKey = "NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt"
    private let playSalt = "kgcloudv2"
    private let androidUA = "Android15-1070-11440-46-0-DiscoveryDRADProtocol-wifi"
    private let rsaPublicKeyBase64 = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDECi0Np2UR87scwrvTr72L6oO01rBbbBPriSDFPxr3Z5syug0O24QyQO8bg27+0+4kBzTBTBOZ/WWU0WryL1JSXRTXLgFVxtzIY41Pe7lPOgsfTCn5kZcvKhYKJesKnnJDNr5/abvTGf+rHG3YRwsCHcQ08/q6ifSioBszvb3QiwIDAQAB"

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 18
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    struct QRLogin: Equatable {
        let key: String
        let url: String
    }

    enum QRState: Equatable {
        case waiting
        case scanned
        case expired
        case success(String)
        case error(String)
    }

    func qrKey() async throws -> QRLogin {
        KugouMusicAuth.shared.prepareDevice()
        let qrcodeText = "https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=\(appid)&"
        let response = try await gatewayRequest(
            "/v2/qrcode",
            baseURL: loginBase,
            signType: .web,
            params: [
                "appid": qrAppid,
                "type": "1",
                "plat": "4",
                "qrcode_txt": qrcodeText,
                "srcappid": qrSrcAppid,
            ],
            headers: [
                "User-Agent": Self.browserUA,
                "x-router": "login-user.kugou.com",
            ]
        )
        let json = response.json
        let key = Self.deepString(json, names: ["qrcode", "key"])
        guard !key.isEmpty else { throw NetEaseError.unknown("酷狗二维码生成失败") }
        return QRLogin(key: key, url: "https://h5.kugou.com/apps/loginQRCode/html/index.html?qrcode=\(Self.urlEncode(key))")
    }

    func pollQR(key: String) async throws -> QRState {
        let response = try await gatewayRequest(
            "/v2/get_userinfo_qrcode",
            baseURL: loginBase,
            signType: .web,
            params: [
                "plat": "4",
                "appid": appid,
                "srcappid": qrSrcAppid,
                "qrcode": key,
            ],
            headers: [
                "User-Agent": Self.browserUA,
                "x-router": "login-user.kugou.com",
            ]
        )
        let json = response.json
        let status = Self.deepInt(json, names: ["status"])
        let token = Self.deepString(json, names: ["token", "user_token", "access_token", "key"])
        let userId = Self.deepString(json, names: ["userid", "user_id", "uid", "kugooid", "kugouid"]).filter(\.isNumber)
        guard !token.isEmpty, !userId.isEmpty else {
            if status == 2 { return .scanned }
            if status == 3 { return .expired }
            return .waiting
        }
        let nick = Self.deepString(json, names: ["nickname", "nick", "username", "user_name", "uname"])
        let avatar = Self.deepString(json, names: ["avatar", "pic", "img", "headpic", "user_pic", "userpic"])
        let vip = Self.deepInt(json, names: ["vip_type", "vipType", "viptype", "isvip", "is_vip", "vip"])
        KugouMusicAuth.shared.saveLogin(userId: userId, token: token, nickname: nick, avatar: avatar, vipType: vip)
        await registerDevice()
        return .success(nick.isEmpty ? "酷狗音乐用户 \(userId)" : nick)
    }

    func userPlaylists() async throws -> [Playlist] {
        let auth = KugouMusicAuth.shared
        guard auth.isLoggedIn else { return [] }
        let dataBody: [String: Any] = [
            "total_ver": 979,
            "type": 2,
            "page": 1,
            "pagesize": 200,
            "userid": Int(auth.userId) ?? 0,
            "token": auth.token,
        ]
        let response = try await gatewayRequest(
            "/v7/get_all_list",
            method: "POST",
            params: [
                "total_ver": "979",
                "type": "2",
                "page": "1",
                "pagesize": "200",
                "userid": auth.userId,
                "token": auth.token,
            ],
            data: dataBody,
            headers: ["x-router": "cloudlist.service.kugou.com"]
        )
        let json = response.json
        let code = Self.deepInt(json, names: ["error_code", "errcode", "code"])
        let status = Self.deepInt(json, names: ["status"])
        let raw = Self.deepArrays(json, names: ["lists", "list", "info", "data", "listinfo", "collection_list", "playlist"])
        BeansLogger.shared.log("酷狗歌单同步：status=\(status) code=\(code) 返回 \(raw.count) 个", level: .debug)
        var seen = Set<Int>()
        return raw.compactMap { item in
            guard let playlist = Self.mapPlaylist(item), !seen.contains(playlist.id) else { return nil }
            seen.insert(playlist.id)
            return playlist
        }
    }

    func playlistSongs(listID: Int) async throws -> [Song] {
        let auth = KugouMusicAuth.shared
        guard auth.isLoggedIn else { return [] }
        let pid = "\(listID)"
        var all: [[String: Any]] = []
        var page = 1
        repeat {
            let body: [String: Any] = [
                "listid": pid,
                "page": page,
                "pagesize": 200,
                "area_code": 1,
                "show_relate_goods": 0,
                "allplatform": 1,
                "show_cover": 1,
                "type": 0,
                "userid": Int(auth.userId) ?? 0,
                "token": auth.token,
            ]
            let json = try await cloudlistRequest("/v4/get_list_all_file", params: ["listid": pid, "page": "\(page)", "pagesize": "200"], data: body)
            let pageTracks = Self.deepArrays(json, names: ["songs", "songlist", "list", "info", "files", "data"])
            BeansLogger.shared.log("酷狗歌单歌曲：listid=\(pid) page=\(page) 返回 \(pageTracks.count) 首", level: .debug)
            all.append(contentsOf: pageTracks)
            if pageTracks.count < 200 { break }
            page += 1
        } while page <= 10
        return all
            .sorted { (Self.int($0["fsort"] ?? $0["sort"] ?? $0["position"]) ) < (Self.int($1["fsort"] ?? $1["sort"] ?? $1["position"])) }
            .compactMap(Self.mapTrack)
    }

    func songURL(song: Song) async throws -> String? {
        guard let hash = song.kugouHash, !hash.isEmpty else { return nil }
        return try await songURL(hash: hash, albumAudioId: song.kugouAlbumAudioId, albumId: song.kugouAlbumId)
    }

    func songURL(hash: String, albumAudioId: String?, albumId: String?) async throws -> String? {
        let auth = KugouMusicAuth.shared
        let h = hash.uppercased()
        var comps = URLComponents(string: "https://trackercdn.kugou.com/i/v2/")!
        var params: [String: String] = [
            "cmd": "26",
            "hash": h,
            "behavior": "play",
            "appid": appid,
            "pid": "2",
            "mid": auth.mid,
            "userid": auth.userId.isEmpty ? "0" : auth.userId,
            "version": clientver,
            "vipType": "\(auth.vipType)",
            "token": auth.token.isEmpty ? "0" : auth.token,
            "key": "\(h)\(playSalt)\(appid)\(auth.mid)\(auth.userId.isEmpty ? "0" : auth.userId)".kgMD5Hex,
        ]
        if let albumAudioId, !albumAudioId.isEmpty { params["album_audio_id"] = albumAudioId }
        if let albumId, !albumId.isEmpty { params["album_id"] = albumId }
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: comps.url!)
        request.setValue(androidUA, forHTTPHeaderField: "User-Agent")
        request.setValue(auth.cookieHeader, forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        var text = String(data: data, encoding: .utf8) ?? ""
        text = text.replacingOccurrences(of: "<!--KG_TAG_RES_START-->", with: "").replacingOccurrences(of: "<!--KG_TAG_RES_END-->", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        let raw = Self.deepString(json, names: ["play_url", "play_backup_url", "url", "src", "backup_url"])
        return raw.isEmpty ? nil : raw
    }

    func lyric(hash: String, duration: TimeInterval) async -> String {
        guard !hash.isEmpty else { return "" }
        var search = URLComponents(string: "http://lyrics.kugou.com/search")!
        search.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "hash", value: hash.uppercased()),
            URLQueryItem(name: "duration", value: "\(Int(duration * 1000))"),
        ]
        guard let sjson = try? await getJSON(search.url!, ua: Self.browserUA),
              let first = (sjson["candidates"] as? [[String: Any]])?.first,
              let id = first["id"], let accessKey = first["accesskey"] else { return "" }
        var download = URLComponents(string: "http://lyrics.kugou.com/download")!
        download.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "id", value: "\(id)"),
            URLQueryItem(name: "accesskey", value: "\(accessKey)"),
            URLQueryItem(name: "fmt", value: "lrc"),
            URLQueryItem(name: "charset", value: "utf8"),
        ]
        guard let djson = try? await getJSON(download.url!, ua: Self.browserUA),
              let content = djson["content"] as? String,
              let data = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: "")) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func registerDevice() async {
        let auth = KugouMusicAuth.shared
        let guid = auth.guid.isEmpty ? UUID().uuidString : auth.guid
        let dataMap: [String: Any] = [
            "availableRamSize": 4983533568,
            "availableRomSize": 48114719,
            "availableSDSize": 48114717,
            "basebandVer": "",
            "batteryLevel": 100,
            "batteryStatus": 3,
            "brand": "Redmi",
            "buildSerial": "unknown",
            "device": "marble",
            "imei": guid,
            "imsi": "",
            "manufacturer": "Xiaomi",
            "uuid": guid,
            "accelerometer": false,
            "gyroscope": false,
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dataMap),
              let aes = Self.randomLower(6),
              let encrypted = Self.aesCBCEncrypt(jsonData, password: aes),
              let pData = try? JSONSerialization.data(withJSONObject: ["aes": aes, "uid": Int(auth.userId) ?? 0, "token": auth.token]),
              let rsa = Self.rsaEncryptPKCS1(pData, publicKeyBase64: rsaPublicKeyBase64) else { return }
        do {
            let response = try await gatewayRequest(
                "/risk/v2/r_register_dev",
                baseURL: userService,
                method: "POST",
                params: ["part": "1", "platid": "1", "p": rsa.kgHexString],
                dataRaw: encrypted,
                headers: [
                    "x-router": "userservice.kugou.com",
                    "Content-Type": "application/octet-stream",
                ],
                responseAsData: true
            )
            var json: [String: Any]?
            if let parsed = try? JSONSerialization.jsonObject(with: response.rawData) as? [String: Any] {
                json = parsed
            } else if let decrypted = Self.aesCBCDecrypt(response.rawData, password: aes),
                      let parsed = try? JSONSerialization.jsonObject(with: decrypted) as? [String: Any] {
                json = parsed
            }
            let dfid = Self.deepString(json ?? [:], names: ["dfid"])
            if !dfid.isEmpty { KugouMusicAuth.shared.saveDeviceDFID(dfid) }
            BeansLogger.shared.log("酷狗设备注册：dfid=\(dfid.isEmpty ? "未返回" : "已获取")", level: .debug)
        } catch {
            BeansLogger.shared.log("酷狗设备注册失败：\(error.localizedDescription)", level: .debug)
        }
    }

    private enum SignType { case android, web }
    private struct RawResponse { let json: [String: Any]; let rawData: Data }

    private func cloudlistRequest(_ path: String, params: [String: String], data: [String: Any]) async throws -> [String: Any] {
        let auth = KugouMusicAuth.shared
        var final = baseParams()
        final["userid"] = auth.userId
        final["token"] = auth.token
        params.forEach { final[$0.key] = $0.value }
        let body = try JSONSerialization.data(withJSONObject: data)
        final["signature"] = androidSignature(params: final, data: String(data: body, encoding: .utf8) ?? "")
        let response = try await request(path, baseURL: gateway, method: body.isEmpty ? "GET" : "POST", params: final, body: body, headers: [
            "User-Agent": androidUA,
            "x-router": "cloudlist.service.kugou.com",
            "kg-rc": "1",
            "kg-thash": "5d816a0",
            "kg-rec": "1",
            "kg-rf": "B9EDA08A64250DEFFBCADDEE00F8F25F",
            "dfid": auth.dfid,
            "mid": auth.mid,
            "Content-Type": "application/json",
            "Cookie": auth.cookieHeader,
        ])
        return response.json
    }

    private func gatewayRequest(_ path: String, baseURL: String? = nil, method: String = "GET", signType: SignType = .android, params: [String: String] = [:], data: [String: Any]? = nil, dataRaw: Data? = nil, headers: [String: String] = [:], responseAsData: Bool = false) async throws -> RawResponse {
        var final = baseParams()
        params.forEach { final[$0.key] = $0.value }
        let body = try data.map { try JSONSerialization.data(withJSONObject: $0) } ?? dataRaw
        let bodyString = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        final["signature"] = signType == .web ? webSignature(params: final) : androidSignature(params: final, data: bodyString)
        var requestHeaders = [
            "User-Agent": androidUA,
            "kg-rc": "1",
            "kg-thash": "5d816a0",
            "kg-rec": "1",
            "kg-rf": "B9EDA08A64250DEFFBCADDEE00F8F25F",
            "dfid": KugouMusicAuth.shared.dfid,
            "mid": KugouMusicAuth.shared.mid,
            "clienttime": final["clienttime"] ?? "",
        ]
        if !KugouMusicAuth.shared.cookieHeader.isEmpty { requestHeaders["Cookie"] = KugouMusicAuth.shared.cookieHeader }
        headers.forEach { requestHeaders[$0.key] = $0.value }
        let response = try await request(path, baseURL: baseURL ?? gateway, method: method, params: final, body: body, headers: requestHeaders)
        if responseAsData { return response }
        return response
    }

    private func request(_ path: String, baseURL: String, method: String, params: [String: String], body: Data?, headers: [String: String]) async throws -> RawResponse {
        guard var comps = URLComponents(string: baseURL + path) else { throw NetEaseError.network }
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw NetEaseError.network }
        var request = URLRequest(url: url)
        request.httpMethod = method
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw NetEaseError.network }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return RawResponse(json: json, rawData: data)
    }

    private func baseParams() -> [String: String] {
        let auth = KugouMusicAuth.shared
        var p = [
            "dfid": auth.dfid,
            "mid": auth.mid,
            "uuid": "-",
            "appid": appid,
            "clientver": clientver,
            "clienttime": "\(Int(Date().timeIntervalSince1970))",
        ]
        if auth.isLoggedIn {
            p["token"] = auth.token
            p["userid"] = auth.userId
        }
        return p
    }

    private func androidSignature(params: [String: String], data: String) -> String {
        let body = params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined()
        return "\(androidSignKey)\(body)\(data)\(androidSignKey)".kgMD5Hex
    }

    private func webSignature(params: [String: String]) -> String {
        let body = params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined()
        return "\(webSignKey)\(body)\(webSignKey)".kgMD5Hex
    }

    private func getJSON(_ url: URL, ua: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NetEaseError.network }
        return obj
    }

    private static func mapPlaylist(_ raw: [String: Any]) -> Playlist? {
        let id = int(raw["listid"] ?? raw["id"] ?? raw["global_collection_id"] ?? raw["specialid"])
        guard id > 0 else { return nil }
        let name = string(raw["name"] ?? raw["listname"] ?? raw["list_name"] ?? raw["specialname"] ?? raw["title"])
        let cover = string(raw["pic"] ?? raw["img"] ?? raw["cover"] ?? raw["sizable_cover"] ?? raw["list_pic"]).replacingOccurrences(of: "{size}", with: "240")
        let count = int(raw["count"] ?? raw["song_count"] ?? raw["total"] ?? raw["file_count"] ?? raw["songcount"])
        return Playlist(id: id, name: name.isEmpty ? "酷狗歌单" : name, coverURL: URL(string: cover), trackCount: count, source: .kugou)
    }

    private static func mapTrack(_ raw: [String: Any]) -> Song? {
        let trans = raw["trans_param"] as? [String: Any] ?? raw["transParam"] as? [String: Any] ?? [:]
        let hash = string(raw["hash"] ?? raw["Hash"] ?? raw["file_hash"] ?? raw["FileHash"] ?? raw["audio_hash"] ?? raw["320hash"] ?? raw["128hash"] ?? raw["sqhash"] ?? trans["ogg_320_hash"] ?? trans["ogg_128_hash"])
        let albumAudioId = string(raw["album_audio_id"] ?? raw["albumAudioId"] ?? raw["audio_id"] ?? raw["audioid"] ?? raw["mixsongid"] ?? raw["songid"] ?? raw["id"])
        let stable = abs((hash.isEmpty ? albumAudioId : hash).hashValue)
        var title = clean(string(raw["songname"] ?? raw["song_name"] ?? raw["name"] ?? raw["title"]))
        var artist = clean(string(raw["singername"] ?? raw["singer_name"] ?? raw["author_name"] ?? raw["singer"] ?? raw["artist"]))
        let filename = clean(string(raw["filename"] ?? raw["FileName"]))
        if !filename.isEmpty {
            let parts = filename.components(separatedBy: " - ")
            if parts.count >= 2 {
                if artist.isEmpty { artist = clean(parts[0]) }
                if title.isEmpty || title == filename { title = clean(parts.dropFirst().joined(separator: " - ")) }
            } else if title.isEmpty {
                title = filename
            }
        }
        guard !title.isEmpty, !hash.isEmpty || !albumAudioId.isEmpty else { return nil }
        let album = string(raw["album_name"] ?? raw["albumname"] ?? raw["album"] ?? (raw["albuminfo"] as? [String: Any])?["name"])
        let cover = string(raw["pic"] ?? raw["img"] ?? raw["image"] ?? raw["cover"] ?? raw["sizable_cover"] ?? trans["union_cover"]).replacingOccurrences(of: "{size}", with: "300")
        let durRaw = double(raw["timelength"] ?? raw["time_length"] ?? raw["timelen"] ?? raw["duration"] ?? raw["interval"])
        let seconds = durRaw > 1000 ? durRaw / 1000.0 : durRaw
        return Song(
            id: stable,
            name: title,
            artists: artist,
            album: album,
            coverURL: URL(string: cover),
            duration: seconds,
            source: .kugou,
            kugouHash: hash,
            kugouAlbumAudioId: albumAudioId,
            kugouAlbumId: string(raw["album_id"] ?? raw["albumid"] ?? raw["AlbumID"] ?? raw["albumId"]),
            fee: int(raw["privilege"] ?? raw["media_privilege"] ?? raw["media_pay_type"] ?? raw["pay_type"])
        )
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: #"\.(mp3|flac|m4a|aac|ogg|wav)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deepString(_ obj: Any, names: [String]) -> String {
        if let value = deepValue(obj, names: names), let array = value as? [Any] {
            return array.first.map { string($0) } ?? ""
        }
        return string(deepValue(obj, names: names))
    }

    private static func deepInt(_ obj: Any, names: [String]) -> Int { int(deepValue(obj, names: names)) }

    private static func deepArrays(_ obj: Any, names: [String]) -> [[String: Any]] {
        var best: [[String: Any]] = []
        func walk(_ value: Any) {
            if let array = value as? [[String: Any]], array.count > best.count {
                best = array
            } else if let dict = value as? [String: Any] {
                for (key, child) in dict {
                    if names.contains(where: { $0.lowercased() == key.lowercased() }) {
                        walk(child)
                    }
                }
                if best.isEmpty {
                    dict.values.forEach(walk)
                }
            } else if let array = value as? [Any] {
                for child in array { walk(child) }
            }
        }
        walk(obj)
        return best
    }

    private static func deepValue(_ obj: Any, names: [String]) -> Any? {
        let wanted = Set(names.map { $0.lowercased() })
        func walk(_ value: Any) -> Any? {
            if let dict = value as? [String: Any] {
                for (key, child) in dict where wanted.contains(key.lowercased()) {
                    return child
                }
                for child in dict.values {
                    if let found = walk(child) { return found }
                }
            } else if let array = value as? [Any] {
                for child in array {
                    if let found = walk(child) { return found }
                }
            }
            return nil
        }
        return walk(obj)
    }

    private static func string(_ value: Any?) -> String {
        if let s = value as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    private static func int(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }

    private static func double(_ value: Any?) -> Double {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) ?? 0 }
        return 0
    }

    private static func urlEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }

    private static var browserUA: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    }

    private static func randomLower(_ length: Int) -> String? {
        let chars = Array("1234567890abcdefghijklmnopqrstuvwxyz")
        return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    private static func aesCBCEncrypt(_ data: Data, password: String) -> Data? {
        let digest = password.kgMD5Hex
        return crypt(data, op: CCOperation(kCCEncrypt), key: Data(digest.prefix(16).utf8), iv: Data(digest.suffix(16).utf8))
    }

    private static func aesCBCDecrypt(_ data: Data, password: String) -> Data? {
        let digest = password.kgMD5Hex
        return crypt(data, op: CCOperation(kCCDecrypt), key: Data(digest.prefix(16).utf8), iv: Data(digest.suffix(16).utf8))
    }

    private static func crypt(_ data: Data, op: CCOperation, key: Data, iv: Data) -> Data? {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyPtr.baseAddress, kCCKeySizeAES128, ivPtr.baseAddress, dataPtr.baseAddress, data.count, outPtr.baseAddress, out.count, &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        let outputCapacity = out.count
        out.removeSubrange(outLen..<outputCapacity)
        return out
    }

    private static func rsaEncryptPKCS1(_ data: Data, publicKeyBase64: String) -> Data? {
        guard let keyData = Data(base64Encoded: publicKeyBase64) else { return nil }
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 1024,
        ]
        guard let key = SecKeyCreateWithData(keyData as CFData, attrs as CFDictionary, nil) else { return nil }
        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, data as CFData, &error) else { return nil }
        return encrypted as Data
    }
}

private extension Data {
    var kgHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var kgMD5Hex: String { Data(utf8).md5Hex() }
}
