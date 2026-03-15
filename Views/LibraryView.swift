import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]

    @State private var isImporting = false
    @State private var selectedBook: Book?

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    emptyLibraryView
                } else {
                    libraryGrid
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isImporting = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.pdf, .epub, .plainText, .markdown],
                allowsMultipleSelection: true
            ) { result in
                handleFileImport(result)
            }
            .navigationDestination(item: $selectedBook) { book in
                ReaderView(book: book)
            }
            .task {
                await scanDocumentsFolder()
            }
        }
    }

    private func scanDocumentsFolder() async {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

        let existingPaths = Set(books.map { $0.filePath })

        do {
            let files = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            for fileURL in files {
                let fileName = fileURL.lastPathComponent
                guard !existingPaths.contains(fileName) else { continue }

                let ext = fileURL.pathExtension.lowercased()
                guard ext == "pdf" || ext == "epub" || ext == "txt" || ext == "md" else { continue }

                let fileType: BookFileType
                switch ext {
                case "pdf": fileType = .pdf
                case "epub": fileType = .epub
                case "txt": fileType = .txt
                case "md": fileType = .markdown
                default: continue
                }
                let title = fileURL.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: " ")

                // Insert book immediately without cover
                let book = Book(
                    title: title,
                    author: nil,
                    coverImage: nil,
                    filePath: fileName,
                    fileType: fileType
                )
                modelContext.insert(book)

                // Load cover in background — avoid passing SwiftData model across isolation
                if fileType == .pdf {
                    let url = fileURL
                    Task {
                        let (author, coverImage) = await Task.detached {
                            PDFMetadataExtractor.extractMetadata(from: url)
                        }.value
                        book.author = author
                        book.coverImage = coverImage
                    }
                }
            }
        } catch {
            print("Failed to scan documents: \(error)")
        }
    }

    private var emptyLibraryView: some View {
        ContentUnavailableView {
            Label("No Books", systemImage: "books.vertical")
        } description: {
            Text("Tap + to import PDF, ePub, TXT, or Markdown files")
        } actions: {
            Button("Import Books") {
                isImporting = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var libraryGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(books) { book in
                    BookCardView(book: book)
                        .onTapGesture {
                            selectedBook = book
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteBook(book)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .padding()
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                importBook(from: url)
            }
        case .failure(let error):
            print("Import failed: \(error.localizedDescription)")
        }
    }

    private func importBook(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            print("Failed to access security scoped resource")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let fileType: BookFileType
        switch url.pathExtension.lowercased() {
        case "pdf": fileType = .pdf
        case "epub": fileType = .epub
        case "txt": fileType = .txt
        case "md": fileType = .markdown
        default:
            print("Unsupported file type: \(url.pathExtension)")
            return
        }

        do {
            guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let destinationFilename = "\(UUID().uuidString).\(url.pathExtension)"
            let destinationURL = documentsURL.appendingPathComponent(destinationFilename)

            try FileManager.default.copyItem(at: url, to: destinationURL)

            let title = url.deletingPathExtension().lastPathComponent
            var author: String? = nil
            var coverImage: Data? = nil

            if fileType == .pdf {
                (author, coverImage) = PDFMetadataExtractor.extractMetadata(from: destinationURL)
            } else if fileType == .epub {
                if let metadata = EPubParser.parseMetadata(from: destinationURL) {
                    if let epubTitle = metadata.title, !epubTitle.isEmpty {
                        let book = Book(
                            title: epubTitle,
                            author: metadata.author,
                            coverImage: metadata.coverImage,
                            filePath: destinationFilename,
                            fileType: fileType
                        )
                        modelContext.insert(book)
                        return
                    }
                    author = metadata.author
                    coverImage = metadata.coverImage
                }
            }

            let book = Book(
                title: title,
                author: author,
                coverImage: coverImage,
                filePath: destinationFilename,
                fileType: fileType
            )

            modelContext.insert(book)
        } catch {
            print("Failed to copy file: \(error.localizedDescription)")
        }
    }

    private func deleteBook(_ book: Book) {
        if let fileURL = book.fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        modelContext.delete(book)
    }
}

struct BookCardView: View {
    let book: Book

    var body: some View {
        VStack(spacing: 8) {
            if let coverData = book.coverImage,
               let image = PlatformImage(data: coverData) {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(2/3, contentMode: .fill)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 200)
                    .overlay {
                        Image(systemName: {
                            switch book.fileType {
                            case .pdf: return "doc.fill"
                            case .epub: return "book.fill"
                            case .txt, .markdown: return "doc.plaintext"
                            }
                        }())
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.footnote)
                    .fontWeight(.medium)
                    .lineLimit(2)

                Text(book.displayAuthor)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if book.currentPosition > 0 {
                ProgressView(value: book.currentPosition)
                    .tint(.accentColor)
            }
        }
    }
}

#Preview {
    LibraryView()
        .modelContainer(for: Book.self, inMemory: true)
}
