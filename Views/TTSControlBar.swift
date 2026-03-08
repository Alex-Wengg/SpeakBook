import SwiftUI

struct TTSControlBar: View {
    @Bindable var ttsService: TTSService
    let getText: () -> String?

    @State private var showEnginePicker = false
    @State private var showVoicePicker = false
    @State private var showTextPicker = false

    var body: some View {
        VStack(spacing: 8) {
            // Status message
            if !ttsService.loadingMessage.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(ttsService.loadingMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if case .error(let message) = ttsService.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            HStack(spacing: 16) {
                // Engine picker button
                Button {
                    showEnginePicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(.title3)
                        Text(ttsService.currentEngine.rawValue)
                            .font(.caption)
                    }
                }
                .popover(isPresented: $showEnginePicker) {
                    EnginePickerView(
                        ttsService: ttsService,
                        isPresented: $showEnginePicker
                    )
                }

                // Voice picker button
                Button {
                    showVoicePicker = true
                } label: {
                    Image(systemName: "person.wave.2")
                        .font(.title3)
                }
                .popover(isPresented: $showVoicePicker) {
                    VoicePickerView(
                        ttsService: ttsService,
                        isPresented: $showVoicePicker
                    )
                }

                // Text start position picker
                Button {
                    showTextPicker = true
                } label: {
                    Image(systemName: "text.cursor")
                        .font(.title3)
                }
                .sheet(isPresented: $showTextPicker) {
                    TextStartPickerView(
                        ttsService: ttsService,
                        getText: getText,
                        isPresented: $showTextPicker
                    )
                }

                Spacer()

                // Play/Pause button
                Button {
                    Task {
                        await handlePlayPause()
                    }
                } label: {
                    Group {
                        switch ttsService.state {
                        case .loadingModels, .generating:
                            ProgressView()
                                .controlSize(.small)
                        case .playing:
                            Image(systemName: "pause.fill")
                        case .paused:
                            Image(systemName: "play.fill")
                        default:
                            Image(systemName: "play.fill")
                        }
                    }
                    .font(.title2)
                    .frame(width: 44, height: 44)
                }
                .disabled(ttsService.state == .loadingModels || ttsService.state == .generating)

                // Stop button
                Button {
                    ttsService.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title3)
                }
                .disabled(ttsService.state == .idle)

                Spacer()

                // Progress indicator
                if ttsService.isPlaying || ttsService.state == .paused {
                    Text("\(Int(ttsService.progress * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            // Progress bar
            if ttsService.isPlaying || ttsService.state == .paused {
                ProgressView(value: ttsService.progress)
                    .tint(.accentColor)
                    .padding(.horizontal)
            }

            // Volume slider
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: $ttsService.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func handlePlayPause() async {
        switch ttsService.state {
        case .idle, .ready, .error:
            if let text = getText() {
                await ttsService.speak(text: text)
            }
        case .playing:
            ttsService.pause()
        case .paused:
            ttsService.resume()
        case .loadingModels, .generating:
            break
        }
    }
}

struct VoicePickerView: View {
    @Bindable var ttsService: TTSService
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List(ttsService.availableVoices, id: \.self) { voice in
                Button {
                    Task {
                        await ttsService.setVoice(voice)
                        isPresented = false
                    }
                } label: {
                    HStack {
                        Text(formatVoiceName(voice))

                        Spacer()

                        if voice == ttsService.currentVoice {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Select Voice")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
        .frame(minWidth: 250, minHeight: 300)
    }

    private func formatVoiceName(_ voice: String) -> String {
        // Convert "af_heart" to "Heart (Female)"
        let parts = voice.split(separator: "_")
        guard parts.count >= 2 else { return voice }

        let prefix = String(parts[0])
        let name = String(parts[1]).capitalized

        let gender: String
        if prefix.hasPrefix("a") {
            gender = prefix.hasSuffix("f") ? "American Female" : "American Male"
        } else if prefix.hasPrefix("b") {
            gender = prefix.hasSuffix("f") ? "British Female" : "British Male"
        } else {
            gender = ""
        }

        return gender.isEmpty ? name : "\(name) (\(gender))"
    }
}

struct EnginePickerView: View {
    @Bindable var ttsService: TTSService
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List(TTSService.TTSEngine.allCases, id: \.self) { engine in
                Button {
                    Task {
                        await ttsService.setEngine(engine)
                        isPresented = false
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.rawValue)
                            Text(engineDescription(engine))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if engine == ttsService.currentEngine {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("TTS Engine")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
        .frame(minWidth: 250, minHeight: 200)
    }

    private func engineDescription(_ engine: TTSService.TTSEngine) -> String {
        switch engine {
        case .pocketTTS: return "3 voices, voice cloning"
        case .kokoro: return "40+ voices, phoneme-based"
        }
    }
}

struct TextStartPickerView: View {
    @Bindable var ttsService: TTSService
    let getText: () -> String?
    @Binding var isPresented: Bool

    @State private var sentences: [String] = []
    @State private var searchText = ""

    var filteredSentences: [(index: Int, text: String)] {
        let indexed = sentences.enumerated().map { (index: $0.offset, text: $0.element) }
        if searchText.isEmpty {
            return indexed
        }
        return indexed.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                if sentences.isEmpty {
                    ContentUnavailableView {
                        Label("No Text", systemImage: "text.page")
                    } description: {
                        Text("No text available on this page")
                    }
                } else {
                    ForEach(filteredSentences, id: \.index) { item in
                        Button {
                            startFromSentence(at: item.index)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(item.index + 1)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, alignment: .trailing)

                                Text(item.text)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Find text...")
            .navigationTitle("Start Reading From")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
        .onAppear {
            loadSentences()
        }
    }

    private func loadSentences() {
        guard let text = getText() else {
            sentences = []
            return
        }

        // Split into sentences using natural language processing-style splitting
        var result: [String] = []
        let delimiters = CharacterSet(charactersIn: ".!?")

        // Split by sentence-ending punctuation
        let parts = text.components(separatedBy: delimiters)
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed.count > 10 {
                result.append(trimmed)
            }
        }

        // If no good sentence splits, try splitting by newlines
        if result.isEmpty {
            result = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count > 10 }
        }

        // If still nothing, just use the whole text
        if result.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        }

        sentences = result
    }

    private func startFromSentence(at index: Int) {
        // Build text from selected sentence onwards
        let remainingText = sentences[index...].joined(separator: ". ")

        isPresented = false

        Task {
            await ttsService.speak(text: remainingText)
        }
    }
}
