import Foundation

enum SearchFilterMapper {
    static func toParams(_ filter: SearchFilter) -> String {
        switch filter {
        case .songs: return "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
        case .albums: return "EgWKAQIYAWoKEAkQBRAKEAMQBA%3D%3D"
        case .artists: return "EgWKAQIgAWoKEAkQBRAKEAMQBA%3D%3D"
        case .playlists: return "EgWKAQIoAWoKEAkQBRAKEAMQBA%3D%3D"
        }
    }
}
