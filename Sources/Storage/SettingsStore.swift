import Foundation

@Observable
final class SettingsStore {
    private let key = "reader_settings_v1"
    private let opdsSourcesKey = "opds_sources_v1"
    private let opdsSelectedIdKey = "opds_selected_source_id_v1"
    private let opdsDefaultsSeededKey = "opds_defaults_seeded_v1"

    static let defaultOpdsZhName = "轻小说文库 (中文)"
    static let defaultOpdsZhUrl = "https://opds.wol.moe/zh_CN"
    static let defaultOpdsEnName = "Project Gutenberg (英文公版)"
    static let defaultOpdsEnUrl = "https://www.gutenberg.org/ebooks/search.opds/"

    var settings: ReaderSettings {
        didSet {
            scheduleSaveSettings()
        }
    }

    private var saveWorkItem: DispatchWorkItem?

    var opdsSources: [OpdsSource] = []
    var selectedOpdsSourceId: String?

    var selectedOpdsSource: OpdsSource? {
        if let id = selectedOpdsSourceId, let hit = opdsSources.first(where: { $0.id == id }) {
            return hit
        }
        return opdsSources.first
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(ReaderSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = ReaderSettings()
        }
        loadOpdsSources()
    }

    func applyThemeMode(_ mode: AppThemeMode) {
        var next = settings
        next.themeMode = mode
        next.readerBgColorHex = -1
        next.readerFocusColorHex = -1
        next.readerBottomBgColorHex = -1
        next.readerSentenceCardColorHex = -1
        next.readerWordCardColorHex = -1
        settings = next
    }

    private func scheduleSaveSettings() {
        saveWorkItem?.cancel()
        let snapshot = settings
        let storageKey = key
        let item = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: storageKey)
            }
        }
        saveWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    // MARK: - OPDS Sources Store
    static func defaultOpdsSources() -> [OpdsSource] {
        [
            OpdsSource(name: defaultOpdsZhName, url: defaultOpdsZhUrl),
            OpdsSource(name: defaultOpdsEnName, url: defaultOpdsEnUrl)
        ]
    }

    private func loadOpdsSources() {
        let ud = UserDefaults.standard
        var existing: [OpdsSource] = []
        if let data = ud.data(forKey: opdsSourcesKey),
           let decoded = try? JSONDecoder().decode([OpdsSource].self, from: data) {
            existing = decoded.filter { !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        var selectedId = ud.string(forKey: opdsSelectedIdKey)

        if !ud.bool(forKey: opdsDefaultsSeededKey) {
            var existingUrls = Set(existing.map { $0.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() })
            for def in Self.defaultOpdsSources() {
                let norm = def.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
                if existingUrls.insert(norm).inserted {
                    existing.append(def)
                }
            }
            if selectedId == nil || selectedId?.isEmpty == true {
                selectedId = existing.first?.id
            }
            ud.set(true, forKey: opdsDefaultsSeededKey)
            self.opdsSources = existing
            self.selectedOpdsSourceId = selectedId
            persistOpdsSources()
            return
        }

        self.opdsSources = existing
        self.selectedOpdsSourceId = selectedId
    }

    private func persistOpdsSources() {
        let ud = UserDefaults.standard
        if let data = try? JSONEncoder().encode(opdsSources) {
            ud.set(data, forKey: opdsSourcesKey)
        }
        ud.set(selectedOpdsSourceId, forKey: opdsSelectedIdKey)
    }

    func selectOpdsSource(_ id: String?) {
        selectedOpdsSourceId = id
        UserDefaults.standard.set(id, forKey: opdsSelectedIdKey)
    }

    func addOrUpdateOpdsSource(_ source: OpdsSource) {
        if let idx = opdsSources.firstIndex(where: { $0.id == source.id }) {
            opdsSources[idx] = source
        } else {
            opdsSources.append(source)
        }
        selectedOpdsSourceId = source.id
        persistOpdsSources()
    }

    func deleteOpdsSource(_ id: String) {
        opdsSources.removeAll { $0.id == id }
        if selectedOpdsSourceId == id {
            selectedOpdsSourceId = opdsSources.first?.id
        }
        persistOpdsSources()
    }

    func restoreDefaultOpdsSources() {
        var existingUrls = Set(opdsSources.map { $0.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() })
        for def in Self.defaultOpdsSources() {
            let norm = def.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            if existingUrls.insert(norm).inserted {
                opdsSources.append(def)
            }
        }
        if selectedOpdsSourceId == nil || selectedOpdsSourceId?.isEmpty == true {
            selectedOpdsSourceId = opdsSources.first?.id
        }
        persistOpdsSources()
    }
}
