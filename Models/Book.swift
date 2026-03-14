import Foundation
import SwiftData

enum BookFileType: String, Codable {
    case pdf
    case epub
    case txt
    case markdown
}

@Model
final class Book {
    var id: UUID
    var title: String
    var author: String?
    @Attribute(.externalStorage) var coverImage: Data?
    var filePath: String
    var fileType: BookFileType
    var dateAdded: Date
    var lastOpened: Date?
    var currentPage: Int
    var currentChapter: String?
    var currentPosition: Double
    var ttsSentenceIndex: Int?
    var preferredEngine: String?
    var preferredVoice: String?

    init(
        title: String,
        author: String? = nil,
        coverImage: Data? = nil,
        filePath: String,
        fileType: BookFileType
    ) {
        self.id = UUID()
        self.title = title
        self.author = author
        self.coverImage = coverImage
        self.filePath = filePath
        self.fileType = fileType
        self.dateAdded = Date()
        self.lastOpened = nil
        self.currentPage = 0
        self.currentChapter = nil
        self.currentPosition = 0.0
    }

    var fileURL: URL? {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return documentsURL?.appendingPathComponent(filePath)
    }

    var displayAuthor: String {
        author ?? "Unknown Author"
    }
}
