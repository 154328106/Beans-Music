import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared

    @State private var topLists: [TopList] = []
    @State private var dailySongs: [Song] = []
    @State private var personalized: [Playlist] = []

    @State private var loading = true
    @State private var errorMessage: String?
    @State private var selectedTopList: TopList?
    @State private var selectedPlaylist: Playlist?
    @State private var showDailyList = false
    @State private var showSectionSort = false
    /// 主页板块顺序（每日推荐 / 排行榜 / 歌单广场，可自定义）
    @State private var homeOrder = SectionOrderStore.load(SectionOrderStore.homeKey, defaults: SectionOrderStore.homeDefaults)

    /// 当前平台可排序的板块：三个平台都保留主页推荐、排行榜和歌单广场位置。
    private var availableSections: [String] {
        source == .qq ? ["每日推荐", "排行榜"] : SectionOrderStore.homeDefaults
    }
    /// 首页数据源：记住上次选择，下次打开仍保持该平台（默认网易云）
    @AppStorage("beans.homeSource") private var homeSourceRaw = SearchProvider.netease.rawValue
    @State private var selectedSubsonicRank: SubsonicRankItem?
    @State private var subsonicSongs: [Song] = []
    @State private var subsonicNewest: [SubsonicAlbum] = []
    @State private var subsonicStarred: [Song] = []
    private var homeProviders: [SearchProvider] { platformPrefs.enabledSearchProviders }
    /// 首页数据源：网易云 / QQ音乐（与搜索页同一控件样式）
    private var source: SearchProvider {
        guard let saved = SearchProvider(rawValue: homeSourceRaw), homeProviders.contains(saved) else {
            return homeProviders.first ?? .netease
        }
        return saved
    }

    @State private var qqTopLists: [QQTopInfo] = []
    @State private var selectedQQTopList: QQTopInfo?
    @State private var kugouTopLists: [KugouTopInfo] = []
    @State private var selectedKugouTopList: KugouTopInfo?
    @State private var selectedQQPlaylist: Playlist?
    /// 排行榜展开状态：收起显示前 3，展开显示前 10
    @State private var ranksExpanded = false
    /// 歌单广场展开状态：收起显示前 6，展开显示全部
    @State private var playlistsExpanded = false
    /// 首页加载去重：SwiftUI 视图刷新时 .task 可能被重复触发，避免网络请求风暴。
    @State private var activeLoadKey: String?
    @State private var lastLoadedKey = ""
    @State private var lastLoadedAt = Date.distantPast
    /// 首次启动免责声明：确认进入后若加载失败自动刷新
    @AppStorage("beans.disclaimerAccepted") private var disclaimerAccepted = false
    /// 网易云歌单广场当前分类（「全部」展示官方精品歌单）
    @State private var neteaseCat = "全部"
    /// 官方歌单分类列表
    @State private var playlistCats: [String] = []

    var body: some View {
        let _ = theme.accent
        ZStack {
            // 主页背景：壁纸/背景色永远在发现页生效（homeMode），同步开启时其他页面也生效
            GlassBackdrop(customColor: theme.customBackground, homeMode: true)
            // 实例级 UITabBar 清透风格（固定全透明，无需调节）
            TabBarAppearanceConfigurator()
            ScrollView {
                ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 26) {
                    header
                    providerPicker
                    if let errorMessage {
                        ErrorStateView(message: errorMessage) {
                            Task { await load(force: true) }
                        }
                    } else if loading {
                        LoadingStateView()
                    } else if source == .subsonic {
                        subsonicHomeSection
                    } else {
                        // 板块按用户自定义顺序渲染（可拖拽排序）
                        ForEach(homeOrder.filter { availableSections.contains($0) }, id: \.self) { key in
                            switch key {
                            case "每日推荐":
                                if !dailySongs.isEmpty { dailySection.sectionEntrance(delay: 0) }
                            case "排行榜":
                                if hasRankData { topListsSection.sectionEntrance(delay: 0.08) }
                            case "歌单广场":
                                if !personalized.isEmpty { personalizedSection.sectionEntrance(delay: 0.16) }
                            default:
                                EmptyView()
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 190)
                }
            }
            .beansScrollIndicatorsHidden()
            .refreshable { await load(force: true) }
            .task(id: source) { await load(force: false) }
            .onAppear {
                guard let saved = SearchProvider(rawValue: homeSourceRaw), homeProviders.contains(saved) else {
                    homeSourceRaw = (homeProviders.first ?? .netease).rawValue
                    return
                }
            }
            .onReceive(platformPrefs.changes) { _ in
                let next = platformPrefs.ensureVisible(source)
                if next != source {
                    homeSourceRaw = next.rawValue
                }
            }
            .onChange(of: source) { _ in
                homeOrder = SectionOrderStore.load(SectionOrderStore.homeKey, defaults: availableSections)
            }
            .onChange(of: disclaimerAccepted) { accepted in
                // 免责声明确认进入后：若首页加载失败则自动刷新（无需手动下拉）
                if accepted, errorMessage != nil {
                    Task { await load(force: true) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .beansNeteaseLoginDidUpdate)) { _ in
                guard platformPrefs.isEnabled(SearchProvider.netease) else { return }
                reloadAfterLoginUpdate(.netease)
            }
            .onReceive(NotificationCenter.default.publisher(for: .beansQQLoginDidUpdate)) { _ in
                guard platformPrefs.isEnabled(SearchProvider.qq) else { return }
                reloadAfterLoginUpdate(.qq)
            }
            .onReceive(NotificationCenter.default.publisher(for: .beansKugouLoginDidUpdate)) { _ in
                guard platformPrefs.isEnabled(SearchProvider.kugou) else { return }
                reloadAfterLoginUpdate(.kugou)
            }
            .sheet(item: $selectedTopList) { topList in
                TopListDetailView(topList: topList)
                    .environmentObject(player)
                    .environmentObject(auth)
            }
            .sheet(item: $selectedPlaylist) { playlist in
                PlaylistView(playlist: playlist)
                    .environmentObject(player)
                    .environmentObject(auth)
            }
            .sheet(item: $selectedQQTopList) { info in
                QQTopListDetailView(topID: info.id, name: info.name)
                    .environmentObject(player)
                    .environmentObject(auth)
            }
            .sheet(item: $selectedSubsonicRank) { item in
                SubsonicRankDetailView(title: item.title, subtitle: item.subtitle, type: item.type)
                    .environmentObject(player)
            }
            .sheet(item: $selectedKugouTopList) { info in
                KugouTopListDetailView(topList: info)
                    .environmentObject(player)
            }
            .sheet(item: $selectedQQPlaylist) { playlist in
                QQPlaylistSongsSheet(playlist: playlist)
                    .environmentObject(player)
                    .environmentObject(auth)
            }
            .sheet(isPresented: $showDailyList) {
                DailySongsSheet(songs: dailySongs)
                    .environmentObject(player)
                    .environmentObject(auth)
            }
            .sheet(isPresented: $showSectionSort) {
                SectionOrderSheet(title: "主页板块排序", sections: availableSections, order: $homeOrder)
                    .onDisappear { SectionOrderStore.save(SectionOrderStore.homeKey, homeOrder) }
            }
        }
    }

    /// 顶部问候区：大标题 + 刷新按钮
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(greeting)
                        .font(BeansFont.appFont(30, .bold))
                        .foregroundStyle(Color.beansLabel)
                    Text(auth.user?.nickname ?? "发现好音乐")
                        .font(BeansFont.appFont(13))
                        .foregroundStyle(Color.beansComment)
                }
                Spacer()
                HStack(spacing: 10) {
                    GlassIconButton(systemName: "arrow.up.arrow.down") {
                        BeansHaptics.tap()
                        showSectionSort = true
                    }
                    GlassIconButton(systemName: "arrow.clockwise") {
                        BeansHaptics.tap()
                        Task { await load(force: true) }
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    /// 平台选择（网易云 / QQ音乐 / 酷狗音乐，样式与搜索页一致）
    private var providerPicker: some View {
        HStack(spacing: 4) {
            ForEach(homeProviders) { p in
                Button {
                    BeansHaptics.tap()
                    if source != p { homeSourceRaw = p.rawValue }
                } label: {
                    HStack(spacing: 6) {
                        if let imageName = p.brandImageName {
                            Image(imageName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: p.icon)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(p.rawValue)
                            .font(BeansFont.appFont(13, .semibold))
                    }
                    .foregroundStyle(source == p ? Color.white : Color.beansComment)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background {
                        if source == p {
                            Capsule().fill(p.tint)
                        } else {
                            Capsule().fill(.clear)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background {
                        BeansGlass(shape: Capsule())
        }
        .clipShape(Capsule())
        .beansCardShadow(radius: 6, y: 2)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "早上好"
        case 12..<18: return "下午好"
        default: return "晚上好"
        }
    }


    /// 每日推荐封面右下角播放状态：当前播放中显示动态指示器，暂停显示暂停，其余显示播放
    @ViewBuilder
    private func dailyPlayStateBadge(for song: Song) -> some View {
        let isCurrent = player.currentSong?.identityKey == song.identityKey
        ZStack {
            if isCurrent && player.isPlaying {
                NowPlayingIndicator()
                    .frame(width: 24, height: 24)
                    .background(.black.opacity(0.45), in: Circle())
            } else {
                Image(systemName: isCurrent ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(.black.opacity(0.45), in: Circle())
            }
        }
        .padding(7)
    }

    /// 网易云排行榜：全部榜单保留，热歌榜置顶
    private var neteaseTopLists: [TopList] {
        var list = topLists
        if let hot = list.first(where: { $0.name.contains("热歌榜") }),
           let idx = list.firstIndex(where: { $0.id == hot.id }), idx != 0 {
            list.remove(at: idx)
            list.insert(hot, at: 0)
        }
        return list
    }

    /// 每平台排行榜最多 10 个（收起只显示前 3，展开显示前 10）
    private var visibleRankCount: Int {
        switch source {
        case .netease: return neteaseTopLists.count
        case .qq: return qqTopLists.count
        case .kugou: return kugouTopLists.count
        // 本地音乐没有榜单
        case .subsonic: return 0
        }
    }

    private var displayedRankCount: Int {
        ranksExpanded ? min(visibleRankCount, 10) : min(visibleRankCount, 3)
    }

    /// 当前平台是否有排行榜数据（网易云用 topLists，QQ 用 qqTopLists）
    private var hasRankData: Bool {
        switch source {
        case .netease: return !topLists.isEmpty
        case .qq: return !qqTopLists.isEmpty
        case .kugou: return !kugouTopLists.isEmpty
        case .subsonic: return false
        }
    }

    // MARK: - 排行榜（竖排行列表）

    private var topListsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "排行榜")
            VStack(spacing: 0) {
                if ranksExpanded {
                    rankToggleButton(label: "收起", icon: "chevron.up")
                    Divider().overlay(Color.beansComment.opacity(0.12))
                }
                rankRowsContent
                if !ranksExpanded, visibleRankCount > 3 {
                    rankToggleButton(label: "展开全部（\(min(visibleRankCount, 10))）", icon: "chevron.down")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.06))
                    .background {
                        BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .beansCardShadow(radius: 9, y: 3)
            .id("rankTopSection")
        }
    }

    /// 排行榜行列表（按平台渲染）
    @ViewBuilder
    private var rankRowsContent: some View {
        if source == .netease {
            ForEach(Array(neteaseTopLists.prefix(displayedRankCount).enumerated()), id: \.element.id) { index, topList in
                rankRow(index: index, name: topList.name, subtitle: topList.updateFrequency, coverURL: topList.coverURL) {
                    BeansHaptics.tap()
                    selectedTopList = topList
                }
                Divider().overlay(Color.beansComment.opacity(0.12))
            }
        } else if source == .qq {
            ForEach(Array(qqTopLists.prefix(displayedRankCount).enumerated()), id: \.element.id) { index, info in
                rankRow(index: index, name: info.name, subtitle: "QQ 峰尖榜", coverURL: info.coverURL) {
                    BeansHaptics.tap()
                    selectedQQTopList = info
                }
                Divider().overlay(Color.beansComment.opacity(0.12))
            }
        } else if source == .kugou {
            ForEach(Array(kugouTopLists.prefix(displayedRankCount).enumerated()), id: \.element.id) { index, info in
                // 酷狗返回的榜单封面很花，统一改成自绘渐变色块（coverURL 传 nil 即走占位）
                rankRow(index: index, name: info.name, subtitle: info.updateFrequency, coverURL: nil) {
                    BeansHaptics.tap()
                    selectedKugouTopList = info
                }
                Divider().overlay(Color.beansComment.opacity(0.12))
            }
        } else {
            EmptyView()
        }
    }

    /// 展开 / 收起切换按钮
    private func rankToggleButton(label: String, icon: String) -> some View {
        Button {
            BeansHaptics.select()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { ranksExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(BeansFont.appFont(13, .medium))
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color.beansAmber)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rankRow(index: Int, name: String, subtitle: String, coverURL: URL?, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .font(BeansFont.appFont(16, .bold, .rounded))
                    .foregroundStyle(index < 3 ? Color.beansAmber : Color.beansComment)
                    .frame(width: 24)
                if let coverURL {
                    CoverImage(url: coverURL, size: 52, cornerRadius: 12)
                } else {
                    rankCoverTile(name: name)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(BeansFont.appFont(15, .semibold))
                        .foregroundStyle(Color.beansLabel)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.beansComment.opacity(0.6))
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 榜单占位色块：渐变底 + 榜名，用于封面不好看/拿不到的平台
    private func rankCoverTile(name: String) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(qqRankGradient(name))
            .frame(width: 52, height: 52)
            .overlay {
                Text(rankShortName(name))
                    .font(BeansFont.appFont(12, .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.55)
                    .padding(4)
            }
    }

    /// 榜名精简：去掉平台前缀，只留「热歌榜」这种核心词
    private func rankShortName(_ name: String) -> String {
        var s = name
        for prefix in ["酷狗音乐", "酷狗", "QQ音乐", "网易云音乐", "网易云"] {
            if s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? name : String(s.prefix(5))
    }

    /// QQ 峰尖榜占位渐变（保留备用）
    private func qqRankGradient(_ name: String) -> LinearGradient {
        let palettes: [[Color]] = [
            [Color(red: 0.35, green: 0.55, blue: 0.95), Color(red: 0.20, green: 0.30, blue: 0.65)],
            [Color(red: 0.95, green: 0.42, blue: 0.36), Color(red: 0.70, green: 0.18, blue: 0.20)],
            [Color(red: 0.20, green: 0.78, blue: 0.62), Color(red: 0.08, green: 0.52, blue: 0.44)],
            [Color(red: 0.92, green: 0.62, blue: 0.25), Color(red: 0.72, green: 0.38, blue: 0.12)],
            [Color(red: 0.62, green: 0.45, blue: 0.90), Color(red: 0.40, green: 0.25, blue: 0.68)],
            [Color(red: 0.30, green: 0.70, blue: 0.85), Color(red: 0.16, green: 0.45, blue: 0.65)]
        ]
        // 不能用 hashValue：它每进程加盐，同一个榜每次启动都换色
        let seed = name.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 9973 } % palettes.count
        return LinearGradient(colors: palettes[seed], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - 每日推荐（横滑歌曲卡 + 播放）

    private var dailySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "每日推荐", trailing: "查看全部") {
                BeansHaptics.tap()
                showDailyList = true
            }
            // 横滑歌曲卡：每日推荐前 8 首
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(dailySongs.prefix(8).enumerated()), id: \.element.identityKey) { index, song in
                        Button {
                            BeansHaptics.tap()
                            player.play(songs: dailySongs, startAt: index)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverImage(url: song.coverURL, size: 108, cornerRadius: 16)
                                    .overlay(alignment: .topLeading) {
                                        if song.isVIP {
                                            Text("VIP")
                                                .font(BeansFont.appFont(9, .bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1.5)
                                                .background(Capsule().fill(Color(red: 0.93, green: 0.25, blue: 0.22)))
                                                .padding(6)
                                        }
                                    }
                                    .overlay(alignment: .bottomTrailing) {
                                        dailyPlayStateBadge(for: song)
                                    }
                                Text(song.name)
                                    .font(BeansFont.appFont(12, .medium))
                                    .foregroundStyle(Color.beansLabel)
                                    .lineLimit(1)
                                    .frame(width: 108, alignment: .leading)
                                Text(song.artists.isEmpty ? song.album : song.artists)
                                    .font(BeansFont.appFont(10))
                                    .foregroundStyle(Color.beansComment)
                                    .lineLimit(1)
                                    .frame(width: 108, alignment: .leading)
                            }
                        }
                        .buttonStyle(GlassPressButtonStyle(scale: 0.94))
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 歌单广场（官方分类 + 双列网格）

    /// 官方歌单分类：全部 + 热门分类（接口失败时用内置兜底）
    private var catChips: [String] {
        if playlistCats.isEmpty {
            return ["全部", "华语", "流行", "经典", "摇滚", "民谣", "电子", "影视原声", "ACG", "怀旧", "欧美", "日韩", "粤语", "古风", "轻音乐", "治愈", "学习", "运动", "夜晚"]
        }
        return ["全部"] + Array(playlistCats.prefix(18))
    }

    private var personalizedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: source == .qq ? "QQ歌单广场" : "歌单广场")
            if source == .netease {
                // 官方分类标签：点击切换分类（「全部」为官方精品歌单）
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(catChips, id: \.self) { cat in
                            Button {
                                BeansHaptics.tap()
                                guard cat != neteaseCat else { return }
                                neteaseCat = cat
                                Task { await loadPlaylists(cat: cat) }
                            } label: {
                                Text(cat)
                                    .font(BeansFont.appFont(12, .medium))
                                    .foregroundStyle(neteaseCat == cat ? Color.white : Color.beansComment)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background {
                                        if neteaseCat == cat {
                                            Capsule().fill(Color.beansAmber)
                                        } else {
                                            Capsule().fill(.ultraThinMaterial)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(displayedPlaylists) { playlist in
                    Button {
                        if source == .qq {
                            selectedQQPlaylist = playlist
                        } else {
                            selectedPlaylist = playlist
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            CoverImage(url: playlist.coverURL, size: 144, cornerRadius: 18)
                                .frame(maxWidth: .infinity)
                            Text(playlist.name)
                                .font(BeansFont.appFont(12, .medium))
                                .foregroundStyle(Color.beansLabel)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                                                        BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.96))
                }
            }
            if personalized.count > collapsedPlaylistCount {
                Button {
                    BeansHaptics.select()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        playlistsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(playlistsExpanded ? "收起歌单广场" : "展开全部（\(personalized.count)）")
                            .font(BeansFont.appFont(13, .semibold))
                        Image(systemName: playlistsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color.beansAmber)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background { BeansGlass(shape: Capsule()) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
            }
        }
    }

    private var collapsedPlaylistCount: Int { 6 }

    private var displayedPlaylists: [Playlist] {
        playlistsExpanded ? personalized : Array(personalized.prefix(collapsedPlaylistCount))
    }

    // MARK: - 动作

    /// 本地音乐的四个「榜」。Subsonic 没有真正的排行榜概念，
    /// 这里是 getAlbumList2 的几种排序，用榜单形式呈现。
    private static let subsonicRanks: [(title: String, subtitle: String, type: String)] = [
        ("热听榜", "最多播放", "frequent"),
        ("新歌榜", "最新加入", "newest"),
        ("热歌榜", "评分最高", "highest"),
        ("最近播放", "最近听过", "recent"),
    ]

    /// 首页的「本地音乐」：横滑卡 + 榜单列表并存，跟平台首页一个结构
    private var subsonicHomeSection: some View {
        VStack(alignment: .leading, spacing: 26) {
            if !SubsonicAuth.shared.isLoggedIn {
                EmptyStateView(icon: "externaldrive.badge.plus", text: "还没连接音乐服务器，去「我的」页添加")
            } else {
                subsonicSongRow(title: "随便听听", songs: subsonicSongs, trailing: "换一批") {
                    Task { await loadSubsonicRandom() }
                }
                subsonicRankList
                subsonicAlbumRow(title: "最近添加", albums: subsonicNewest)
                subsonicSongRow(title: "我的收藏", songs: subsonicStarred, trailing: nil, action: nil)
            }
        }
    }

    /// 四行榜单（与网易云/酷狗同款 rankRow）
    private var subsonicRankList: some View {
        VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "排行榜")
                VStack(spacing: 0) {
                    ForEach(Array(Self.subsonicRanks.enumerated()), id: \.element.type) { index, rank in
                        rankRow(index: index,
                                name: rank.title,
                                subtitle: rank.subtitle,
                                coverURL: nil) {
                            BeansHaptics.tap()
                            selectedSubsonicRank = SubsonicRankItem(
                                title: rank.title, subtitle: rank.subtitle, type: rank.type)
                        }
                        if index < Self.subsonicRanks.count - 1 {
                            Divider().overlay(Color.beansComment.opacity(0.12))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background {
                    BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .beansCardShadow(radius: 9, y: 3)
        }
    }

    /// 横滑歌曲卡（与「每日推荐」同款）
    @ViewBuilder
    private func subsonicSongRow(title: String, songs: [Song], trailing: String?, action: (() -> Void)?) -> some View {
        if !songs.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                if let trailing, let action {
                    SectionHeader(title: title, trailing: trailing) {
                        BeansHaptics.tap()
                        action()
                    }
                } else {
                    SectionHeader(title: title)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(Array(songs.prefix(12).enumerated()), id: \.element.identityKey) { index, song in
                            Button {
                                BeansHaptics.tap()
                                player.play(songs: songs, startAt: index)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    CoverImage(url: song.coverURL, size: 108, cornerRadius: 16)
                                    Text(song.name)
                                        .font(BeansFont.appFont(12, .semibold))
                                        .foregroundStyle(Color.beansLabel)
                                        .lineLimit(1)
                                    Text(song.artists)
                                        .font(BeansFont.appFont(10))
                                        .foregroundStyle(Color.beansComment)
                                        .lineLimit(1)
                                }
                                .frame(width: 108, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .beansScrollIndicatorsHidden()
            }
        }
    }

    /// 横滑专辑卡：点一张就把整张丢进播放队列
    @ViewBuilder
    private func subsonicAlbumRow(title: String, albums: [SubsonicAlbum]) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: title)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(albums.prefix(12)) { album in
                            Button {
                                BeansHaptics.tap()
                                Task { await playAlbum(album) }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    CoverImage(url: album.coverURL, size: 108, cornerRadius: 16)
                                    Text(album.name)
                                        .font(BeansFont.appFont(12, .semibold))
                                        .foregroundStyle(Color.beansLabel)
                                        .lineLimit(1)
                                    Text(album.artist)
                                        .font(BeansFont.appFont(10))
                                        .foregroundStyle(Color.beansComment)
                                        .lineLimit(1)
                                }
                                .frame(width: 108, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .beansScrollIndicatorsHidden()
            }
        }
    }

    private func playAlbum(_ album: SubsonicAlbum) async {
        guard let songs = try? await SubsonicAPI.shared.albumSongs(id: album.id), !songs.isEmpty else {
            ToastCenter.shared.show("这张专辑没有取到曲目")
            return
        }
        player.play(songs: songs, startAt: 0)
    }

    private func loadSubsonicRandom() async {
        subsonicSongs = (try? await SubsonicAPI.shared.randomSongs(count: 30)) ?? []
    }

    /// 三个横滑板块并发拉，互不影响：某接口在某实现上缺失只会让那一栏空着
    private func loadSubsonic() async {
        guard SubsonicAuth.shared.isLoggedIn else {
            subsonicSongs = []
            subsonicNewest = []
            subsonicStarred = []
            return
        }
        async let random = SubsonicAPI.shared.randomSongs(count: 30)
        async let newest = SubsonicAPI.shared.albums(type: "newest", size: 12)
        async let starred = SubsonicAPI.shared.starredSongs(limit: 12)
        subsonicSongs = (try? await random) ?? []
        subsonicNewest = (try? await newest) ?? []
        subsonicStarred = (try? await starred) ?? []
    }

    private func load(force: Bool = false) async {
        // 本地音乐不走平台那套缓存/榜单逻辑，单独拉曲目
        if source == .subsonic {
            loading = subsonicSongs.isEmpty && subsonicNewest.isEmpty
            errorMessage = nil
            await loadSubsonic()
            loading = false
            return
        }
        let cache = DiscoverCache.shared
        let requestedSource = source
        // 网易云非「全部」分类的歌单不缓存（切换分类即重新拉取）
        let requestedCat = neteaseCat
        let loadKey = "\(requestedSource.rawValue)|\(requestedCat)"
        if activeLoadKey == loadKey {
            return
        }
        if !force,
           lastLoadedKey == loadKey,
           Date().timeIntervalSince(lastLoadedAt) < 20,
           hasAnyData {
            loading = false
            errorMessage = nil
            return
        }
        activeLoadKey = loadKey
        defer {
            if activeLoadKey == loadKey {
                activeLoadKey = nil
            }
        }
        let cacheable = requestedCat == "全部" || requestedSource != .netease
        if let cached = cache.cached(for: requestedSource), !force, cacheable {
            guard !Task.isCancelled, requestedSource == source else { return }
            apply(cached)
            loading = false
            errorMessage = nil
            lastLoadedKey = loadKey
            lastLoadedAt = Date()
            if cache.isFresh(cached) { return }
            // 缓存过期：先用缓存展示，后台静默刷新
        } else {
            loading = true
            errorMessage = nil
        }

        do {
            let snapshot = try await fetchSnapshot(for: requestedSource, neteaseCat: requestedCat)
            guard !Task.isCancelled, requestedSource == source else { return }
            apply(snapshot)
            if cacheable, !snapshot.isEmpty {
                cache.save(snapshot, for: requestedSource)
            }
            loading = false
            errorMessage = nil
            lastLoadedKey = loadKey
            lastLoadedAt = Date()
        } catch {
            guard !Task.isCancelled, requestedSource == source else { return }
            loading = false
            if !hasAnyData {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reloadAfterLoginUpdate(_ provider: SearchProvider) {
        if source == provider {
            Task { await load(force: true) }
        } else {
            homeSourceRaw = provider.rawValue
        }
    }

    /// 网易云歌单广场：切换官方分类时单独拉取（不写缓存）
    private func loadPlaylists(cat: String) async {
        guard source == .netease else { return }
        do {
            let pp = cat == "全部"
                ? try await NetEaseAPI.shared.highQualityPlaylists(limit: 18)
                : try await NetEaseAPI.shared.playlistSquare(cat: cat, order: "hot", limit: 18)
            personalized = pp
            errorMessage = nil
        } catch {
            // 分类拉取失败：保留现有歌单，不打断用户
        }
    }

    private func fetchSnapshot(for source: SearchProvider, neteaseCat: String) async throws -> DiscoverCache.Snapshot {
        var snapshot = DiscoverCache.Snapshot()
        snapshot.savedAt = Date()
        switch source {
        // 本地音乐在 load() 开头就已分流返回, 走不到这里; 给个空快照满足返回类型
        case .subsonic:
            return snapshot
        case .qq:
            async let a = QQMusicAPI.shared.recommendSongs(limit: 30)
            async let b = QQMusicAPI.shared.topLists()
            async let c = QQMusicAPI.shared.recommendPlaylists(limit: 12)
            let (dr, tl, pp) = try await (a, b, c)
            snapshot.dailySongs = dr
            snapshot.qqTopLists = tl
            snapshot.personalized = pp
        case .netease:
            async let a = NetEaseAPI.shared.topLists()
            async let b = NetEaseAPI.shared.dailyRecommend()
            // 「全部」展示官方精品歌单，其他分类展示该分类热门歌单
            async let c = neteaseCat == "全部"
                ? NetEaseAPI.shared.highQualityPlaylists(limit: 18)
                : NetEaseAPI.shared.playlistSquare(cat: neteaseCat, order: "hot", limit: 18)
            async let d = NetEaseAPI.shared.playlistCatlist()
            let (tl, dr, pp, cats) = try await (a, b, c, d)
            snapshot.topLists = tl
            snapshot.dailySongs = dr
            snapshot.personalized = pp
            if !cats.isEmpty { playlistCats = cats }
        case .kugou:
            async let songs = KugouMusicAPI.shared.searchSongs(keyword: "热门歌曲", limit: 30)
            async let ranks = KugouMusicAPI.shared.topLists(limit: 10)
            async let playlists = KugouMusicAPI.shared.recommendPlaylists(limit: 12)
            let (daily, top, pp) = try await (songs, ranks, playlists)
            snapshot.dailySongs = daily
            snapshot.kugouTopLists = top
            snapshot.personalized = pp
        }
        return snapshot
    }

    private func apply(_ snapshot: DiscoverCache.Snapshot) {
        dailySongs = snapshot.dailySongs
        topLists = snapshot.topLists
        personalized = snapshot.personalized
        qqTopLists = snapshot.qqTopLists
        kugouTopLists = snapshot.kugouTopLists
    }

    private var hasAnyData: Bool {
        !dailySongs.isEmpty || !topLists.isEmpty || !personalized.isEmpty
            || !qqTopLists.isEmpty || !kugouTopLists.isEmpty
    }
}

// MARK: - QQ 峰尖榜详情

struct QQTopListDetailView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore

    let topID: Int
    let name: String
    @State private var tracks: [Song] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var searchText = ""

    var body: some View {
        let _ = theme.accent
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                Group {
                if loading {
                    LoadingStateView()
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load() }
                    }
                } else {
                    List {
                        Section {
                            HStack(spacing: 12) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    guard !filteredTracks.isEmpty else { return }
                                    BeansHaptics.tap()
                                    player.play(songs: filteredTracks, startAt: 0)
                                }
                                GlassButton(title: "随机播放", systemName: "shuffle") {
                                    guard !filteredTracks.isEmpty else { return }
                                    BeansHaptics.tap()
                                    player.play(songs: filteredTracks, startAt: Int.random(in: 0..<filteredTracks.count))
                                }
                            }
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 8)
                        }
                        Section {
                            ForEach(Array(filteredTracks.enumerated()), id: \.element.identityKey) { index, song in
                                SongCell(song: song, glassRow: true) {
                                    player.play(songs: filteredTracks, startAt: index)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    }
                    .beansScrollContentBackgroundHidden()
                    .listStyle(.plain)
                }
            }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索榜单歌曲")
        }
        .task { await load() }
    }

    private var filteredTracks: [Song] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return tracks }
        return tracks.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            tracks = try await QQMusicAPI.shared.topListSongs(topid: topID)
            loading = false
        } catch {
            errorMessage = error.localizedDescription
            loading = false
        }
    }
}

// MARK: - QQ 歌单内歌曲

struct QQPlaylistSongsSheet: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore

    let playlist: Playlist
    @State private var tracks: [Song] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var searchText = ""

    var body: some View {
        let _ = theme.accent
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                Group {
                if loading {
                    LoadingStateView()
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load() }
                    }
                } else {
                    List {
                        Section {
                            HStack(spacing: 12) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    guard !filteredTracks.isEmpty else { return }
                                    BeansHaptics.tap()
                                    player.play(songs: filteredTracks, startAt: 0)
                                }
                                GlassButton(title: "随机播放", systemName: "shuffle") {
                                    guard !filteredTracks.isEmpty else { return }
                                    BeansHaptics.tap()
                                    player.play(songs: filteredTracks, startAt: Int.random(in: 0..<filteredTracks.count))
                                }
                            }
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 8)
                        }
                        Section {
                            ForEach(Array(filteredTracks.enumerated()), id: \.element.identityKey) { index, song in
                                SongCell(song: song, glassRow: true) {
                                    player.play(songs: filteredTracks, startAt: index)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    }
                    .beansScrollContentBackgroundHidden()
                    .listStyle(.plain)
                }
            }
            }
            .navigationTitle(playlist.name)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索歌单内歌曲")
        }
        .task { await load() }
    }

    private var filteredTracks: [Song] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return tracks }
        return tracks.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            tracks = try await QQMusicAPI.shared.playlistSongs(listID: playlist.id)
            loading = false
        } catch {
            errorMessage = error.localizedDescription
            loading = false
        }
    }
}

// MARK: - 每日推荐全部歌曲

struct DailySongsSheet: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore

    let songs: [Song]
    @State private var searchText = ""

    var body: some View {
        let _ = theme.accent
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                Group {
                if songs.isEmpty {
                    EmptyStateView(icon: "sparkles", text: "今日推荐加载中，下拉刷新试试")
                } else {
                    List {
                    Section {
                        HStack(spacing: 12) {
                            GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                guard !filteredSongs.isEmpty else { return }
                                BeansHaptics.tap()
                                player.play(songs: filteredSongs, startAt: 0)
                            }
                            GlassButton(title: "随机播放", systemName: "shuffle") {
                                guard !filteredSongs.isEmpty else { return }
                                BeansHaptics.tap()
                                player.play(songs: filteredSongs, startAt: Int.random(in: 0..<filteredSongs.count))
                            }
                        }
                        .listRowBackground(Color.clear)
                        .padding(.vertical, 8)
                    }
                    Section {
                        ForEach(Array(filteredSongs.enumerated()), id: \.element.identityKey) { index, song in
                            SongCell(song: song, glassRow: true) {
                                BeansHaptics.tap()
                                player.play(songs: filteredSongs, startAt: index)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                }
                .beansScrollContentBackgroundHidden()
                .listStyle(.plain)
                }
            }
            }
            .navigationTitle("今日推荐")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索每日推荐")
        }
    }

    private var filteredSongs: [Song] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return songs }
        return songs.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }
}
// MARK: - 排行榜详情

