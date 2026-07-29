# Osier — handoff notes (2026-07-27)

Context lives in `PHASE-0-FINDINGS.md` (read §R3 first), `SPEC.md`, `TRIAGE.md`. Everything
below is polish on a **working app**: trigger, notch pill, auto-paste, stats bar, dictionary
(+ auto-learning suggestions), and filler-word stripping are all live as of tonight.

## Done (2026-07-28)

### ~~1. Notch entrance animation~~ — done, **not yet seen running**
`IndicatorWindow.swift`. The entrance is now a top-anchored reveal: in notch mode the pill
starts offset up by its own height (`notchEntranceTravel`) and slides down, with no scale
and no fade. `TopEdgeRevealMask` clips at the pill's top edge only (negative padding keeps
the other three sides open so the settled shadow isn't cut), so the part still "inside" the
notch simply isn't drawn. The other positions keep the old scale+rise+fade pop.

The collapse is **vertical only** (revised after Sara watched v1). First attempt morphed one
`NotchShape` from pill to tab by interpolating its width — which reads as a bar sliding
sideways to the right corner, not as a notch doing anything. Now: the full pill keeps its
width and retracts straight up into the notch (same `notchEntranceTravel`, same mask), the
dot/label ride up with it (`.offset`, not a fade), and the lock tab drops out of the notch's
right corner 0.12 s behind it. The glyph lives inside `lockTab` rather than a separate
overlay, so it can't drift out of step with its own shape.

Related: `.animation(nil, value: bubbleWidth)`. The pill widens when live-caption text
arrives, and that same moment un-collapses the tab — so the width change was getting swept
into the collapse animation and stretching the pill sideways. Width now snaps.

The old `collapsedLockTab` branch inside `case .recording` is gone, and with it the
conditional paddings that used to re-lay-out the container mid-collapse.

Two things this needed: the bubble is no longer clipped at all in notch mode (`BubbleClip`
with a nil shape) — the tab is allowed to hang below the pill's content box, and a bounds
clip would cut it off; and the entrance mask is notch-only, to keep the other positions'
blur material out of an extra compositing layer.

Window constraint respected: no window is moved, resized or animated. Offsets, masks and
frame changes are all content-level, inside the fixed 560×160 canvas.

### ~~2. Dictionary boost guardrails~~ — done
`CustomDictionary.isBoostSafe` + `minimumBoostLength = 6`, filtered inside `boostTerms`, so
it applies to both engines at once. A term is boostable if it's multi-word or ≥6 chars;
short single words are dropped from boosting only — they still replace as normal, which is
exact and can't fire on a word that wasn't said. No new toggle (invisible default). The
Settings "Boost recognition" info text now says so. Covered by
`CustomDictionaryBoostTermsTests`.

Also fixed in passing: the test target's `TEST_HOST` still pointed at `OpenSuperWhisper.app`
after the rebrand, so **the whole unit suite couldn't run**. Now `Osier.app`.

### Accessibility permission that never took (#tcc-responsible-process)
Symptom: Osier toggled **on** in Privacy & Security ▸ Accessibility, and the app still can't
paste — no error, it's just not trusted. Cause: `run.sh` ended by exec'ing the binary
(`…/Osier.app/Contents/MacOS/Osier`), so the process ran as a child of Terminal, and macOS
attributes TCC to the *responsible process* — Terminal, whose own Accessibility toggle was
off. Osier's grant was never consulted.

`run.sh` now launches with `open -W --stdout … --stderr …` instead, so Osier is responsible
for itself; the redirects keep the logs in the Terminal window and a trap keeps Ctrl-C
stopping the app. It also quits a running copy first, since `open` would otherwise just
activate the old one instead of the build it just made.

Second, unrelated way this breaks: anything that builds+launches the app without re-signing
(`xcodebuild test` does exactly that — it launches the unsigned test host) leaves a TCC
identity that doesn't match `dev-codesign.sh`'s stable one. Run tests via `Scripts/test.sh`,
which re-signs afterwards.

Dev convenience while here: `Scripts/make-dock-launcher.sh` builds `~/Applications/Run
Osier.app` — a Dock-pinnable click that opens Terminal on `Scripts/dock-run.sh` (quit, build,
run, logs).

## Open items, in priority order

### 3. Remove temporary diagnostics (after a few clean days)
- `#chord-double-fire` prints: `ModifierKeyMonitor.handleFlagsChanged`,
  `ShortcutManager.handleKeyDown`
- `#notch-too-tall` reposition logs: `IndicatorWindowManager.reposition`
Keep `Diag` itself — it's load-bearing (unified log, survives force-quit).

