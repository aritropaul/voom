import Foundation

@Observable @MainActor
public final class PresetStore {
    public static let shared = PresetStore()

    private static let storageKey = "RecordingPresets"

    public var presets: [RecordingPreset] = []

    private init() {
        load()
    }

    public func add(_ preset: RecordingPreset) {
        presets.append(preset)
        save()
    }

    public func delete(_ preset: RecordingPreset) {
        presets.removeAll { $0.id == preset.id }
        save()
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    public func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([RecordingPreset].self, from: data) else {
            return
        }
        presets = decoded
    }
}