struct TopListDetailView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore

    let topList: TopList
    @State private var tracks: [Song] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var searchText = ""

    var body: some View {
        let _ = theme.accent
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                Group {
                if loading {
                    LoadingStateView()
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load() }
                    }
                } else {
                    List {
                        header
                        Section {
                            HStack(spacing: 12) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    guard !filteredTracks.isEmpty else { return }
                                    BeansHaptics.tap()
                                    player.play(songs: filteredTracks, startAt: 0)
                                }
                                GlassButton(title: "随机播放", systemName: "shuffle") {
                                    guard !filteredTracks.isEmpty else { return }
                                    BeansHaptics.tap()
                                    player.play(songs: filteredTracks, startAt: Int.random(in: 0..<filteredTracks.count))
                                }
                            }
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 8)
                        }
                        Section {
                            ForEach(Array(filteredTracks.enumerated()), id: \.element.identityKey) { index, song in
                                SongCell(song: song, glassRow: true) {
                                    player.play(songs: filteredTracks, startAt: index)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    }
                    .beansScrollContentBackgroundHidden()
                    .listStyle(.plain)
                }
            }
            }
            .navigationTitle(topList.name)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索榜单歌曲")
        }
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            CoverImage(url: topList.coverURL, size: 88, cornerRadius: 16)
            VStack(alignment: .leading, spacing: 6) {
                Text(topList.name)
                    .font(BeansFont.appFont(18, .bold))
                    .foregroundStyle(Color.beansLabel)
                Text(topList.updateFrequency)
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(Color.beansComment)
                Text("\(tracks.count) 首")
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(Color.beansComment)
            }
            Spacer()
        }
        .padding(14)
        .background {
            BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .beansCardShadow(radius: 8, y: 3)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var filteredTracks: [Song] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return tracks }
        return tracks.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            tracks = try await NetEaseAPI.shared.playlistTracks(id: topList.id)
            loading = false
        } catch {
            errorMessage = error.localizedDescription
            loading = false
        }
    }
}

