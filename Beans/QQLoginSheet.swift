import SwiftUI
import UIKit

/// QQ 音乐登录页：网页登录（默认）/ 扫码登录 / 手动粘贴 Cookie
/// 网页登录：应用内 WKWebView 打开 y.qq.com，登录完成后自动读取 Cookie，最稳定。
/// 扫码登录：逆向 ptlogin2 接口，仍保留为备选方案。
struct QQLoginSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    @State private var qrImage: UIImage?
    @State private var status: QQMusicAuth.ScanState = .waiting
    @State private var timer: Timer?
    @State private var mode: QQLoginMode = .web

    enum QQLoginMode: String, CaseIterable, Identifiable {
        case web = "网页登录"
        case scan = "扫码登录"
        case paste = "粘贴Cookie"
        var id: String { rawValue }
    }

    private let auth = QQMusicAuth.shared

    var body: some View {
        let _ = theme.accent
        ZStack {
            GlassBackdrop()
            VStack(spacing: 16) {
                Capsule()
                    .fill(Color.beansComment.opacity(0.3))
                    .frame(width: 38, height: 4)
                    .padding(.top, 12)

                HStack {
                    Text("登录 QQ 音乐")
                        .font(BeansFont.appFont(20, .bold))
                        .foregroundStyle(Color.beansLabel)
                    Spacer()
                    Button {
                        BeansHaptics.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.beansComment)
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.9))
                }
                .padding(.horizontal, 24)

                Picker("登录方式", selection: $mode) {
                    ForEach(QQLoginMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)

                Group {
                    switch mode {
                    case .web:
                        QQWebLoginPanel(onSuccess: { dismiss() })
                    case .scan:
                        scanContent
                    case .paste:
                        QQCookieImportPanel(onSuccess: { dismiss() })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    // MARK: - 扫码登录内容（进入该页签时才启动二维码流程）

    private var scanContent: some View {
        VStack(spacing: 20) {
            Text("使用手机 QQ 扫描二维码\n登录后可播放更多 QQ 音乐歌曲（含 VIP 试听）")
                .font(BeansFont.appFont(13))
                .foregroundStyle(Color.beansComment)
                .multilineTextAlignment(.center)

            qrArea
                .frame(width: 240, height: 240)
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 18, y: 8)

            statusView
                .frame(height: 40)

            Spacer(minLength: 8)
        }
        .onAppear { start() }
    }

    // MARK: - 二维码区域

    @ViewBuilder
    private var qrArea: some View {
        ZStack {
            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
            } else {
                ProgressView().tint(Color.beansAmber)
            }
            if isError || status == .expired {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 34))
                    Text(isError ? errorText : "二维码已过期")
                        .font(BeansFont.appFont(13))
                        .multilineTextAlignment(.center)
                    GlassButton(title: "刷新", systemName: "arrow.clockwise", prominent: true) {
                        start()
                    }
                }
                .foregroundStyle(Color.beansLabel)
                .frame(width: 200, height: 200)
                .background(.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var statusView: some View {
        Group {
            switch status {
            case .waiting:
                Label("请使用手机 QQ 扫码", systemImage: "qrcode.viewfinder")
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansComment)
            case .scanned:
                Label("已扫码，请在手机上确认登录", systemImage: "checkmark.circle")
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansSage)
            case .success:
                Label("登录成功，正在同步…", systemImage: "checkmark.seal.fill")
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansSage)
            case .expired:
                Text("二维码已过期，请点击刷新")
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansComment)
            case .error(let message):
                Text(message)
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var isError: Bool {
        if case .error = status { return true }
        return false
    }

    private var errorText: String {
        if case .error(let message) = status { return message }
        return ""
    }

    // MARK: - 扫码流程

    private func start() {
        timer?.invalidate()
        timer = nil
        status = .waiting
        Task {
            do {
                let data = try await auth.fetchQRCode()
                await MainActor.run {
                    qrImage = UIImage(data: data)
                    status = .waiting
                    startPolling()
                }
            } catch {
                await MainActor.run {
                    status = .error(error.localizedDescription)
                }
            }
        }
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task {
                do {
                    let state = try await auth.poll()
                    await MainActor.run { handle(state) }
                } catch {
                    // 网络抖动：跳过本次轮询
                }
            }
        }
    }

    private func handle(_ state: QQMusicAuth.ScanState) {
        status = state
        switch state {
        case .success:
            timer?.invalidate()
            timer = nil
            BeansHaptics.success()
            ToastCenter.shared.show("QQ 音乐登录成功")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                dismiss()
            }
        case .expired, .error:
            timer?.invalidate()
            timer = nil
        default:
            break
        }
    }
}
