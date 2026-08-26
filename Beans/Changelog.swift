import SwiftUI

// MARK: - 版本更新日志（每次发版追加一条，用于更新弹窗与设置内更新日志）

struct VersionLog: Identifiable {
    let id: String
    let version: String
    let title: String
    let features: [String]
    let fixes: [String]
}

enum ChangelogStore {
    static let lastSeenKey = "beans.lastSeenVersion"

    static var currentVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return short
    }

    static var lastSeenVersion: String {
        UserDefaults.standard.string(forKey: lastSeenKey) ?? ""
    }

    static func markSeen() {
        UserDefaults.standard.set(currentVersion, forKey: lastSeenKey)
    }

    /// 版本更新后首次进入展示更新说明
    static var shouldShowWhatsNew: Bool {
        lastSeenVersion != currentVersion
    }

    static var latest: VersionLog? { logs.first }

    /// 日志按新到旧排列；每次发版在顶部追加一条
    static let logs: [VersionLog] = [
        VersionLog(
            id: "1.6.1",
            version: "1.6.1",
            title: "内置 guoyue2010 免费听歌预设",
            features: [
                "内置 guoyue2010/lxmusic- 的 QQ音乐与网易云兼容音源，新安装或升级后自动补入预设",
                "免费听歌默认开启，官方地址不可用时可直接使用内置预设兜底",
                "支持识别“非常刀”等 LX 事件脚本，并转换为 Beans 可用的模板音源",
                "QQ 音乐登录页移除扫码登录入口，仅保留网页登录与粘贴 Cookie",
                "播放器新增“播放控件跟随封面取色”开关，关闭后播放键、进度条与高亮改用自定义主题色",
                "播放设置新增高刷新动效开关，默认关闭以降低发热和耗电",
                "播放器新增播放/暂停 morph 图标、封面拖动 3D 倾斜与切歌模糊缩放",
                "进度条拖动新增时间预览浮层、整秒吸附和触感反馈",
                "播放器设置新增进度条颜色自定义，可单独覆盖播放进度高亮色",
            ],
            fixes: [
                "导入 guoyue2010 仓库地址与内置预设共用同一套配置，避免两处音源参数不一致",
                "导入音源支持多个返回字段路径，兼容 data.music、data.url、url 等不同响应格式",
                "修复 QQ 音乐同步歌单封面 URL 兼容性，避免封面一直显示加载",
                "降低播放页持续动画帧率，并让进度条流光仅在播放中运行",
                "默认关闭与其他音频混合播放，并主动注册系统播放控制，恢复锁屏与灵动岛播放状态",
                "导入音源改为并发解析，慢源或失效源不会再长时间拖住播放",
                "底栏文字显示开关移入主题设置，设置页归类更清晰",
                "播放页恢复系统全屏承载，修复顶栏按钮点击穿透到底层页面的问题",
                "重构播放器底部控制台，降低打开播放页时的重动画开销",
            ]
        ),

        VersionLog(
            id: "1.6.0",
            version: "1.6.0",
            title: "支持导入 guoyue2010 音源仓库",
            features: [
                "支持直接粘贴 guoyue2010/lxmusic- 仓库地址，一次导入 QQ音乐与网易云兼容源",
                "QQ 通用音源使用歌曲 songmid，网易云通用音源使用歌曲 ID",
                "后导入的音源优先尝试，方便替换已经失效的旧音源",
            ],
            fixes: [
                "音源请求失败时记录网络错误、HTTP 状态码和响应格式问题",
                "避免把音源平台、音质等配置字段错误发送为 HTTP 请求头",
            ]
        ),

        VersionLog(
            id: "1.5.0",
            version: "1.5.0",
            title: "支持导入洛雪音源脚本",
            features: [
                "支持粘贴音源链接或导入 JS / JSON / TXT 配置",
                "自动识别 Huibq keep-alive 洛雪脚本，并转换为网易云与 QQ 音源",
                "设置中可统一开启导入音源，并单独启用、停用或删除每个音源",
                "官方播放地址不可用或仅有试听片段时自动回退导入音源",
            ],
            fixes: [
                "导入音源优先尝试 320K，失败后自动回退 128K",
                "修复旧版 JS 配置提取时遗漏最外层括号的问题",
            ]
        ),

        VersionLog(
            id: "1.4.9",
            version: "1.4.9",
            title: "修复 QQ 独家 VIP 歌曲播放",
            features: [],
            fixes: [
                "播放前补拉 QQ 歌曲详情，使用独家版权歌曲真实的 media_mid 生成官方文件地址",
                "恢复 QQ 官方 songmid + media_mid 文件名格式，兼容 media_mid 与 songmid 不同的曲目",
                "新增 320K、128K、M4A 三级音质回退",
                "播放前验证 QQ CDN 音频地址，遇到 404 自动切换文件候选、CDN 与音质",
            ]
        ),

        VersionLog(
            id: "1.4.8",
            version: "1.4.8",
            title: "修复 QQ 音乐官方播放链路",
            features: [],
            fixes: [
                "修复已登录 QQ 音乐后，会员状态识别失败会跳过官方播放地址的问题",
                "修复 QQ vkey 播放凭证传递方式，优先使用音乐域登录凭证并携带 authst",
                "修复 QQ 扫码登录未完整保存 musickey，导致显示已登录但无法播放的问题",
                "兼容 media_mid、单 MID 与双 MID 文件名，并使用接口返回的可用 CDN 地址",
                "QQ 官方音频请求补充登录 Cookie，修复部分歌曲一直缓冲或无声的问题",
            ]
        ),

        VersionLog(
            id: "1.4.7",
            version: "1.4.7",
            title: "闪退检测 + 歌词进度偏移校正",
            features: [
                "新增闪退检测：捕获未捕获异常与崩溃信号，写入崩溃日志（Documents/BeansLogs/crash-*.log），并在下次启动时提示上次是否异常退出，方便排查闪退原因",
                "新增「歌词进度偏移」调节：歌词与音频不同步时，可在播放器设置中手动校正（正数提前、负数延后）",
            ],
            fixes: [
                "优化启动稳定性与崩溃可追溯性",
            ]
        ),

        VersionLog(
            id: "1.3.4",
            version: "1.3.4",
            title: "UI 板块排序 + 音频混合 + 流畅度与日志优化",
            features: [
                "UI 板块自定义排序：主页 / 音乐库 / 我的界面三个页面均可拖动调整板块上下顺序并保存",
                "新增「与其他音频同时播放」开关（默认开）：打开其他音频软件时 Beans 继续播放不被打断，关闭则自动暂停",
                "主页记住上次选择的平台（网易云 / QQ音乐），下次打开仍保持该平台",
                "底部「发现」改名「主页」，图标改为房子",
                "设置新增「底栏显示文字」开关：关闭后底栏只显示图标、不显示文字",
                "圆形封面自动旋转默认开启",
                "全局 120Hz 高刷新：ProMotion 设备保持高刷新渲染，提升滚动与动画流畅度",
                "引导页免责确认新增「一键填入」按钮，点击自动填入确认文字",
                "日志更详细：记录搜索完成、播放成功（域名）与播放失败 / 中断事件",
            ],
            fixes: [
                "修复 VIP 误判：网易云 fee==8 的翻唱 / 免费歌不再误标 VIP，网易云按 fee==1||4、QQ 按 fee!=0 判定",
                "移除所有第三方音源与「免费听歌」开关，播放一律走官方接口",
                "「我的」界面移除历史听歌排行、定时关闭入口，功能重新排版",
                "设置里的备份 / 恢复、日志按钮改为液态玻璃样式",
                "设置页与播放器设置页流畅度优化（列表懒加载）",
            ]
        ),

        VersionLog(
            id: "1.3.3",
            version: "1.3.3",
            title: "关于页新增免费开源提示",
            features: [
                "关于页新增提示：本软件完全免费，全部功能开源于 GitHub",
            ],
            fixes: []
        ),

        VersionLog(
            id: "1.3.2",
            version: "1.3.2",
            title: "检查更新自动下载新版 IPA",
            features: [
                "检查更新后自动下载新版 IPA：检测到新版本直接下载到「文件」App → Beans → Downloads，无需跳转浏览器",
                "下载或检查失败时提示可能需要特殊网络环境（代理 / VPN）",
                "iOS 26 以下系统隐藏「液态玻璃 / 磨砂玻璃」切换开关，低版本自动使用磨砂玻璃",
            ],
            fixes: []
        ),

        VersionLog(
            id: "1.3.1",
            version: "1.3.1",
            title: "兼容 iOS 15 低版本系统",
            features: [
                "兼容 iOS 15+ 低版本系统：iOS 15 / 16 均可正常运行，液态玻璃自动回退磨砂玻璃",
            ],
            fixes: [
                "引导登录第一页更换为 Beans 专属图标",
                "修复相册上传壁纸在低版本系统无法使用的问题",
            ],
        ),

        VersionLog(
            id: "1.2.2",
            version: "1.2.2",
            title: "自动检测更新 + 兼容 iOS 16 低版本",
            features: [
                "自动检测更新：启动时静默检查 GitHub 最新版本，发现新版弹出提示，可一键前往下载",
                "「我的」页面底部新增「更新地址」与「检查更新」入口，可随时手动检测",
                "兼容 iOS 16+ 低版本系统：液态玻璃自动回退磨砂玻璃，低版本也能正常使用",
            ],
            fixes: []
        ),

        VersionLog(
            id: "1.1.1",
            version: "1.1.1",
            title: "首次使用引导 + 网易云网页登录 + 歌词倾斜",
            features: [
                "首次使用引导式登录：新用户安装后先浏览 4 页引导（欢迎、DIY 美化、双平台、免责确认），再进入软件",
                "网易云网页登录：应用内打开网页版完成登录，支持扫码 / 手机号，自动同步账号与歌单",
                "歌词倾斜角度：新增 3D 立体倾斜（后仰 + 左右倾斜），角度自由调节，营造立体透视感",
                "覆盖安装新版本后首次进入，自动展示本版本更新说明（仅弹一次，设置内可随时查看历史更新日志）",
                "设置配置备份与恢复：一键导出全部自定义配置（主题、配色、歌词效果、播放器布局、音质等）为 JSON 文件，支持导入恢复",
            ],
            fixes: []
        ),

        VersionLog(
            id: "1.0",
            version: "1.0",
            title: "欢迎使用 Beans Music",
            features: [
                "欢迎使用 Beans Music，感谢你的支持！",
                "聚合网易云 / QQ 音乐 / 酷狗音乐：扫码登录即可同步歌单、收藏与 VIP 标识",
                "歌词滚动与翻译、自定义歌词颜色 / 渐变 / 发光，打造专属播放体验",
                "液态玻璃界面、抖音式切歌、动态封面取色、播放排行等丰富功能",
                "本软件仅供个人学习研究使用，音乐版权归各平台所有，请支持正版",
            ],
            fixes: []
        ),
    ]
}

