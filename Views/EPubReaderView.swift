import SwiftUI
import WebKit

struct EPubReaderView: View {
    @Bindable var book: Book
    @Environment(TTSService.self) private var ttsService
    @State private var metadata: EPubMetadata?
    @State private var currentChapterIndex: Int = 0
    @State private var isLoading = true
    @State private var extractedPath: URL?
    @State private var errorMessage: String?
    @State private var showTTSControls = false
    @State private var currentChapterText: String?
    @State private var isAutoAdvancing = false

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Loading ePub...")
            } else if let error = errorMessage {
                ContentUnavailableView {
                    Label("Failed to Load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else if let metadata = metadata, let extractedPath = extractedPath {
                EPubContentView(
                    metadata: metadata,
                    extractedPath: extractedPath,
                    currentChapterIndex: $currentChapterIndex,
                    highlightSentence: ttsService.currentSentence,
                    onTextExtracted: { text in
                        currentChapterText = text
                    }
                )

                if showTTSControls {
                    TTSControlBar(ttsService: ttsService, getText: {
                        currentChapterText
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

                chapterNavigator
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
            loadEPub()
            Task { await ttsService.applyBookSettings(engine: book.preferredEngine, voice: book.preferredVoice) }
            ttsService.onSentenceChanged = { index in
                book.ttsSentenceIndex = index
                // Update overall reading position (chapter + within-chapter progress)
                if let metadata = metadata, metadata.spine.count > 1 {
                    let chunkCount = ttsService.sentences.count
                    let withinChapter = chunkCount > 0 ? Double(index) / Double(chunkCount) : 0
                    book.currentPosition = (Double(currentChapterIndex) + withinChapter) / Double(max(1, metadata.spine.count - 1))
                }
            }
            ttsService.onPlaybackFinished = {
                // Sleep timer: end of section stops playback here
                if case .endOfSection = ttsService.sleepTimerMode {
                    ttsService.cancelSleepTimer()
                    return
                }
                guard showTTSControls else { return }
                guard let metadata = metadata,
                      currentChapterIndex < metadata.spine.count - 1 else { return }

                isAutoAdvancing = true
                currentChapterIndex += 1
                book.ttsSentenceIndex = nil

                Task {
                    // Wait for WKWebView to load and extract the new chapter text
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if let text = currentChapterText {
                        await ttsService.speak(text: text)
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
        .onChange(of: currentChapterIndex) { _, _ in
            if ttsService.isPlaying && !isAutoAdvancing {
                book.ttsSentenceIndex = nil
                ttsService.stop()
            }
            isAutoAdvancing = false
        }
    }

    private var chapterNavigator: some View {
        HStack {
            Button {
                if currentChapterIndex > 0 {
                    currentChapterIndex -= 1
                }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(currentChapterIndex == 0)

            Spacer()

            if let metadata = metadata {
                Text("Chapter \(currentChapterIndex + 1) of \(metadata.spine.count)")
                    .font(.caption)
                    .monospacedDigit()
            }

            Spacer()

            Button {
                if let metadata = metadata, currentChapterIndex < metadata.spine.count - 1 {
                    currentChapterIndex += 1
                }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(metadata == nil || currentChapterIndex >= (metadata?.spine.count ?? 1) - 1)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func loadEPub() {
        guard let fileURL = book.fileURL else {
            errorMessage = "Book file not found"
            isLoading = false
            return
        }

        let currentChapter = book.currentChapter
        Task.detached {
            let result = EPubParser.extractAndPrepare(epubURL: fileURL)
            await MainActor.run {
                if let result = result {
                    self.extractedPath = result.extractedPath
                    self.metadata = result.metadata
                    self.currentChapterIndex = self.findChapterIndex(for: currentChapter, in: result.metadata)
                    self.isLoading = false
                } else {
                    self.errorMessage = "Failed to parse ePub file"
                    self.isLoading = false
                }
            }
        }
    }

    private func findChapterIndex(for chapterId: String?, in metadata: EPubMetadata) -> Int {
        guard let chapterId = chapterId else { return 0 }
        return metadata.spine.firstIndex(of: chapterId) ?? 0
    }

    private func saveProgress() {
        guard let metadata = metadata else { return }
        if currentChapterIndex < metadata.spine.count {
            book.currentChapter = metadata.spine[currentChapterIndex]
            book.currentPosition = Double(currentChapterIndex) / Double(max(1, metadata.spine.count - 1))
        }
    }
}

#if os(iOS)
struct EPubContentView: UIViewRepresentable {
    let metadata: EPubMetadata
    let extractedPath: URL
    @Binding var currentChapterIndex: Int
    var highlightSentence: String
    var onTextExtracted: ((String) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isTextInteractionEnabled = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.backgroundColor = .systemBackground
        context.coordinator.onTextExtracted = onTextExtracted
        context.coordinator.webView = webView

        EPubContentViewHelper.loadChapter(
            webView: webView, index: currentChapterIndex,
            metadata: metadata, extractedPath: extractedPath,
            coordinator: context.coordinator
        )

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        EPubContentViewHelper.handleUpdate(
            webView: webView, coordinator: context.coordinator,
            currentChapterIndex: currentChapterIndex,
            highlightSentence: highlightSentence,
            metadata: metadata, extractedPath: extractedPath
        )
    }

    func makeCoordinator() -> EPubCoordinator {
        EPubCoordinator(currentIndex: currentChapterIndex)
    }
}
#else
struct EPubContentView: NSViewRepresentable {
    let metadata: EPubMetadata
    let extractedPath: URL
    @Binding var currentChapterIndex: Int
    var highlightSentence: String
    var onTextExtracted: ((String) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isTextInteractionEnabled = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.onTextExtracted = onTextExtracted
        context.coordinator.webView = webView

        EPubContentViewHelper.loadChapter(
            webView: webView, index: currentChapterIndex,
            metadata: metadata, extractedPath: extractedPath,
            coordinator: context.coordinator
        )

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        EPubContentViewHelper.handleUpdate(
            webView: webView, coordinator: context.coordinator,
            currentChapterIndex: currentChapterIndex,
            highlightSentence: highlightSentence,
            metadata: metadata, extractedPath: extractedPath
        )
    }

    func makeCoordinator() -> EPubCoordinator {
        EPubCoordinator(currentIndex: currentChapterIndex)
    }
}
#endif

// MARK: - Shared Coordinator

class EPubCoordinator: NSObject, WKNavigationDelegate {
    var currentIndex: Int
    var currentHighlight: String = ""
    var onTextExtracted: ((String) -> Void)?
    weak var webView: WKWebView?

    init(currentIndex: Int) {
        self.currentIndex = currentIndex
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

// MARK: - Shared Helper Methods

enum EPubContentViewHelper {
    static func handleUpdate(
        webView: WKWebView, coordinator: EPubCoordinator,
        currentChapterIndex: Int,
        highlightSentence: String,
        metadata: EPubMetadata, extractedPath: URL
    ) {
        if coordinator.currentIndex != currentChapterIndex {
            coordinator.currentIndex = currentChapterIndex
            loadChapter(
                webView: webView, index: currentChapterIndex,
                metadata: metadata, extractedPath: extractedPath,
                coordinator: coordinator
            )
        }

        if coordinator.currentHighlight != highlightSentence {
            coordinator.currentHighlight = highlightSentence
            highlightText(in: webView, text: highlightSentence)
        }
    }

    static func highlightText(in webView: WKWebView, text: String) {
        guard !text.isEmpty else {
            let clearJS = "window.clearTTSHighlight && window.clearTTSHighlight();"
            webView.evaluateJavaScript(clearJS, completionHandler: nil)
            return
        }

        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")

        let highlightJS = "window.highlightTTSText && window.highlightTTSText('\(escapedText)');"
        webView.evaluateJavaScript(highlightJS, completionHandler: nil)
    }

    static func loadChapter(
        webView: WKWebView, index: Int,
        metadata: EPubMetadata, extractedPath: URL,
        coordinator: EPubCoordinator
    ) {
        guard index < metadata.spine.count else { return }

        let chapterId = metadata.spine[index]
        guard let chapterHref = metadata.manifest[chapterId] else { return }

        let chapterURL = extractedPath
            .appendingPathComponent(metadata.opfDirectory)
            .appendingPathComponent(chapterHref)

        if FileManager.default.fileExists(atPath: chapterURL.path) {
            let baseURL = chapterURL.deletingLastPathComponent()
            if let htmlContent = try? String(contentsOf: chapterURL, encoding: .utf8) {
                let styledHTML = injectStyles(into: htmlContent)
                webView.loadHTMLString(styledHTML, baseURL: baseURL)

                let plainText = extractPlainText(from: htmlContent)
                coordinator.onTextExtracted?(plainText)
            }
        }
    }

    static func extractPlainText(from html: String) -> String {
        var text = html

        let scriptPattern = #"<script[^>]*>[\s\S]*?</script>"#
        let stylePattern = #"<style[^>]*>[\s\S]*?</style>"#
        text = text.replacingOccurrences(of: scriptPattern, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: stylePattern, with: "", options: .regularExpression)

        let tagPattern = #"<[^>]+>"#
        text = text.replacingOccurrences(of: tagPattern, with: " ", options: .regularExpression)

        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")

        let whitespacePattern = #"\s+"#
        text = text.replacingOccurrences(of: whitespacePattern, with: " ", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func injectStyles(into html: String) -> String {
        let customCSS = """
        <style>
            body {
                font-family: -apple-system, system-ui, sans-serif;
                font-size: 18px;
                line-height: 1.6;
                padding: 16px;
                max-width: 100%;
                word-wrap: break-word;
                background-color: transparent;
            }
            img {
                max-width: 100%;
                height: auto;
            }
            @media (prefers-color-scheme: dark) {
                body {
                    color: #f0f0f0;
                }
            }
            .tts-highlight {
                background-color: rgba(255, 230, 0, 0.4);
                border-radius: 3px;
                padding: 1px 0;
            }
            @media (prefers-color-scheme: dark) {
                .tts-highlight {
                    background-color: rgba(255, 200, 0, 0.3);
                }
            }
        </style>
        <script>
            window.clearTTSHighlight = function() {
                var highlights = document.querySelectorAll('.tts-highlight');
                highlights.forEach(function(el) {
                    var parent = el.parentNode;
                    while (el.firstChild) {
                        parent.insertBefore(el.firstChild, el);
                    }
                    parent.removeChild(el);
                });
            };

            window.highlightTTSText = function(searchText) {
                window.clearTTSHighlight();
                if (!searchText || searchText.length < 3) return;

                var normalizedSearch = searchText.trim().replace(/\\s+/g, ' ');
                if (normalizedSearch.length < 3) return;

                var walker = document.createTreeWalker(
                    document.body,
                    NodeFilter.SHOW_TEXT,
                    null,
                    false
                );

                var textNodes = [];
                var node;
                while (node = walker.nextNode()) {
                    if (node.textContent.trim().length > 0) {
                        textNodes.push(node);
                    }
                }

                var fullText = '';
                var nodeMap = [];
                textNodes.forEach(function(n) {
                    var start = fullText.length;
                    fullText += n.textContent;
                    nodeMap.push({ node: n, start: start, end: fullText.length });
                });

                var normalizedFull = fullText.replace(/\\s+/g, ' ');
                var searchLower = normalizedSearch.toLowerCase();
                var idx = normalizedFull.toLowerCase().indexOf(searchLower);

                if (idx === -1) {
                    var shortSearch = searchLower.substring(0, 50);
                    idx = normalizedFull.toLowerCase().indexOf(shortSearch);
                }

                if (idx === -1) return;

                var matchStart = idx;
                var matchEnd = idx + normalizedSearch.length;

                for (var i = 0; i < nodeMap.length; i++) {
                    var nm = nodeMap[i];
                    if (nm.end <= matchStart) continue;
                    if (nm.start >= matchEnd) break;

                    var nodeStart = Math.max(0, matchStart - nm.start);
                    var nodeEnd = Math.min(nm.node.textContent.length, matchEnd - nm.start);

                    if (nodeStart < nodeEnd) {
                        var textNode = nm.node;
                        var text = textNode.textContent;
                        var before = text.substring(0, nodeStart);
                        var match = text.substring(nodeStart, nodeEnd);
                        var after = text.substring(nodeEnd);

                        var span = document.createElement('span');
                        span.className = 'tts-highlight';
                        span.textContent = match;

                        var parent = textNode.parentNode;
                        if (before) parent.insertBefore(document.createTextNode(before), textNode);
                        parent.insertBefore(span, textNode);
                        if (after) parent.insertBefore(document.createTextNode(after), textNode);
                        parent.removeChild(textNode);

                        span.scrollIntoView({ behavior: 'smooth', block: 'center' });
                        break;
                    }
                }
            };
        </script>
        """

        if let headRange = html.range(of: "</head>", options: .caseInsensitive) {
            var modifiedHTML = html
            modifiedHTML.insert(contentsOf: customCSS, at: headRange.lowerBound)
            return modifiedHTML
        } else if let bodyRange = html.range(of: "<body", options: .caseInsensitive) {
            var modifiedHTML = html
            modifiedHTML.insert(contentsOf: "<head>\(customCSS)</head>", at: bodyRange.lowerBound)
            return modifiedHTML
        }

        return "<html><head>\(customCSS)</head><body>\(html)</body></html>"
    }
}

