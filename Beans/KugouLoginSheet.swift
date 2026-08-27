import SwiftUI
import WebKit

struct KugouLoginSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        let _ = theme.accent
        BeansNavigationStack {
            VStack(spacing: 12) {
                Picker("登录方式", selection: $tab) {
                    Text("网页登录").tag(0)
                    Text("Cookie").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 18)
                .padding(.top, 12)

                if tab == 0 {
                    KugouWebLoginPanel { dismiss() }
                } else {
                    KugouCookieImportPanel { dismiss() }
                }
            }
            .navigationTitle("酷狗音乐登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .modifier(BeansSheetModifier(detents: [.large], dragIndicator: true))
    }
}

struct KugouWebLoginPanel: View {
    @EnvironmentObject private var theme: ThemeStore
    @State private var pageLoaded = false
    @State private var syncing = false
    @State private var message = ""
    @State private var timer: Timer?
    let onSuccess: () -> Void

    var body: some View {
        let _ = theme.accent
        VStack(spacing: 10) {
            Text("在网页中完成酷狗账号登录，完成后会自动读取 Cookie 并同步歌单")
                .font(BeansFont.appFont(12))
                .foregroundStyle(Color.beansComment)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            ZStack {
                KugouWebView(onLoaded: { pageLoaded = true })
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                    .padding(.horizontal, 20)

                if !pageLoaded {
                    ProgressView("正在加载酷狗音乐…")
                        .tint(Color.beansAmber)
                }
            }
            .frame(maxHeight: .infinity)

            if !message.isEmpty {
                Text(message)
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(message.hasPrefix("✓") ? Color.beansSage : Color.red.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            Button { syncNow() } label: {
                HStack(spacing: 6) {
                    if syncing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(syncing ? "正在读取登录状态…" : "同步登录状态")
                }
                .font(BeansFont.appFont(14, .semibold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.beansAmber, in: Capsule())
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.96))
            .disabled(syncing)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .onAppear { startAutoDetect() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func startAutoDetect() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            readCookies { dict in
                let auth = KugouMusicAuth.shared
                guard auth.hasValidLogin(dict) else { return }
                auth.importCookies(dict, nickname: nil)
                finishSuccess()
            }
        }
    }

    private func syncNow() {
        syncing = true
        message = ""
        readCookies { dict in
            syncing = false
            let auth = KugouMusicAuth.shared
            if auth.hasValidLogin(dict) {
                auth.importCookies(dict, nickname: nil)
                finishSuccess()
            } else {
                message = "未检测到有效登录态，请先在网页中完成酷狗登录"
            }
        }
    }

    private func finishSuccess() {
        timer?.invalidate()
        timer = nil
        message = "✓ 酷狗音乐登录成功"
        BeansHaptics.success()
        ToastCenter.shared.show("酷狗音乐登录成功")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            onSuccess()
        }
    }

    private func readCookies(_ completion: @escaping ([String: String]) -> Void) {
        let wanted = KugouMusicAuth.webCookieNames
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            var dict: [String: String] = [:]
            for cookie in cookies where wanted.contains(cookie.name) {
                dict[cookie.name] = cookie.value
            }
            for cookie in cookies where cookie.domain.contains("kugou.com") || cookie.domain.contains("kgimg.com") {
                dict[cookie.name] = cookie.value
            }
            DispatchQueue.main.async { completion(dict) }
        }
    }
}

struct KugouCookieImportPanel: View {
    @EnvironmentObject private var theme: ThemeStore
    @State private var cookieText = ""
    @State private var message = ""
    let onSuccess: () -> Void

    var body: some View {
        let _ = theme.accent
        VStack(spacing: 12) {
            Text("电脑浏览器打开 https://www.kugou.com 登录后，复制 Request Headers 里的整段 Cookie 粘贴到下方")
                .font(BeansFont.appFont(12))
                .foregroundStyle(Color.beansComment)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            TextEditor(text: $cookieText)
                .font(BeansFont.appFont(11, .regular, .monospaced))
                .beansScrollContentBackgroundHidden()
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(height: 170)
                .padding(.horizontal, 20)

            if !message.isEmpty {
                Text(message)
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(message.hasPrefix("✓") ? Color.beansSage : Color.red.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            Button { importCookie() } label: {
                Label("导入 Cookie", systemImage: "arrow.down.doc")
                    .font(BeansFont.appFont(14, .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.beansAmber, in: Capsule())
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.96))
            .padding(.horizontal, 20)

            Spacer(minLength: 8)
        }
        .padding(.top, 8)
    }

    private func importCookie() {
        let dict = KugouMusicAuth.parseCookieHeader(cookieText)
        let auth = KugouMusicAuth.shared
        guard auth.hasValidLogin(dict) else {
            message = "Cookie 格式或登录态无效，请确认已完整复制"
            return
        }
        auth.importCookies(dict, nickname: nil)
        message = "✓ 酷狗音乐登录成功"
        BeansHaptics.success()
        ToastCenter.shared.show("酷狗音乐登录成功")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            onSuccess()
        }
    }
}

struct KugouWebView: UIViewRepresentable {
    let onLoaded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoaded: onLoaded)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        if let url = URL(string: "https://www.kugou.com/") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoaded: () -> Void
        init(onLoaded: @escaping () -> Void) {
            self.onLoaded = onLoaded
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoaded()
        }
    }
}
