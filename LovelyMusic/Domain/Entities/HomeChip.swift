import Foundation

struct HomeChip: Identifiable, Hashable {
    let id: String
    let title: String
    let params: String?
    let isSelected: Bool
}
