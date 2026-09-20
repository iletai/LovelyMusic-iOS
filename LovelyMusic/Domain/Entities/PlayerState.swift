import Foundation

enum PlayerState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case error(String)

    var isActive: Bool {
        switch self {
        case .playing, .paused, .buffering: return true
        default: return false
        }
    }
}