// MARK: - 酷狗排行榜详情

struct KugouTopListDetailView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    let topList: KugouTopInfo
    @State private var tracks: [Song] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var searchText = ""

    var body: some View {
        let _ = theme.accent
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                Group {
                if loading {
                    LoadingStateView()
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load() }
                    }
                } else if tracks.isEmpty {
                    EmptyStateView(icon: "music.note.list", text: "该排行榜暂无歌曲")
                } else {
                    List {
                        header
                        Section {
                            HStack(spacing: 12) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    guard !filteredTracks.isEmpty else { return }
                                    BeansHaptics.tap()
                                    player.play(songs: filteredTracks, startAt: 0)
                                }
                                GlassButton(title: "随机播放", systemName: "shuffle") {
                                    guard !filteredTracks.isEmpty else { return }
                                    BeansHaptics.tap()
                                    player.play(songs: filteredTracks, startAt: Int.random(in: 0..<filteredTracks.count))
                                }
                            }
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 8)
                        }
                        Section {
                            ForEach(Array(filteredTracks.enumerated()), id: \.element.identityKey) { index, song in
                                SongCell(song: song, glassRow: true) {
                                    player.play(songs: filteredTracks, startAt: index)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    }
                    .beansScrollContentBackgroundHidden()
                    .listStyle(.plain)
                }
            }
            }
            .navigationTitle(topList.name)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索榜单歌曲")
        }
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            // 酷狗返回的榜单封面很花，跟列表页保持一致用自绘色块
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.30, green: 0.62, blue: 0.95),
                                              Color(red: 0.12, green: 0.36, blue: 0.72)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 88, height: 88)
                .overlay {
                    Text(topList.name)
                        .font(BeansFont.appFont(15, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.5)
                        .padding(8)
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(topList.name)
                    .font(BeansFont.appFont(18, .bold))
                    .foregroundStyle(Color.beansLabel)
                    .lineLimit(2)
                if !topList.updateFrequency.isEmpty {
                    Text(topList.updateFrequency)
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                }
                Text("\(tracks.count) 首")
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(Color.beansComment)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background {
            BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .beansCardShadow(radius: 8, y: 3)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var filteredTracks: [Song] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return tracks }
        return tracks.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            tracks = try await KugouMusicAPI.shared.rankSongs(rankID: topList.id)
            loading = false
        } catch {
            errorMessage = error.localizedDescription
            loading = false
        }
    }
}
