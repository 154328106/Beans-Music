import SwiftUI
import Combine

/// 用户选择需要显示的平台。只控制入口可见性，不删除平台能力。
final class PlatformPreferenceStore: ObservableObject {
    static let shared = PlatformPreferenceStore()

    private static let key = "beans.enabledPlatforms.v1"

    @Published private(set) var selectedRaw: Set<String>

    var changes: AnyPublisher<Set<String>, Never> { $selectedRaw.eraseToAnyPublisher() }

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        if saved.isEmpty {
            selectedRaw = Set(SearchProvider.allCases.map(\.rawValue))
        } else {
            selectedRaw = Set(saved)
        }
        // 老版本保存的是“当时所有平台”，升级后不会自动包含新枚举；只迁移一次，
        // 之后用户手动隐藏飞牛音乐时保持其选择。
        let feiniuMigrationKey = "beans.enabledPlatforms.feiniu.v1"
        if !UserDefaults.standard.bool(forKey: feiniuMigrationKey) {
            selectedRaw.insert(SearchProvider.feiniu.rawValue)
            UserDefaults.standard.set(true, forKey: feiniuMigrationKey)
        }
        normalize()
        save()
    }

    var enabledSearchProviders: [SearchProvider] {
        var list = SearchProvider.allCases.filter { selectedRaw.contains($0.rawValue) }
        if list.isEmpty { list = [.netease] }
        // 本地音乐不是平台, 不受开关控制; 即使被关掉也补回来, 且固定排在最前
        if !list.contains(.subsonic) { list.insert(.subsonic, at: 0) }
        return list
    }

    var enabledLibraryProviders: [LibraryProvider] {
        LibraryProvider.allCases.filter {
            // 本地音乐(自建服务器)不是平台, 不受"启用哪些平台"开关控制
            guard let sp = $0.searchProvider else { return true }
            return selectedRaw.contains(sp.rawValue)
        }
    }

    var summaryText: String {
        enabledSearchProviders.map(\.title).joined(separator: " / ")
    }

    func isEnabled(_ provider: SearchProvider) -> Bool {
        selectedRaw.contains(provider.rawValue)
    }

    func isEnabled(_ provider: LibraryProvider) -> Bool {
        guard let sp = provider.searchProvider else { return true }
        return isEnabled(sp)
    }

    func set(_ provider: SearchProvider, enabled: Bool) {
        if enabled {
            selectedRaw.insert(provider.rawValue)
        } else if selectedRaw.count > 1 {
            selectedRaw.remove(provider.rawValue)
        }
        normalize()
        save()
    }

    func ensureVisible(_ provider: SearchProvider) -> SearchProvider {
        isEnabled(provider) ? provider : enabledSearchProviders.first ?? .netease
    }

    func ensureVisible(_ provider: LibraryProvider) -> LibraryProvider {
        isEnabled(provider) ? provider : enabledLibraryProviders.first ?? .netease
    }

    func resetToDefault() {
        selectedRaw = Set(SearchProvider.allCases.map(\.rawValue))
        save()
    }

    private func normalize() {
        let allowed = Set(SearchProvider.allCases.map(\.rawValue))
        selectedRaw = selectedRaw.intersection(allowed)
        if selectedRaw.isEmpty {
            selectedRaw = [SearchProvider.netease.rawValue]
        }
    }

    private func save() {
        UserDefaults.standard.set(Array(selectedRaw), forKey: Self.key)
    }
}

extension LibraryProvider {
    /// 对应的搜索平台；本机与自建服务器没有对应平台，返回 nil
    var searchProvider: SearchProvider? {
        switch self {
        case .netease: return .netease
        case .qq: return .qq
        case .kugou: return .kugou
        case .server: return .subsonic
        case .feiniu: return .feiniu
        }
    }
}

struct PlatformPreferencePicker: View {
    @ObservedObject private var store = PlatformPreferenceStore.shared

    var body: some View {
        VStack(spacing: 10) {
            ForEach(SearchProvider.allCases) { provider in
                Button {
                    BeansHaptics.select()
                    store.set(provider, enabled: !store.isEnabled(provider))
                } label: {
                    HStack(spacing: 12) {
                        if let imageName = provider.brandImageName {
                            Image(imageName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: provider.icon)
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 28, height: 28)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.title)
                                .font(BeansFont.appFont(14, .semibold))
                                .foregroundStyle(Color.beansLabel)
                            Text(store.isEnabled(provider) ? "已显示" : "已隐藏")
                                .font(BeansFont.appFont(11))
                                .foregroundStyle(Color.beansComment)
                        }
                        Spacer()
                        Image(systemName: store.isEnabled(provider) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(store.isEnabled(provider) ? Color.beansAmber : Color.beansComment)
                    }
                    .padding(12)
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(store.isEnabled(provider) ? Color.beansAmber.opacity(0.12) : Color.primary.opacity(0.04))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(store.isEnabled(provider) ? Color.beansAmber.opacity(0.35) : Color.beansComment.opacity(0.12), lineWidth: 0.8)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
