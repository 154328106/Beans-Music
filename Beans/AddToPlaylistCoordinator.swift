import SwiftUI

/// 「添加到歌单」的全局协调器。
///
/// 原来 `SongCell` 每一行都挂了一个 `.sheet(isPresented:)`，
/// 一个列表几十行就是几十个 sheet presenter —— SwiftUI 会为每个都准备呈现环境，
/// 是长列表卡顿的大头之一。
/// 改成全局一份：行里只负责把歌曲塞进来，弹窗由 RootView 统一挂一个。
final class AddToPlaylistCoordinator: ObservableObject {
    static let shared = AddToPlaylistCoordinator()
    private init() {}

    @Published var pending: Song?

    func request(_ song: Song) {
        pending = song
    }
}
