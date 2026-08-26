import SwiftUI
import UIKit

@main
struct BeansApp: App {
    @StateObject private var auth = AuthStore()
    @StateObject private var player = PlayerManager()
    @StateObject private var theme = ThemeStore.shared
    @StateObject private var favorites = FavoritesStore.shared
    /// 免责声明确认状态：未确认前主界面在模糊层下方可见，确认后移除门禁
    @AppStorage("beans.disclaimerAccepted") private var disclaimerAccepted = false

    init() {
        // 闪退检测：优先初始化，检测上次异常退出并安装崩溃捕获
        _ = CrashReporter.shared
        // 启动时重新注册用户上传的全局字体（覆盖安装后依然生效）
        FontManager.reinstallIfNeeded()
        // 提升整体流畅度：保持高刷新率渲染
        HighRefreshKeeper.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(auth)
                    .environmentObject(player)
                    .environmentObject(theme)
                    .environmentObject(favorites)
                // 未确认前展示首次使用引导页（分页引导 + 免责确认）
                if !disclaimerAccepted {
                    OnboardingView { disclaimerAccepted = true }
                }
            }
        }
    }
}
