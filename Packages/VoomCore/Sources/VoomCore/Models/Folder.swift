import Foundation

public struct Folder: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var colorHex: String?

    public init(name: String, colorHex: String? = nil) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.colorHex = colorHex
    }
}
