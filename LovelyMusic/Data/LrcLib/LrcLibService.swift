import Foundation

final class LrcLibService: LyricsRepositoryProtocol {
    private let baseURL: URL
    private let session = URLSession.shared
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init() {
        guard let url = URL(string: "https://lrclib.net/api") else {
            fatalError("Invalid hardcoded LrcLib base URL")
        }
        self.baseURL = url
    }

    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("get"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        var queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        if let duration {
            queryItems.append(URLQueryItem(name: "duration", value: String(duration)))
        }
        components.queryItems = queryItems

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("LovelyMusic/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }

        let lrcResponse = try decoder.decode(LrcLibResponse.self, from: data)

        if let syncedLyrics = lrcResponse.syncedLyrics, !syncedLyrics.isEmpty {
            let lines = parseLRC(syncedLyrics)
            return SyncedLyrics(lines: lines, source: "LrcLib")
        }

        if let plainLyrics = lrcResponse.plainLyrics, !plainLyrics.isEmpty {
            let lines = plainLyrics.components(separatedBy: .newlines)
                .enumerated()
                .map { LyricLine(time: Double($0.offset) * 3.0, text: $0.element) }
            return SyncedLyrics(lines: lines, source: "LrcLib (plain)")
        }

        return nil
    }

    private func parseLRC(_ lrc: String) -> [LyricLine] {
        lrc.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("["),
                  let closeBracket = line.firstIndex(of: "]") else { return nil }

            let timeStr = String(line[line.index(after: line.startIndex)..<closeBracket])
            let text = String(line[line.index(after: closeBracket)...])
                .trimmingCharacters(in: .whitespaces)

            guard !text.isEmpty else { return nil }

            let timeParts = timeStr.split(separator: ":")
            guard timeParts.count == 2,
                  let minutes = Double(timeParts[0]),
                  let seconds = Double(timeParts[1]) else { return nil }

            let time = minutes * 60.0 + seconds
            return LyricLine(time: time, text: text)
        }
    }
}

private struct LrcLibResponse: Codable {
    let syncedLyrics: String?
    let plainLyrics: String?
    let trackName: String?
    let artistName: String?
    let duration: Double?
}
