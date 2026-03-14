import SwiftUI

struct TextReaderView: View {
    @Bindable var book: Book
    @Environment(TTSService.self) private var ttsService
    @State private var textContent: String?
    @State private var paragraphs: [(id: Int, text: String)] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showTTSControls = false

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Loading…")
            } else if let error = errorMessage {
                ContentUnavailableView {
                    Label("Failed to Load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else if textContent != nil {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(paragraphs, id: \.id) { para in
                                let highlighted = highlightSentence(
                                    in: para.text,
                                    sentence: showTTSControls ? ttsService.currentSentence : ""
                                )
                                Text(highlighted)
                                    .textSelection(.enabled)
                                    .id(para.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                    .onChange(of: ttsService.currentSentenceIndex) { _, _ in
                        scrollToCurrentSentence(proxy: proxy)
                    }
                }

                if showTTSControls {
                    TTSControlBar(ttsService: ttsService, getText: {
                        textContent
                    }, onEngineChanged: { engine in
                        book.preferredEngine = engine.rawValue
                    }, onVoiceChanged: { voice in
                        book.preferredVoice = voice
                    }, getStartChunk: {
                        if let idx = book.ttsSentenceIndex, idx > 0 {
                            return idx
                        }
                        return 0
                    })
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 16) {
                    if showTTSControls {
                        Button {
                            ttsService.debugMode.toggle()
                        } label: {
                            Image(systemName: ttsService.debugMode ? "ladybug.fill" : "ladybug")
                                .foregroundStyle(ttsService.debugMode ? .blue : .primary)
                        }
                    }

                    Button {
                        showTTSControls.toggle()
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
            loadText()
            Task { await ttsService.applyBookSettings(engine: book.preferredEngine, voice: book.preferredVoice) }
            ttsService.onSentenceChanged = { index in
                book.ttsSentenceIndex = index
                // Update overall progress based on chunk position
                let total = ttsService.sentences.count
                if total > 0 {
                    book.currentPosition = Double(index + 1) / Double(total)
                }
            }
            ttsService.onPlaybackFinished = {
                // Text files are a single section — clear saved position on completion
                book.ttsSentenceIndex = nil
                book.currentPosition = 1.0
            }
        }
        .onDisappear {
            ttsService.onSentenceChanged = nil
            ttsService.onPlaybackFinished = nil
            ttsService.stop()
        }
    }

    private func loadText() {
        guard let fileURL = book.fileURL else {
            errorMessage = "File not found"
            isLoading = false
            return
        }

        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            textContent = content
            splitIntoParagraphs(content)
            isLoading = false
        } catch {
            errorMessage = "Failed to read file: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func splitIntoParagraphs(_ text: String) {
        let parts = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        paragraphs = parts.enumerated().map { (id: $0.offset, text: $0.element) }
    }

    private func highlightSentence(in paragraph: String, sentence: String) -> AttributedString {
        if book.fileType == .markdown {
            var attributed = (try? AttributedString(markdown: paragraph, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(paragraph)
            applyHighlight(to: &attributed, sentence: sentence)
            return attributed
        } else {
            var attributed = AttributedString(paragraph)
            applyHighlight(to: &attributed, sentence: sentence)
            return attributed
        }
    }

    private func applyHighlight(to attributed: inout AttributedString, sentence: String) {
        guard !sentence.isEmpty else { return }

        if let range = attributed.range(of: sentence) {
            attributed[range].backgroundColor = .yellow.opacity(0.4)
        } else {
            // Fallback: try 50-char prefix match
            let prefix = String(sentence.prefix(50))
            if prefix.count > 10, let range = attributed.range(of: prefix) {
                attributed[range].backgroundColor = .yellow.opacity(0.4)
            }
        }
    }

    private func scrollToCurrentSentence(proxy: ScrollViewProxy) {
        let sentence = ttsService.currentSentence
        guard !sentence.isEmpty else { return }

        // Find which paragraph contains the current sentence
        if let para = paragraphs.first(where: { $0.text.contains(sentence) }) {
            withAnimation {
                proxy.scrollTo(para.id, anchor: .center)
            }
        } else {
            // Fallback: try prefix
            let prefix = String(sentence.prefix(50))
            if prefix.count > 10, let para = paragraphs.first(where: { $0.text.contains(prefix) }) {
                withAnimation {
                    proxy.scrollTo(para.id, anchor: .center)
                }
            }
        }
    }
}
