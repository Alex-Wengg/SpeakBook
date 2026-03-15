import Foundation
import AVFoundation
import FluidAudio
import os.log

private let ttsLogger = Logger(subsystem: "com.speakbook.app", category: "TTS")

@Observable
final class TTSService {
    enum State: Equatable {
        case idle
        case loadingModels
        case ready
        case generating
        case playing
        case paused
        case error(String)
    }

    enum TTSEngine: String, CaseIterable {
        case pocketTTS = "PocketTTS"
        case kokoro = "Kokoro"
    }

    enum SleepTimerMode: Equatable {
        case off
        case timed(minutes: Int)
        case endOfSection
    }

    private(set) var state: State = .idle
    private(set) var loadingMessage: String = ""
    private(set) var statusMessage: String = ""
    private(set) var currentVoice: String = "alba"
    private(set) var currentEngine: TTSEngine = .pocketTTS
    private(set) var progress: Double = 0.0
    var debugMode: Bool = false
    var skipSilence: Bool = false
    var volume: Float = 1.0 {
        didSet { audioEngine?.mainMixerNode.outputVolume = volume }
    }
    private(set) var currentSentence: String = ""
    private(set) var currentSentenceIndex: Int = -1
    private(set) var sentences: [String] = []
    var onPlaybackFinished: (() -> Void)?
    var onSentenceChanged: ((Int) -> Void)?
    private(set) var customLexicon: TtsCustomLexicon?
    private(set) var lexiconEntryCount: Int = 0
    private(set) var sleepTimerMode: SleepTimerMode = .off
    private(set) var sleepTimerRemainingSeconds: Int = 0

    private var pocketManager: PocketTtsManager?
    private var kokoroManager: KokoroTtsManager?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var synthesisTask: Task<Void, Never>?
    private var idleUnloadTask: Task<Void, Never>?
    private var sleepTimerTask: Task<Void, Never>?
    private var statusMessageTask: Task<Void, Never>?
    private var isStopped = false
    private var currentFullText: String = ""
    private var totalSamples = 0
    private var playedSamples = 0
    private var lastBufferFinished = false

    /// Seconds of idle before unloading models to prevent thermal throttling
    private let idleUnloadDelay: TimeInterval = 60

    var isPlaying: Bool {
        state == .playing
    }

    var availableVoices: [String] {
        switch currentEngine {
        case .pocketTTS:
            return [
                "alba", "anna", "azelma", "bill_boerst", "caro_davy",
                "charles", "cosette", "eponine", "eve", "fantine",
                "george", "jane", "javert", "jean", "marius",
                "mary", "michael", "paul", "peter_yearsley", "stuart_bell", "vera"
            ]
        case .kokoro:
            // American + British English voices
            return TtsConstants.availableVoices.filter { $0.hasPrefix("af_") || $0.hasPrefix("am_") || $0.hasPrefix("bf_") || $0.hasPrefix("bm_") }
        }
    }

    init() {
        setupAudioSession()
        loadCustomLexicon()
    }

