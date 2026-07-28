# SPEC-REBRAND — Osier "wicker" restyle

Visual rebrand only. Branch `rebrand/wicker`, one commit per phase.
Status: **§0 signed off 2026-07-28. Executing.**

---

## 0. Decisions — RESOLVED

| | Decision | Resolution |
|---|---|---|
| D1 | Notch pill surface | **Stays pure black.** Untouched. Only the glyph inside changes. |
| D2 | Rust vs. copper accent | Repoint `STheme.accent` to leaf green; rust = recording only. |
| D3 | Menu bar scope | Brand rows on top, separator, existing menu kept intact. |
| D4 | Recall row | Omitted — feature does not exist. |
| D5 | Paused state | Rendering designed, not wired. |
| D6 | Elapsed time | Included; flagged in commit message. |
| D7 | App icon | `.icns` via `iconutil`, matching existing wiring. |

**D1 is the hard constraint on this whole job: do not touch the notch.** `NotchShape.fill(.black)`,
the forced dark colorScheme, `TopEdgeRevealMask`, the collapse/entrance springs and every metric in
`NotchMetrics`/`NotchTuning` are off-limits. What changes inside the pill: the blinking red dot and
the red `lock.fill` tab glyph become the speaking-strand mark, caption text becomes serif, elapsed
time appears in mono digits, and red/orange give way to rust and straw.

Working-tree note: 32 pre-existing uncommitted files were carried onto this branch. Each phase
commit stages only its own paths, so that work stays uncommitted and untangled.

---

## 0b. Original findings (kept for context)

### D1 — The notch pill cannot be cream *(resolved: stays black)*

