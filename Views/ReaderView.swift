import SwiftUI
import SwiftData

struct ReaderView: View {
    @Bindable var book: Book
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch book.fileType {
            case .pdf:
                PDFReaderView(book: book)
            case .epub:
                EPubReaderView(book: book)
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            book.lastOpened = Date()
        }
    }
}
