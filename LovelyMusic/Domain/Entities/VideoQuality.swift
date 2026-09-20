import Foundation

enum VideoQuality: String, CaseIterable {
    case sd360
    case sd480
    case hd720
    case hd1080
    case qhd1440
    case uhd2160
    case auto

    var displayName: String {
        switch self {
        case .sd360: return "360p"
        case .sd480: return "480p"
        case .hd720: return "720p"
        case .hd1080: return "1080p Full HD"
        case .qhd1440: return "1440p 2K"
        case .uhd2160: return "2160p 4K"
        case .auto: return String(localized: "Auto (Highest)")
        }
    }

    var maxHeight: Int {
        switch self {
        case .sd360: return 360
        case .sd480: return 480
        case .hd720: return 720
        case .hd1080: return 1080
        case .qhd1440: return 1440
        case .uhd2160: return 2160
        case .auto: return Int.max
        }
    }
}
