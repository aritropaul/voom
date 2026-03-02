import Foundation

struct Folder: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var colorHex: String?

    init(name: String, colorHex: String? = nil) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.colorHex = colorHex
    }
}
