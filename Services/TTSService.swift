import Foundation
import AVFoundation
import FluidAudioTTS
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

    private(set) var state: State = .idle
    private(set) var loadingMessage: String = ""
    private(set) var currentVoice: String = "alba"
    private(set) var progress: Double = 0.0
    private(set) var batchPrefillVersion: String = "Not loaded"
    private(set) var availableVersions: [String] = []
    var debugMode: Bool = false
    private(set) var currentSentence: String = ""
    private(set) var isThrottling: Bool = false  // True when generation < real-time
    private(set) var currentRTFx: Double = 0.0   // Current real-time factor (>1.0 = faster than real-time)
    private(set) var currentSentenceIndex: Int = -1
    private(set) var sentences: [String] = []

    private var manager: PocketTtsManager?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var synthesisTask: Task<Void, Never>?
    private var idleUnloadTask: Task<Void, Never>?
    private var isStopped = false
    private var totalFrames = 0
    private var playedFrames = 0

    /// Seconds of idle before unloading models to prevent thermal throttling
    private let idleUnloadDelay: TimeInterval = 60

    var isPlaying: Bool {
        state == .playing
    }

    var availableVoices: [String] {
        ["alba", "heart", "bella"]
    }

    init() {
        setupAudioSession()
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }

    func initialize() async {
        guard manager == nil else { return }

        let initStart = Date()
        state = .loadingModels
        loadingMessage = "Loading TTS models..."
        ttsLogger.notice("Starting TTS initialization")

        do {
            let mgr = PocketTtsManager(defaultVoice: currentVoice)
            try await mgr.initialize()
            manager = mgr

            // Get batch prefill version info
            let version = await mgr.getBatchPrefillVersion()
            batchPrefillVersion = version.displayName
            ttsLogger.notice("Batch prefill: \(version.displayName)")

            // Get available versions
            let versions = await mgr.getAvailableVersions()
            self.availableVersions = Array(versions.map { $0.rawValue }.sorted().reversed())
            ttsLogger.notice("Available versions: \(self.availableVersions.joined(separator: ", "))")

            let elapsed = Date().timeIntervalSince(initStart)
            ttsLogger.notice("TTS models loaded in \(String(format: "%.0f", elapsed * 1000))ms")
            loadingMessage = ""
            state = .ready
        } catch {
            loadingMessage = ""
            state = .error("Failed to load TTS: \(error.localizedDescription)")
        }
    }

    func speak(text: String) async {
        guard !text.isEmpty else { return }

        // Cancel any pending model unload
        cancelIdleUnloadTimer()

        if manager == nil {
            await initialize()
        }

        guard let manager = manager else { return }

        stop()
        cancelIdleUnloadTimer()  // Cancel again since stop() starts the timer
        isStopped = false
        playedFrames = 0
        totalFrames = 0
        currentSentence = ""
        currentSentenceIndex = -1
        sentences = []

        // Setup audio engine
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
                let stream = await manager.synthesizeStream(text: text, voice: currentVoice)

                // Batch frames to reduce scheduling overhead (5 frames = 400ms chunks)
                let batchSize = 5
                // Pre-buffer before starting playback (75 frames = 6 seconds runway)
                // Needed because thermal throttling can drop RTFx to 0.5-0.7x
                let preBufferFrames = 75
                var sampleBuffer: [Float] = []
                var frameCount = 0
                var totalBufferedFrames = 0
                var hasStartedPlayback = false

                var frameTimings: [Double] = []
                var lastFrameTime = Date()

                for try await frame in stream {
                    guard !isStopped else { break }

                    // Track time between frames
                    let now = Date()
                    let frameDelta = now.timeIntervalSince(lastFrameTime) * 1000
                    frameTimings.append(frameDelta)
                    lastFrameTime = now

                    // Update RTFx every 10 frames
                    if frame.frameIndex > 0 && frame.frameIndex % 10 == 0 {
                        let avgMs = frameTimings.suffix(10).reduce(0, +) / 10.0
                        let rtfx = 80.0 / avgMs  // 80ms per frame / actual time = RTFx
                        ttsLogger.notice("Frame \(frame.frameIndex): avg \(String(format: "%.1f", avgMs))ms/frame, RTFx: \(String(format: "%.2f", rtfx))x")

                        // Update throttling status on main thread
                        let throttling = rtfx < 1.0
                        Task { @MainActor in
                            self.currentRTFx = rtfx
                            if throttling != self.isThrottling {
                                self.isThrottling = throttling
                                if throttling {
                                    ttsLogger.warning("⚠️ Generation slower than real-time (RTFx: \(String(format: "%.2f", rtfx))x) - audio may stutter")
                                }
                            }
                        }
                    }

                    totalFrames = max(totalFrames, frame.frameIndex + 1)

                    // Update current sentence if chunk changed (no await - use nonisolated)
                    if frame.chunkIndex != self.currentSentenceIndex {
                        let chunkIndex = frame.chunkIndex
                        let chunkText = frame.chunkText
                        Task { @MainActor in
                            self.currentSentenceIndex = chunkIndex
                            self.currentSentence = chunkText
                            if self.sentences.count <= chunkIndex {
                                self.sentences.append(chunkText)
                            }
                        }
                    }

                    // Accumulate samples
                    sampleBuffer.append(contentsOf: frame.samples)
                    frameCount += 1

                    // Schedule batch when we have enough frames or it's the last frame
                    if frameCount >= batchSize || frame.isLast {
                        let buffer = createPCMBuffer(from: sampleBuffer)
                        let framesInBatch = frameCount

                        playerNode.scheduleBuffer(buffer) { [weak self] in
                            Task { @MainActor in
                                self?.playedFrames += framesInBatch
                                if let total = self?.totalFrames, total > 0 {
                                    self?.progress = Double(self?.playedFrames ?? 0) / Double(total)
                                }
                            }
                        }

                        sampleBuffer.removeAll(keepingCapacity: true)
                        totalBufferedFrames += framesInBatch
                        frameCount = 0

                        // Start playback after pre-buffering (or on last frame if short)
                        if !hasStartedPlayback && (totalBufferedFrames >= preBufferFrames || frame.isLast) {
                            let latency = Date().timeIntervalSince(startTime)
                            ttsLogger.notice("Pre-buffered \(totalBufferedFrames) frames in \(String(format: "%.0f", latency * 1000))ms, starting playback")
                            await MainActor.run {
                                self.loadingMessage = ""
                                self.state = .playing
                            }
                            try engine.start()
                            playerNode.play()
                            hasStartedPlayback = true
                        }
                    }
                }

                // Schedule any remaining samples
                if !sampleBuffer.isEmpty {
                    let buffer = createPCMBuffer(from: sampleBuffer)
                    playerNode.scheduleBuffer(buffer, completionHandler: nil)
                }

                // Log overall synthesis performance
                let synthesisTime = Date().timeIntervalSince(startTime)
                let totalAudioSeconds = Double(self.totalFrames) * 0.08  // 80ms per frame
                let overallRtfx = totalAudioSeconds / synthesisTime
                ttsLogger.notice("Synthesis complete: \(self.totalFrames) frames (\(String(format: "%.1f", totalAudioSeconds))s audio) in \(String(format: "%.1f", synthesisTime))s = \(String(format: "%.2f", overallRtfx))x RTFx")

                await waitForPlaybackCompletion()

                await MainActor.run {
                    if !self.isStopped {
                        self.state = .idle
                        self.progress = 1.0
                    }
                }
            } catch {
                await MainActor.run {
                    self.state = .error("Synthesis failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let engine = audioEngine, let player = playerNode else { return }

        engine.attach(player)

        // 24kHz mono float format (PocketTTS native output)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        )!

        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    private func createPCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer {
        // 24kHz mono float format (PocketTTS native output)
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
        guard let playerNode = playerNode else { return }

        while playerNode.isPlaying && !isStopped {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }

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

        playedFrames = 0
        totalFrames = 0
        progress = 0.0
        currentSentence = ""
        currentSentenceIndex = -1
        sentences = []
        loadingMessage = ""
        isThrottling = false
        currentRTFx = 0.0
        // Keep ready state if models are loaded
        state = manager != nil ? .ready : .idle

        // Start idle unload timer to prevent thermal throttling
        startIdleUnloadTimer()
    }

    private func startIdleUnloadTimer() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(idleUnloadDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            ttsLogger.notice("Idle timeout - unloading models to prevent thermal throttling")
            await unloadModels()
        }
    }

    private func cancelIdleUnloadTimer() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    private func unloadModels() async {
        await manager?.cleanup()
        manager = nil
        state = .idle
        ttsLogger.notice("Models unloaded")
    }

    func setVoice(_ voice: String) async {
        currentVoice = voice
        await manager?.setDefaultVoice(voice)
    }

    func setBatchVersion(_ versionRaw: String) async -> Bool {
        guard let version = BatchPrefillVersion(rawValue: versionRaw) else {
            ttsLogger.error("Invalid version: \(versionRaw)")
            return false
        }
        guard let mgr = manager else {
            ttsLogger.error("Manager not initialized")
            return false
        }
        let success = await mgr.setBatchPrefillVersion(version)
        if success {
            batchPrefillVersion = version.displayName
            ttsLogger.notice("Switched to version: \(version.displayName)")
        }
        return success
    }

    func cleanup() {
        stop()
        Task {
            await manager?.cleanup()
        }
        manager = nil
    }
}
