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

    private(set) var state: State = .idle
    private(set) var loadingMessage: String = ""
    private(set) var currentVoice: String = "alba"
    private(set) var currentEngine: TTSEngine = .pocketTTS
    private(set) var progress: Double = 0.0
    var debugMode: Bool = false
    var volume: Float = 1.0 {
        didSet { audioEngine?.mainMixerNode.outputVolume = volume }
    }
    private(set) var currentSentence: String = ""
    private(set) var currentSentenceIndex: Int = -1
    private(set) var sentences: [String] = []
    var onPlaybackFinished: (() -> Void)?

    private var pocketManager: PocketTtsManager?
    private var kokoroManager: KokoroTtsManager?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var synthesisTask: Task<Void, Never>?
    private var idleUnloadTask: Task<Void, Never>?
    private var isStopped = false
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
            return ["alba", "heart", "bella"]
        case .kokoro:
            // American English voices only (tested/supported)
            return TtsConstants.availableVoices.filter { $0.hasPrefix("af_") || $0.hasPrefix("am_") }
        }
    }

    init() {
        setupAudioSession()
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
            let mgr = KokoroTtsManager(defaultVoice: currentVoice)
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

    func speak(text: String) async {
        guard !text.isEmpty else { return }

        cancelIdleUnloadTimer()

        if !isEngineReady {
            await initialize()
        }

        guard isEngineReady else { return }

        stop()
        cancelIdleUnloadTimer()
        isStopped = false
        lastBufferFinished = false
        playedSamples = 0
        totalSamples = 0
        currentSentence = ""
        currentSentenceIndex = -1

        let chunks = splitIntoChunks(text)
        sentences = chunks
        let totalChunks = chunks.count

        setupAudioEngine()

        guard let engine = audioEngine, let playerNode = playerNode else {
            state = .error("Failed to setup audio engine")
            return
        }

        state = .generating
        loadingMessage = "Generating speech..."

        let startTime = Date()
        synthesisTask = Task {
            do {
                var hasStartedPlayback = false
                var cumulativeSamples = 0

                for (index, chunk) in chunks.enumerated() {
                    guard !isStopped else { break }

                    await MainActor.run {
                        self.currentSentenceIndex = index
                        self.currentSentence = chunk
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

                    let chunkTime = Date().timeIntervalSince(chunkStart)
                    let chunkDuration = Double(samples.count) / 24000.0
                    ttsLogger.notice("Chunk \(index + 1) done: \(String(format: "%.1f", chunkDuration))s audio in \(String(format: "%.1f", chunkTime))s (\(String(format: "%.1f", chunkDuration / chunkTime))x RTFx)")

                    cumulativeSamples += samples.count
                    totalSamples = cumulativeSamples

                    // Append silence to samples based on trailing punctuation
                    var samplesWithPause = samples
                    if index < totalChunks - 1 {
                        let pause = pauseDuration(after: chunk)
                        if pause > 0 {
                            samplesWithPause += [Float](repeating: 0, count: Int(24000.0 * pause))
                        }
                    }

                    cumulativeSamples += samplesWithPause.count - samples.count
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
                        print("[TTS] Playback finished naturally, calling onPlaybackFinished: \(self.onPlaybackFinished != nil)")
                        self.onPlaybackFinished?()
                    } else {
                        print("[TTS] Playback ended but isStopped=true, skipping callback")
                    }
                }
            } catch {
                print("[TTS synthesis error] \(error)")
                await MainActor.run {
                    self.state = .error("Synthesis failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func synthesizePocketTTS(_ text: String) async throws -> [Float] {
        guard let mgr = pocketManager else { throw TTSError.notInitialized }
        let result = try await mgr.synthesizeDetailed(text: text, voice: currentVoice)
        return result.samples
    }

    private func synthesizeKokoro(_ text: String) async throws -> [Float] {
        guard let mgr = kokoroManager else { throw TTSError.notInitialized }
        let result = try await mgr.synthesizeDetailed(text: text, voice: currentVoice)
        // Kokoro returns samples per chunk — concatenate all chunk samples
        return result.chunks.flatMap { $0.samples }
    }

    private enum TTSError: LocalizedError {
        case notInitialized
        var errorDescription: String? { "TTS engine not initialized" }
    }

    // MARK: - Text Chunking

    private func splitIntoChunks(_ text: String) -> [String] {
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
    private func pauseDuration(after text: String) -> TimeInterval {
        guard let last = text.last else { return 0 }
        switch last {
        case ".":  return 0.45
        case "!":  return 0.40
        case "?":  return 0.50
        case ",":  return 0.15
        case ";":  return 0.25
        case ":":  return 0.30
        default:   return 0.10
        }
    }

    // MARK: - Audio Engine

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let engine = audioEngine, let player = playerNode else { return }

        engine.attach(player)

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        )!

        engine.connect(player, to: engine.mainMixerNode, format: format)

        engine.mainMixerNode.outputVolume = volume
        engine.mainMixerNode.auAudioUnit.maximumFramesToRender = 4096
        engine.outputNode.auAudioUnit.maximumFramesToRender = 4096

        engine.prepare()
    }

    private func createPCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        )!

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)

        let channelData = buffer.floatChannelData![0]
        for (i, sample) in samples.enumerated() {
            channelData[i] = sample
        }

        return buffer
    }

    private func waitForPlaybackCompletion() async {
        while !lastBufferFinished && !isStopped {
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
        Task {
            await pocketManager?.cleanup()
        }
        kokoroManager?.cleanup()
        pocketManager = nil
        kokoroManager = nil
    }
}
