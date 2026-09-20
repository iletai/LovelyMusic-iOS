import os
import Foundation

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.lovelymusic.app"

    static let audio = Logger(subsystem: subsystem, category: "AudioEngine")
    static let audioCache = Logger(subsystem: subsystem, category: "AudioCache")
    static let audioSession = Logger(subsystem: subsystem, category: "AudioSession")
    static let eq = Logger(subsystem: subsystem, category: "EQ")
    static let player = Logger(subsystem: subsystem, category: "Player")
    static let download = Logger(subsystem: subsystem, category: "Download")
    static let innerTube = Logger(subsystem: subsystem, category: "InnerTube")
    static let auth = Logger(subsystem: subsystem, category: "Auth")
    static let playlist = Logger(subsystem: subsystem, category: "Playlist")
    static let favorites = Logger(subsystem: subsystem, category: "Favorites")
    static let app = Logger(subsystem: subsystem, category: "App")
    static let ui = Logger(subsystem: subsystem, category: "UI")
    static let nowPlaying = Logger(subsystem: subsystem, category: "NowPlaying")
}
