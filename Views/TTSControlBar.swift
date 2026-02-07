import SwiftUI

struct TTSControlBar: View {
    @Bindable var ttsService: TTSService
    let getText: () -> String?

    @State private var showVoicePicker = false
    @State private var showBatchInfo = false
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

                // Batch prefill version button
                Button {
                    showBatchInfo = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(batchVersionColor)
                        Text(batchVersionShort)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
                .popover(isPresented: $showBatchInfo) {
                    BatchPrefillInfoView(
                        ttsService: ttsService,
                        isPresented: $showBatchInfo
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

                // Throttling warning
                if ttsService.isThrottling {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(String(format: "%.1fx", ttsService.currentRTFx))
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .help("Generation slower than real-time - audio may stutter")
                }

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
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var batchVersionColor: Color {
        if ttsService.batchPrefillVersion.contains("v3") {
            return .green
        } else if ttsService.batchPrefillVersion.contains("v2") {
            return .yellow
        } else {
            return .red
        }
    }

    private var batchVersionShort: String {
        if ttsService.batchPrefillVersion.contains("v3") {
            return "v3"
        } else if ttsService.batchPrefillVersion.contains("v2") {
            return "v2"
        } else {
            return "v1"
        }
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
            .navigationBarTitleDisplayMode(.inline)
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
            .navigationBarTitleDisplayMode(.inline)
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

struct BatchPrefillInfoView: View {
    @Bindable var ttsService: TTSService
    @Binding var isPresented: Bool

    private let versions: [(id: String, rawValue: String, name: String, tokens: String, speed: String, color: Color)] = [
        ("v3", "v3 (100 text tokens)", "Batch v3", "100 text tokens", "Fastest", .green),
        ("v2", "v2 (50 text tokens)", "Batch v2", "50 text tokens", "Fast", .yellow),
        ("v1", "v1 (token-by-token)", "Token-by-token", "50 text tokens", "Slow", .red),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(versions, id: \.id) { version in
                        Button {
                            Task {
                                _ = await ttsService.setBatchVersion(version.rawValue)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                // Status indicator
                                Image(systemName: isCurrentVersion(version.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isCurrentVersion(version.id) ? version.color : .secondary)
                                    .font(.title3)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(version.name)
                                            .fontWeight(isCurrentVersion(version.id) ? .semibold : .regular)

                                        if isCurrentVersion(version.id) {
                                            Text("Active")
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(version.color.opacity(0.2))
                                                .foregroundStyle(version.color)
                                                .clipShape(Capsule())
                                        }
                                    }

                                    Text("\(version.tokens) • \(version.speed)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                // Show if version is available
                                if !isVersionAvailable(version.rawValue) {
                                    Text("Not available")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .foregroundStyle(.primary)
                        .disabled(!isVersionAvailable(version.rawValue))
                        .opacity(isVersionAvailable(version.rawValue) ? 1.0 : 0.5)
                    }
                } header: {
                    Text("Batch Prefill Mode")
                } footer: {
                    Text("Batch prefill processes multiple tokens at once during the conditioning step, dramatically reducing latency. v3 handles longer sentences per chunk.")
                        .font(.caption2)
                }
            }
            .navigationTitle("TTS Engine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
        .frame(minWidth: 300, minHeight: 350)
    }

    private func isCurrentVersion(_ versionId: String) -> Bool {
        ttsService.batchPrefillVersion.lowercased().contains(versionId)
    }

    private func isVersionAvailable(_ rawValue: String) -> Bool {
        ttsService.availableVersions.contains(rawValue)
    }
}
