import SwiftUI
import UIKit

enum RootTab: String, CaseIterable, Identifiable {
    case discover
    case search
    case library
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discover: return "主页"
        case .search: return "搜索"
        case .library: return "音乐库"
        case .profile: return "我的"
        }
    }

    var icon: String {
        switch self {
        case .discover: return "house.fill"
        case .search: return "magnifyingglass"
        case .library: return "music.note.list"
        case .profile: return "person.crop.circle"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var favorites: FavoritesStore
    @AppStorage("beans.themeMode") private var themeModeRaw = BeansThemeMode.system.rawValue

    @State private var selection: RootTab = .discover
    @State private var showPlayer = false
    /// 免责声明确认状态（门禁在 BeansApp 中，这里用于确认后弹出更新说明）
    @AppStorage("beans.disclaimerAccepted") private var disclaimerAccepted = false
    /// 底栏是否显示文字（关闭后只显示图标）
    @AppStorage("beans.tabLabelsVisible") private var tabLabelsVisible = true
    /// 版本更新说明弹窗
    @State private var showWhatsNew = false
    /// 自动检测更新结果
    @State private var updateInfo: UpdateChecker.ReleaseInfo?
    @State private var showUpdateAlert = false
    private var themeMode: BeansThemeMode {
        BeansThemeMode(rawValue: themeModeRaw) ?? .system
    }

    var body: some View {
        let _ = theme.accent
        ZStack {
            // 系统原生 TabView：iOS 26 上 UITabBar 自动使用原生液态玻璃，
            // 按压折射反馈、拖动效果、高光均由系统渲染（与应用商店等系统 App 一致）。
            // 背景（壁纸/背景色）由每个 tab 页面内部的 GlassBackdrop 渲染，
            // 因为系统 TabView 的内容层会盖住 RootView 底层的 ZStack 背景。
            TabView(selection: $selection) {
                DiscoverView()
                    .tabItem { Label(tabLabelsVisible ? "主页" : "", systemImage: "house.fill") }
                    .tag(RootTab.discover)
                SearchView()
                    .tabItem { Label(tabLabelsVisible ? "搜索" : "", systemImage: "magnifyingglass") }
                    .tag(RootTab.search)
                LibraryView()
                    .tabItem { Label(tabLabelsVisible ? "音乐库" : "", systemImage: "music.note.list") }
                    .tag(RootTab.library)
                ProfileView()
                    .tabItem { Label(tabLabelsVisible ? "我的" : "", systemImage: "person.crop.circle") }
                    .tag(RootTab.profile)
            }
            .tint(Color.beansAmber)

            // 迷你播放器：悬浮在系统 TabBar 上方
            VStack(spacing: 0) {
                Spacer()
                if player.currentSong != nil {
                    MiniPlayerView(showPlayer: $showPlayer)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 62)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .preferredColorScheme(themeMode.colorScheme)
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerView()
                .environmentObject(favorites)
                .environmentObject(player)
                .environmentObject(auth)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: player.currentSong?.id)
        .overlay(alignment: .bottom) {
            ToastView(center: ToastCenter.shared)
        }
        .onAppear {
            // 已确认过免责声明：直接判断是否需要展示更新说明
            if disclaimerAccepted, ChangelogStore.shouldShowWhatsNew {
                showWhatsNew = true
            }
        }
        .onChange(of: disclaimerAccepted) { accepted in
            // 首次进入：确认免责声明后弹出更新说明
            if accepted, ChangelogStore.shouldShowWhatsNew {
                showWhatsNew = true
            }
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewSheet()
        }
        .task(id: disclaimerAccepted) {
            guard disclaimerAccepted else { return }
            if let info = await UpdateChecker.checkIfNeeded() {
                updateInfo = info
                showUpdateAlert = true
            }
        }
        .alert("发现新版本", isPresented: $showUpdateAlert, presenting: updateInfo) { info in
            Button("前往更新") { UIApplication.shared.open(info.htmlURL) }
            Button("以后再说", role: .cancel) {}
        } message: { info in
            Text("Beans Music 有新版本 \(info.version) 啦，是否前往 GitHub 下载更新？")
        }
    }
}

// MARK: - 系统 TabBar 清透风格（实例级配置）
// 系统 TabView 创建之后，`UITabBar.appearance()` 全局代理对已存在的实例不再生效，
// 所以每个 tab 页面内放一个 TabBarAppearanceConfigurator，通过 tabBarController
// 拿到当前 UITabBar 实例，直接设置固定清透外观（全透明、无阴影）。

struct TabBarAppearanceConfigurator: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        // 纯外观配置视图：禁止拦截触摸，避免透明全屏视图吃掉页面按钮点击
        controller.view.isUserInteractionEnabled = false
        DispatchQueue.main.async { Self.apply(from: controller) }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        DispatchQueue.main.async { Self.apply(from: uiViewController) }
    }

    /// 固定清透风格：全透明背景、无阴影；选中态用主题色，
    /// 材质与模糊完全交给系统对底层页面内容的渲染，不再支持手动调节透明度
    private static func apply(from controller: UIViewController) {
        guard let tabBar = controller.tabBarController?.tabBar else { return }
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        // 超薄材质模糊：与迷你播放器一致的清透玻璃透明度
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        appearance.backgroundColor = .clear
        appearance.shadowColor = .clear
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = UIColor.beansAmber
        tabBar.isTranslucent = true
    }
}
