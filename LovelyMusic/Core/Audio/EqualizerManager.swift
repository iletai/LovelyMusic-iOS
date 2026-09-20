import SwiftUI

// NOTE: Equalizer access is gated behind premium in SettingsView.
// Non-premium users see a PRO badge and paywall instead of EqualizerView.
@Observable final class EqualizerManager {
    /// When true, didSet observers on selectedPreset and customBands
    /// skip their UserDefaults writes. This prevents redundant double-writes
    /// when selectPreset() sets both properties in sequence.
    private var isBatchUpdate = false

    var isEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "equalizerEnabled")
            NotificationCenter.default.post(name: .equalizerChanged, object: nil)
        }
    }

    var selectedPreset: EqualizerPreset = .flat {
        didSet {
            guard !isBatchUpdate else { return }
            if let data = try? JSONEncoder().encode(selectedPreset) {
                UserDefaults.standard.set(data, forKey: "equalizerPreset")
            }
        }
    }

    var customBands: [Float] = Array(repeating: 0, count: 10) {
        didSet {
            guard !isBatchUpdate else { return }
            UserDefaults.standard.set(customBands, forKey: "equalizerCustomBands")
            NotificationCenter.default.post(name: .equalizerChanged, object: nil)
        }
    }

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "equalizerEnabled")
        if let data = UserDefaults.standard.data(forKey: "equalizerPreset"),
           let preset = try? JSONDecoder().decode(EqualizerPreset.self, from: data) {
            selectedPreset = preset
        }
        if let bands = UserDefaults.standard.array(forKey: "equalizerCustomBands") as? [Float], bands.count == 10 {
            customBands = bands
        }
    }

    func selectPreset(_ preset: EqualizerPreset) {
        isBatchUpdate = true
        selectedPreset = preset
        customBands = preset.bands
        isBatchUpdate = false

        if let data = try? JSONEncoder().encode(preset) {
            UserDefaults.standard.set(data, forKey: "equalizerPreset")
        }
        UserDefaults.standard.set(preset.bands, forKey: "equalizerCustomBands")
        NotificationCenter.default.post(name: .equalizerChanged, object: nil)
    }

    func resetToFlat() {
        selectPreset(.flat)
    }
}

extension Notification.Name {
    static let equalizerChanged = Notification.Name("equalizerChanged")
}
