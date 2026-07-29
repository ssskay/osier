# PALETTE-REGRADE — corrective pass on the wicker palette

**Scope: `OpenSuperWhisper/Brand/OsierTheme.swift` only.** No layout changes, no view
edits, no new tokens, no renames. Every token below already exists; only its hex changes.
If a fix seems to require touching a view file, stop and flag it instead.

**Status:** requested 2026-07-29 after Sara reviewed the built Settings and main windows.

---

## The diagnosis

The palette is not wrong in hue — it's wrong in *lightness distribution*.

The reference mockups use two zones: near-white paper and near-black green ink, with
whitespace and hairlines doing the structural work. The implementation instead created a
family of mid-tone tans (`wicker`, `straw`, `caution`) and used them as **fills** for large
regions — the Settings sidebar, the stats bar, the permission notice. The result is that
almost every pixel sits between 75% and 88% lightness with olive text on top. Nothing is
white, nothing is black, and the eye has no anchor.

Two corollaries:

1. **High-chroma tan as a fill is the single biggest offender.** `wicker #E6DDC6` is a
   saturated tan. As a 1px border it would be invisible; as the whole Settings sidebar it
   dominates. Same for `straw #C8B795` on hairlines — a hairline should be felt, not read.
2. **`caution` is louder than anything else in the app.** A `0.14` fill plus a `0.42`
   border makes a routine permission notice the most visually dominant element in the
   Settings window. Cautions should be quiet; they are not errors.

---

## The changes

### Raw ramp

| Token | From | To | Why |
|---|---|---|---|
| `cream` light | `0xF1EFE8` | `0xF7F5EF` | Lift the paper toward the mockup's near-white. |
| `cream` dark | `0x211E19` | `0x1F1D18` | Unchanged in spirit; one step deeper for contrast headroom. |
| `wicker` light | `0xE6DDC6` | `0xEDEAE0` | **The main fix.** Drop chroma hard, raise lightness. Stays warm, stops being tan. |
| `wicker` dark | `0x2B2721` | `0x2A2722` | Effectively unchanged. |
| `straw` light | `0xC8B795` | `0xDFDACA` | Hairlines must recede. This is the difference between a rule and a band. |
| `straw` dark | `0x3D372E` | `0x3A352D` | Effectively unchanged. |
| `leaf` light | `0x3B6D11` | `0x2E5C0E` | Deeper, less yellow. The mockup's green reads nearly black. |
| `leaf` dark | `0x4F8A1E` | `0x5C9A26` | Compensate for the darker light-mode value. |
| `bark` | unchanged | unchanged | Already correct. |
| `newGrowth` | unchanged | unchanged | Already correct. |
| `rust` | unchanged | unchanged | **Do not touch.** Recording-only rule stands. |

### Semantic tokens

| Token | From | To | Why |
|---|---|---|---|
| `surfaceRaised` light | `0xFBFAF6` | `0xFFFFFF` | Cards become actual paper. This is what gives the cream ground something to be *next to*. |
| `surfaceSunken` light | `0xE6DDC6` | `0xEAE7DC` | Follows `wicker` down in chroma. |
| `hairlineSoft` light | `0xDED3B8` | `0xE8E4D8` | Same reasoning as `straw`. |
| `ink` light | `0x173404` | `0x1B3A0B` | Marginally richer; matches the mockup's ink. |
| `inkSoft` light | `0x4A5D3A` | `0x5C6B52` | **Desaturate.** This olive is the muddiest colour in the app and it's on every label and caption. |
| `inkFaint` light | `0x7C8A6E` | `0x8B9382` | Same — neutralise toward warm gray so placeholders stop reading as green. |
| `inkSoft` dark | `0xB8AF9C` | `0xB4ADA0` | Minor; keeps the pair consistent. |
| `mark` light | `0x3B6D11` | `0x2E5C0E` | Tracks `leaf`. |
| `markWash` alpha | `0.14` | `0.10` | Selection fills currently read as a second surface colour. |

### Caution — the loudest fix

| Token | From | To |
|---|---|---|
| `caution` light | `0xA8862E` | `0x7A6520` |
| `caution` dark | `0xD4B15A` | `0xC9A54E` |
| `cautionWash` alpha | `0.14` | `0.05` |
| `cautionBorder` alpha | `0.42` | `0.16` |

The intent: the notice should read as a paragraph with a quiet marker, not as a highlighted
block. Only the token values change here — **do not restructure the notice view**. If the
`0.05` wash and `0.16` border still read as a slab once built, say so and we'll decide on
the layout separately.

---

## Constraints

1. **`rust` and every `onNotch*` token are frozen.** The notch pill is off-limits per
   `SPEC-REBRAND.md` D1, and rust-means-recording is the identity rule.
2. **`highlight` / `onHighlight` stay fixed values.** The existing comment explains why —
   they must stay legible as a pair.
3. **No new tokens.** If a surface needs a value that doesn't exist, that's a layout
   problem, not a palette problem. Flag it, don't invent a token.
4. **One commit, one file.** The working tree has pre-existing uncommitted work; stage
   `OpenSuperWhisper/Brand/OsierTheme.swift` by path and nothing else.
5. Re-run the palette-leak check afterwards:
   `grep -rnE '0x[0-9A-Fa-f]{6}|Color\(red:|\.red|\.orange' --include="*.swift"` should be
   clean except `OsierTheme.swift`.

---

## Verification

Rebuild, then capture Settings ▸ Dictation and the main window in both appearances. The
things to judge, in order:

1. Does the Settings sidebar recede behind the content, or does it still read as a slab?
2. Does the stats bar in the main window sit *behind* the numbers rather than competing?
3. Is the Input Monitoring notice quieter than the section it sits in?
4. In dark mode, are `surface` and `surfaceRaised` still too close to distinguish? (Flagged
   as a known risk in `SPEC-REBRAND.md`; this pass doesn't change their dark values, so if
   it was a problem before it still is.)

Commit message: `fix(brand): re-grade the palette — lift surfaces, quiet the tans`
