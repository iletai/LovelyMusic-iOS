import Foundation

struct EqualizerPreset: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let icon: String
    let bands: [Float]

    var localizedName: String {
        String(localized: String.LocalizationValue(name))
    }

    static let frequencyLabels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]

    static let flat = EqualizerPreset(id: "flat", name: "Flat", icon: "equal", bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    static let bassBoost = EqualizerPreset(id: "bass", name: "Bass Boost", icon: "speaker.wave.3", bands: [6, 5, 4, 2, 1, 0, 0, 0, 0, 0])
    static let trebleBoost = EqualizerPreset(id: "treble", name: "Treble Boost", icon: "waveform", bands: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6])
    static let vocal = EqualizerPreset(id: "vocal", name: "Vocal", icon: "mic", bands: [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1])
    static let rock = EqualizerPreset(id: "rock", name: "Rock", icon: "guitars", bands: [5, 4, 2, 0, -1, -1, 0, 2, 4, 5])
    static let pop = EqualizerPreset(id: "pop", name: "Pop", icon: "music.note", bands: [-1, 1, 3, 4, 3, 0, -1, -1, 0, 1])
    static let jazz = EqualizerPreset(id: "jazz", name: "Jazz", icon: "pianokeys", bands: [3, 2, 1, 2, 0, -1, 0, 1, 2, 3])
    static let classical = EqualizerPreset(id: "classical", name: "Classical", icon: "music.quarternote.3", bands: [4, 3, 2, 1, 0, 0, 0, 1, 3, 4])

    static let allPresets: [EqualizerPreset] = [.flat, .bassBoost, .trebleBoost, .vocal, .rock, .pop, .jazz, .classical]
}
