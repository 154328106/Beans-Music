import SwiftUI

/// 音乐服务器列表：可存多台、随时切换、点进去改配置。
struct SubsonicServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = SubsonicAuth.shared

    @State private var editing: SubsonicServer?
    @State private var adding = false

    var body: some View {
        NavigationView {
            List {
                if auth.servers.isEmpty {
                    Section {
                        Text("还没有添加服务器")
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("支持 Subsonic 协议的自建服务：Navidrome、道理鱼音乐、gonic、Airsonic 等。")
                    }
                } else {
                    Section {
                        ForEach(auth.servers) { s in
                            Button {
                                auth.select(id: s.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.displayName)
                                            .foregroundStyle(.primary)
                                        Text("\(s.username) · \(s.server)")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if s.id == auth.currentID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                    Button {
                                        editing = s
                                    } label: {
                                        Image(systemName: "slider.horizontal.3")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        .onDelete { idx in
                            idx.map { auth.servers[$0].id }.forEach { auth.remove(id: $0) }
                        }
                    } header: {
                        Text("我的服务器")
                    } footer: {
                        Text("点一行切换当前服务器，点右侧滑杆图标改配置，左滑删除。")
                    }
                }

                Section {
                    Button {
                        adding = true
                    } label: {
                        Label("添加服务器", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("音乐服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editing) { s in
                SubsonicServerEditor(original: s)
            }
            .sheet(isPresented: $adding) {
                SubsonicServerEditor(original: SubsonicServer())
            }
        }
    }
}

/// 单台服务器的编辑表单：新增与修改共用。
struct SubsonicServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = SubsonicAuth.shared

    let original: SubsonicServer

    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""

    @State private var testing = false
    @State private var result: String?
    @State private var succeeded = false

    private var isNew: Bool { !auth.servers.contains { $0.id == original.id } }
    private var canSave: Bool { !server.isEmpty && !username.isEmpty }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("备注名（选填，如 家里的 NAS）", text: $name)
                    TextField("服务器地址（必填）", text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("用户名（必填）", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                } footer: {
                    Text("地址形如 192.168.1.10:4000，不写 http:// 会自动补上。")
                }

                Section {
                    Button {
                        Task { await testAndSave() }
                    } label: {
                        HStack {
                            if testing { ProgressView() }
                            Text(testing ? "连接中…" : "测试连接并保存")
                        }
                    }
                    .disabled(testing || !canSave)

                    // 按钮灰着时把原因说清楚，否则会以为是 App 卡了
                    if !testing && !canSave {
                        Text(server.isEmpty ? "请先填写服务器地址" : "请先填写用户名")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button("跳过测试，直接保存") {
                        save(select: true)
                        dismiss()
                    }
                    .disabled(!canSave)

                    if let result {
                        Text(result)
                            .font(.footnote)
                            .foregroundStyle(succeeded ? Color.green : Color.red)
                    }
                } footer: {
                    Text("密码只保存在本机。连接时优先使用官方推荐的 token 签名（密码不上网）；服务器不支持时会自动降级为密码认证。")
                }
            }
            .navigationTitle(isNew ? "添加服务器" : "编辑服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                name = original.name
                server = original.server
                username = original.username
                password = original.password
            }
        }
    }

    @discardableResult
    private func save(select: Bool) -> SubsonicServer {
        var item = original
        item.name = name
        item.server = server
        item.username = username
        item.password = password
        let saved = auth.upsert(item)
        if select { auth.select(id: saved.id) }
        return saved
    }

    private func testAndSave() async {
        testing = true
        result = nil
        // 先落盘并切成当前，SubsonicAPI 是从「当前服务器」取地址的
        save(select: true)
        do {
            let version = try await SubsonicAPI.shared.testConnection()
            succeeded = true
            var text = "连接成功，服务器版本 \(version)"
            if !auth.coversSupported {
                text += "（该服务器封面接口不可用，将显示占位图）"
            }
            result = text
        } catch {
            succeeded = false
            result = error.localizedDescription
            // 测试失败不删配置：地址可能只是暂时不通，留着让用户改
        }
        testing = false
    }
}
