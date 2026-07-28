import Foundation

/// A single custom-dictionary rule: whenever `original` is recognized in a
/// transcription it is rewritten to `replacement`. Useful for fixing proper
/// nouns, brand names and domain jargon that the speech models consistently
/// mis-transcribe (e.g. "git hub" -> "GitHub").
struct CustomDictionaryEntry: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var original: String
    var replacement: String

    init(id: UUID = UUID(), original: String = "", replacement: String = "") {
        self.id = id
        self.original = original
        self.replacement = replacement
    }
}

enum CustomDictionary {

    /// Applies the user's dictionary replacements to a transcription.
    ///
    /// Matching is case-insensitive and constrained to word boundaries so that
    /// substrings inside larger words are left untouched (e.g. a rule for "cat"
    /// will not touch "category"). The replacement string is inserted verbatim,
    /// preserving the casing the user typed.
    static func apply(_ text: String, entries: [CustomDictionaryEntry]) -> String {
        guard !text.isEmpty, !entries.isEmpty else { return text }

        var result = text
        for entry in entries {
            let original = entry.original.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip incomplete rows. An empty `original` has nothing to match; an empty
            // `replacement` would silently DELETE every occurrence of `original` from the
            // output — a natural intermediate state when the user has filled "Heard" but not
            // yet "Replace with". Both are treated as no-ops rather than data loss.
            guard !original.isEmpty, !replacement.isEmpty else { continue }

            let escaped = NSRegularExpression.escapedPattern(for: original)
            // Only add a \b assertion where the adjacent character of the search
            // term is itself a word character — otherwise the boundary never
            // matches for terms that start/end with punctuation (e.g. "C++").
            let leadingBoundary = isWordCharacter(original.first) ? "\\b" : ""
            let trailingBoundary = isWordCharacter(original.last) ? "\\b" : ""
            let pattern = leadingBoundary + escaped + trailingBoundary

            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }

            let range = NSRange(result.startIndex..., in: result)
            // Use the trimmed replacement (consistent with promptBoost) so a stray leading/
            // trailing space in the rule doesn't produce double spaces in the output.
            let template = NSRegularExpression.escapedTemplate(for: replacement)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }

    /// Shortest single word that may be boosted. Below this the vocabulary rescorer starts
    /// rewriting ordinary speech into dictionary terms — observed live: "tools" → "Tonys",
    /// "start" → "Bart", "so" → "SLO". Short terms are close enough to common words that the
    /// rescorer's edit-distance check treats them as the same word.
    static let minimumBoostLength = 6

    /// Whether a term is safe to bias the decoder toward. Long words and multi-word phrases
    /// are distinctive enough that a false match is unlikely; short single words are not.
    /// This gates boosting ONLY — a short term still works as a normal replacement rule
    /// (`apply`), which is exact and can't fire on a word the user didn't say.
    static func isBoostSafe(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains(where: { $0.isWhitespace }) { return true }
        return trimmed.count >= minimumBoostLength
    }

    /// The de-duplicated list of replacement terms (the "correct" forms) that are safe to
    /// boost. This is the single source of the words we boost on both engines: Whisper via
    /// the initial prompt (`promptBoost`) and Parakeet via custom-vocabulary boosting
    /// (`FluidAudioEngine`). Order is preserved; de-duplication is case-insensitive.
    ///
    /// Terms that fail `isBoostSafe` are dropped here rather than surfaced as a per-entry
    /// toggle: over-correction is a property of the rescorer, not a preference, and the
    /// entry keeps working as a replacement either way.
    static func boostTerms(entries: [CustomDictionaryEntry]) -> [String] {
        var seen = Set<String>()
        return entries
            .map { $0.replacement.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && isBoostSafe($0) && seen.insert($0.lowercased()).inserted }
    }

    /// Builds an initial-prompt fragment from the dictionary's replacement terms
    /// so a prompt-conditioned model (Whisper) is biased toward producing the
    /// correct spelling in the first place.
    static func promptBoost(entries: [CustomDictionaryEntry]) -> String {
        boostTerms(entries: entries).joined(separator: ", ")
    }

    static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character = character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }
}

/// One auto-learned candidate term and how often it has been dictated.
struct AutoDictionaryCandidate: Codable, Equatable {
    var word: String
    var count: Int
    var lastSeen: Date
}

/// Willow-style auto-learning: notice proper-noun-ish terms that keep appearing in
/// dictations and offer them as one-click dictionary suggestions in Settings. Nothing is
/// ever added silently — the user approves or dismisses each term.
enum AutoDictionary {

    /// A term becomes a suggestion once it has been dictated this many times.
    static let suggestionThreshold = 3
    /// The candidate cache is pruned to this many most-recently-seen terms.
    static let cacheLimit = 300
    /// At most this many suggestions are shown at once.
    static let suggestionLimit = 8

