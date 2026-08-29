import SwiftUI

/// 首页榜单入口的标识（sheet(item:) 需要 Identifiable）
struct SubsonicRankItem: Identifiable {
    var id: String { type }
    let title: String
    let subtitle: String
    let type: String
}

/// 本地音乐「榜单」详情：把某一类专辑摊平成曲目列表。
///
/// Subsonic 没有真正的排行榜概念，这里的「榜」其实是 `getAlbumList2` 的几种排序
/// （最多播放 / 最新加入 / 评分最高 / 最近播放），用榜单的形式呈现而已。
struct SubsonicRankDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerManager

    let title: String
    let subtitle: String
    /// getAlbumList2 的 type：frequent / newest / highest / recent
    let type: String

    @State private var songs: [Song] = []
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            List {
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                } else if !loading && songs.isEmpty {
                    Text("这个榜单没有取到曲目").foregroundStyle(.secondary)
                }
                ForEach(Array(songs.enumerated()), id: \.element.identityKey) { index, song in
                    SongCell(song: song) {
                        player.play(songs: songs, startAt: index)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        guard !songs.isEmpty else { return }
                        BeansHaptics.tap()
                        player.play(songs: songs, startAt: 0)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .disabled(songs.isEmpty)
                }
            }
            .overlay { if loading { ProgressView() } }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let albums = try await SubsonicAPI.shared.albums(type: type, size: 30)
            var out: [Song] = []
            // 并发取每张专辑的曲目，串行会很慢（小库里一张专辑常常只有一首）
            await withTaskGroup(of: [Song].self) { group in
                for a in albums {
                    group.addTask { (try? await SubsonicAPI.shared.albumSongs(id: a.id)) ?? [] }
                }
                for await s in group { out.append(contentsOf: s) }
            }
            songs = out
        } catch {
            errorText = error.localizedDescription
        }
    }
}
