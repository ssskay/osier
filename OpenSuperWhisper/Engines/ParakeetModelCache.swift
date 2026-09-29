import Foundation
import FluidAudio

/// Process-wide cache of the loaded Parakeet (FluidAudio) CoreML models and the tokenized
/// custom-vocabulary context.
///
/// Why: before this, every dictation paid for model loading up to three times — the live preview
/// called `AsrModels.downloadAndLoad` + `CustomVocabularyContext.loadWithCtcTokens` on record
/// start, and the boosted file pass called both again on stop, on top of the copy the engine
/// already held. Each call re-opens the CoreML bundles from disk (hundreds of ms to seconds),
/// all of it on the critical path between "stop talking" and "text lands". The structs are
/// `Sendable` wrappers around thread-safe `MLModel`s, so one loaded copy can back every
/// `AsrManager` / `SlidingWindowAsrManager`; per-session decoder state lives in the managers.
/// (#parakeet-latency)
actor ParakeetModelCache {
    static let shared = ParakeetModelCache()

    private var asrModels: [String: AsrModels] = [:]
    private var asrLoads: [String: Task<AsrModels, Error>] = [:]

    private var vocabKey: [String]?
    private var vocab: (vocab: CustomVocabularyContext, models: CtcModels)?
    private var vocabLoad: (key: [String], task: Task<(vocab: CustomVocabularyContext, models: CtcModels), Error>)?

    /// Loaded models for "v2"/"v3" (anything else → v3). Concurrent callers share one load.
    func models(versionString: String) async throws -> AsrModels {
        let key = versionString == "v2" ? "v2" : "v3"
        if let cached = asrModels[key] { return cached }
        if let inFlight = asrLoads[key] { return try await inFlight.value }

        let task = Task<AsrModels, Error> {
            let start = DispatchTime.now().uptimeNanoseconds
            let models = try await AsrModels.downloadAndLoad(version: key == "v2" ? .v2 : .v3)
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
            Diag.mark("ParakeetModelCache: loaded ASR models \(key) in \(Int(ms))ms")
            return models
        }
        asrLoads[key] = task
        defer { asrLoads[key] = nil }
        let models = try await task.value
        asrModels[key] = models
        return models
    }

    /// Tokenized vocabulary + CTC models for `terms`, or nil when there's nothing to boost.
    /// Re-tokenizes only when the term list changes (dictionary edits), not per dictation.
    func vocabulary(terms rawTerms: [String]) async throws -> (vocab: CustomVocabularyContext, models: CtcModels)? {
        let terms = rawTerms.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        if vocabKey == terms, let vocab { return vocab.vocab.terms.isEmpty ? nil : vocab }
        if let inFlight = vocabLoad, inFlight.key == terms {
            let loaded = try await inFlight.task.value
            return loaded.vocab.terms.isEmpty ? nil : loaded
        }

        let task = Task<(vocab: CustomVocabularyContext, models: CtcModels), Error> {
            let start = DispatchTime.now().uptimeNanoseconds
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Osier-ParakeetVocabulary-\(UUID().uuidString)")
                .appendingPathExtension("txt")
            try terms.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }
            let loaded = try await CustomVocabularyContext.loadWithCtcTokens(from: url.path)
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
            Diag.mark("ParakeetModelCache: loaded CTC models + \(loaded.vocab.terms.count) vocab terms in \(Int(ms))ms")
            return loaded
        }
        vocabLoad = (terms, task)
        defer { if vocabLoad?.key == terms { vocabLoad = nil } }
        let loaded = try await task.value
        vocabKey = terms
        vocab = loaded
        return loaded.vocab.terms.isEmpty ? nil : loaded
    }

    /// Load everything the next dictation will need, off the critical path. Never downloads:
    /// bails unless the selected Parakeet version is already on disk, preserving the
    /// "no surprise downloads" rule that lazy engine loading exists for.
    func prewarm(versionString: String, boostTerms: [String]) async {
        let version: AsrModelVersion = versionString == "v2" ? .v2 : .v3
        let cacheDir = AsrModels.defaultCacheDirectory(for: version)
        guard AsrModels.modelsExist(at: cacheDir, version: version) else { return }
        _ = try? await models(versionString: versionString)
        // CTC models may need a first-time download; only warm them once the user has already
        // opted into boosting (they'd be fetched on the first dictation anyway).
        _ = try? await vocabulary(terms: boostTerms)
    }

    /// Drop everything (e.g. to reclaim RAM after switching away from Parakeet).
    func purge() {
        asrModels.removeAll()
        vocabKey = nil
        vocab = nil
    }
}