    /// Capitalized words the heuristic should never suggest: sentence-starters slip
    /// through when punctuation is odd, and days/months are capitalized but not jargon.
    private static let stopWords: Set<String> = [
        "the", "and", "but", "okay", "yeah", "yes", "hey", "also", "then", "now",
        "well", "wait", "wow", "man", "just", "like", "you", "your", "this", "that",
        "there", "here", "what", "when", "where", "which", "who", "how", "why",
        "i'm", "i'll", "i've", "i'd", "it's", "let's", "don't", "can't", "we're",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "english", "america", "american", "google", "apple", "internet", "youtube",
    ]

    /// Extracts candidate terms: runs of capitalized words (up to 4) that do NOT start a
    /// sentence — mid-sentence capitalization is the transcription engine telling us it
    /// thinks this is a name. ("I met Hatsune Miku today" → ["Hatsune Miku"])
    static func candidateTerms(in text: String) -> [String] {
        var results: [String] = []
        let sentences = text.split(whereSeparator: { ".!?\n;".contains($0) })
        for sentence in sentences {
            let tokens = sentence.split(whereSeparator: { $0.isWhitespace })
                .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "_'"))) }
                .filter { !$0.isEmpty }
            var index = 0
            while index < tokens.count {
                guard index > 0, qualifies(tokens[index]) else { index += 1; continue }
                var phrase = [tokens[index]]
                var next = index + 1
                while next < tokens.count, phrase.count < 4, qualifies(tokens[next]) {
                    phrase.append(tokens[next])
                    next += 1
                }
                results.append(phrase.joined(separator: " "))
                index = next
            }
        }
        return results
    }

    private static func qualifies(_ token: String) -> Bool {
        guard token.count >= 3,
              let first = token.first, first.isUppercase,
              !stopWords.contains(token.lowercased())
        else { return false }
        // Reject shouting/interjections: all-caps is fine only for short acronym-ish
        // tokens (AAFCS, SLO ships via the manual dictionary; auto-learning is
        // conservative on purpose).
        let isAllCaps = token.allSatisfy { !$0.isLowercase }
        return !isAllCaps || token.count <= 6
    }

    /// Feed one finished transcription into the candidate cache. Called by the
    /// dictation pipeline after post-processing, on the main actor.
    static func record(_ text: String) {
        let prefs = AppPreferences.shared
        guard prefs.autoDictionaryEnabled else { return }

        let known = knownTerms(entries: prefs.customDictionaryEntries)
        let dismissed = Set(prefs.autoDictionaryDismissed.map { $0.lowercased() })
        var cache = prefs.autoDictionaryCache
        var changed = false

        for term in candidateTerms(in: text) {
            let key = term.lowercased()
            guard !known.contains(key), !dismissed.contains(key) else { continue }
            var candidate = cache[key] ?? AutoDictionaryCandidate(word: term, count: 0, lastSeen: Date())
            candidate.count += 1
            candidate.lastSeen = Date()
            candidate.word = term
            cache[key] = candidate
            changed = true
        }

        if cache.count > cacheLimit {
            let keep = cache.sorted { $0.value.lastSeen > $1.value.lastSeen }.prefix(cacheLimit)
            cache = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            changed = true
        }
        if changed { prefs.autoDictionaryCache = cache }
    }

    /// Terms ready to offer: seen enough times, not already in the dictionary, not dismissed.
    static func suggestions(existingEntries: [CustomDictionaryEntry]) -> [String] {
        let prefs = AppPreferences.shared
        let known = knownTerms(entries: existingEntries)
        let dismissed = Set(prefs.autoDictionaryDismissed.map { $0.lowercased() })
        return prefs.autoDictionaryCache.values
            .filter { $0.count >= suggestionThreshold
                && !known.contains($0.word.lowercased())
                && !dismissed.contains($0.word.lowercased()) }
            .sorted { ($0.count, $0.lastSeen.timeIntervalSince1970) > ($1.count, $1.lastSeen.timeIntervalSince1970) }
            .prefix(suggestionLimit)
            .map(\.word)
    }

    /// Reject a suggestion permanently (and forget its counts).
    static func dismiss(_ term: String) {
        let prefs = AppPreferences.shared
        prefs.autoDictionaryDismissed = prefs.autoDictionaryDismissed + [term]
        var cache = prefs.autoDictionaryCache
        cache.removeValue(forKey: term.lowercased())
        prefs.autoDictionaryCache = cache
    }

    /// Remove an accepted term's counts (it now lives in the dictionary proper).
    static func forget(_ term: String) {
        var cache = AppPreferences.shared.autoDictionaryCache
        cache.removeValue(forKey: term.lowercased())
        AppPreferences.shared.autoDictionaryCache = cache
    }

    private static func knownTerms(entries: [CustomDictionaryEntry]) -> Set<String> {
        Set(entries.flatMap { [$0.original.lowercased(), $0.replacement.lowercased()] })
    }
}
