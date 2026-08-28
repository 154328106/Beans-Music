import SwiftUI

/// 自建音乐服务器（Navidrome / 道理鱼音乐）的浏览页：搜索 / 歌单 / 专辑 / 随便听听。
///
/// 刻意做成**独立入口**而不是并进网易云那套多平台搜索——
/// Subsonic 没有评论、没有 VIP、艺人页结构也不同，硬塞进去要改一大片，
/// 独立一页反而更贴合「这是我自己的曲库」这件事。
struct SubsonicLibraryView: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var auth = SubsonicAuth.shared

    enum Tab: String, CaseIterable, Identifiable {
        case playlists = "歌单"
        case albums = "专辑"
        case random = "随便听听"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .playlists
    @State private var keyword = ""
    @State private var searching = false

    @State private var songs: [Song] = []
    @State private var playlists: [(id: String, name: String, count: Int, coverURL: URL?)] = []
    @State private var albums: [(id: String, name: String, artist: String, coverURL: URL?)] = []

    @State private var loading = false
    @State private var errorText: String?
    @State private var title = ""

    var body: some View {
        List {
            if let errorText {
                Section {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if !songs.isEmpty {
                Section(title.isEmpty ? "曲目" : title) {
                    ForEach(Array(songs.enumerated()), id: \.element.identityKey) { index, song in
                        SongCell(song: song) {
                            player.play(songs: songs, startAt: index)
                        }
                    }
                }
            }

            if songs.isEmpty && !loading {
                switch tab {
                case .playlists:
                    Section("歌单") {
                        if playlists.isEmpty {
                            Text("服务器上还没有歌单").foregroundStyle(.secondary)
                        }
                        ForEach(playlists, id: \.id) { p in
                            Button {
                                Task { await openPlaylist(p) }
                            } label: {
                                HStack {
                                    Text(p.name)
                                    Spacer()
                                    Text("\(p.count) 首").foregroundStyle(.secondary).font(.footnote)
                                }
                            }
                        }
                    }
                case .albums:
                    Section("最新专辑") {
                        if albums.isEmpty {
                            Text("没有取到专辑").foregroundStyle(.secondary)
                        }
                        ForEach(albums, id: \.id) { a in
                            Button {
                                Task { await openAlbum(a) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.name)
                                    Text(a.artist).foregroundStyle(.secondary).font(.footnote)
                                }
                            }
                        }
                    }
                case .random:
                    EmptyView()
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(auth.serverName.isEmpty ? "音乐服务器" : auth.serverName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $keyword, prompt: "搜索服务器上的音乐")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: keyword) { newValue in
            if newValue.isEmpty && searching {
                searching = false
                songs = []
                title = ""
                Task { await reload() }
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .onChange(of: tab) { _ in
            songs = []
            title = ""
            keyword = ""
            searching = false
            Task { await reload() }
        }
        .overlay {
            if loading { ProgressView() }
        }
        .task { await reload() }
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        loading = true
        errorText = nil
        do { try await work() } catch { errorText = error.localizedDescription }
        loading = false
    }

    private func reload() async {
        guard auth.isLoggedIn else {
            errorText = "尚未配置音乐服务器"
            return
        }
        await run {
            switch tab {
            case .playlists:
                playlists = try await SubsonicAPI.shared.playlists()
            case .albums:
                albums = try await SubsonicAPI.shared.albums(type: "newest", size: 50)
            case .random:
                songs = try await SubsonicAPI.shared.randomSongs(count: 50)
                title = "随便听听"
            }
        }
    }

    private func search() async {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        searching = true
        await run {
            songs = try await SubsonicAPI.shared.search(key)
            title = "搜索「\(key)」"
        }
    }

    private func openPlaylist(_ p: (id: String, name: String, count: Int, coverURL: URL?)) async {
        await run {
            songs = try await SubsonicAPI.shared.playlistSongs(id: p.id)
            title = p.name
        }
    }

    private func openAlbum(_ a: (id: String, name: String, artist: String, coverURL: URL?)) async {
        await run {
            songs = try await SubsonicAPI.shared.albumSongs(id: a.id)
            title = a.name
        }
    }
}
