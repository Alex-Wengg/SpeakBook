import SwiftUI
import PDFKit

struct PDFReaderView: View {
    @Bindable var book: Book
    @Environment(TTSService.self) private var ttsService
    @State private var pdfDocument: PDFDocument?
    @State private var currentPage: Int = 0
    @State private var totalPages: Int = 0
    @State private var showTTSControls = false

    var body: some View {
        VStack(spacing: 0) {
            if let document = pdfDocument {
                ZStack(alignment: .bottom) {
                    PDFKitView(
                        document: document,
                        currentPage: $currentPage
                    )
                    .ignoresSafeArea(edges: .bottom)

                    // Current sentence overlay
                    if showTTSControls && !ttsService.currentSentence.isEmpty {
                        currentSentenceOverlay
                    }
                }

                if showTTSControls {
                    TTSControlBar(ttsService: ttsService) {
                        getCurrentPageText()
                    }
                }

                pageIndicator
            } else {
                ProgressView("Loading PDF...")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 16) {
                    // Debug mode toggle (only show when TTS controls are visible)
                    if showTTSControls {
                        Button {
                            ttsService.debugMode.toggle()
                        } label: {
                            Image(systemName: ttsService.debugMode ? "ladybug.fill" : "ladybug")
                                .foregroundStyle(ttsService.debugMode ? .blue : .primary)
                        }
                    }

                    // TTS toggle
                    Button {
                        showTTSControls.toggle()
                        // Pre-initialize TTS when controls are shown
                        if showTTSControls {
                            Task {
                                await ttsService.initialize()
                            }
                        }
                    } label: {
                        Image(systemName: showTTSControls ? "speaker.wave.2.fill" : "speaker.wave.2")
                    }
                }
            }
        }
        .onAppear {
            loadPDF()
        }
        .onDisappear {
            ttsService.stop()
            saveProgress()
        }
        .onChange(of: currentPage) { _, newValue in
            updateProgress(page: newValue)
            // Stop TTS when page changes
            if ttsService.isPlaying {
                ttsService.stop()
            }
        }
    }

    private var currentSentenceOverlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ttsService.debugMode {
                // Debug header with chunk info
                HStack {
                    Text("Chunk \(ttsService.currentSentenceIndex + 1)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue, in: Capsule())

                    Spacer()

                    Text("Debug Mode")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // The sentence text
            Text(ttsService.currentSentence)
                .font(ttsService.debugMode ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ttsService.debugMode ? .regularMaterial : .ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(ttsService.debugMode ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 2)
        )
        .padding(.horizontal)
        .padding(.bottom, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: ttsService.currentSentence)
    }

    private func getCurrentPageText() -> String? {
        guard let document = pdfDocument,
              let page = document.page(at: currentPage) else {
            return nil
        }
        return page.string
    }

    private var pageIndicator: some View {
        HStack {
            Button {
                if currentPage > 0 {
                    currentPage -= 1
                }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(currentPage == 0)

            Spacer()

            Text("Page \(currentPage + 1) of \(totalPages)")
                .font(.caption)
                .monospacedDigit()

            Spacer()

            Button {
                if currentPage < totalPages - 1 {
                    currentPage += 1
                }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(currentPage >= totalPages - 1)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func loadPDF() {
        guard let fileURL = book.fileURL else { return }

        if let document = PDFDocument(url: fileURL) {
            pdfDocument = document
            totalPages = document.pageCount
            currentPage = book.currentPage
        }
    }

    private func updateProgress(page: Int) {
        guard totalPages > 0 else { return }
        book.currentPage = page
        book.currentPosition = Double(page) / Double(totalPages - 1)
    }

    private func saveProgress() {
        book.currentPage = currentPage
    }
}

struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var currentPage: Int

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.usePageViewController(true)

        if let page = document.page(at: currentPage) {
            pdfView.go(to: page)
        }

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if let currentPDFPage = pdfView.currentPage {
            let pageIndex = document.index(for: currentPDFPage)
            if pageIndex != currentPage {
                if let page = document.page(at: currentPage) {
                    pdfView.go(to: page)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: PDFKitView

        init(_ parent: PDFKitView) {
            self.parent = parent
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let currentPage = pdfView.currentPage,
                  let document = pdfView.document else { return }

            let pageIndex = document.index(for: currentPage)
            DispatchQueue.main.async {
                self.parent.currentPage = pageIndex
            }
        }
    }
}