### 4. MouseButtonMonitor
Same CGEventTap design that failed twice for the keyboard trigger (taps die via
`tapDisabledByTimeout` and never recover — see findings §R3). If the mouse trigger is ever
used, port it to NSEvent global+local monitors like `ModifierKeyMonitor` now is.

### 5. Nice-to-haves (unprioritized)
- Stats bar: per-period cuts (today / this week) alongside lifetime.
- Auto-dictionary: threshold currently 3 occurrences, cap 8 suggestions
  (`AutoDictionary.suggestionThreshold` / `suggestionLimit`) — tune with real use.
- The old `/Applications/OpenSuperWhisper.app` (Homebrew, Maxim's signature) is still
  installed and caused two separate TCC fights. `brew uninstall --cask opensuperwhisper`.

## Feature backlog (brainstorm 2026-07-28, unordered — pick by mood)

Now that it's a personal tool, features can assume *Sara's* setup. Ranked loosely by
leverage-per-effort; each notes the existing hook it builds on.

1. **Voice capture → Hamster Hub.** A spoken routing prefix — "note to Hamtaro: …" —
   detected after transcription: instead of pasting, POST the text to Hamster TV
   (`localhost:5050/api/entries`, or `memory_log` semantics). `PostRecordHook` already
   pipes every transcription to a shell command with JSON on stdin, so v0 is a hook
   script, zero app changes; v1 makes it a first-class voice command with a confirmation
   flash in the pill. This turns dictation into the capture layer for the whole hamster
   system — from any app, without opening anything.

2. **Re-paste last dictation** hotkey/menu-bar item. When focus was in the wrong window,
   the text currently strands in history. One shortcut: re-run `insertText` with the most
   recent completed recording. Small, immediately useful (tonight proved it).

3. **Per-app behavior profiles.** `RecordingContext` already captures the frontmost app,
   window title and URL per recording, and `ContextModelSwitcher` already switches models
   by context. Extend the same rule engine to: per-app dictionary subsets, per-app LLM
   cleanup prompt (casual for Slack, terse for terminals), per-app "type vs ⌘V".

4. **Voice snippets** (Willow's "Personal Shortcuts"). Dictionary-style expansions:
   say "insert my email" → `sara@sarakay.me`. Same `CustomDictionaryEntry` machinery,
   one extra entry kind. Cheap.

5. **"Scratch that" command.** Spoken during or right after a dictation: discard the
   last sentence (in-flight) or delete+retype the last insertion (after). The
   `stripSubmitCommand` pattern shows where trailing-command parsing lives.

6. **Brain-dump mode (Oxnard/Bijou fuel).** A long-rant profile: no paste — instead LLM
   post-processing (already in the fork, `remote` backend works with Anthropic's
   OpenAI-compatible endpoint) summarizes to bullets and files the result into Brain
   Dumps / Craft via hook. Trigger: hold-to-record past N seconds, or a spoken prefix.

7. **Japanese practice mode (Dexter).** A hotkey-toggled language pin (menu-bar Language
   picker already exists): dictate in Japanese, history keeps the original; optional
   romaji line via post-processing. Low effort, and it makes Osier a study tool.

8. **Menu-bar daily words.** The stats query already exists; a tiny "today: 1,240 words"
   in the menu-bar item. No streaks, ever.

## Repo / GitHub setup (decided with Claude, 2026-07-27)

MIT allows a full rebrand — the only *legal* obligation is keeping the LICENSE file with
the original copyright notice. The attribution chain (Starmel → my-monkeys → Osier) is
already in the README, which covers etiquette too.

- **Detached repo, not a GitHub fork.** Reasons: GitHub won't let a public fork be private;
  forks are de-ranked in search; and "fork" framing invites upstream PR expectations Sara
  doesn't want. This is a personal tool.
- **Keep the full git history** (don't squash) and add upstream as a remote:
  `git remote add upstream https://github.com/my-monkeys/OpenSuperWhisper.git`
  — SPEC §6 R2 commits to cherry-picking upstream fixes, which needs shared history.
- Sparkle auto-update is already disarmed (`SUEnableAutomaticChecks = false`) so a rebrand
  can't get "updated" back into upstream's build.

## Next session

Items 1 and 2 above are built and the suite is green, but **the animation has only been
reasoned about, never watched**. First thing: run a dictation in notch mode and check the
slide-down and the collapse morph. Things most likely to need a number tweaked:

- `notchEntranceTravel` (pill height + 8) — if any sliver flashes at the top, raise it.
- The two springs: entrance `response: 0.42, dampingFraction: 0.78`, morph `0.42 / 0.82`.
- `IndicatorViewModel.startRecording`'s 1.0 s `collapseTimer` — the morph now takes longer
  than the old swap, so the pill is expanded a beat longer overall.
