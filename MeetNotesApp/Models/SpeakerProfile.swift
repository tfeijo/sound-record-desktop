import Foundation
import SwiftData

@Model
final class SpeakerProfile {
    var id: UUID
    var name: String
    var embeddingData: Data?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String = "",
        embeddingData: Data? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.embeddingData = embeddingData
        self.createdAt = createdAt
    }
}
