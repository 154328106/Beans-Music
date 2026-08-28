import QuartzCore
import Foundation

/// 可选高刷新率保持器。配合 Info.plist 的 CADisableMinimumFrameDurationOnPhone 解开 60fps 上限。
final class HighRefreshKeeper {
    static let shared = HighRefreshKeeper()
    private var displayLink: CADisplayLink?

    private init() {}

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: ["beans.enableHighRefresh": true])
    }

    func configureFromDefaults() {
        configure(enabled: UserDefaults.standard.bool(forKey: "beans.enableHighRefresh"))
    }

    func configure(enabled: Bool) {
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
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
