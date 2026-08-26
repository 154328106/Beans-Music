import Foundation

/// 灰色歌曲 / VIP 试听解锁：仅使用用户导入的自定义音源（JSON 配置 / 落雪 API 服务器）
/// 由 PlayerManager 在网易云 / QQ 无完整 URL 时自动调用。
enum UnblockService {
    struct Resolved {
        let url: URL
        let source: String

        var sourceTitle: String { source }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// 统一的 GET 请求（带移动端 UA，提升第三方接口可用性）
    private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: request),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    /// 入口：按用户导入的自定义音源（已开启的）依次尝试，返回第一个可用地址
    static func resolve(
        name: String,
        artists: String,
        durationMS: Int,
        neteaseID: Int,
        songSource: SongSource = .netease,
        qqMid: String? = nil,
        strict: Bool = false
    ) async -> Resolved? {
        let keyword = ([name, artists].filter { !$0.isEmpty })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return nil }
        let store = UnblockSourceStore.shared
        // 用户导入的自定义源按导入顺序尝试。
        for source in store.customSources where source.enabled {
            if source.kind == "lx-script" {
                if let r = await lxScript(source: source, songSource: songSource, neteaseID: neteaseID, qqMid: qqMid) { return r }
            } else if source.kind == "lx" {
                if let r = await lx(source: source, keyword: keyword) { return r }
            } else if let r = await custom(
                source: source,
                name: name,
                artists: artists,
                neteaseID: neteaseID,
                songSource: songSource,
                qqMid: qqMid
            ) { return r }
        }
        return nil
    }

    // MARK: - 洛雪音源脚本转换配置

    /// Huibq keep-alive 等洛雪脚本的 musicUrl 协议：GET /url/{source}/{songId}/{quality}。
    private static func lxScript(source: ThirdPartySource, songSource: SongSource, neteaseID: Int, qqMid: String?) async -> Resolved? {
        let provider = source.headers["source"] ?? ""
        let songID: String
        switch (songSource, provider) {
        case (.netease, "wy") where neteaseID > 0:
            songID = String(neteaseID)
        case (.qq, "tx"):
            guard let qqMid, !qqMid.isEmpty else { return nil }
            songID = qqMid
        default:
            return nil
        }

        let base = source.template.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let preferred = source.headers["quality"] ?? source.headers["br"] ?? "320k"
        let qualities = preferred == "128k" ? ["128k"] : [preferred, "128k"]
        for quality in qualities {
            guard let url = URL(string: "\(base)/url/\(provider)/\(songID)/\(quality)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("lx-music-mobile/1.0", forHTTPHeaderField: "User-Agent")
            if let apiKey = source.headers["apiKey"], !apiKey.isEmpty {
                request.setValue(apiKey, forHTTPHeaderField: "X-Request-Key")
            }
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse else {
                BeansLogger.shared.log("导入音源请求失败：\(source.name) 平台=\(provider) 音质=\(quality)", level: .debug)
                continue
            }
            guard http.statusCode == 200 else {
                BeansLogger.shared.log("导入音源 HTTP 失败：\(source.name) 状态=\(http.statusCode) 平台=\(provider) 音质=\(quality)", level: .debug)
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                BeansLogger.shared.log("导入音源响应格式错误：\(source.name)", level: .debug)
                continue
            }
            let code = object["code"] as? Int ?? Int(object["code"] as? String ?? "") ?? -1
            guard code == 0,
                  let urlString = object["url"] as? String,
                  !urlString.isEmpty,
                  let playURL = URL(string: urlString) else {
                let message = object["msg"] as? String ?? "code=\(code)"
                BeansLogger.shared.log("导入音源返回失败：\(source.name) \(message)", level: .debug)
                continue
            }
            BeansLogger.shared.log("导入音源命中：\(source.name) 平台=\(provider) 音质=\(quality)", level: .info)
            return Resolved(url: playURL, source: source.name)
        }
        return nil
    }

    private static func custom(
        source: ThirdPartySource,
        name: String,
        artists: String,
        neteaseID: Int,
        songSource: SongSource,
        qqMid: String?
    ) async -> Resolved? {
        guard !source.template.isEmpty else { return nil }
        let expectedProvider = songSource == .qq ? "tx" : "wy"
        if let provider = source.headers["source"], !provider.isEmpty, provider != expectedProvider {
            return nil
        }
        let songID: String
        switch songSource {
        case .netease where neteaseID > 0:
            songID = String(neteaseID)
        case .qq:
            guard let qqMid, !qqMid.isEmpty else { return nil }
            songID = qqMid
        default:
            return nil
        }
        var urlString = source.template
        urlString = urlString.replacingOccurrences(of: "{id}", with: songID)
        urlString = urlString.replacingOccurrences(of: "{name}", with: urlEncoded(name))
        let keyword = ([name, artists].filter { !$0.isEmpty }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        urlString = urlString.replacingOccurrences(of: "{keyword}", with: urlEncoded(keyword))
        urlString = urlString.replacingOccurrences(of: "{artist}", with: urlEncoded(artists))
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let metadataKeys: Set<String> = ["source", "quality", "br", "apiKey"]
        for (key, value) in source.headers where !metadataKeys.contains(key) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            BeansLogger.shared.log("导入音源请求失败：\(source.name) \(error.localizedDescription)", level: .debug)
            return nil
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            BeansLogger.shared.log("导入音源 HTTP 失败：\(source.name) 状态=\(status)", level: .debug)
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = valueAtPath(obj, source.urlPath),
              let resolvedURL = value as? String, !resolvedURL.isEmpty,
              let playURL = URL(string: resolvedURL) else {
            BeansLogger.shared.log("导入音源响应中没有播放地址：\(source.name)", level: .debug)
            return nil
        }
        BeansLogger.shared.log("导入音源命中：\(source.name) 平台=\(expectedProvider)", level: .info)
        return Resolved(url: playURL, source: source.name)
    }

    // MARK: - 落雪音乐源（lx-music-api-server 风格 HTTP API）
    /// 兼容落雪 API 服务器（如 lx-music-api-server）：先按关键词搜索拿到歌曲 id，
    /// 再请求播放地址。headers 里可配置 source（wy/kg/qq/mg/tx，默认 kg）与 br（默认 320）。
    private static func lx(source: ThirdPartySource, keyword: String) async -> Resolved? {
        guard source.kind == "lx", !source.template.isEmpty else { return nil }
        let base = source.template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base) else { return nil }
        let lxSource = source.headers["source"] ?? "kg"
        let br = source.headers["br"] ?? "320"
        // 1) 搜索：GET /music/search?source=&query=&page=1&limit=5
        var searchComps = URLComponents(url: baseURL.appendingPathComponent("music/search"), resolvingAgainstBaseURL: false)
        searchComps?.queryItems = [
            URLQueryItem(name: "source", value: lxSource),
            URLQueryItem(name: "query", value: keyword),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let searchURL = searchComps?.url, let data = await get(searchURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = obj["data"] as? [String: Any],
              let list = dataObj["list"] as? [[String: Any]],
              let first = list.first,
              let id = first["id"] as? String ?? (first["id"] as? Int).map(String.init)
        else { return nil }
        // 2) 取播放地址：GET /music/url?source=&id=&br=
        var urlComps = URLComponents(url: baseURL.appendingPathComponent("music/url"), resolvingAgainstBaseURL: false)
        urlComps?.queryItems = [
            URLQueryItem(name: "source", value: lxSource),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "br", value: br)
        ]
        guard let urlURL = urlComps?.url, let data2 = await get(urlURL),
              let obj2 = try? JSONSerialization.jsonObject(with: data2) as? [String: Any],
              let d2 = obj2["data"] as? [String: Any],
              let urlStr = d2["url"] as? String, !urlStr.isEmpty,
              let playURL = URL(string: urlStr)
        else { return nil }
        return Resolved(url: playURL, source: "落雪 (\(lxSource))")
    }

    /// 点分路径取值：url / data.url / data.audioUrl ...
    private static func valueAtPath(_ obj: Any, _ path: String) -> Any? {
        var current: Any = obj
        for key in path.split(separator: ".") {
            guard let dict = current as? [String: Any], let next = dict[String(key)] else { return nil }
            current = next
        }
        return current
    }

    private static func urlEncoded(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }

}