`IndicatorWindow.notchBackground` fills `NotchShape` with `.black`, and the whole subtree is
forced to `.environment(\.colorScheme, .dark)` (IndicatorWindow.swift:854). That is not a
default nobody revisited — it is the illusion the Indicator system is built on. The pill hangs
flush off the physical bezel and reads as the notch *growing downward*. A cream pill turns that
into a cream tab stuck under a black bezel, and the entrance animation ("retracts into the
notch", TopEdgeRevealMask) stops making sense.

- **Recommended:** notch pill keeps a near-black surface — retint from pure black to **bark
  `#173404` at very low lightness** (a warm near-black that is *green*, not neutral), so it still
  reads continuous with the bezel. Brand lands via the mark, the serif transcript, cream text
  (`#F1EFE8`), and a straw hairline. Cream *surfaces* go to the non-notch floating pill
  positions, which have no bezel to match and already use a material background.
- Alternative if you want cream in the notch anyway: say so and I'll do it, but the top-edge
  reveal will need re-tuning and it will not look bezel-continuous.

### D2 — Rust is already in use as a decorative accent *(blocking, phase 2)*

`STheme.accent` is copper `#E8734A` and is applied as *decoration* across the whole Settings
window — toggle tints, section accents, focus rings (SettingsTheme.swift:19). Copper and rust
`#D85A30` are near-neighbours. If both exist, "rust means recording" is dead on arrival.

- **Recommended:** repoint `STheme.accent` to **leaf `#3B6D11`** (new growth `#97C459` on dark),
  and let rust exist nowhere except the recording state. This *is* a visible change to Settings
  chrome beyond a straight palette swap — calling it out because you'll notice it.

### D3 — The menu bar brief deletes six working features *(blocking, phase 3)*

The brief says the dropdown holds Start dictation / Recall / last take + Copy / Open Osier…,
"Nothing else." The menu today (OpenSuperWhisperApp.swift:217–349) has: Open Window, **Language**
submenu, **Translate to English**, **Model** submenu, **Microphone** submenu, **Settings…**,
**Check for Updates…**, Quit. Taking the brief literally removes the only quick path to model,
mic and language switching. That is a feature removal, not paint, and it contradicts "no
behavior changes."

- **Recommended:** add the brand rows at the *top* (Start dictation + hotkey, last take in serif,
  Copy), then a separator, then everything that's there now, unchanged. You get the
  discoverability without losing the switches.
- If you genuinely want the six gone, that's fine — but it's a product decision, and I'd want it
  in its own commit, not inside a rebrand.

### D4 — "Recall" does not exist

No `.recall` shortcut, no recall command, no mention in SPEC.md, SPEC-BASKETS.md or HANDOFF.md.
There is nothing to read a hotkey for. **Recommended:** omit the row this pass; add it when the
feature ships. (Also: `ShortcutManager` currently exposes only `cancelShortcutDescription` — the
toggle-record description needs a matching accessor, ~4 lines, no logic change.)

### D5 — There is no paused state

`RecordingState` is idle / connecting / recording / decoding / busy / error / info. The app has
no pause. **Recommended:** design the frozen-strand + pause-glyph rendering into the mark so it's
ready, but wire no state. I'll style the two states the brief didn't mention and that *do* exist
and are user-visible: `.decoding` ("Transcribing…") and `.busy`.

### D6 — Elapsed time is new behavior

`recordingStartedAt` exists but nothing displays elapsed time. Showing it means a ~1 Hz timer
redrawing the pill. Small, but it's an addition, not paint. **Recommended:** include it, flagged
in the commit message per the ground rules. Say the word and I'll drop it instead.

### D7 — Icon wiring is `.icns`, not an asset catalog

`Assets.xcassets` has no `AppIcon.appiconset` — the app ships `OpenSuperWhisper/AppIcon.icns` via
`CFBundleIconFile`, while `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` points at a set that
isn't there. **Recommended:** `Scripts/make-appicon.sh` renders PNGs → `iconutil` → `AppIcon.icns`,
matching the wiring that actually works. No pbxproj churn.

**Also:** the tree has 32 uncommitted files (~1,215 insertions across Indicator, Settings,
CustomDictionary, ShortcutManager). `rebrand/wicker` branched from here inherits all of it and the
per-phase commits will be tangled with yours. I'd like you to commit or stash that first — I
haven't touched branching yet.

---

## 1. Surface inventory

| # | Surface | Files | What changes |
|---|---|---|---|
| 1 | **Notch pill** | `Indicator/IndicatorWindow.swift` (view layer only) | Surface tint, hairline, mark replaces red dot, serif caption, mono elapsed, rust-only-when-recording |
| 1b | Collapsed lock tab | same, `lockTab` | `lock.fill` red → mark strand in rust |
| 1c | Floating pill (non-notch) | same, `backgroundColor` | Cream / deep-warm-gray surface |
| 1d | Cancel confirm bar | same, `CancelConfirmationBar` | `.orange` → straw |
| 2 | **History / main window** | `ContentView.swift` | Palette, cream surfaces, transcript rows serif |
| 2b | Settings chrome | `SettingsTheme.swift` (+ ~24 hex literals repo-wide) | `STheme` repointed at palette; accent per D2 |
| 2c | Onboarding | `Onboarding/OnboardingView.swift` | Palette + mark |
| 3 | **Menu bar** | `OpenSuperWhisperApp.swift:198–350` | Mark as status image, brand rows per D3 |
| 4 | **App icon** | `Scripts/make-appicon.sh` → `AppIcon.icns` | Generated from the shared shape |
| 5 | Naming | `Info.plist` ✅ already Osier, `Readme.md` ✅ already attributed, `run.sh:82`, `Scripts/dock-run.sh` | Residual strings + quiet build output |

Untouched, deliberately: `NotchShape`, `NotchMetrics`, `NotchTuning`, `IndicatorWindowManager`
positioning/sizing, every engine, the whole `IndicatorViewModel` state machine.

## 2. Tokens

New file `OpenSuperWhisper/OsierTheme.swift`. Raw ramp + semantic layer; `STheme` is rewritten to
alias these so there is exactly one source of color.

```
enum Osier {
  // raw — light            dark
  bark       #173404        #0E2003
  leaf       #3B6D11        #4F8A1E   // greens lighten one step on dark
  newGrowth  #97C459        #A8D06B
  cream      #F1EFE8        #211E19   // cream surfaces → deep warm gray, never pure black
  wicker     #E6DDC6        #2B2721
  straw      #C8B795        #3D372E
  rust       #D85A30        #E06B41
}
```

Semantic (what code actually calls):

| Token | Light | Dark | Rule |
|---|---|---|---|
| `surface` | cream | deep warm gray | window + pill fill |
| `surfaceRaised` | white-ish | wicker-dark | cards, rows |
| `hairline` | straw | straw-dark | 1px borders |
| `ink` / `inkSoft` | bark / leaf-mid | cream / straw | text |
| `mark` | leaf | newGrowth | the ring, idle |
| `recording` | **rust** | **rust-dark** | **recording state only — never decoration** |
| — | — | — | notch surface stays `.black`, untokenized, untouched (D1) |

Type: transcripts `.fontDesign(.serif)`; chrome stays SF Pro; elapsed `.monospacedDigit()`.
Verification: `grep -rnE '0x[0-9A-Fa-f]{6}|Color\(red:|\.red|\.orange' --include="*.swift"` clean
except `OsierTheme.swift` at the end of each phase.

## 3. The mark — "speaking strand"

`OpenSuperWhisper/Brand/SpeakingStrand.swift`, one parametric SwiftUI view, every size and state:

```
SpeakingStrand(state:, phase:, size:)   // .idle .recording .transcribing .error
```

- Ring: 3 overlapping willow strands, open-ended arcs at slightly different radii/phase so the
  weave reads as over-under. Always `mark` green.
- Middle strand: horizontal waveform crossing the ring — irregular, seeded, *not* symmetric bars.
  Idle flat-ish green; recording rust + ripples off an animated `phase`; error becomes a short
  exclamation, ring stays green (no red).
- Renders at 16pt (menu bar, template-tinted), 22pt (pill), 512pt+ (icon) from the same code.

## 4. Phase order

| Phase | Commit | Gate |
|---|---|---|
| 0 | `SPEC-REBRAND.md` + decisions | **you sign off §0** |
| 1 | `feat(brand): palette tokens + speaking-strand mark` | builds; no surface changed yet |
| 2 | `feat(brand): restyle notch pill` | screenshots idle/recording × light/dark |
| 3 | `feat(brand): restyle main window + settings chrome` | screenshots |
| 4 | `feat(brand): menu bar` | hotkeys read live from ShortcutManager |
| 5 | `feat(brand): generated app icon` | `Scripts/make-appicon.sh` reproducible |
| 6 | `chore(brand): naming + quiet build scripts` | `run.sh` prints 3 lines on success |

Screenshots land in `docs/rebrand/` as `<surface>-<state>-<light\|dark>-<before\|after>.png`.
Every phase checked in both appearances; a phase isn't done until both are shot.
