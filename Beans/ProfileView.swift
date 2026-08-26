import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// 自动下载新版 IPA 的结果
enum DownloadOutcome {
    case success(fileName: String)
    case failure(message: String)
}

struct ProfileView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager
    @AppStorage("beans.themeMode") private var themeModeRaw = BeansThemeMode.system.rawValue

    @State private var showHistory = false

    /// 统一账号登录面板（网易云 + QQ 音乐整合）
    @State private var showAccountHub = false
    /// 设置页（外观 + 歌词翻译等）
    @State private var showSettings = false
    @State private var showSectionSort = false
    /// 我的界面板块顺序（账号 / 我的功能 / 使用说明 / 关于，可自定义）
    @State private var profileOrder = SectionOrderStore.load(SectionOrderStore.profileKey, defaults: SectionOrderStore.profileDefaults)
    /// 软件使用说明
    @State private var showUsageGuide = false
    /// 手动检查更新
    @State private var checkingUpdate = false
    @State private var updateResult: UpdateChecker.CheckResult?
    @State private var showUpdateResult = false
    /// 自动下载新版 IPA
    @ObservedObject private var ipaDownloader = IPADownloader.shared
    @State private var showDownloadOverlay = false
    @State private var downloadOutcome: DownloadOutcome?
    @State private var showDownloadOutcome = false
    @State private var pendingUpdateInfo: UpdateChecker.ReleaseInfo?
    @ObservedObject private var qqAuth = QQMusicAuth.shared

    private var themeMode: BeansThemeMode {
        BeansThemeMode(rawValue: themeModeRaw) ?? .system
    }

    private var appVersionText: String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2"
        return "Beans Music · \(ver)"
    }

    /// 三个平台登录状态的合并提示（展示各平台真实昵称）
    private var accountStatusLine: String {
        var parts: [String] = []
        if auth.isLoggedIn {
            if let nick = auth.user?.nickname, !nick.isEmpty {
                parts.append("网易云 \(nick)")
            } else {
                parts.append("网易云 UID \(auth.user?.uid ?? 0)")
            }
        }
        if qqAuth.isLoggedIn {
            parts.append(qqAuth.nickname.isEmpty ? "QQ 已登录" : qqAuth.nickname)
        }
        if parts.isEmpty { return "登录后可同步网易云歌单 / 播放 QQ 歌曲" }
        return parts.joined(separator: " · ")
    }

    /// 顶部标题 + 右上角设置齿轮
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("我的")
                    .font(BeansFont.appFont(30, .bold))
                    .foregroundStyle(Color.beansLabel)
                Text("网易云 / QQ 音乐账号与外观设置")
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansComment)
            }
            Spacer()
            HStack(spacing: 10) {
                GlassIconButton(systemName: "arrow.up.arrow.down") {
                    BeansHaptics.tap()
                    showSectionSort = true
                }
                GlassIconButton(systemName: "gearshape.fill") {
                    BeansHaptics.tap()
                    showSettings = true
                }
            }
        }
        .padding(.top, 8)
    }

    var body: some View {
        let _ = theme.accent
        ZStack {
            // 页面背景：同步开启时显示壁纸/背景色，否则默认氛围渐变
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            // 实例级 UITabBar 清透风格（固定全透明，无需调节）
            TabBarAppearanceConfigurator()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    // 板块按用户自定义顺序渲染（可拖拽排序）
                    ForEach(profileOrder, id: \.self) { key in
                        switch key {
                        case "账号":
                            userCard
                        case "我的功能":
                            featuresGrid
                        case "使用说明":
                            usageGuideCard
                        case "关于":
                            aboutSection
                        default:
                            EmptyView()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 190)
            }
            .beansScrollIndicatorsHidden()
        }
        .task(id: auth.isLoggedIn) {
            await auth.refreshAccount()
            await qqAuth.fetchVIPStatus()
        }
        .sheet(isPresented: $showHistory) {
            HistoryView()
                .environmentObject(player)
                .environmentObject(auth)
        }
        .sheet(isPresented: $showAccountHub) {
            AccountHubSheet()
                .environmentObject(auth)
                .environmentObject(theme)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(theme)
                .environmentObject(player)
        }
        .sheet(isPresented: $showSectionSort) {
            SectionOrderSheet(title: "我的板块排序", sections: SectionOrderStore.profileDefaults, order: $profileOrder)
                .onDisappear { SectionOrderStore.save(SectionOrderStore.profileKey, profileOrder) }
        }
        .sheet(isPresented: $showUsageGuide) {
            UsageGuideSheet()
        }
        .alert("检查更新", isPresented: $showUpdateResult, presenting: updateResult) { result in
            switch result {
            case .update(let info):
                Button("前往更新") { UIApplication.shared.open(info.htmlURL) }
                Button("取消", role: .cancel) {}
            case .upToDate:
                Button("好", role: .cancel) {}
            case .failed:
                Button("好", role: .cancel) {}
            }
        } message: { result in
            switch result {
            case .update(let info):
                Text("发现新版本 \(info.version)，是否前往 GitHub 下载更新？")
            case .upToDate:
                Text("当前已是最新版本 \(UpdateChecker.currentVersion)")
            case .failed:
                Text("检查失败，请检查网络后重试\n如果长时间无反应，可能需要特殊网络环境（代理 / VPN）才能访问 GitHub")
            }
        }
        .overlay {
            if showDownloadOverlay { downloadProgressOverlay }
        }
        .alert("下载新版", isPresented: $showDownloadOutcome, presenting: downloadOutcome) { outcome in
            switch outcome {
            case .success:
                Button("好", role: .cancel) {}
            case .failure:
                Button("好", role: .cancel) {}
                Button("前往更新页") {
                    if let info = pendingUpdateInfo {
                        UIApplication.shared.open(info.htmlURL)
                    }
                }
            }
        } message: { outcome in
            switch outcome {
            case .success(let fileName):
                Text("新版 IPA 已下载到「文件」App → Beans → Downloads\n文件名：\(fileName)")
            case .failure(let message):
                Text("下载失败：\(message)\n如果长时间无反应，可能需要特殊网络环境（代理 / VPN）才能访问 GitHub")
            }
        }
    }

    /// 下载进度浮层（居中卡片，兼容所有系统版本）
    private var downloadProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.beansHighlight)
                    Text("正在下载新版 IPA")
                        .font(BeansFont.appFont(15, .semibold))
                        .foregroundStyle(Color.beansLabel)
                }
                if ipaDownloader.progress >= 0 {
                    ProgressView(value: ipaDownloader.progress)
                        .progressViewStyle(.linear)
                        .tint(Color.beansAmber)
                    Text("\(Int(ipaDownloader.progress * 100))%")
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                } else {
                    ProgressView()
                        .tint(Color.beansAmber)
                    Text("正在连接下载服务器…")
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                }
                Text("下载完成后可在「文件」App → Beans → Downloads 中查看")
                    .font(BeansFont.appFont(11))
                    .foregroundStyle(Color.beansComment.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            .padding(22)
            .frame(maxWidth: 300)
            .background {
                BeansGlass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .beansCardShadow(radius: 12, y: 6)
            .padding(32)
        }
        .transition(.opacity)
    }

    private var userCard: some View {
        VStack(spacing: 16) {
            Button {
                BeansHaptics.tap()
                // 统一账号面板：网易云 + QQ 音乐登录整合在一起
                showAccountHub = true
            } label: {
                HStack(spacing: 14) {
                    // 头像：主题渐变描边环
                    AsyncImage(url: auth.user?.avatarURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(Color.beansComment)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
                    .background(Color.beansGlassFill, in: Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(auth.user?.nickname ?? (auth.isLoggedIn ? "网易云已登录" : "免登录 · 点击登录"))
                                .font(BeansFont.appFont(20, .bold))
                                .foregroundStyle(Color.beansLabel)
                                .lineLimit(1)
                            if auth.isLoggedIn, let badge = auth.user?.vipBadge {
                                VIPBadgeView(text: badge)
                            }
                        }
                        Text(accountStatusLine)
                            .font(BeansFont.appFont(12, .regular, .monospaced))
                            .foregroundStyle(Color.beansComment)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.beansComment.opacity(0.7))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if auth.isLoggedIn || qqAuth.isLoggedIn {
                platformStatusRow
            }
        }
        .padding(16)
        .background {
                        BeansGlass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .beansCardShadow(radius: 10, y: 4)
    }

    /// 每个登录平台单独展示登录成功状态（网易云 / QQ 音乐）
    private var platformStatusRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if auth.isLoggedIn {
                platformChip(icon: "cloud.fill", name: "网易云", status: auth.user?.nickname ?? "已登录", badge: auth.user?.vipBadge)
            }
            if qqAuth.isLoggedIn {
                platformChip(icon: "play.rectangle.fill", name: "QQ 音乐", status: qqAuth.nickname.isEmpty ? "已登录" : qqAuth.nickname, badge: qqAuth.vipBadge)
            }
        }
        .padding(.top, 2)
    }

    private func platformChip(icon: String, name: String, status: String, badge: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.beansAmber)
            Text(name)
                .font(BeansFont.appFont(12, .semibold))
                .foregroundStyle(Color.beansLabel)
            Text(status)
                .font(BeansFont.appFont(11))
                .foregroundStyle(Color.beansComment)
                .lineLimit(1)
            if let badge {
                VIPBadgeView(text: badge)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }



    /// 壁纸格子：点击应用为当前背景；使用中的壁纸显示主题色边框+勾选；右上角删除
    private func wallpaperCell(path: String) -> some View {
        let isActive = path == theme.backgroundImagePath
        return ZStack(alignment: .topTrailing) {
            Button {
                BeansHaptics.tap()
                theme.applyWallpaper(at: path)
            } label: {
                Group {
                    if let img = UIImage(contentsOfFile: path) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.beansGlassFill
                    }
                }
                .frame(height: 108)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.beansAmber)
                            .background(Circle().fill(.ultraThinMaterial))
                            .padding(5)
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                BeansHaptics.medium()
                theme.deleteWallpaper(at: path)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.beansComment)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.ultraThinMaterial))
                    .clipShape(Circle())
                    .contentShape(Circle())
                    .padding(6)
            }
            .buttonStyle(.plain)
            .zIndex(2)
        }
    }

    /// 功能宫格：常用功能统一整合排版
    private var featuresGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "我的功能")
            VStack(spacing: 12) {
                featureCell(icon: "clock.arrow.circlepath", title: "播放历史", subtitle: "最近播放 \(player.history.count) 首") {
                    showHistory = true
                }
                featureCell(icon: qqAuth.isLoggedIn || auth.isLoggedIn ? "checkmark.seal.fill" : "globe", title: "账号与登录", subtitle: qqAuth.isLoggedIn || auth.isLoggedIn ? accountStatusLine : "统一登录网易云 / QQ 音乐") {
                    BeansHaptics.tap()
                    showAccountHub = true
                }
            }
        }
    }

    private func featureCell(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button {
            BeansHaptics.tap()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.beansAmber)
                    .frame(width: 34, height: 34)
                    .background(Color.beansGlassFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(BeansFont.appFont(14, .semibold))
                        .foregroundStyle(Color.beansLabel)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(BeansFont.appFont(11))
                        .foregroundStyle(Color.beansComment)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background {
                                BeansGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
    }


    /// 软件使用说明入口
    private var usageGuideCard: some View {
        Button {
            BeansHaptics.tap()
            showUsageGuide = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.beansAmber)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("软件使用说明")
                        .font(BeansFont.appFont(15, .semibold))
                        .foregroundStyle(Color.beansLabel)
                    Text("了解多平台切换、账号、播放与个性化玩法")
                        .font(BeansFont.appFont(11))
                        .foregroundStyle(Color.beansComment)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.beansComment.opacity(0.6))
            }
            .padding(16)
            .background {
                                BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .beansCardShadow(radius: 9, y: 3)
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "关于")
            VStack(spacing: 8) {
                Label(appVersionText, systemImage: "beats.headphones")
                    .font(BeansFont.appFont(14, .semibold))
                    .foregroundStyle(Color.beansLabel)
                Text("网易云 / QQ音乐 第三方客户端 · 仅供学习研究")
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(Color.beansComment)
                    .multilineTextAlignment(.center)
                Text("只用作个人学习研究，禁止用于商业及非法用途，如产生法律纠纷与本人无关")
                    .font(BeansFont.appFont(11))
                    .foregroundStyle(Color.beansComment.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("本软件完全免费，全部功能开源 · GitHub：XIaodou0416/Beans-Music")
                    .font(BeansFont.appFont(11, .semibold))
                    .foregroundStyle(Color.beansAmber)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background {
                                BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .beansCardShadow(radius: 9, y: 3)

            copyrightDisclosure

            updateLinkCard
        }
    }

    /// 版权声明（默认折叠，可展开查看）
    private var copyrightDisclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("“QQ”、“QQ音乐”及企鹅形象等文字、图形和商业标识，其著作权或商标权归腾讯公司所有。QQ音乐享有对其平台授权音乐的版权，请勿随意下载、复制版权内容。具体内容请参考QQ音乐用户协议。")
                Text("“网易云”、“网易云音乐”等文字、图形和商业标识，其著作权或商标权归网易所有。网易云音乐享有对其平台授权音乐的版权，请勿随意下载、复制版权内容。具体内容请参考网易云音乐用户协议。")
                Text("音乐 API 来自 GitHub 开源项目，非官方版 API；本软件不提供任何音频存储服务，如需下载音频，请支持正版！")
            }
            .font(BeansFont.appFont(11))
            .foregroundStyle(Color.beansComment)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.beansAmber)
                    .frame(width: 26)
                Text("版权声明")
                    .font(BeansFont.appFont(14, .semibold))
                    .foregroundStyle(Color.beansLabel)
                Spacer()
            }
            .padding(.vertical, 2)
        }
        .tint(Color.beansAmber)
        .padding(16)
        .background {
                            BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .beansCardShadow(radius: 9, y: 3)
    }

    /// 自动下载新版 IPA（带进度浮层）
    private func startAutoDownload(info: UpdateChecker.ReleaseInfo, assetURL: URL) {
        showDownloadOverlay = true
        Task {
            do {
                let url = try await ipaDownloader.download(assetURL: assetURL, version: info.version)
                await MainActor.run {
                    showDownloadOverlay = false
                    downloadOutcome = .success(fileName: url.lastPathComponent)
                    showDownloadOutcome = true
                }
            } catch {
                await MainActor.run {
                    showDownloadOverlay = false
                    downloadOutcome = .failure(message: error.localizedDescription)
                    showDownloadOutcome = true
                }
            }
        }
    }

    /// 更新地址 + 检查更新（GitHub 项目，可点击交互）
    private var updateLinkCard: some View {
        VStack(spacing: 10) {
            Button {
                BeansHaptics.tap()
                if let url = URL(string: "https://github.com/XIaodou0416/Beans-Music") {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.beansHighlight)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("更新地址")
                            .font(BeansFont.appFont(14, .semibold))
                            .foregroundStyle(Color.beansLabel)
                        Text("GitHub：XIaodou0416/Beans-Music")
                            .font(BeansFont.appFont(11))
                            .foregroundStyle(Color.beansComment)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.beansComment)
                }
                .padding(16)
                .background {
                    BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .beansCardShadow(radius: 9, y: 3)
            }
            .buttonStyle(.plain)

            Button {
                BeansHaptics.tap()
                guard !checkingUpdate else { return }
                checkingUpdate = true
                Task {
                    let result = await UpdateChecker.checkNow()
                    await MainActor.run {
                        checkingUpdate = false
                        updateResult = result
                        if case .update(let info) = result {
                            // 发现新版：自动下载 IPA（无安装包时回退到更新提示）
                            pendingUpdateInfo = info
                            if let assetURL = info.assetURL {
                                startAutoDownload(info: info, assetURL: assetURL)
                            } else {
                                showUpdateResult = true
                            }
                        } else {
                            showUpdateResult = true
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: checkingUpdate ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.beansHighlight)
                        .frame(width: 26)
                        .rotationEffect(.degrees(checkingUpdate ? 360 : 0))
                        .animation(checkingUpdate ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: checkingUpdate)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(checkingUpdate ? "正在检查…" : "检查更新")
                            .font(BeansFont.appFont(14, .semibold))
                            .foregroundStyle(Color.beansLabel)
                        Text("检测 GitHub 最新版本")
                            .font(BeansFont.appFont(11))
                            .foregroundStyle(Color.beansComment)
                    }
                    Spacer()
                }
                .padding(16)
                .background {
                    BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .beansCardShadow(radius: 9, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(checkingUpdate)
        }
    }
}

// MARK: - 统一账号登录面板（网易云 + QQ 音乐整合）

struct AccountHubSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    @ObservedObject private var qqAuth = QQMusicAuth.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showNeteaseLogin = false
    @State private var showQQLogin = false
    @State private var confirmNeteaseLogout = false
    @State private var confirmQQLogout = false

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader(title: "账号")
                        neteaseCard
                        qqCard
                        Text("网易云登录可同步歌单、收藏与听歌排行；QQ 音乐登录可播放更多歌曲")
                            .font(BeansFont.appFont(11))
                            .foregroundStyle(Color.beansComment)
                            .padding(.horizontal, 4)
                    }
                    .padding(16)
                }
                .beansScrollIndicatorsHidden()
            }
            .navigationTitle("账号登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showNeteaseLogin) {
            LoginView()
                .environmentObject(auth)
                .environmentObject(theme)
        }
        .sheet(isPresented: $showQQLogin) {
            QQLoginSheet()
                .environmentObject(theme)
        }
        .confirmationDialog("退出网易云登录？", isPresented: $confirmNeteaseLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                auth.logout()
                ToastCenter.shared.show("已退出网易云账号")
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("退出 QQ 音乐？", isPresented: $confirmQQLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                qqAuth.logout()
                ToastCenter.shared.show("已退出 QQ 音乐")
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 网易云账号卡片
    private var neteaseCard: some View {
        Button {
            BeansHaptics.tap()
            if auth.isLoggedIn { confirmNeteaseLogout = true } else { showNeteaseLogin = true }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.06))
                        .frame(width: 48, height: 48)
                    Image("BrandNetease")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("网易云音乐")
                        .font(BeansFont.appFont(15, .semibold))
                        .foregroundStyle(Color.beansLabel)
                    HStack(spacing: 6) {
                        Text(auth.isLoggedIn ? (auth.user?.nickname ?? "已登录") : "未登录 · 扫码登录同步歌单")
                            .font(BeansFont.appFont(12))
                            .foregroundStyle(Color.beansComment)
                            .lineLimit(1)
                        if auth.isLoggedIn, let badge = auth.user?.vipBadge {
                            VIPBadgeView(text: badge)
                        }
                    }
                }
                Spacer()
                Text(auth.isLoggedIn ? "退出" : "登录")
                    .font(BeansFont.appFont(13, .medium))
                    .foregroundStyle(auth.isLoggedIn ? Color.red : Color.beansAmber)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(14)
            .background {
                                BeansGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
    }

    /// QQ 音乐账号卡片
    private var qqCard: some View {
        Button {
            BeansHaptics.tap()
            if qqAuth.isLoggedIn { confirmQQLogout = true } else { showQQLogin = true }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.06))
                        .frame(width: 48, height: 48)
                    Image("BrandQQ")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("QQ 音乐")
                        .font(BeansFont.appFont(15, .semibold))
                        .foregroundStyle(Color.beansLabel)
                    HStack(spacing: 6) {
                        Text(qqAuth.isLoggedIn ? (qqAuth.nickname.isEmpty ? "已登录" : qqAuth.nickname) : "未登录 · 网页 / 扫码 / Cookie 登录")
                            .font(BeansFont.appFont(12))
                            .foregroundStyle(Color.beansComment)
                            .lineLimit(1)
                        if qqAuth.isLoggedIn, let badge = qqAuth.vipBadge {
                            VIPBadgeView(text: badge)
                        }
                    }
                }
                Spacer()
                Text(qqAuth.isLoggedIn ? "退出" : "登录")
                    .font(BeansFont.appFont(13, .medium))
                    .foregroundStyle(qqAuth.isLoggedIn ? Color.red : Color.beansAmber)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(14)
            .background {
                                BeansGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
    }

}

