import SwiftUI

struct FeiniuServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = FeiniuAuth.shared
    @State private var editing = false
    @State private var confirmRemove = false

    var body: some View {
        NavigationView {
            List {
                if let server = auth.config {
                    Section("当前服务器") {
                        Button { editing = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "externaldrive.connected.to.line.below.fill")
                                    .font(.title2)
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(server.displayName).foregroundStyle(.primary)
                                    Text("\(server.username) · \(server.server)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: auth.isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle")
                                    .foregroundStyle(auth.isConfigured ? .green : .orange)
                            }
                        }
                    }
                    Section {
                        Button("重新登录或修改配置") { editing = true }
                        Button("删除飞牛音乐配置", role: .destructive) { confirmRemove = true }
                    }
                } else {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "externaldrive.badge.plus")
                                .font(.system(size: 34))
                                .foregroundStyle(.orange)
                            Text("尚未连接飞牛音乐").font(.headline)
                            Text("填写 NAS 地址和 fnOS 账号后，即可读取飞牛音乐曲库。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                    Section {
                        Button("添加飞牛音乐服务器") { editing = true }
                    }
                }
            }
            .navigationTitle("飞牛音乐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $editing) {
                FeiniuServerEditor(original: auth.config ?? FeiniuServer())
            }
            .confirmationDialog("删除飞牛音乐配置？", isPresented: $confirmRemove) {
                Button("删除", role: .destructive) { auth.remove() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只会删除本机保存的地址、账号和 token，不会修改 NAS 上的曲库。")
            }
        }
    }
}

struct FeiniuServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = FeiniuAuth.shared

    let original: FeiniuServer

    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var accessCode = ""
    @State private var relayMode = false
    @State private var working = false
    @State private var result: String?
    @State private var succeeded = false

    private var canLogin: Bool {
        !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("备注名（如 家里的飞牛）", text: $name)
                    TextField("NAS 地址（如 192.168.1.10:5666）", text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("fnOS 用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("fnOS 密码", text: $password)
                } footer: {
                    Text("可填写局域网 IP、域名或 FN Connect 解析后的地址；末尾不需要 /music/api/v1。")
                }

                Section("高级连接") {
                    SecureField("访问安全码（未开启可留空）", text: $accessCode)
                    Toggle("FN Connect 中继模式", isOn: $relayMode)
                }

                Section {
                    Button {
                        Task { await loginAndSave() }
                    } label: {
                        HStack {
                            if working { ProgressView() }
                            Text(working ? "正在连接…" : "登录、测试并保存")
                        }
                    }
                    .disabled(working || !canLogin)

                    if let result {
                        Text(result)
                            .font(.footnote)
                            .foregroundStyle(succeeded ? Color.green : Color.red)
                    }
                } footer: {
                    Text("密码先在本机计算 SHA-256 后提交。登录成功后，播放和封面请求使用飞牛音乐签发的 token。")
                }
            }
            .navigationTitle(auth.config == nil ? "连接飞牛音乐" : "修改飞牛音乐")
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
                accessCode = original.accessCode
                relayMode = original.relayMode
            }
        }
    }

    private func loginAndSave() async {
        working = true
        result = nil
        var input = original
        input.name = name
        input.server = server
        input.username = username
        input.password = password
        input.accessCode = accessCode
        input.relayMode = relayMode
        do {
            let loggedIn = try await FeiniuAPI.shared.login(input)
            await MainActor.run { auth.save(loggedIn) }
            let count = try await FeiniuAPI.shared.testConnection()
            succeeded = true
            result = "连接成功，曲库共 \(count) 首歌曲"
            try? await Task.sleep(nanoseconds: 600_000_000)
            dismiss()
        } catch {
            succeeded = false
            result = error.localizedDescription
        }
        working = false
    }
}
