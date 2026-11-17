import Foundation

@Observable
final class SettingsStore {
    private let key = "reader_settings_v1"

    var settings: ReaderSettings {
        didSet {
            save()
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(ReaderSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = ReaderSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
