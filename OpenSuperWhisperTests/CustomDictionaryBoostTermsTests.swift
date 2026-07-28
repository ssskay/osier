import XCTest
@testable import OpenSuperWhisper

/// `boostTerms` is the single source of the words boosted on BOTH engines
/// (Whisper prompt-boost + Parakeet decode vocabulary), so its contract is
/// covered directly here.
final class CustomDictionaryBoostTermsTests: XCTestCase {

    private func entry(_ original: String, _ replacement: String) -> CustomDictionaryEntry {
        CustomDictionaryEntry(original: original, replacement: replacement)
    }

    func testUsesReplacementsAndIgnoresOriginal() {
        let terms = CustomDictionary.boostTerms(entries: [entry("my monkey", "My-Monkey")])
        XCTAssertEqual(terms, ["My-Monkey"])
    }

    func testIncludesBoostOnlyEntriesWithEmptyOriginal() {
        // An entry with no "heard as" still boosts its replacement term.
        let terms = CustomDictionary.boostTerms(entries: [entry("", "Kubernetes")])
        XCTAssertEqual(terms, ["Kubernetes"])
    }

    func testDeduplicatesCaseInsensitivelyPreservingOrder() {
        let terms = CustomDictionary.boostTerms(entries: [
            entry("", "Parakeet"),
            entry("swiftui", "SwiftUI"),
            entry("", "parakeet"),   // duplicate of "Parakeet" (case-insensitive) → dropped
            entry("", "Kubernetes"),
        ])
        XCTAssertEqual(terms, ["Parakeet", "SwiftUI", "Kubernetes"])
    }

    func testFiltersEmptyAndWhitespaceReplacements() {
        let terms = CustomDictionary.boostTerms(entries: [
            entry("", "   "),
            entry("heard", ""),
            entry("", "Validity"),
        ])
        XCTAssertEqual(terms, ["Validity"])
    }

    func testPromptBoostJoinsBoostTermsWithCommas() {
        let entries = [entry("", "Alphabet"), entry("", "Betamax")]
        XCTAssertEqual(CustomDictionary.promptBoost(entries: entries), "Alphabet, Betamax")
    }

    // MARK: - Over-correction guardrail (#over-boost)

    /// Short single words are the ones the vocabulary rescorer mangles ordinary speech into:
    /// "tools" → "Tonys", "start" → "Bart", "so" → "SLO". They're excluded from boosting.
    func testExcludesShortSingleWords() {
        let terms = CustomDictionary.boostTerms(entries: [
            entry("", "SLO"),
            entry("", "Bart"),
            entry("", "Tonys"),
            entry("", "Kubernetes"),
        ])
        XCTAssertEqual(terms, ["Kubernetes"])
    }

    /// Multi-word terms are distinctive enough to boost no matter how short their parts are.
    func testKeepsMultiWordTermsRegardlessOfLength() {
        let terms = CustomDictionary.boostTerms(entries: [
            entry("", "Yi Ma"),
            entry("", "Bart Simpson"),
        ])
        XCTAssertEqual(terms, ["Yi Ma", "Bart Simpson"])
    }

    /// The boundary is inclusive: exactly `minimumBoostLength` characters is boostable.
    func testLengthBoundaryIsInclusive() {
        XCTAssertEqual(CustomDictionary.minimumBoostLength, 6)
        XCTAssertTrue(CustomDictionary.isBoostSafe("GitHub"))   // 6
        XCTAssertFalse(CustomDictionary.isBoostSafe("Xcode"))    // 5
    }

    /// The guardrail gates boosting only — an excluded term is still replaced verbatim.
    func testExcludedTermsStillReplace() {
        let entries = [entry("slow", "SLO")]
        XCTAssertTrue(CustomDictionary.boostTerms(entries: entries).isEmpty)
        XCTAssertEqual(CustomDictionary.apply("the slow budget", entries: entries), "the SLO budget")
    }
}
