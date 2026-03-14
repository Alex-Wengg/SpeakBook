import SwiftUI
import FluidAudio

struct LexiconEntry: Identifiable {
    let id = UUID()
    var word: String
    var soundsLike: String
    var phonemes: String  // generated IPA, hidden from user
    var isConverting: Bool = false
    var isPreviewing: Bool = false
    var error: String?
}

struct LexiconEditorView: View {
    @Bindable var ttsService: TTSService
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [LexiconEntry] = []
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("No Entries", systemImage: "character.book.closed")
                    } description: {
                        Text("Add words that are mispronounced and how they should sound.")
                    } actions: {
                        Button("Add Entry") { addEntry() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach($entries) { $entry in
                            LexiconEntryRow(entry: $entry, ttsService: ttsService)
                        }
                        .onDelete(perform: deleteEntries)

                        if let error = saveError {
                            Section {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pronunciation")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button {
                            addEntry()
                        } label: {
                            Image(systemName: "plus")
                        }

                        Button("Save") {
                            save()
                        }
                        .fontWeight(.semibold)
                        .disabled(isSaving)
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear { loadEntries() }
    }

    private func addEntry() {
        entries.append(LexiconEntry(word: "", soundsLike: "", phonemes: ""))
    }

    private func deleteEntries(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
    }

    private func loadEntries() {
        let content = ttsService.loadLexiconFileContent()
        guard !content.isEmpty else { return }

        // Parse existing word=phonemes file into entries
        // We show the phonemes as the "sounds like" hint since we can't reverse G2P
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let word = String(parts[0])
            let phonemes = String(parts[1])
            entries.append(LexiconEntry(
                word: word,
                soundsLike: "",
                phonemes: phonemes
            ))
        }
    }

    private func save() {
        isSaving = true
        saveError = nil

        // Build word=phonemes content from entries
        var lines: [String] = []
        for entry in entries {
            let word = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let phonemes = entry.phonemes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, !phonemes.isEmpty else { continue }
            lines.append("\(word)=\(phonemes)")
        }

        let content = lines.joined(separator: "\n")

        do {
            try ttsService.saveAndApplyLexicon(content)
            isSaving = false
            dismiss()
        } catch {
            saveError = error.localizedDescription
            isSaving = false
        }
    }
}

private struct LexiconEntryRow: View {
    @Binding var entry: LexiconEntry
    var ttsService: TTSService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Word")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                TextField("e.g. Kokoro", text: $entry.word)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }

            HStack {
                Text("Sounds like")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                TextField("e.g. co KO ro", text: $entry.soundsLike)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { convertToPhonemes() }

                Button {
                    convertToPhonemes()
                } label: {
                    if entry.isConverting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.right.circle.fill")
                    }
                }
                .disabled(entry.soundsLike.trimmingCharacters(in: .whitespaces).isEmpty || entry.isConverting)
            }

            if !entry.phonemes.isEmpty {
                HStack {
                    Text("IPA")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    Text(entry.phonemes)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        preview()
                    } label: {
                        Image(systemName: entry.isPreviewing ? "speaker.wave.2.fill" : "speaker.wave.2")
                            .foregroundStyle(entry.isPreviewing ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(entry.isPreviewing)
                }
            }

            if let error = entry.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func preview() {
        let word = entry.word.trimmingCharacters(in: .whitespaces)
        let phonemes = entry.phonemes.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !phonemes.isEmpty else { return }

        entry.isPreviewing = true
        let ssml = "<phoneme ph=\"\(phonemes)\">\(word)</phoneme>"

        Task {
            await ttsService.preview(text: ssml)
            entry.isPreviewing = false
        }
    }

    private func convertToPhonemes() {
        let input = entry.soundsLike.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }

        entry.isConverting = true
        entry.error = nil

        Task {
            do {
                // Split multi-word input, phonemize each word, join with space separator
                let words = input.split(separator: " ").map(String.init)
                var allPhonemes: [String] = []

                for word in words {
                    if let phonemes = try await ttsService.phonemize(word: word) {
                        allPhonemes.append(phonemes)
                    } else {
                        entry.error = "Could not convert \"\(word)\""
                        entry.isConverting = false
                        return
                    }
                }

                entry.phonemes = allPhonemes.joined(separator: " ")
                entry.isConverting = false
            } catch {
                entry.error = error.localizedDescription
                entry.isConverting = false
            }
        }
    }
}
