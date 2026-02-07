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
                    TTSControlBar(ttsService: ttsService) {
                        currentChapterText
                    }
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
        }
        .onDisappear {
            ttsService.stop()
            saveProgress()
        }
        .onChange(of: currentChapterIndex) { _, _ in
            if ttsService.isPlaying {
                ttsService.stop()
            }
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

        DispatchQueue.global(qos: .userInitiated).async {
            if let result = EPubParser.extractAndPrepare(epubURL: fileURL) {
                DispatchQueue.main.async {
                    self.extractedPath = result.extractedPath
                    self.metadata = result.metadata
                    self.currentChapterIndex = findChapterIndex(for: book.currentChapter, in: result.metadata)
                    self.isLoading = false
                }
            } else {
                DispatchQueue.main.async {
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

        loadChapter(webView: webView, index: currentChapterIndex, coordinator: context.coordinator)

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.currentIndex != currentChapterIndex {
            context.coordinator.currentIndex = currentChapterIndex
            loadChapter(webView: webView, index: currentChapterIndex, coordinator: context.coordinator)
        }

        // Update highlighting when sentence changes
        if context.coordinator.currentHighlight != highlightSentence {
            context.coordinator.currentHighlight = highlightSentence
            highlightText(in: webView, text: highlightSentence)
        }
    }

    private func highlightText(in webView: WKWebView, text: String) {
        guard !text.isEmpty else {
            // Clear highlighting
            let clearJS = "window.clearTTSHighlight && window.clearTTSHighlight();"
            webView.evaluateJavaScript(clearJS, completionHandler: nil)
            return
        }

        // Escape text for JavaScript
        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")

        let highlightJS = "window.highlightTTSText && window.highlightTTSText('\(escapedText)');"
        webView.evaluateJavaScript(highlightJS, completionHandler: nil)
    }

    private func loadChapter(webView: WKWebView, index: Int, coordinator: Coordinator) {
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

                // Extract plain text for TTS
                let plainText = extractPlainText(from: htmlContent)
                coordinator.onTextExtracted?(plainText)
            }
        }
    }

    private func extractPlainText(from html: String) -> String {
        // Simple HTML tag removal for TTS
        var text = html

        // Remove script and style blocks
        let scriptPattern = #"<script[^>]*>[\s\S]*?</script>"#
        let stylePattern = #"<style[^>]*>[\s\S]*?</style>"#
        text = text.replacingOccurrences(of: scriptPattern, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: stylePattern, with: "", options: .regularExpression)

        // Remove all HTML tags
        let tagPattern = #"<[^>]+>"#
        text = text.replacingOccurrences(of: tagPattern, with: " ", options: .regularExpression)

        // Decode HTML entities
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")

        // Normalize whitespace
        let whitespacePattern = #"\s+"#
        text = text.replacingOccurrences(of: whitespacePattern, with: " ", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func injectStyles(into html: String) -> String {
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

                // Normalize the search text
                var normalizedSearch = searchText.trim().replace(/\\s+/g, ' ');
                if (normalizedSearch.length < 3) return;

                // Use TreeWalker to find text nodes
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

                // Build full text and find position
                var fullText = '';
                var nodeMap = [];
                textNodes.forEach(function(n) {
                    var start = fullText.length;
                    fullText += n.textContent;
                    nodeMap.push({ node: n, start: start, end: fullText.length });
                });

                // Find best match (fuzzy)
                var normalizedFull = fullText.replace(/\\s+/g, ' ');
                var searchLower = normalizedSearch.toLowerCase();
                var idx = normalizedFull.toLowerCase().indexOf(searchLower);

                if (idx === -1) {
                    // Try first 50 chars as fallback
                    var shortSearch = searchLower.substring(0, 50);
                    idx = normalizedFull.toLowerCase().indexOf(shortSearch);
                }

                if (idx === -1) return;

                // Find the matching node(s)
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

                        // Scroll into view
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

    func makeCoordinator() -> Coordinator {
        Coordinator(currentIndex: currentChapterIndex)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
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
}
