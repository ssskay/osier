import Foundation
import AVFoundation
import FluidAudio

class FluidAudioEngine: TranscriptionEngine {
    var engineName: String { "FluidAudio" }
    
    private var asrManager: AsrManager?
    private var asrModels: AsrModels?
    private var isCancelled = false
    private var transcriptionTask: Task<String, Error>?
    private var progressTask: Task<Void, Never>?

    /// When set ("v2"/"v3"), overrides the pref-selected model version — lets the
    /// remote local-fallback build an engine for a specific model without mutating
    /// global prefs.
    private let versionOverride: String?

    init(versionOverride: String? = nil) {
        self.versionOverride = versionOverride
    }
    
    var onProgressUpdate: ((Float) -> Void)?
    
    var isModelLoaded: Bool {
        asrManager != nil
    }
    
    func initialize() async throws {
        let versionString = versionOverride ?? AppPreferences.shared.fluidAudioModelVersion

        let models = try await ParakeetModelCache.shared.models(versionString: versionString)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)

        asrManager = manager
        asrModels = models
    }
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        guard let asrManager = asrManager else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        isCancelled = false
        
        // Notify start
        onProgressUpdate?(0.02)
        
        guard !isCancelled else {
            throw CancellationError()
        }
        
        // Start progress monitoring task using FluidAudio's transcriptionProgressStream
        let onProgress = onProgressUpdate
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            guard let self = self else { return }
            
            do {
                // Get the real progress stream from FluidAudio
                let progressStream = await asrManager.transcriptionProgressStream
                
                for try await progress in progressStream {
                    guard !Task.isCancelled, !self.isCancelled else { break }
                    
                    // FluidAudio reports 0.0-1.0, we map to 0.05-0.95
                    let scaledProgress = 0.05 + Float(progress) * 0.90
                    
                    await MainActor.run {
                        onProgress?(scaledProgress)
                    }
                }
            } catch {
                // Stream finished or error
            }
        }
        
        defer {
            progressTask?.cancel()
            progressTask = nil
        }

        // Two file paths:
        //  • No custom dictionary  → the offline AsrManager (full accuracy, the default).
        //  • Custom dictionary set  → a sliding-window pass with vocabulary boosting, the only
        //    place FluidAudio 0.15.4 exposes decoder boosting. We feed the WAV through it
        //    rather than the mic (see `transcribeFileWithBoosting`).
        let boostTerms = activeBoostTerms()
        let rawText: String
        if boostTerms.isEmpty {
            // A fresh TDT decoder state per file keeps transcriptions independent.
            var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
            rawText = try await asrManager.transcribe(url, decoderState: &decoderState).text
        } else {
            rawText = try await transcribeFileWithBoosting(url: url, boostTerms: boostTerms)
        }

        guard !isCancelled else {
            throw CancellationError()
        }

        // Finalize
        onProgressUpdate?(0.95)

        var processedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if settings.shouldApplyAsianAutocorrect && !processedText.isEmpty {
            processedText = AutocorrectWrapper.format(processedText)
        }

        if settings.shouldApplyCustomDictionary {
            processedText = CustomDictionary.apply(processedText, entries: settings.customDictionaryEntries)
        }

        onProgressUpdate?(1.0)
        
        return processedText.isEmpty ? TranscriptionResult.noSpeech : processedText
    }
    
    func cancelTranscription() {
        isCancelled = true
        progressTask?.cancel()
        progressTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }
    
    func getSupportedLanguages() -> [String] {
        EngineCapabilities.supportedLanguages(
            engine: "fluidaudio", fluidAudioModelVersion: AppPreferences.shared.fluidAudioModelVersion)
    }

    /// The custom-dictionary terms to bias recognition toward, or `[]` when the dictionary
    /// is disabled/empty. Single source shared with Whisper's prompt boost and the live
    /// streaming preview (`CustomDictionary.boostTerms`).
    private func activeBoostTerms() -> [String] {
        let prefs = AppPreferences.shared
        // Boosting is opt-in (separate from the always-on text replacement): only bias the
        // decoder when the user explicitly enabled it for rare/distinctive terms (#over-boost).
        guard prefs.customDictionaryEnabled, prefs.customDictionaryBoostEnabled else { return [] }
        return CustomDictionary.boostTerms(entries: prefs.customDictionaryEntries)
    }

    /// Window config for the file-boosting pass. The geometry is the proven 11+2+2 layout, exactly
    /// as `.default` — but both confirmation gates are zeroed, and that difference is load-bearing.
    ///
    /// `SlidingWindowAsrManager` is built for LIVE captions. Each window's text lands in a
    /// `volatile` slot and is only promoted to `confirmed` by the *next* window that clears
    /// `confirmationThreshold` AND `minContextForConfirmation`. A window that misses either gate
    /// overwrites the volatile slot instead — silently destroying the previous window's ~11s of
    /// speech — and `finish()` returns just `confirmed + volatile`. Holding text back until a later
    /// window vouches for it is right for a live caption, which can still revise itself; a finished
    /// file has nothing left to revise, so withholding a window only loses it.
    ///
    /// The tail took the damage because the last window is always a short partial chunk (3–7s),
    /// which is the one least likely to clear the gates — and nothing follows it to promote the
    /// full window before it. Measured on a 14.1s clip: `.default` returned ", you know." (11
    /// chars) against 268 chars from the offline path. Zeroing both gates confirms every window,
    /// making the pass lossless. (#tail-truncation)
    static let fileBoostingConfig = SlidingWindowAsrConfig(
        chunkSeconds: 11.0,
        hypothesisChunkSeconds: 2.0,
        leftContextSeconds: 2.0,
        rightContextSeconds: 2.0,
        minContextForConfirmation: 0,
        confirmationThreshold: 0
    )

    /// Transcribes a whole file through a `SlidingWindowAsrManager` configured with vocabulary
    /// boosting — the only API surface in FluidAudio 0.15.4 that biases the Parakeet decoder
    /// toward custom terms. The 11+2+2 window matches the offline chunking, so output quality
    /// tracks the offline path; boosting only nudges misrecognized terms.
    ///
    /// The audio comes entirely from `streamAudio(_:)` (the WAV read into one buffer, then sliced),
    /// never a microphone — `startStreaming(source:)` only records the source as metadata and opens
    /// no input device. `finish()` returns the merged transcript.
    private func transcribeFileWithBoosting(url: URL, boostTerms: [String]) async throws -> String {
        // Reuse the models this engine already loaded (and honour `versionOverride`, which the
        // old per-call reload ignored). Reloading here cost a full CoreML load per dictation.
        let models: AsrModels
        if let asrModels {
            models = asrModels
        } else {
            models = try await ParakeetModelCache.shared.models(
                versionString: versionOverride ?? AppPreferences.shared.fluidAudioModelVersion)
        }

        let manager = SlidingWindowAsrManager(config: Self.fileBoostingConfig)
        try await configureVocabulary(on: manager, boostTerms: boostTerms)
        try await manager.loadModels(models)
        try await manager.startStreaming(source: .system)

        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            await manager.cancel()
            return ""
        }
        try audioFile.read(into: buffer)

        // Feed in window-sized chunks (the manager re-buffers internally for its sliding window).
        let samplesPerChunk = Int(Self.fileBoostingConfig.chunkSeconds * format.sampleRate)
        var position = 0
        let totalFrames = Int(buffer.frameLength)
        while position < totalFrames {
            if isCancelled {
                await manager.cancel()
                throw CancellationError()
            }
            let chunkSize = min(samplesPerChunk, totalFrames - position)
            guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkSize))
            else { break }
            for channel in 0..<Int(format.channelCount) {
                if let src = buffer.floatChannelData?[channel], let dst = chunk.floatChannelData?[channel] {
                    for i in 0..<chunkSize { dst[i] = src[position + i] }
                }
            }
            chunk.frameLength = AVAudioFrameCount(chunkSize)
            await manager.streamAudio(chunk)
            position += chunkSize
            await Task.yield()
        }

        return try await manager.finish()
    }

    /// Configures vocabulary boosting on a `SlidingWindowAsrManager` from the dictionary terms,
    /// using the same temp-file + CTC-token approach the engine has always used. Throws on failure
    /// so the caller surfaces it rather than silently transcribing without the requested boost.
    private func configureVocabulary(on manager: SlidingWindowAsrManager, boostTerms: [String]) async throws {
        // Cached: CTC models + tokenization are loaded once per dictionary revision, not per clip.
        guard let vocabulary = try await ParakeetModelCache.shared.vocabulary(terms: boostTerms) else { return }
        try await manager.configureVocabularyBoosting(
            vocabulary: vocabulary.vocab,
            ctcModels: vocabulary.models
        )
    }
}