// MARK: - 设置页（外观 + 歌词翻译，从「我的」右上角齿轮进入）

struct SettingsView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("beans.themeMode") private var themeModeRaw = BeansThemeMode.system.rawValue
    /// 音质等级（借鉴 Kumone）
    @AppStorage("beans.audioQuality") private var audioQualityRaw = BeansAudioQuality.exhigh.rawValue
    /// 底栏是否显示文字（关闭后只显示图标）
    @AppStorage("beans.tabLabelsVisible") private var tabLabelsVisible = true
    /// 官方地址不可用时，是否尝试用户导入的音源
    @AppStorage("beans.enableUnblock") private var enableImportedSources = false
    @ObservedObject private var sourceStore = UnblockSourceStore.shared

    @State private var appearanceExpanded = false
    @State private var showWallpaperPicker = false
    @State private var showFontImporter = false
    /// 更新日志
    @State private var showChangelog = false
    /// 配置备份与恢复
    @State private var backupDoc: BackupDocument?
    @State private var showExportBackup = false
    @State private var showRestorePicker = false
    @State private var pendingRestore: [String: Any]?
    @State private var showRestoreConfirm = false
    @State private var backupMessage: String?
    /// 日志
    @State private var showLogViewer = false
    @State private var showLogShare = false
    @State private var showLogImport = false
    @State private var importedLogText: String?
    @State private var showSourceImporter = false

    private var themeMode: BeansThemeMode {
        BeansThemeMode(rawValue: themeModeRaw) ?? .system
    }

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        appearanceSection
                        playbackSection
                        changelogSection
                        backupSection
                        logSection
                        footerNote
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
                .beansScrollIndicatorsHidden()
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showWallpaperPicker) {
            WallpaperPhotoPicker { data in
                theme.addWallpaper(data)
                BeansHaptics.success()
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showFontImporter) {
            FontDocumentPicker { url in
                installFont(from: url)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showChangelog) {
            ChangelogListView()
        }
        .sheet(isPresented: $showSourceImporter) {
            ThirdPartySourceImportSheet()
                .environmentObject(theme)
        }
        .fileExporter(
            isPresented: $showExportBackup,
            document: backupDoc,
            contentType: .json,
            defaultFilename: "Beans设置备份-\(Self.backupDateString())"
        ) { result in
            switch result {
            case .success:
                backupMessage = "配置备份已导出"
                ToastCenter.shared.show("配置备份已导出")
            case .failure(let error):
                backupMessage = "导出失败：\(error.localizedDescription)"
                ToastCenter.shared.show("导出失败")
            }
        }
        .sheet(isPresented: $showLogViewer) {
            LogViewerSheet(importedText: importedLogText)
        }
        .sheet(isPresented: $showLogShare) {
            ShareSheet(items: [BeansLogger.shared.exportLogURL()])
        }
        .fullScreenCover(isPresented: $showLogImport) {
            BackupDocumentPicker { url in
                importLogFile(url)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showRestorePicker) {
            BackupDocumentPicker { url in
                handleBackupImport(url)
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("导入备份将覆盖当前部分设置，是否继续？", isPresented: $showRestoreConfirm, titleVisibility: .visible) {
            Button("恢复", role: .destructive) {
                applyRestore(pendingRestore)
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 校验扩展名并安装字体（asCopy 返回的 URL 已在沙盒内，可直接读取）
    private func installFont(from url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ["ttf", "otf", "ttc"].contains(ext) else {
            ToastCenter.shared.show("请选择 ttf / otf 字体文件")
            return
        }
        if let name = FontManager.install(from: url) {
            BeansHaptics.success()
            ToastCenter.shared.show("字体已应用：\(name)")
        } else {
            ToastCenter.shared.show("字体安装失败，请使用 ttf / otf 文件")
        }
    }

    /// 外观设置（原「我的」页外观折叠内容）
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "外观")
            // 主题模式：液态玻璃行，点击展开 / 收起全部外观设置
            Button {
                BeansHaptics.select()
                withAnimation(.easeInOut(duration: 0.25)) {
                    appearanceExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.beansAmber)
                        .frame(width: 28)
                    Text("主题模式")
                        .font(BeansFont.appFont(15))
                        .foregroundStyle(Color.beansLabel)
                    Spacer()
                    Image(systemName: appearanceExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.beansComment.opacity(0.6))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background {
                                        BeansGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.98))

            // 底栏是否显示文字（关闭后底栏只显示图标）
            Toggle(isOn: $tabLabelsVisible) {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.beansAmber)
                        .frame(width: 28)
                    Text("底栏显示文字")
                        .font(BeansFont.appFont(15))
                        .foregroundStyle(Color.beansLabel)
                }
            }
            .toggleStyle(.switch)
            .tint(Color.beansAmber)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            if appearanceExpanded {
            VStack(alignment: .leading, spacing: 14) {
                Picker("主题模式", selection: $themeModeRaw) {
                    ForEach(BeansThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                // 玻璃材质：液态玻璃仅 iOS 26+ 可用，低版本隐藏该开关（自动使用磨砂玻璃）
                if #available(iOS 26, *) {
                    Picker("玻璃材质", selection: Binding(
                        get: { theme.fxStyle },
                        set: { theme.setFXStyle($0) }
                    )) {
                        ForEach(BeansFXStyle.allCases, id: \.self) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Divider().overlay(Color.beansComment.opacity(0.15))

                HStack {
                    Image(systemName: "eyedropper.halffull")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.beansAmber)
                        .frame(width: 28)
                    Text("自定义强调色")
                        .font(BeansFont.appFont(15))
                        .foregroundStyle(Color.beansLabel)
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: { theme.customAccent ?? Color.beansAmber },
                        set: { theme.setCustomAccent($0.hexString) }
                    ))
                    .labelsHidden()
                }
                HStack(spacing: 12) {
                    Button {
                        theme.clearCustomAccent()
                        BeansHaptics.select()
                    } label: {
                        Text("恢复预设")
                            .font(BeansFont.appFont(13, .medium))
                            .foregroundStyle(Color.beansAmber)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(theme.customAccentHex == nil ? "使用预设主题" : "已自定义")
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                }

                    Divider().overlay(Color.beansComment.opacity(0.15))

                    HStack {
                        Image(systemName: "photo.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.beansAmber)
                            .frame(width: 28)
                        Text("主页背景色")
                            .font(BeansFont.appFont(15))
                            .foregroundStyle(Color.beansLabel)
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: { theme.customBackground ?? Color.beansBackground },
                            set: { theme.setBackground($0.hexString) }
                        ))
                        .labelsHidden()
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.beansAmber)
                            .frame(width: 28)
                        Button {
                            showWallpaperPicker = true
                        } label: {
                            HStack(spacing: 8) {
                                Text("上传壁纸（可多张）")
                                    .font(BeansFont.appFont(15))
                                    .foregroundStyle(Color.beansLabel)
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(Color.beansAmber)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    // 壁纸库：所有已上传壁纸，点击即应用为当前背景
                    if !theme.wallpaperPaths.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                            ForEach(theme.wallpaperPaths, id: \.self) { path in
                                wallpaperCell(path: path)
                            }
                        }
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: "photo.stack")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.beansComment)
                            Text("还没有壁纸，上传后会显示在这里")
                                .font(BeansFont.appFont(12))
                                .foregroundStyle(Color.beansComment)
                            Spacer()
                        }
                    }
                    HStack(spacing: 12) {
                        if theme.customBackgroundImage != nil {
                            Button {
                                theme.clearBackgroundImage()
                                BeansHaptics.select()
                            } label: {
                                Text("清除当前背景")
                                    .font(BeansFont.appFont(13, .medium))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        Text(theme.customBackgroundImage == nil ? "当前：默认背景" : "当前：已应用壁纸")
                            .font(BeansFont.appFont(12))
                            .foregroundStyle(Color.beansComment)
                    }
                Toggle(isOn: Binding(
                    get: { theme.backgroundSyncAll },
                    set: { theme.setBackgroundSyncAll($0) }
                )) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.beansAmber)
                        Text("同步到搜索 / 音乐库 / 我的")
                            .font(BeansFont.appFont(13))
                            .foregroundStyle(Color.beansLabel)
                    }
                }
                .toggleStyle(.switch)
                .tint(Color.beansAmber)

                Divider().overlay(Color.beansComment.opacity(0.15))

                HStack {
                    Button {
                        theme.setBackground("")
                        BeansHaptics.select()
                    } label: {
                        Text("恢复默认背景")
                            .font(BeansFont.appFont(13, .medium))
                            .foregroundStyle(Color.beansAmber)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }

                Divider().overlay(Color.beansComment.opacity(0.15))

                HStack {
                    Image(systemName: "text.quote")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.beansAmber)
                        .frame(width: 28)
                    Text("注释文字颜色")
                        .font(BeansFont.appFont(15))
                        .foregroundStyle(Color.beansLabel)
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: {
                            if let raw = UserDefaults.standard.string(forKey: "beans.commentColorHex"),
                               let c = Color(hex: raw) { return c }
                            return Color.beansComment
                        },
                        set: { UserDefaults.standard.set($0.hexString, forKey: "beans.commentColorHex") }
                    ))
                    .labelsHidden()
                }
                HStack(spacing: 12) {
                    Button {
                        UserDefaults.standard.removeObject(forKey: "beans.commentColorHex")
                        BeansHaptics.select()
                    } label: {
                        Text("恢复默认")
                            .font(BeansFont.appFont(13, .medium))
                            .foregroundStyle(Color.beansAmber)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("全 App 说明文字颜色")
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                }

                Divider().overlay(Color.beansComment.opacity(0.15))

                HStack {
                    Image(systemName: "textformat")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.beansAmber)
                        .frame(width: 28)
                    Text("全局字体")
                        .font(BeansFont.appFont(15))
                        .foregroundStyle(Color.beansLabel)
                    Spacer()
                    Text(FontManager.installedFontName ?? "系统默认")
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                }
                HStack(spacing: 12) {
                    Button {
                        showFontImporter = true
                    } label: {
                        Text("上传字体")
                            .font(BeansFont.appFont(13, .medium))
                            .foregroundStyle(Color.beansAmber)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        FontManager.clear()
                        BeansHaptics.select()
                        ToastCenter.shared.show("已恢复系统默认字体")
                    } label: {
                        Text("恢复默认字体")
                            .font(BeansFont.appFont(13, .medium))
                            .foregroundStyle(Color.beansAmber)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                Text("支持 ttf / otf 字体，上传后全局生效（含歌词），重启保留")
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(Color.beansComment)

            }
            .padding(16)
            .background {
                        BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
            .beansCardShadow(radius: 9, y: 3)
            }
        }
    }

    /// 播放与歌词设置（借鉴 Kumone：音质 / 免费听歌 / 显示歌词翻译）
    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "播放设置")
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.beansAmber)
                            .frame(width: 28)
                        Text("音质")
                            .font(BeansFont.appFont(15))
                            .foregroundStyle(Color.beansLabel)
                    }
                    Picker("音质", selection: $audioQualityRaw) {
                        ForEach(BeansAudioQuality.allCases) { q in
                            Text(q.displayName).tag(q.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("无损与 Hi-Res 需要黑胶 VIP，未开通时自动回落到可用音质")
                        .font(BeansFont.appFont(11))
                        .foregroundStyle(Color.beansComment)
                }

                Divider().overlay(Color.beansComment.opacity(0.15))

                Toggle(isOn: Binding(get: { player.mixesWithOthers }, set: { player.mixesWithOthers = $0 })) {
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.beansAmber)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("与其他音频同时播放")
                                .font(BeansFont.appFont(15))
                                .foregroundStyle(Color.beansLabel)
                            Text("开启：播放音乐时打开其他音频软件也能继续播放；关闭：其他音频开始播放时自动暂停")
                                .font(BeansFont.appFont(11))
                                .foregroundStyle(Color.beansComment)
                        }
                    }
                }
                .toggleStyle(.switch)
                .tint(Color.beansAmber)

                Divider().overlay(Color.beansComment.opacity(0.15))

                Toggle(isOn: $enableImportedSources) {
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.beansAmber)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("使用导入音源")
                                .font(BeansFont.appFont(15))
                                .foregroundStyle(Color.beansLabel)
                            Text("仅在官方地址不可用或为试听片段时回退")
                                .font(BeansFont.appFont(11))
                                .foregroundStyle(Color.beansComment)
                        }
                    }
                }
                .toggleStyle(.switch)
                .tint(Color.beansAmber)

                HStack(spacing: 10) {
                    Button {
                        BeansHaptics.tap()
                        showSourceImporter = true
                    } label: {
                        Label("导入音源", systemImage: "square.and.arrow.down")
                            .font(BeansFont.appFont(13, .semibold))
                            .foregroundStyle(Color.beansAmber)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(sourceStore.customSources.isEmpty ? "尚未导入" : "\(sourceStore.customSources.count) 个")
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                }

                ForEach(sourceStore.customSources) { source in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                                .font(BeansFont.appFont(13, .medium))
                                .foregroundStyle(Color.beansLabel)
                                .lineLimit(1)
                            Text(source.headers["source"]?.uppercased() ?? source.kind)
                                .font(BeansFont.appFont(10))
                                .foregroundStyle(Color.beansComment)
                        }
                        Spacer()
                        Toggle("", isOn: sourceEnabledBinding(source.id))
                            .labelsHidden()
                            .tint(Color.beansAmber)
                        Button {
                            sourceStore.remove(source)
                            BeansHaptics.tap()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除音源")
                    }
                }

            }
            .padding(16)
            .background {
                                BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .beansCardShadow(radius: 9, y: 3)
        }
    }

    private func sourceEnabledBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { sourceStore.customSources.first(where: { $0.id == id })?.enabled ?? false },
            set: { value in
                guard let index = sourceStore.customSources.firstIndex(where: { $0.id == id }) else { return }
                sourceStore.customSources[index].enabled = value
            }
        )
    }

    /// 更新日志入口
    private var changelogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                BeansHaptics.tap()
                showChangelog = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.beansAmber)
                        .frame(width: 28)
                    Text("更新日志")
                        .font(BeansFont.appFont(15))
                        .foregroundStyle(Color.beansLabel)
                    Spacer()
                    Text("v\(ChangelogStore.currentVersion)")
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.beansComment.opacity(0.6))
                }
                .padding(16)
                .background {
                                    BeansGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .buttonStyle(.plain)
            .beansCardShadow(radius: 8, y: 3)
        }
    }

    /// 配置备份与恢复：导出全部 beans.* 设置为 JSON 分享；导入后写回 UserDefaults
    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "备份与恢复")
            HStack(spacing: 10) {
                backupActionButton(icon: "square.and.arrow.up", title: "导出备份") {
                    BeansHaptics.tap()
                    exportBackup()
                }
                backupActionButton(icon: "square.and.arrow.down", title: "导入恢复") {
                    BeansHaptics.tap()
                    showRestorePicker = true
                }
            }
            if let backupMessage {
                Text(backupMessage)
                    .font(BeansFont.appFont(11))
                    .foregroundStyle(Color.beansComment)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func backupActionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(BeansFont.appFont(14, .semibold))
            .foregroundStyle(Color.beansLabel)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background {
                BeansGlass(shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.95))
    }

    /// 导出：收集 beans.* 设置生成 JSON，交给系统原生导出面板
    private func exportBackup() {
        let defaults = UserDefaults.standard
        var payload: [String: Any] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.hasPrefix("beans.") else { continue }
            // 超大原始 Data 直接跳过（壁纸 base64 已以字符串形式存于 beans.wallpapers.data，不受影响）
            if let data = value as? Data, data.count > 2 * 1024 * 1024 { continue }
            let safe = backupJSONSafe(value)
            // 逐个校验可序列化，异常类型直接跳过，避免整份备份生成失败
            guard JSONSerialization.isValidJSONObject([key: safe]) else { continue }
            payload[key] = safe
        }
        // 字体文件（Documents/Fonts）随备份一起导出
        if let font = FontManager.exportFontData() {
            payload["beans.font.restore"] = [
                "name": font.name,
                "data": font.data.base64EncodedString(),
            ] as [String: Any]
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        payload["beans.backup.meta"] = [
            "app": "Beans Music",
            "created": ISO8601DateFormatter().string(from: Date()),
            "version": version,
        ] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            backupMessage = "备份生成失败：存在无法序列化的设置项"
            ToastCenter.shared.show("备份生成失败")
            return
        }
        backupDoc = BackupDocument(data: data)
        backupMessage = nil
        BeansLogger.shared.log("导出配置备份（\(payload.count) 项，含壁纸/字体/歌单）", level: .info)
        showExportBackup = true
    }

    private static func backupDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// 读取用户选择的备份文件并解析，弹确认后恢复
    private func handleBackupImport(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            ToastCenter.shared.show("备份文件解析失败")
            return
        }
        pendingRestore = json
        showRestoreConfirm = true
    }

    /// 恢复：把 JSON 备份中 beans.* 键写回 UserDefaults
    private func applyRestore(_ json: [String: Any]?) {
        guard let json else { return }
        let defaults = UserDefaults.standard
        var count = 0
        for (key, value) in json {
            guard key.hasPrefix("beans."), key != "beans.backup.meta", key != "beans.font.restore" else { continue }
            guard let restored = backupPlistSafe(value) else { continue }
            defaults.set(restored, forKey: key)
            count += 1
        }
        // 恢复壁纸：写回 beans.wallpapers.* 后重建文件（沙盒路径变化也能恢复）
        theme.reloadWallpapersFromBackup()
        // 恢复字体文件
        if let fontPayload = json["beans.font.restore"] as? [String: Any],
           let name = fontPayload["name"] as? String,
           let b64 = fontPayload["data"] as? String,
           let fontData = Data(base64Encoded: b64) {
            if FontManager.restoreFont(name: name, data: fontData) {
                count += 1
            }
        }
        BeansLogger.shared.log("恢复配置备份：\(count) 项设置", level: .info)
        if count > 0 {
            BeansHaptics.success()
            backupMessage = "已恢复 \(count) 项设置，部分设置需重启应用后完全生效"
            ToastCenter.shared.show("已恢复 \(count) 项设置")
        } else {
            backupMessage = "备份中未找到可恢复的设置"
        }
    }

    /// 任意 UserDefaults 值 → JSON 可序列化（Data 转 base64、Date 转时间戳）
    private func backupJSONSafe(_ value: Any) -> Any {
        if let data = value as? Data {
            return ["__beansData__": data.base64EncodedString()]
        }
        if let date = value as? Date { return date.timeIntervalSince1970 }
        if let dict = value as? [String: Any] { return dict.mapValues { backupJSONSafe($0) } }
        if let array = value as? [Any] { return array.map { backupJSONSafe($0) } }
        if let dict = value as? [String: String] { return dict }
        if let array = value as? [String] { return array }
        return value
    }

    /// JSON 值 → UserDefaults 可存类型（只保留 plist 兼容类型）
    private func backupPlistSafe(_ value: Any) -> Any? {
        if let dict = value as? [String: Any], dict.count == 1,
           let b64 = dict["__beansData__"] as? String,
           let data = Data(base64Encoded: b64) {
            return data
        }
        if value is String || value is NSNumber { return value }
        if let array = value as? [Any] {
            let mapped = array.compactMap { backupPlistSafe($0) }
            return mapped.count == array.count ? mapped : nil
        }
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (k, v) in dict {
                guard let mv = backupPlistSafe(v) else { return nil }
                result[k] = mv
            }
            return result
        }
        return nil
    }

    /// 日志：查看 / 导出 / 导入 / 清空
    private var logSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "日志")
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    logActionButton(icon: "doc.text.magnifyingglass", title: "查看日志") {
                        importedLogText = nil
                        showLogViewer = true
                    }
                    logActionButton(icon: "square.and.arrow.up", title: "导出日志") {
                        showLogShare = true
                    }
                }
                HStack(spacing: 10) {
                    logActionButton(icon: "square.and.arrow.down", title: "导入日志") {
                        showLogImport = true
                    }
                    logActionButton(icon: "trash", title: "清空日志") {
                        BeansLogger.shared.clear()
                        ToastCenter.shared.show("日志已清空")
                    }
                }
                Text("日志记录搜索、播放、登录、导入、备份等关键事件；遇到问题可导出日志发给开发者，方便快速定位 Bug")
                    .font(BeansFont.appFont(11))
                    .foregroundStyle(Color.beansComment)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background {
                BeansGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    private func logActionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(BeansFont.appFont(13, .semibold))
            .foregroundStyle(Color.beansLabel)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background {
                BeansGlass(shape: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.95))
    }

    /// 导入日志文件：读取文本后在日志查看器中展示
    private func importLogFile(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            ToastCenter.shared.show("读取日志文件失败")
            return
        }
        importedLogText = text
        BeansLogger.shared.log("导入日志文件：\(url.lastPathComponent)", level: .info)
        showLogViewer = true
    }

    private var footerNote: some View {
        VStack(spacing: 6) {
            Text("Beans Music · 仅供学习交流，纯 AI 实现此应用")
                .font(BeansFont.appFont(11))
                .foregroundStyle(Color.beansComment.opacity(0.7))
            Text("接入网易云音乐、QQ 音乐等公开接口")
                .font(BeansFont.appFont(11))
                .foregroundStyle(Color.beansComment.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    /// 壁纸格子：点击应用为当前背景；使用中的壁纸显示主题色边框+勾选；右上角删除
    private func wallpaperCell(path: String) -> some View {
        let isActive = path == theme.backgroundImagePath
        return ZStack(alignment: .topTrailing) {
            Button {
                BeansHaptics.tap()
                theme.applyWallpaper(at: path)
            } label: {
                Group {
                    if let img = UIImage(contentsOfFile: path) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.beansGlassFill
                    }
                }
                .frame(height: 108)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.beansAmber)
                            .background(Circle().fill(.ultraThinMaterial))
                            .padding(5)
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                BeansHaptics.medium()
                theme.deleteWallpaper(at: path)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.beansComment)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.ultraThinMaterial))
                    .clipShape(Circle())
                    .contentShape(Circle())
                    .padding(6)
            }
            .buttonStyle(.plain)
            .zIndex(2)
        }
    }
}

// MARK: - 壁纸照片选择器（PHPicker 封装：iOS 14+ 兼容，支持多选图片）

struct WallpaperPhotoPicker: UIViewControllerRepresentable {
    let onPicked: (Data) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 0 // 0 = 多选
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: WallpaperPhotoPicker
        init(_ parent: WallpaperPhotoPicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            for result in results {
                let provider = result.itemProvider
                if provider.canLoadObject(ofClass: UIImage.self) {
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                        guard let data, !data.isEmpty else { return }
                        DispatchQueue.main.async {
                            self.parent.onPicked(data)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 字体文件选择器（UIDocumentPicker 包装，比 SwiftUI fileImporter 稳定：所有文件可选，系统 asCopy 复制到沙盒）

struct FontDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FontDocumentPicker
        init(_ parent: FontDocumentPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.onPick(url)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}
// MARK: - 配置备份文档（SwiftUI 原生 fileExporter 导出，稳定可靠）

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
// MARK: - 配置备份文件选择器（UIDocumentPicker 封装：比 SwiftUI fileImporter 稳定，所有文件可选）

struct BackupDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .plainText, .item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: BackupDocumentPicker
        init(_ parent: BackupDocumentPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.onPick(url)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}