    private func setupAudioSession() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
        #endif
    }

    // MARK: - Engine Management

    func applyBookSettings(engine: String?, voice: String?) async {
        if let engineRaw = engine, let engine = TTSEngine(rawValue: engineRaw) {
            if engine != currentEngine {
                await setEngine(engine)
            }
        }
        if let voice = voice, voice != currentVoice {
            await setVoice(voice)
        }
    }

    func setEngine(_ engine: TTSEngine) async {
        guard engine != currentEngine else { return }
        stop()
        cancelIdleUnloadTimer()
        await unloadModels()

        currentEngine = engine
        switch engine {
        case .pocketTTS:
            currentVoice = "alba"
        case .kokoro:
            currentVoice = TtsConstants.recommendedVoice
        }
        ttsLogger.notice("Switched to engine: \(engine.rawValue), voice: \(self.currentVoice)")
    }

    func initialize() async {
        switch currentEngine {
        case .pocketTTS:
            await initializePocketTTS()
        case .kokoro:
            await initializeKokoro()
        }
    }

    private func initializePocketTTS() async {
        guard pocketManager == nil else { return }

        let initStart = Date()
        state = .loadingModels
        loadingMessage = "Loading PocketTTS models..."
        ttsLogger.notice("Starting PocketTTS initialization")

        do {
            let mgr = PocketTtsManager(defaultVoice: currentVoice)
            try await mgr.initialize()
            pocketManager = mgr

            let elapsed = Date().timeIntervalSince(initStart)
            ttsLogger.notice("PocketTTS models loaded in \(String(format: "%.0f", elapsed * 1000))ms")
            loadingMessage = ""
            state = .ready
        } catch {
            loadingMessage = ""
            state = .error("Failed to load PocketTTS: \(error.localizedDescription)")
        }
    }

    private func initializeKokoro() async {
        guard kokoroManager == nil else { return }

        let initStart = Date()
        state = .loadingModels
        loadingMessage = "Loading Kokoro models..."
        ttsLogger.notice("Starting Kokoro initialization")

        do {
            let mgr = KokoroTtsManager(defaultVoice: currentVoice, customLexicon: customLexicon)
            try await mgr.initialize()
            kokoroManager = mgr

            let elapsed = Date().timeIntervalSince(initStart)
            ttsLogger.notice("Kokoro models loaded in \(String(format: "%.0f", elapsed * 1000))ms")
            loadingMessage = ""
            state = .ready
        } catch {
            print("[Kokoro init error] \(error)")
            loadingMessage = ""
            state = .error("Failed to load Kokoro: \(error.localizedDescription)")
        }
    }

    private var isEngineReady: Bool {
        switch currentEngine {
        case .pocketTTS: return pocketManager != nil
        case .kokoro: return kokoroManager != nil
        }
    }

    // MARK: - Synthesis

    func speak(text: String, startFromChunk: Int = 0) async {
        guard !text.isEmpty else { return }

        cancelIdleUnloadTimer()

        if !isEngineReady {
            await initialize()
        }

        guard isEngineReady else { return }

        stop()
        cancelIdleUnloadTimer()
        currentFullText = text
        isStopped = false
        lastBufferFinished = false
        playedSamples = 0
        totalSamples = 0
        currentSentence = ""
        currentSentenceIndex = -1

        let chunks = splitIntoChunks(text)
        sentences = chunks

        setupAudioEngine()

        guard audioEngine != nil, playerNode != nil else {
            state = .error("Failed to setup audio engine")
            return
        }

        synthesisTask = Task {
            switch currentEngine {
            case .pocketTTS:
                await speakStreaming(text: text, chunks: chunks, startFromChunk: startFromChunk)
            case .kokoro:
                await speakBatch(chunks: chunks, startFromChunk: startFromChunk)
            }
        }
    }

    // MARK: - Batch Synthesis (Kokoro)

    private func speakBatch(chunks: [String], startFromChunk: Int) async {
        let totalChunks = chunks.count
        let effectiveStart = min(max(startFromChunk, 0), totalChunks - 1)

        guard let engine = audioEngine, let playerNode = playerNode else { return }

        state = .generating
        loadingMessage = "Generating speech..."

        let startTime = Date()
        do {
            var hasStartedPlayback = false
            var cumulativeSamples = 0

            for (index, chunk) in chunks.enumerated() {
                guard !isStopped else { break }
                if index < effectiveStart { continue }

                await MainActor.run {
                    self.currentSentenceIndex = index
                    self.currentSentence = chunk
                    self.onSentenceChanged?(index)
                }

                ttsLogger.notice("[\(self.currentEngine.rawValue)] Synthesizing chunk \(index + 1)/\(totalChunks)")
                let chunkStart = Date()

                let samples: [Float]
                switch currentEngine {
                case .pocketTTS:
                    samples = try await synthesizePocketTTS(chunk)
                case .kokoro:
                    samples = try await synthesizeKokoro(chunk)
                }

                guard !isStopped else { break }

                let processedSamples = skipSilence ? trimTrailingSilence(from: samples) : samples

                let chunkTime = Date().timeIntervalSince(chunkStart)
                let chunkDuration = Double(processedSamples.count) / 24000.0
                ttsLogger.notice("Chunk \(index + 1) done: \(String(format: "%.1f", chunkDuration))s audio in \(String(format: "%.1f", chunkTime))s (\(String(format: "%.1f", chunkDuration / chunkTime))x RTFx)")

                cumulativeSamples += processedSamples.count
                totalSamples = cumulativeSamples

                var samplesWithPause = processedSamples
                if index < totalChunks - 1 {
                    let pause = pauseDuration(after: chunk)
                    if pause > 0 {
                        samplesWithPause += [Float](repeating: 0, count: Int(24000.0 * pause))
                    }
                }

                cumulativeSamples += samplesWithPause.count - processedSamples.count
                let buffer = createPCMBuffer(from: samplesWithPause)
                let chunkIndex = index
                let isLastChunk = index == totalChunks - 1
                playerNode.scheduleBuffer(buffer) { [weak self] in
                    Task { @MainActor in
                        guard let self = self, !self.isStopped else { return }
                        self.progress = Double(chunkIndex + 1) / Double(totalChunks)
                        if isLastChunk {
                            self.lastBufferFinished = true
                        }
                    }
                }

                if !hasStartedPlayback {
                    let latency = Date().timeIntervalSince(startTime)
                    ttsLogger.notice("First chunk ready in \(String(format: "%.0f", latency * 1000))ms, starting playback")
                    await MainActor.run {
                        self.loadingMessage = ""
                        self.state = .playing
                    }
                    try engine.start()
                    playerNode.play()
                    hasStartedPlayback = true
                }
            }

            let totalTime = Date().timeIntervalSince(startTime)
            let totalAudio = Double(cumulativeSamples) / 24000.0
            ttsLogger.notice("All \(totalChunks) chunks done: \(String(format: "%.1f", totalAudio))s audio in \(String(format: "%.1f", totalTime))s")

            await waitForPlaybackCompletion()

            await MainActor.run {
                if !self.isStopped {
                    self.progress = 1.0
                    self.state = .idle
                    self.onPlaybackFinished?()
                }
            }
        } catch {
            await MainActor.run {
                self.state = .error("Synthesis failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Streaming Synthesis (PocketTTS)

    private func speakStreaming(text: String, chunks: [String], startFromChunk: Int) async {
        guard let mgr = pocketManager else {
            ttsLogger.error("speakStreaming: pocketManager is nil")
            return
        }

        // Build effective text from startFromChunk onward
        let effectiveText: String
        if startFromChunk > 0 && startFromChunk < chunks.count {
            effectiveText = chunks[startFromChunk...].joined(separator: " ")
        } else {
            effectiveText = text
        }

        let voiceName = currentVoice
        NSLog("[TTS-STREAM] text length=\(effectiveText.count), voice=\(voiceName)")

        state = .generating
        loadingMessage = "Generating speech..."

        do {
            // Ensure voice is valid for PocketTTS, fall back to default if not
            let voice = availableVoices.contains(currentVoice) ? currentVoice : "alba"
            NSLog("[TTS-STREAM] calling synthesizeStreaming with voice=\(voice)...")
            let streamStart = Date()
            let stream = try await mgr.synthesizeStreaming(
                text: effectiveText,
                voice: voice
            )
            let streamSetup = Date().timeIntervalSince(streamStart)
            NSLog("[TTS-STREAM] stream created in \(String(format: "%.0f", streamSetup * 1000))ms")

            var hasStartedPlayback = false
            var bufferedFrames = 0
            let preBufferCount = 5  // 400ms pre-buffer before starting playback
            var lastChunkIndex = -1
            var streamFinished = false

            for try await frame in stream {
                if bufferedFrames == 0 {
                    NSLog("[TTS-STREAM] first frame received!")
                }
                guard !isStopped else { break }

                // Track sentence changes via chunkIndex from the stream
                if frame.chunkIndex != lastChunkIndex {
                    lastChunkIndex = frame.chunkIndex
                    let sentenceIdx = startFromChunk + frame.chunkIndex
                    if sentenceIdx < chunks.count {
                        await MainActor.run {
                            self.currentSentenceIndex = sentenceIdx
                            self.currentSentence = chunks[sentenceIdx]
                            self.onSentenceChanged?(sentenceIdx)
                        }
                    }
                }

                let processedSamples = skipSilence ? trimTrailingSilence(from: frame.samples) : frame.samples
                let buffer = createPCMBuffer(from: processedSamples)

                let capturedChunkIndex = frame.chunkIndex
                let capturedChunkCount = frame.chunkCount
                playerNode?.scheduleBuffer(buffer) { [weak self] in
                    Task { @MainActor in
                        guard let self = self, !self.isStopped else { return }
                        self.progress = Double(capturedChunkIndex + 1) / Double(capturedChunkCount)
                    }
                }

                bufferedFrames += 1

                // Start playback after pre-buffer fills
                if !hasStartedPlayback && bufferedFrames >= preBufferCount {
                    await MainActor.run {
                        self.loadingMessage = ""
                        self.state = .playing
                    }
                    try audioEngine?.start()
                    playerNode?.play()
                    hasStartedPlayback = true
                }
            }

            streamFinished = true

            // Very short text may not hit preBufferCount — start playback now
            if !hasStartedPlayback && !isStopped {
                await MainActor.run {
                    self.loadingMessage = ""
                    self.state = .playing
                }
                try audioEngine?.start()
                playerNode?.play()
            }

            // Wait for all scheduled buffers to finish playing
            if streamFinished && !isStopped {
                await waitForStreamingPlaybackCompletion()
            }

            await MainActor.run {
                if !self.isStopped {
                    self.progress = 1.0
                    self.state = .idle
                    self.onPlaybackFinished?()
                }
            }
        } catch {
            NSLog("[TTS-STREAM] ERROR: \(error)")
            await MainActor.run {
                self.loadingMessage = ""
                self.state = .error("Synthesis failed: \(error.localizedDescription)")
            }
        }
    }

    private func synthesizePocketTTS(_ text: String) async throws -> [Float] {
        guard let mgr = pocketManager else { throw TTSError.notInitialized }
        let result = try await mgr.synthesizeDetailed(text: text, voice: currentVoice)
        return result.samples
    }

    /// Guard frames to trim from the end of each Kokoro chunk (4 frames × 600 samples = 100ms).
    /// FluidAudio only trims the 5s variant internally; we trim all variants here to remove
    /// trailing artifacts the model appends.
    private let kokoroGuardSamples = 4 * 600

    private func synthesizeKokoro(_ text: String) async throws -> [Float] {
        guard let mgr = kokoroManager else { throw TTSError.notInitialized }
        let result = try await mgr.synthesizeDetailed(text: text, voice: currentVoice)
        // Concatenate chunk samples, trimming guard frames from each chunk's tail
        return result.chunks.flatMap { chunk -> [Float] in
            let samples = chunk.samples
            if samples.count > kokoroGuardSamples {
                return Array(samples.dropLast(kokoroGuardSamples))
            }
            return samples
        }
    }

    private enum TTSError: LocalizedError {
        case notInitialized
        var errorDescription: String? { "TTS engine not initialized" }
    }

    // MARK: - Text Chunking

    func splitIntoChunks(_ text: String) -> [String] {
        var result: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Split on sentence-ending punctuation and clause-separating punctuation
        var current = ""
        for char in trimmed {
            current.append(char)
            if ".!?,;:".contains(char) {
                let clause = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clause.isEmpty {
                    result.append(clause)
                }
                current = ""
            }
        }

        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            result.append(remainder)
        }

        // Merge very short chunks (< 40 chars) with the next to avoid tiny synthesis calls
        var merged: [String] = []
        var accumulator = ""
        for chunk in result {
            if accumulator.isEmpty {
                accumulator = chunk
            } else {
                accumulator += " " + chunk
            }
            // Only split if accumulator is long enough AND ends with punctuation
            let lastChar = accumulator.last ?? " "
            if accumulator.count >= 40 && ".!?,;:".contains(lastChar) {
                merged.append(accumulator)
                accumulator = ""
            }
        }
        if !accumulator.isEmpty {
            if let last = merged.last {
                merged[merged.count - 1] = last + " " + accumulator
            } else {
                merged.append(accumulator)
            }
        }

        return merged
    }

    /// Returns the pause duration in seconds based on the trailing punctuation of a chunk.
    func pauseDuration(after text: String) -> TimeInterval {
        guard let last = text.last else { return 0 }
        let base: TimeInterval
        switch last {
        case ".":  base = 0.45
        case "!":  base = 0.40
        case "?":  base = 0.50
        case ",":  base = 0.15
        case ";":  base = 0.25
        case ":":  base = 0.30
        default:   base = 0.10
        }
        return skipSilence ? base * 0.3 : base
    }

    /// Trims trailing near-silence from audio samples, keeping a 50ms tail.
    private func trimTrailingSilence(from samples: [Float]) -> [Float] {
        let threshold: Float = 0.005
        let tailSamples = Int(24000.0 * 0.05) // 50ms at 24kHz

        // Find last sample above threshold
        var lastLoudIndex = samples.count - 1
        while lastLoudIndex > 0 && abs(samples[lastLoudIndex]) < threshold {
            lastLoudIndex -= 1
        }

        // Keep 50ms tail after last loud sample
        let endIndex = min(samples.count, lastLoudIndex + tailSamples + 1)
        return Array(samples.prefix(endIndex))
    }

    // MARK: - Preview (standalone playback, doesn't affect main state)

    private var previewEngine: AVAudioEngine?
    private var previewPlayer: AVAudioPlayerNode?
    private var previewTask: Task<Void, Never>?

    /// Synthesize and play a short text snippet for preview purposes.
    /// Uses a separate audio engine — does not affect main playback state.
    func preview(text: String) async {
        guard !text.isEmpty else { return }

        // Ensure Kokoro is ready
        if kokoroManager == nil { await initializeKokoro() }
        guard let mgr = kokoroManager else { return }

        // Stop any previous preview
        stopPreview()

        // Synthesize
        let samples: [Float]
        do {
            let result = try await mgr.synthesizeDetailed(text: text, voice: currentVoice)
            samples = result.chunks.flatMap { chunk -> [Float] in
                let s = chunk.samples
                if s.count > kokoroGuardSamples {
                    return Array(s.dropLast(kokoroGuardSamples))
                }
                return s
            }
        } catch {
            ttsLogger.error("Preview synthesis failed: \(error.localizedDescription)")
            return
        }

        guard !samples.isEmpty else { return }

        // Set up a dedicated preview audio engine
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false
        ) else {
            ttsLogger.error("Failed to create preview audio format")
            return
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
        engine.prepare()

        let buffer = createPCMBuffer(from: samples)

        do {
            try engine.start()
        } catch {
            ttsLogger.error("Preview engine start failed: \(error.localizedDescription)")
            return
        }

        previewEngine = engine
        previewPlayer = player

        player.scheduleBuffer(buffer, completionHandler: nil)
        player.play()

        // Wait for playback to finish, then tear down
        previewTask = Task {
            let durationNs = UInt64(Double(samples.count) / 24000.0 * 1_000_000_000)
            try? await Task.sleep(nanoseconds: durationNs + 200_000_000)
            await MainActor.run { self.stopPreview() }
        }
    }

    func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewPlayer?.stop()
        previewEngine?.stop()
        previewPlayer = nil
        previewEngine = nil
    }

    // MARK: - Audio Engine

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let engine = audioEngine, let player = playerNode else { return }

        engine.attach(player)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        ) else {
            ttsLogger.error("Failed to create audio format")
            audioEngine = nil
            playerNode = nil
            return
        }

        engine.connect(player, to: engine.mainMixerNode, format: format)

        engine.mainMixerNode.outputVolume = volume
        engine.mainMixerNode.auAudioUnit.maximumFramesToRender = 4096
        engine.outputNode.auAudioUnit.maximumFramesToRender = 4096

        engine.prepare()
    }

    private func createPCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
        let channelData = buffer.floatChannelData else {
            ttsLogger.error("Failed to create PCM buffer")
            // Return a minimal valid buffer as fallback
            let fallbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
            let fallbackBuffer = AVAudioPCMBuffer(pcmFormat: fallbackFormat, frameCapacity: 1)!
            fallbackBuffer.frameLength = 0
            return fallbackBuffer
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        let ptr = channelData[0]
        for (i, sample) in samples.enumerated() {
            ptr[i] = sample
        }

        return buffer
    }

    private func waitForPlaybackCompletion() async {
        while !lastBufferFinished && !isStopped {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func waitForStreamingPlaybackCompletion() async {
        // AVAudioPlayerNode.isPlaying stays true even after all buffers drain,
        // so we schedule a tiny silent sentinel buffer whose completion handler
        // signals that all real audio has finished playing.
        guard let player = playerNode,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false
              ),
              let sentinel = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1),
              let channelData = sentinel.floatChannelData else { return }
        sentinel.frameLength = 1
        channelData[0][0] = 0

        var done = false
        player.scheduleBuffer(sentinel) {
            done = true
        }

        while !done && !isStopped {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Playback Controls

    func pause() {
        playerNode?.pause()
        state = .paused
    }

    func resume() {
        playerNode?.play()
        state = .playing
    }

    func stop() {
        isStopped = true
        synthesisTask?.cancel()
        synthesisTask = nil

        playerNode?.stop()
        audioEngine?.stop()

        playerNode = nil
        audioEngine = nil

        playedSamples = 0
        totalSamples = 0
        progress = 0.0
        currentSentence = ""
        currentSentenceIndex = -1
        sentences = []
        loadingMessage = ""
        state = isEngineReady ? .ready : .idle

        startIdleUnloadTimer()
    }

    // MARK: - Voice

    func setVoice(_ voice: String) async {
        currentVoice = voice
        switch currentEngine {
        case .pocketTTS:
            await pocketManager?.setDefaultVoice(voice)
        case .kokoro:
            try? await kokoroManager?.setDefaultVoice(voice)
        }

        // Notify user the new voice will apply on the next sentence
        if state == .playing || state == .paused || state == .generating {
            showStatusMessage("Voice changed — applies on next sentence")
        }
    }

    // MARK: - Sentence Navigation

    func skipToNextSentence() async {
        let savedSentences = sentences
        let text = currentFullText
        let nextIndex = currentSentenceIndex + 1
        guard !text.isEmpty, nextIndex < savedSentences.count else { return }
        await speak(text: text, startFromChunk: nextIndex)
    }

    func skipToPreviousSentence() async {
        let text = currentFullText
        let prevIndex = max(currentSentenceIndex - 1, 0)
        guard !text.isEmpty else { return }
        await speak(text: text, startFromChunk: prevIndex)
    }

    // MARK: - Sleep Timer

    func setSleepTimer(_ mode: SleepTimerMode) {
        sleepTimerTask?.cancel()
        sleepTimerMode = mode

        switch mode {
        case .off:
            sleepTimerRemainingSeconds = 0
        case .timed(let minutes):
            sleepTimerRemainingSeconds = minutes * 60
            sleepTimerTask = Task {
                while sleepTimerRemainingSeconds > 0 && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self.sleepTimerRemainingSeconds -= 1 }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.stop()
                    self.sleepTimerMode = .off
                }
            }
        case .endOfSection:
            sleepTimerRemainingSeconds = 0
        }
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerMode = .off
        sleepTimerRemainingSeconds = 0
    }

    // MARK: - Status Messages

    private func showStatusMessage(_ message: String, duration: TimeInterval = 3) {
        statusMessageTask?.cancel()
        statusMessage = message
        statusMessageTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self.statusMessage = "" }
        }
    }

    // MARK: - Custom Lexicon

    private static var lexiconFileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("custom_lexicon.txt")
    }

    func loadCustomLexicon() {
        guard let url = Self.lexiconFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            customLexicon = nil
            lexiconEntryCount = 0
            kokoroManager?.setCustomLexicon(nil)
            return
        }

        do {
            let lexicon = try TtsCustomLexicon.load(from: url)
            customLexicon = lexicon
            lexiconEntryCount = lexicon.count
            kokoroManager?.setCustomLexicon(lexicon)
            ttsLogger.notice("Loaded custom lexicon with \(lexicon.count) entries")
        } catch {
            ttsLogger.error("Failed to load custom lexicon: \(error.localizedDescription)")
            customLexicon = nil
            lexiconEntryCount = 0
        }
    }

    func saveAndApplyLexicon(_ content: String) throws {
        guard let url = Self.lexiconFileURL else { return }

        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: url)
            customLexicon = nil
            lexiconEntryCount = 0
            kokoroManager?.setCustomLexicon(nil)
            return
        }

        try content.write(to: url, atomically: true, encoding: .utf8)
        let lexicon = try TtsCustomLexicon.parse(content)
        customLexicon = lexicon
        lexiconEntryCount = lexicon.count
        kokoroManager?.setCustomLexicon(lexicon)
        ttsLogger.notice("Applied custom lexicon with \(lexicon.count) entries")
    }

    func loadLexiconFileContent() -> String {
        guard let url = Self.lexiconFileURL,
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return content
    }

    /// Converts a "sounds like" word to IPA phonemes via the G2P model.
    /// Requires Kokoro engine to be initialized.
    func phonemize(word: String) async throws -> String? {
        if kokoroManager == nil {
            await initializeKokoro()
        }
        guard let mgr = kokoroManager else { return nil }
        guard let tokens = try await mgr.phonemize(word: word) else { return nil }
        return tokens.joined()
    }

    // MARK: - Lifecycle

    private func startIdleUnloadTimer() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(idleUnloadDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            ttsLogger.notice("Idle timeout - unloading models")
            await unloadModels()
        }
    }

    private func cancelIdleUnloadTimer() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    private func unloadModels() async {
        await pocketManager?.cleanup()
        pocketManager = nil
        kokoroManager?.cleanup()
        kokoroManager = nil
        state = .idle
        ttsLogger.notice("Models unloaded")
    }

    func cleanup() {
        stop()
        let pocket = pocketManager
        let kokoro = kokoroManager
        pocketManager = nil
        kokoroManager = nil
        kokoro?.cleanup()
        Task {
            await pocket?.cleanup()
        }
    }
}
