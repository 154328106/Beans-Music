import Foundation

/// 用户自定义的第三方解锁源（JSON / 落雪 API 服务器导入）
/// kind：netease-id（按网易云 ID 查询）、keyword（按 歌名+歌手 关键词查询）或 lx（落雪 API 服务器）
/// template：请求 URL 模板，支持占位符 {id} {name} {keyword} {artist}
/// urlPath：响应 JSON 中播放地址的字段路径（支持点分，如 url / data.url / data.audioUrl）
/// headers：可选的附加请求头
/// enabled：导入后用户可自行选择开启 / 关闭
struct ThirdPartySource: Identifiable, Codable, Hashable {
    var id = UUID().uuidString
    var name: String
    var kind: String = "keyword"
    var template: String
    var urlPath: String = "url"
    var headers: [String: String] = [:]
    var enabled: Bool = true

    enum CodingKeys: String, CodingKey { case id, name, kind, template, urlPath, headers, enabled }

    init(id: String = UUID().uuidString, name: String, kind: String = "keyword", template: String, urlPath: String = "url", headers: [String: String] = [:], enabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.template = template
        self.urlPath = urlPath
        self.headers = headers
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名音源"
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "keyword"
        template = try c.decodeIfPresent(String.self, forKey: .template) ?? ""
        urlPath = try c.decodeIfPresent(String.self, forKey: .urlPath) ?? "url"
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// 第三方解锁源管理：用户导入的自定义源（UserDefaults 持久化，导入后可选开启 / 关闭）
final class UnblockSourceStore: ObservableObject {
    static let shared = UnblockSourceStore()

    /// 用户导入的自定义源
    @Published var customSources: [ThirdPartySource] {
        didSet { save() }
    }

    private let defaults = UserDefaults.standard
    private let customKey = "beans.unblock.custom"

    private init() {
        if let data = defaults.data(forKey: customKey),
           let list = try? JSONDecoder().decode([ThirdPartySource].self, from: data) {
            customSources = list
        } else {
            customSources = []
        }
    }

    func add(_ source: ThirdPartySource) {
        customSources.append(source)
    }

    func remove(_ source: ThirdPartySource) {
        customSources.removeAll { $0.id == source.id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(customSources) {
            defaults.set(data, forKey: customKey)
        }
    }
}
