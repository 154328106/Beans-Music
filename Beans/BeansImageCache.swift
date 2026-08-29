import SwiftUI
import UIKit

/// 图片缓存 + 带缓存的异步图片视图。
///
/// 为什么不用 SwiftUI 自带的 `AsyncImage`：它**没有内存缓存**，
/// 视图滚出屏幕再滚回来就重新走一遍「请求 → 解码」。
/// 列表里几十张封面这么来回折腾，掉帧非常明显。
///
/// 这里两层兜底：
///   1. `NSCache` 存**已解码**的 UIImage —— 命中就是零成本，连解码都省了
///   2. 没命中再走 URLSession（`URLCache` 已在 App 启动时调大，多数能命中磁盘缓存）
final class BeansImageCache {
    static let shared = BeansImageCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = 64 * 1024 * 1024   // 64MB 解码后像素
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        // 成本按像素估：宽 × 高 × 4 字节
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }

    /// 启动时调大 URLCache。系统默认只有 512KB 内存 / 10MB 磁盘，
    /// 封面稍多就被挤出去，等于没有缓存。
    static func configureURLCache() {
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            diskPath: "beans_image_cache"
        )
    }
}

/// 带缓存的异步图片。命中内存缓存时**同步**出图，不会闪一下占位图。
struct BeansAsyncImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }
        // 命中内存缓存：直接出图，不进异步流程
        if let cached = BeansImageCache.shared.image(for: url) {
            image = cached
            return
        }
        image = nil
        failed = false
        do {
            var req = URLRequest(url: url)
            // 优先吃 URLCache，拿不到再上网
            req.cachePolicy = .returnCacheDataElseLoad
            let (data, _) = try await URLSession.shared.data(for: req)
            guard !Task.isCancelled, let decoded = UIImage(data: data) else { return }
            BeansImageCache.shared.insert(decoded, for: url)
            // 再确认一次 url 没变（快速滚动时 task 可能已被换掉）
            guard self.url == url else { return }
            image = decoded
        } catch {
            failed = true
        }
    }
}
