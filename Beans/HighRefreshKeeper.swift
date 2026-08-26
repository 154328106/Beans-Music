import QuartzCore

/// 全局高刷新率保持器：用一个持续运行的 CADisplayLink 请求 ProMotion 120Hz 渲染，
/// 提升整个 App 的滚动与动画流畅度。低刷新率设备（60Hz）自动按设备上限运行，不影响功耗机制。
final class HighRefreshKeeper {
    static let shared = HighRefreshKeeper()
    private var displayLink: CADisplayLink?

    private init() {}

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 90, maximum: 120)
        } else {
            link.preferredFramesPerSecond = 120
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {}
}