// MARK: - 更新说明弹窗（每次升级首次进入展示）

struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: ThemeStore.shared.backgroundSyncAll ? ThemeStore.shared.customBackground : nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let log = ChangelogStore.latest {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Beans Music")
                                    .font(BeansFont.appFont(17, .bold))
                                    .foregroundStyle(Color.beansLabel)
                                Text("已更新至 \(log.version) · \(log.title)")
                                    .font(BeansFont.appFont(13))
                                    .foregroundStyle(Color.beansComment)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            VStack(alignment: .leading, spacing: 12) {
                                Text("新增功能")
                                    .font(BeansFont.appFont(14, .bold))
                                    .foregroundStyle(Color.beansAmber)
                                ForEach(log.features, id: \.self) { item in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.beansAmber)
                                            .padding(.top, 2)
                                        Text(item)
                                            .font(BeansFont.appFont(13))
                                            .foregroundStyle(Color.beansLabel)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                if !log.fixes.isEmpty {
                                    Divider().overlay(Color.beansComment.opacity(0.15))
                                    Text("问题修复")
                                        .font(BeansFont.appFont(14, .bold))
                                        .foregroundStyle(Color.beansAmber)
                                    ForEach(log.fixes, id: \.self) { item in
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 12))
                                                .foregroundStyle(Color.beansAmber)
                                                .padding(.top, 2)
                                            Text(item)
                                                .font(BeansFont.appFont(13))
                                                .foregroundStyle(Color.beansLabel)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            }
                            .beansCardShadow(radius: 9, y: 3)
                        }
                    }
                    .padding(16)
                }
                .beansScrollIndicatorsHidden()
            }
            .navigationTitle("更新说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始使用") {
                        ChangelogStore.markSeen()
                        dismiss()
                    }
                    .font(BeansFont.appFont(14, .semibold))
                    .foregroundStyle(Color.beansAmber)
                }
            }
        }
        .modifier(BeansSheetModifier(detents: [.medium, .large]))
    }
}

