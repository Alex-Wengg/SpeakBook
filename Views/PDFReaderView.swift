import SwiftUI
import PDFKit

struct PDFReaderView: View {
    @Bindable var book: Book
    @Environment(TTSService.self) private var ttsService
    @State private var pdfDocument: PDFDocument?
    @State private var currentPage: Int = 0
    @State private var totalPages: Int = 0
    @State private var showTTSControls = false
    @State private var isAutoAdvancing = false

    var body: some View {
        VStack(spacing: 0) {
            if let document = pdfDocument {
                ZStack(alignment: .bottom) {
                    PDFKitView(
                        document: document,
                        currentPage: $currentPage,
                        highlightSentence: showTTSControls ? ttsService.currentSentence : ""
                    )
                    .ignoresSafeArea(edges: .bottom)

                    // Current sentence overlay (debug mode only)
                    if showTTSControls && ttsService.debugMode && !ttsService.currentSentence.isEmpty {
                        currentSentenceOverlay
                    }
                }

                if showTTSControls {
                    TTSControlBar(ttsService: ttsService, getText: {
                        getCurrentPageText()
                    }, onEngineChanged: { engine in
                        book.preferredEngine = engine.rawValue
                    }, onVoiceChanged: { voice in
                        book.preferredVoice = voice
                    }, getStartChunk: {
                        // Resume from saved sentence if on the same page
                        if book.currentPage == currentPage, let idx = book.ttsSentenceIndex, idx > 0 {
                            return idx
                        }
                        return 0
                    })
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
            Task { await ttsService.applyBookSettings(engine: book.preferredEngine, voice: book.preferredVoice) }
            ttsService.onSentenceChanged = { index in
                book.ttsSentenceIndex = index
                // Update overall reading position (page + within-page progress)
                if totalPages > 1 {
                    let chunkCount = ttsService.sentences.count
                    let withinPage = chunkCount > 0 ? Double(index) / Double(chunkCount) : 0
                    book.currentPosition = (Double(currentPage) + withinPage) / Double(max(1, totalPages - 1))
                }
            }
            ttsService.onPlaybackFinished = {
                // Sleep timer: end of section stops playback here
                if case .endOfSection = ttsService.sleepTimerMode {
                    ttsService.cancelSleepTimer()
                    return
                }
                print("[TTS] onPlaybackFinished called. showTTSControls=\(showTTSControls), currentPage=\(currentPage), totalPages=\(totalPages)")
                guard showTTSControls, currentPage < totalPages - 1 else {
                    print("[TTS] Guard failed, not advancing")
                    return
                }
                isAutoAdvancing = true
                currentPage += 1
                book.ttsSentenceIndex = nil
                print("[TTS] Advanced to page \(currentPage)")
                Task {
                    if let text = getCurrentPageText() {
                        print("[TTS] Got text for page \(currentPage), starting speech (\(text.prefix(60))...)")
                        await ttsService.speak(text: text)
                    } else {
                        print("[TTS] No text for page \(currentPage)")
                    }
                }
            }
        }
        .onDisappear {
            ttsService.onSentenceChanged = nil
            ttsService.onPlaybackFinished = nil
            ttsService.stop()
            saveProgress()
        }
        .onChange(of: currentPage) { _, newValue in
            updateProgress(page: newValue)
            // Stop TTS when user manually changes page (not auto-advance)
            if ttsService.isPlaying && !isAutoAdvancing {
                book.ttsSentenceIndex = nil
                ttsService.stop()
            }
            isAutoAdvancing = false
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
        guard let raw = page.string else { return nil }
        return PDFTextCleaner.clean(raw)
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
        book.currentPosition = Double(page) / Double(max(1, totalPages - 1))
    }

    private func saveProgress() {
        book.currentPage = currentPage
    }

}

#if os(iOS)
struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var currentPage: Int
    var highlightSentence: String

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

        PDFHighlightHelper.updateHighlight(
            in: pdfView, document: document,
            text: highlightSentence, coordinator: context.coordinator
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject {
        var parent: PDFKitView
        var currentHighlight: String = ""
        var isProgrammaticSelection = false
        init(_ parent: PDFKitView) { self.parent = parent }

        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let currentPage = pdfView.currentPage,
                  let document = pdfView.document else { return }
            let pageIndex = document.index(for: currentPage)
            DispatchQueue.main.async { self.parent.currentPage = pageIndex }
        }
    }
}
#else
struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var currentPage: Int
    var highlightSentence: String

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage

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

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if let currentPDFPage = pdfView.currentPage {
            let pageIndex = document.index(for: currentPDFPage)
            if pageIndex != currentPage {
                if let page = document.page(at: currentPage) {
                    pdfView.go(to: page)
                }
            }
        }

        PDFHighlightHelper.updateHighlight(
            in: pdfView, document: document,
            text: highlightSentence, coordinator: context.coordinator
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject {
        var parent: PDFKitView
        var currentHighlight: String = ""
        var isProgrammaticSelection = false
        init(_ parent: PDFKitView) { self.parent = parent }

        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let currentPage = pdfView.currentPage,
                  let document = pdfView.document else { return }
            let pageIndex = document.index(for: currentPage)
            DispatchQueue.main.async { self.parent.currentPage = pageIndex }
        }
    }
}
#endif

// MARK: - PDF Text Cleaning

enum PDFTextCleaner {
    /// Strip page numbers, footnote markers, headers/footers and other noise from extracted PDF text.
    static func clean(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        var cleaned: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines
            if trimmed.isEmpty { continue }

            // Skip standalone numbers (page numbers, footnote numbers)
            if trimmed.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == " " }) { continue }

            cleaned.append(trimmed)
        }

        let result = cleaned.joined(separator: " ")
        return result.isEmpty ? nil : result
    }
}

// MARK: - Shared Highlight Logic

enum PDFHighlightHelper {
    static func updateHighlight(
        in pdfView: PDFView, document: PDFDocument,
        text: String, coordinator: PDFKitView.Coordinator
    ) {
        guard coordinator.currentHighlight != text else { return }
        coordinator.currentHighlight = text

        // Guard programmatic selection changes so they don't overwrite user selection
        coordinator.isProgrammaticSelection = true
        defer { coordinator.isProgrammaticSelection = false }

        guard !text.isEmpty else {
            pdfView.clearSelection()
            return
        }

        // Try to find exact text in the document
        if let selection = document.findString(text, withOptions: .caseInsensitive).first {
            selection.color = .yellow
            pdfView.setCurrentSelection(selection, animate: true)
            pdfView.scrollSelectionToVisible(nil)
            return
        }

        // Fallback: try a shorter prefix
        let prefix = String(text.prefix(60))
        if prefix.count > 10,
           let selection = document.findString(prefix, withOptions: .caseInsensitive).first {
            selection.color = .yellow
            pdfView.setCurrentSelection(selection, animate: true)
            pdfView.scrollSelectionToVisible(nil)
            return
        }

        // No match found — clear any stale selection
        pdfView.clearSelection()
    }
}
