import Foundation

// MARK: - Demo Catalog — Codable model for demo_catalog.json

struct DemoCatalog: Codable {
    let artists: [DemoArtistEntry]
    let albums: [DemoAlbumEntry]
    let sections: [DemoSectionEntry]
}

struct DemoArtistEntry: Codable {
    let id: String
    let name: String
    let thumbnailURL: String?
    let subscriberCount: String?
    let description: String?

    func toArtist(songs: [Song] = [], albums: [Album] = [], singles: [Album] = []) -> Artist {
        Artist(
            id: id,
            name: name,
            thumbnailURL: thumbnailURL,
            subscriberCount: subscriberCount,
            description: description,
            songs: songs,
            albums: albums,
            singles: singles
        )
    }
}

struct DemoAlbumEntry: Codable {
    let id: String
    let title: String
    let artistName: String
    let artistId: String?
    let year: String?
    let thumbnailURL: String?
    let description: String?
    let songs: [DemoSongEntry]

    func toAlbum() -> Album {
        Album(
            id: id,
            title: title,
            artistName: artistName,
            artistId: artistId,
            year: year,
            thumbnailURL: thumbnailURL,
            description: description,
            songs: songs.map { $0.toSong() }
        )
    }
}

struct DemoSongEntry: Codable {
    let id: String
    let title: String
    let artistName: String
    let artistId: String?
    let albumName: String?
    let albumId: String?
    let duration: Int?
    let thumbnailURL: String?

    func toSong() -> Song {
        Song(
            id: id,
            title: title,
            artistName: artistName,
            artistId: artistId,
            albumName: albumName,
            albumId: albumId,
            duration: duration,
            thumbnailURL: thumbnailURL
        )
    }
}

struct DemoSectionEntry: Codable {
    let title: String
    let items: [DemoSectionItemEntry]
}

struct DemoSectionItemEntry: Codable {
    let type: String
    // Song fields
    let id: String
    let title: String?
    let artistName: String?
    let artistId: String?
    let albumName: String?
    let albumId: String?
    let duration: Int?
    let thumbnailURL: String?
    let year: String?
    // Artist fields
    let name: String?
    let subscriberCount: String?

    func toMusicSectionItem() -> MusicSectionItem? {
        switch type {
        case "song":
            let song = Song(
                id: id,
                title: title ?? "",
                artistName: artistName ?? "",
                artistId: artistId,
                albumName: albumName,
                albumId: albumId,
                duration: duration,
                thumbnailURL: thumbnailURL
            )
            return .song(song)
        case "album":
            let album = Album(
                id: id,
                title: title ?? "",
                artistName: artistName ?? "",
                artistId: artistId,
                year: year,
                thumbnailURL: thumbnailURL,
                songs: []
            )
            return .album(album)
        case "artist":
            let artist = Artist(
                id: id,
                name: name ?? title ?? "",
                thumbnailURL: thumbnailURL,
                subscriberCount: subscriberCount,
                songs: [],
                albums: [],
                singles: []
            )
            return .artist(artist)
        default:
            return nil
        }
    }
}