// MARK: - 设置内更新日志（汇聚每次更新内容）

struct ChangelogListView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: ThemeStore.shared.backgroundSyncAll ? ThemeStore.shared.customBackground : nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(ChangelogStore.logs) { log in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Text("v\(log.version)")
                                        .font(BeansFont.appFont(15, .bold))
                                        .foregroundStyle(Color.beansAmber)
                                    Text(log.title)
                                        .font(BeansFont.appFont(14, .semibold))
                                        .foregroundStyle(Color.beansLabel)
                                }
                                ForEach(log.features, id: \.self) { item in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text("·")
                                            .foregroundStyle(Color.beansComment)
                                        Text(item)
                                            .font(BeansFont.appFont(12))
                                            .foregroundStyle(Color.beansLabel)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                ForEach(log.fixes, id: \.self) { item in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text("·")
                                            .foregroundStyle(Color.beansAmber)
                                        Text(item)
                                            .font(BeansFont.appFont(12))
                                            .foregroundStyle(Color.beansLabel)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                BeansGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            }
                            .beansCardShadow(radius: 8, y: 3)
                        }
                    }
                    .padding(16)
                }
                .beansScrollIndicatorsHidden()
            }
            .navigationTitle("更新日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .modifier(BeansSheetModifier(detents: [.medium, .large]))
    }
}

