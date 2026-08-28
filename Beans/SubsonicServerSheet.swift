import SwiftUI

/// 「音乐服务器」设置表单：填地址 / 用户名 / 密码，测试连接后保存。
///
/// 与三大平台的登录页不同——这里连的是用户自己的服务器（Navidrome / 道理鱼音乐 等），
/// 没有扫码、没有 Cookie，就是三个输入框。
struct SubsonicServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = SubsonicAuth.shared

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""

    @State private var testing = false
    @State private var result: String?
    @State private var succeeded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.10:4000", text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                } header: {
                    Text("服务器")
                } footer: {
                    Text("支持 Subsonic 协议的自建服务：Navidrome、道理鱼音乐、gonic、Airsonic 等。地址不写 http:// 会自动补上。")
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            if testing { ProgressView().controlSize(.small) }
                            Text(testing ? "连接中…" : "测试连接并保存")
                        }
                    }
                    .disabled(testing || server.isEmpty || username.isEmpty)

                    if let result {
                        Text(result)
                            .font(.footnote)
                            .foregroundStyle(succeeded ? Color.green : Color.red)
                    }
                } footer: {
                    Text("密码只保存在本机。连接时优先使用官方推荐的 token 签名（密码不上网）；服务器不支持时会自动降级为密码认证。")
                }

                if auth.isLoggedIn {
                    Section {
                        Button(role: .destructive) {
                            auth.logout()
                            server = ""; username = ""; password = ""
                            result = nil
                        } label: {
                            Text("断开服务器")
                        }
                    } footer: {
                        Text("当前已连接：\(auth.serverName)")
                    }
                }
            }
            .navigationTitle("音乐服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                if server.isEmpty { server = auth.server }
                if username.isEmpty { username = auth.username }
                if password.isEmpty { password = auth.password }
            }
        }
    }

    private func test() async {
        testing = true
        result = nil
        // 先落盘再测：SubsonicAPI 是从 auth 里取地址的
        auth.save(server: server, username: username, password: password)
        do {
            let version = try await SubsonicAPI.shared.testConnection()
            succeeded = true
            var text = "连接成功，服务器版本 \(version)"
            if !auth.coversSupported {
                text += "（该服务器的封面接口不可用，将只显示占位图）"
            }
            result = text
        } catch {
            succeeded = false
            result = error.localizedDescription
            auth.logout()
        }
        testing = false
    }
}
