import SwiftUI

struct FeiniuLibraryView: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var auth = FeiniuAuth.shared

    enum Tab: String, CaseIterable, Identifiable {
        case playlists = "歌单"
        case albums = "专辑"
        case songs = "全部歌曲"
        case favorites = "收藏"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .playlists
    @State private var keyword = ""
    @State private var searching = false
    @State private var songs: [Song] = []
    @State private var playlists: [FeiniuPlaylist] = []
    @State private var albums: [FeiniuAlbum] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var title = ""

    var body: some View {
        List {
            if let errorText {
                Section { Text(errorText).font(.footnote).foregroundStyle(.red) }
            }

            if !songs.isEmpty {
                Section(title.isEmpty ? "曲目" : title) {
                    ForEach(Array(songs.enumerated()), id: \.element.identityKey) { index, song in
                        SongCell(song: song) { player.play(songs: songs, startAt: index) }
                    }
                }
            }

            if songs.isEmpty && !loading {
                switch tab {
                case .playlists:
                    Section("歌单") {
                        if playlists.isEmpty { Text("飞牛音乐中还没有歌单").foregroundStyle(.secondary) }
                        ForEach(playlists) { playlist in
                            Button { Task { await openPlaylist(playlist) } } label: {
                                HStack {
                                    Text(playlist.name)
                                    Spacer()
                                    Text("\(playlist.trackCount) 首").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                case .albums:
                    Section("专辑") {
                        if albums.isEmpty { Text("没有取到专辑").foregroundStyle(.secondary) }
                        ForEach(albums) { album in
                            Button { Task { await openAlbum(album) } } label: {
                                HStack {
                                    Text(album.name)
                                    Spacer()
                                    Text("\(album.trackCount) 首").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                case .songs, .favorites:
                    if !searching { Text("暂无歌曲").foregroundStyle(.secondary) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(auth.serverName.isEmpty ? "飞牛音乐" : auth.serverName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $keyword, prompt: "搜索飞牛音乐曲库")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: keyword) { value in
            if value.isEmpty && searching {
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
        .overlay { if loading { ProgressView() } }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        loading = true
        errorText = nil
        do { try await work() } catch { errorText = error.localizedDescription }
        loading = false
    }

    private func reload() async {
        guard auth.isConfigured else {
            errorText = "尚未配置飞牛音乐服务器"
            return
        }
        await run {
            switch tab {
            case .playlists:
                playlists = try await FeiniuAPI.shared.playlists()
            case .albums:
                albums = try await FeiniuAPI.shared.albums()
            case .songs:
                songs = try await FeiniuAPI.shared.tracks()
                title = "全部歌曲"
            case .favorites:
                songs = try await FeiniuAPI.shared.favoriteSongs()
                title = "收藏"
            }
        }
    }

    private func search() async {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        searching = true
        await run {
            songs = try await FeiniuAPI.shared.search(value)
            title = "搜索「\(value)」"
        }
    }

    private func openPlaylist(_ playlist: FeiniuPlaylist) async {
        await run {
            songs = try await FeiniuAPI.shared.playlistSongs(id: playlist.id)
            title = playlist.name
        }
    }

    private func openAlbum(_ album: FeiniuAlbum) async {
        await run {
            songs = try await FeiniuAPI.shared.albumSongs(id: album.id)
            title = album.name
        }
    }
}

