import AppKit
import SwiftUI

/// Osier's brand palette — the single source of colour for the whole app.
///
/// An osier is the willow used for basket weaving, so the ramp is willow greens over
/// wicker creams. Two rules make the identity work, and both are load-bearing:
///
/// 1. **Rust is reserved for the recording state.** It appears when the app is capturing
///    audio and nowhere else — never as an accent, a highlight or a warning. That's what
///    makes a flash of rust in the corner of the screen mean something.
/// 2. **Every colour in the app comes from here.** `STheme` (the Settings tokens) aliases
///    these, so there is one ramp, not two.
///
/// Dark mode is derived, not invented: greens lighten one step so they hold up against a
/// dark ground, and the cream surfaces become a deep *warm* gray — never pure black, which
/// would read as a generic dark theme rather than as unlit wicker. The one deliberate
/// exception is the notch pill, which stays pure black so it reads as a continuation of the
/// physical bezel; it does not draw from these tokens at all.
enum Osier {

    // MARK: - Raw ramp

    /// Willow bark — the darkest green. Body text on light, surfaces on dark.
    static let bark = dyn(light: 0x173404, dark: 0x0E2003)
    /// Mature willow leaf — the primary brand green and the app's accent.
    static let leaf = dyn(light: 0x3B6D11, dark: 0x4F8A1E)
    /// New growth — the bright young-shoot green. Accent on dark ground.
    static let newGrowth = dyn(light: 0x97C459, dark: 0xA8D06B)
    /// Bleached cream — the primary surface. Deep warm gray on dark.
    static let cream = dyn(light: 0xF1EFE8, dark: 0x211E19)
    /// Woven wicker — the secondary surface, one step warmer than cream.
    static let wicker = dyn(light: 0xE6DDC6, dark: 0x2B2721)
    /// Dry straw — the hairline and border tone.
    static let straw = dyn(light: 0xC8B795, dark: 0x3D372E)
    /// Rust. Recording only. See the note above before reaching for this.
    static let rust = dyn(light: 0xD85A30, dark: 0xE06B41)

    // MARK: - Semantic tokens
    //
    // What the rest of the app actually calls. Prefer these over the raw ramp: they say
    // what a colour is *for*, so a later tuning pass changes one line rather than forty.

    /// Window and panel backgrounds.
    static let surface = cream
    /// Cards, list rows and anything sitting on top of `surface`.
    static let surfaceRaised = dyn(light: 0xFBFAF6, dark: 0x2B2721)
    /// Inset wells — text fields, search bars, code blocks.
    static let surfaceSunken = dyn(light: 0xE6DDC6, dark: 0x1A1714)
    /// 1px borders and dividers.
    static let hairline = straw
    /// A softer hairline for dividers inside a card, where a full border is too loud.
    static let hairlineSoft = dyn(light: 0xDED3B8, dark: 0x332E26)

    /// Emphasised text — headings and pane titles. The strongest step.
    static let inkBright = dyn(light: 0x0E2003, dark: 0xFFFDF7)
    /// Primary text.
    static let ink = dyn(light: 0x173404, dark: 0xF1EFE8)
    /// Secondary text — labels, captions, metadata.
    static let inkSoft = dyn(light: 0x4A5D3A, dark: 0xB8AF9C)
    /// Tertiary text — hints and placeholders. The quietest readable step.
    static let inkFaint = dyn(light: 0x7C8A6E, dark: 0x8A8072)

    /// The mark's woven ring, and the app accent. Green in every state.
    static let mark = dyn(light: 0x3B6D11, dark: 0xA8D06B)
    /// Selection fills and accent washes behind the accent colour.
    static let markWash = dyn(light: 0x3B6D11, dark: 0xA8D06B, alpha: 0.14)

    /// **Recording only.** The live waveform strand, the capture indicator, nothing else.
    static let recording = rust
    /// Wash behind the recording state (the collapsed tab's glow, the confirm bar's track).
    static let recordingWash = dyn(light: 0xD85A30, dark: 0xE06B41, alpha: 0.16)

    /// Cautions and confirmations. Straw-gold rather than a system amber, so a warning
    /// stays inside the palette instead of importing an alien orange.
    static let caution = dyn(light: 0xA8862E, dark: 0xD4B15A)
    static let cautionWash = dyn(light: 0xA8862E, dark: 0xD4B15A, alpha: 0.14)
    static let cautionBorder = dyn(light: 0xA8862E, dark: 0xD4B15A, alpha: 0.42)

    /// Errors. Deliberately *not* a red alarm — a deep bark-tinged umber that reads as
    /// serious without shouting, per the brand's calm-and-handmade footing.
    static let error = dyn(light: 0x8C3A1E, dark: 0xD98668)
    static let errorWash = dyn(light: 0x8C3A1E, dark: 0xD98668, alpha: 0.14)

    /// Search-match highlight, and the text sitting on it.
    ///
    /// Fixed rather than appearance-reactive, unlike everything else here: the two have to stay
    /// legible *as a pair*, and a highlight that flips with the system appearance while the text
    /// on it flips independently can land dark-on-dark.
    static let highlight = Color(nsColor: srgb(0xE8C766))
    static let onHighlight = Color(nsColor: srgb(0x1F1B12))

    /// Success.
    static let success = dyn(light: 0x3B6D11, dark: 0x8FC44F)
    static let successWash = dyn(light: 0x3B6D11, dark: 0x8FC44F, alpha: 0.14)

    // MARK: - Text on the notch pill
    //
    // The notch pill keeps its pure-black surface (it must read as the physical bezel
    // continuing downward), so its text can't use `ink` — that flips to bark on light
    // appearance and would vanish. These are fixed, appearance-independent values.

    /// Primary text on the always-black notch pill.
    static let onNotch = Color(nsColor: srgb(0xF1EFE8))
    /// Secondary text on the notch pill — confirmed caption text, queue counts.
    static let onNotchSoft = Color(nsColor: srgb(0xC8B795))
    /// Tertiary text on the notch pill — volatile (not-yet-confirmed) caption text.
    static let onNotchFaint = Color(nsColor: srgb(0x8A8072))

    // MARK: - Construction

    private static func srgb(_ v: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255,
                alpha: alpha)
    }

    /// An appearance-reactive colour. Resolved per-draw by AppKit rather than captured at
    /// launch, so a live Appearance switch repaints without relaunching the app.
    private static func dyn(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? srgb(dark, alpha)
                : srgb(light, alpha)
        })
    }
}

// MARK: - Type

extension View {
    /// The brand's serif/sans split: **the user's own transcribed words are set in serif**,
    /// every piece of UI chrome stays in SF Pro. That contrast is the signature — it makes a
    /// transcript read as a written thing rather than as interface text. Applied wherever a
    /// transcript appears: the notch caption, history rows, recall results.
    ///
    /// System serif (New York) via `.fontDesign`, so there is no bundled font to ship.
    func transcriptType() -> some View {
        fontDesign(.serif)
    }
}

extension NSFont {
    /// AppKit counterpart of `transcriptType()` — for transcript text in `NSMenuItem`s and
    /// other AppKit surfaces that can't take a SwiftUI modifier.
    static func osierTranscript(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}
