import Foundation

struct HomeResult {
    let sections: [MusicSection]
    let continuation: String?
    var moodAndGenres: [MoodAndGenre] = []
    var chips: [HomeChip] = []
}