// MARK: - 软件使用说明

struct UsageGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let sections: [(title: String, icon: String, lines: [String])] = [
        (
            "应用简介",
            "music.note.house.fill",
            [
                "Beans Music 是一款聚合网易云音乐、QQ 音乐与酷狗音乐资源的第三方音乐播放器客户端，旨在为您提供跨平台的音乐发现、搜索与播放体验。本应用仅供个人学习研究使用，禁止用于商业及非法用途。"
            ]
        ),
        (
            "多平台切换",
            "arrow.left.arrow.right",
            [
                "首页、搜索与音乐库顶部均可切换数据源平台。每日推荐、排行榜、歌单广场与搜索热榜会随平台切换展示对应内容。"
            ]
        ),
        (
            "账号服务",
            "person.crop.circle.badge.checkmark",
            [
                "「我的」页面支持网易云、QQ 音乐与酷狗音乐账号登录（扫码 / 网页授权）。登录后自动同步各平台歌单、收藏与 VIP 标识，享受完整播放权益。"
            ]
        ),
        (
            "播放体验",
            "play.circle.fill",
            [
                "全屏播放器支持点击封面切换歌词视图，进度条可点击或拖动跳转，支持倍速、定时关闭、循环模式与音质选择。歌词支持发光、渐变、自定义颜色与位置调节。"
            ]
        ),
        (
            "个性化定制",
            "paintpalette.fill",
            [
                "支持上传自定义壁纸、全局主题色、底部布局自由调整（拖动组件到任意位置），让播放器界面更贴合您的审美。"
            ]
        ),
        (
            "使用提示",
            "lightbulb.fill",
            [
                "播放器右上角「更多」菜单集中管理定时关闭、下载、音质等次要功能；「我的」右上角设置包含外观、播放与更新日志。",
                "遇到播放异常时，可尝试切换音源平台或检查账号登录状态。"
            ]
        )
    ]

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: ThemeStore.shared.backgroundSyncAll ? ThemeStore.shared.customBackground : nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: section.icon)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color.beansAmber)
                                    Text(section.title)
                                        .font(BeansFont.appFont(14, .bold))
                                        .foregroundStyle(Color.beansLabel)
                                }
                                ForEach(section.lines, id: \.self) { line in
                                    Text(line)
                                        .font(BeansFont.appFont(12.5))
                                        .foregroundStyle(Color.beansLabel.opacity(0.85))
                                        .lineSpacing(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                BeansGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            }
                            .beansCardShadow(radius: 8, y: 3)
                        }
                        Text("Beans Music · 仅供学习交流，纯 AI 实现此应用 · 接入网易云音乐、QQ 音乐等公开接口")
                            .font(BeansFont.appFont(11))
                            .foregroundStyle(Color.beansComment.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(16)
                }
                .beansScrollIndicatorsHidden()
            }
            .navigationTitle("软件使用说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .modifier(BeansSheetModifier(detents: [.large]))
    }
}
