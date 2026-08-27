import Foundation

final class KugouMusicAuth: ObservableObject {
    static let shared = KugouMusicAuth()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var nickname = ""
    @Published private(set) var vipBadge: String?

    private var cookies: [String: String] = [:]
    private let defaults = UserDefaults.standard
    private let cookieKey = "beans.kugou.cookie.v1"
    private let nickKey = "beans.kugou.nickname.v1"
    private let vipKey = "beans.kugou.vip.v1"

    private init() {
        if let saved = defaults.dictionary(forKey: cookieKey) as? [String: String], !saved.isEmpty {
            if hasValidLogin(saved) {
                cookies = saved
                isLoggedIn = true
                nickname = defaults.string(forKey: nickKey) ?? Self.fallbackNickname(saved)
                vipBadge = defaults.string(forKey: vipKey)
            } else {
                defaults.removeObject(forKey: cookieKey)
                defaults.removeObject(forKey: nickKey)
                defaults.removeObject(forKey: vipKey)
            }
        }
    }

    var userid: Int {
        Int(cookies["userid"] ?? cookies["KugooID"] ?? cookies["KuGooID"] ?? cookies["kg_uid"] ?? cookies["kguser_userid"] ?? "") ?? 0
    }

    var token: String {
        cookies["token"] ?? cookies["t"] ?? cookies["kg_token"] ?? cookies["kguser_token"] ?? ""
    }

    var dfid: String {
        cookies["dfid"] ?? cookies["kg_dfid"] ?? "-"
    }

    var mid: String {
        cookies["KUGOU_API_MID"] ?? cookies["mid"] ?? cookies["kg_mid"] ?? "-"
    }

    var cookieHeader: String {
        let preferred = [
            "userid", "token", "vip_type", "vip_token", "KugooID", "KuGooID", "t",
            "mid", "kg_mid", "dfid", "kg_dfid", "kg_uid", "KUGOU_API_MID",
            "kguser_userid", "kguser_token", "nickname", "NickName"
        ]
        var used = Set<String>()
        var parts: [String] = []
        if userid > 0, cookies["userid"]?.isEmpty ?? true {
            used.insert("userid")
            parts.append("userid=\(userid)")
        }
        if !token.isEmpty, cookies["token"]?.isEmpty ?? true {
            used.insert("token")
            parts.append("token=\(token)")
        }
        for key in preferred {
            guard let value = cookies[key], !value.isEmpty else { continue }
            used.insert(key)
            parts.append("\(key)=\(value)")
        }
        for key in cookies.keys.sorted() where !used.contains(key) {
            guard let value = cookies[key], !value.isEmpty else { continue }
            parts.append("\(key)=\(value)")
        }
        return parts.joined(separator: "; ")
    }

    @discardableResult
    func importCookies(_ dict: [String: String], nickname: String?) -> Bool {
        guard hasValidLogin(dict) else {
            return false
        }
        cookies = dict
        isLoggedIn = true
        self.nickname = nickname ?? Self.fallbackNickname(dict)
        defaults.set(cookies, forKey: cookieKey)
        defaults.set(self.nickname, forKey: nickKey)
        NotificationCenter.default.post(name: .beansKugouLoginDidUpdate, object: nil)
        Task { await self.fetchVIPStatus() }
        return true
    }

    func logout() {
        cookies = [:]
        isLoggedIn = false
        nickname = ""
        vipBadge = nil
        defaults.removeObject(forKey: cookieKey)
        defaults.removeObject(forKey: nickKey)
        defaults.removeObject(forKey: vipKey)
    }

    func hasValidLogin(_ dict: [String: String]) -> Bool {
        let uid = Int(dict["userid"] ?? dict["KugooID"] ?? dict["KuGooID"] ?? dict["kg_uid"] ?? dict["kguser_userid"] ?? "") ?? 0
        let tokenValue = dict["token"] ?? dict["t"] ?? dict["kg_token"] ?? dict["kguser_token"] ?? ""
        return uid > 0 && !tokenValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func fetchVIPStatus() async {
        guard isLoggedIn else { return }
        guard let url = URL(string: "https://vip.kugou.com/recharge/roleinfo") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.kugou.com/", forHTTPHeaderField: "Referer")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let role = json["role"] as? Int ?? 0
        let remain = json["VIPRemains"] as? Int ?? 0
        let expired = json["isExpiredMember"] as? Int ?? 1
        let badge: String? = (role > 0 || remain > 0 || expired == 0) ? "VIP" : nil
        await MainActor.run {
            self.vipBadge = badge
            if let badge {
                self.defaults.set(badge, forKey: self.vipKey)
            } else {
                self.defaults.removeObject(forKey: self.vipKey)
            }
        }
    }

    static let webCookieNames: Set<String> = [
        "userid", "token", "vip_type", "vip_token", "KugooID", "KuGooID", "t",
        "mid", "kg_mid", "dfid", "kg_dfid", "kg_uid", "kg_token", "KUGOU_API_MID",
        "kguser_userid", "kguser_token", "nickname", "NickName"
    ]

    static func parseCookieHeader(_ header: String) -> [String: String] {
        var dict: [String: String] = [:]
        for part in header.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = kv[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty { dict[key] = value }
        }
        return dict
    }

    static func fallbackNickname(_ dict: [String: String]) -> String {
        for key in ["nickname", "NickName", "kg_nickname", "nick"] {
            if let raw = dict[key], !raw.isEmpty {
                return raw.removingPercentEncoding ?? raw
            }
        }
        let uid = dict["userid"] ?? dict["KugooID"] ?? dict["KuGooID"] ?? ""
        return uid.isEmpty ? "酷狗音乐用户" : "酷狗音乐用户 \(uid)"
    }

    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
}
