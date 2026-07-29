# Osier — Notch-Native Dictation for macOS

**Status:** Planning complete, 2026-07-27. Source of truth for scope. Anything Claude Code proposes outside the non-goals list comes back to this doc first.
**Owner:** Sara. Personal tool first, portfolio piece second.

---

## 1. Fork decision: fork `my-monkeys/OpenSuperWhisper`

**Recommendation: hard-fork `my-monkeys/OpenSuperWhisper` (v0.9.9, MIT).** Not Handy, not greenfield.

Reasoning, from direct repo inspection (both repos were cloned and verified 2026-07-27):

- **Handy is disqualified as a fork base.** It's Rust + Tauri with a React frontend rendered in WKWebView. Every pixel of its UI — including the recording overlay — is web content. Grafting a SwiftUI notch onto it means a Swift windowing layer bolted to a Rust app via FFI, with mic-level events crossing the language boundary at 30 FPS. You'd keep the plumbing and rewrite the one thing this project is about. Keep it as a **reference implementation**: its pipeline (cpal → Silero VAD → whisper.cpp/Parakeet), its layout-independent keycode-9 paste trick (`src-tauri/src/input.rs`), and its `ExternalScript` paste extension point are all worth reading.
- **my-monkeys/OpenSuperWhisper is a true fork of Starmel's** (shared git history, merge-base May 2026), Swift/SwiftUI, active as of yesterday, and strictly ahead of upstream: 234 commits Starmel doesn't have. It already contains a working **notch-anchored indicator** with macOS 26/Tahoe crash workarounds, **clipboard-free text insertion**, **LLM post-processing hooks**, a **custom dictionary**, and five transcription engines. Much of this project is configuring and reshaping code that exists, not writing new code.
- **Greenfield is disqualified** because the boring 80% (audio capture, permissions, model management, insertion, engine abstraction) is exactly what the fork pre-solves, and it's in the right language.

**Caveat, stated loudly:** my-monkeys is a small fork (~39 stars, small maintainer group). Treat this as a **hard fork** — take the code, rename, don't depend on their roadmap. Cherry-pick upstream fixes when useful.

## 2. License decision: resolved, no landmines

Verified byte-for-byte in the LICENSE files: Starmel/OpenSuperWhisper, my-monkeys/OpenSuperWhisper, and DynamicNotchKit are all **verbatim MIT**. The my-monkeys fork did not change upstream's license.

- Fork, modify, rebrand, publish on your GitHub as a portfolio piece: **all permitted.**
- Obligation: keep the MIT copyright/permission notice ("Copyright (c) 2024 OpenSuperWhisper") in the repo and credit the upstream chain (Starmel → my-monkeys) in the README. Do this on day one so it's never a cleanup task.
- No GPLv3 anywhere in the dependency chain of record. (Handy is also MIT but its name/logo/brand are explicitly not open source — irrelevant since we're not forking it.)

## 3. Resolved decisions

| Decision | Resolution |
|---|---|
| Fork target | `my-monkeys/OpenSuperWhisper` (hard fork, rename to Osier) |
| License | MIT, attribution chain preserved |
| Notch UI | **Keep their custom notch indicator for now** (proven on Tahoe). Test it in Phase 0, restyle in Phase 1. DynamicNotchKit is the fallback if theirs fights us — swapping later is a contained refactor because the indicator lives in its own directory (`OpenSuperWhisper/Indicator/`). |
| Trigger | **Tap Fn+Control to start, tap Fn+Control again to stop-and-insert.** Toggle, not push-to-talk. Willow muscle memory, including the **lock icon** in the notch while listening. |
| Transcription engine | **Local Parakeet (FluidAudio)**, already wired in the fork. Budget-friendly, fast, offline. Raw proper-noun spelling is its weak spot — that's the cleanup pass's job. whisper.cpp stays available as a config switch. |
| Rant handling | **Chunked/incremental transcription during recording** (see §5 Phase 3). Stop-to-insert latency must stay roughly constant regardless of how long the rant was. This is a requirement, not an optimization. |
| Cleanup layer | Anthropic API (Sara's key), cheap/fast model (Haiku-class). Vocabulary list injected into the system prompt. Only recurring cost in the project. |
| Vocabulary storage | **Flat file** (one term per line, optional `wrong → right` pairs), in Application Support, hot-reloaded — editable without a rebuild. The fork's existing custom-dictionary feature is the starting point. |
| Live streaming transcript in notch | **Not in v1.** Sara doesn't need to see it. |
| Live-insert mode | **v2 candidate, explicitly parked.** A second mode where text pastes bit-by-bit while talking (vs. the default talk-then-paste). Noted because the Phase 3 chunking work is the same infrastructure that would power it — build Phase 3 so it doesn't preclude this. |
| Distribution | Personal build from source + public repo as portfolio. No signing, no notarization, no releases. |

## 4. Notch indicator state spec

The notch is the entire UI. No live transcript. States and transitions:

| State | Visual | Enter on | Exit to |
|---|---|---|---|
| **Idle** | Nothing. The notch is just the notch. | App launch; any terminal state completing | Listening |
| **Listening** | Notch area extends slightly; **lock icon** (the Willow homage) + live waveform reacting to mic level | Fn+Ctrl tap while Idle | Processing (Fn+Ctrl tap), Error (mic failure), Idle (cancel: Esc) |
| **Processing** | Waveform replaced by a pulse/spinner. Covers final transcription chunk + LLM cleanup. Should feel short because chunked transcription already did the work during Listening | Fn+Ctrl tap while Listening | Inserted, Error |
| **Inserted** | Checkmark flash, ~800 ms, then collapse to Idle. If cleanup was skipped/timed out, show a small "raw" badge next to the check | Insertion completes | Idle (auto) |
| **Error** | Amber/red tint + SF Symbol + one-line cause (mic denied / engine failed / insertion blocked). Auto-dismiss ~3 s | Any failure | Idle (auto). Transcript, if any exists, is placed on the clipboard so words are never lost |

Rules that bind all states:

- **Never lose words.** If cleanup fails or times out (budget: ~3 s), insert the raw transcript and badge it — never block insertion on the API.
- **Cancel path:** Esc during Listening discards, returns to Idle, no insertion.
- Second display / no notch: the fork's faux-notch fallback renders the same pill at the top edge. Same states.

## 5. Phased build plan

**Phase 0 — Baseline (no code changes).** Clone the fork, build in Xcode, grant mic + Accessibility permissions, dictate unmodified into three apps (native, Electron, terminal). Turn on their notch indicator mode and **live with it for a few days** — this is the early test Sara asked for. Also try their custom dictionary and LLM post-processing settings as-is to measure how far config alone gets. **Exit criteria: it dictates, the notch indicator shows, and there's a written list of what about the stock notch UI needs to change.** If the install fight from before recurs, it's diagnosed here on a clean build, not worked around.

**Phase 1 — Trigger + notch identity.** Implement the Fn+Ctrl toggle (see risk R3), the lock-icon Listening state, and the full state cycle from §4. Rename to Osier, attribution in README. **Exit: the §4 table is real on screen and the Willow muscle memory works.**

**Phase 2 — The proper-noun fix.** Wire the cleanup pass to the Anthropic API: flat-file vocabulary → system prompt, strict instruction to correct spelling/casing only and never paraphrase, 3 s timeout → raw fallback, key in Keychain. **Exit: a test script of anime titles, K-pop names, Japanese loanwords, and Terraform/Vault/OpenTelemetry/DuckDB/dbt terms comes out spelled right.**

**Phase 3 — Rant mode.** Chunked transcription during recording (VAD-segmented, transcribe segments while still listening) so a 3-minute rant inserts in ~2–3 s after the stop tap, same as a 10-second utterance. The fork's `StreamingTranscriptionController` is the starting point. **Exit: stop-to-insert latency measured flat across 10 s / 1 min / 3 min recordings.**

**Phase 4 — Parked (v2).** Live-insert mode. DynamicNotchKit swap if the custom indicator has worn badly. Portfolio polish.

Phases 0 and 1 become Claude Code prompts; this doc governs scope.

## 6. Technical risks, ranked

1. **R1 — Text insertion reliability.** Category-wide failure mode. *Substantially pre-solved in the fork:* primary path is synthetic Unicode typing (`CGEvent.keyboardSetUnicodeString`, 20-unit surrogate-safe chunks, never touches the clipboard → no clipboard race), with clipboard+Cmd+V as a fallback mode and a change-count-guarded restore. **Mitigation: keep both paths; build a Phase 0 test matrix (native app, Electron, terminal, browser textarea). Accept: secure input fields (passwords) block synthetic events by OS design — show Error state, don't fight it.**
2. **R2 — Fork abandonment.** my-monkeys is small and could stall. **Mitigation: hard fork posture from day one; cherry-pick upstream. Accept the maintenance.**
3. **R3 — Fn+Ctrl trigger capture.** Fn is not a normal hotkey modifier; a reliable Fn+Ctrl chord likely needs a CGEventTap (Accessibility permission — already required for insertion anyway). Fn behavior also varies with the "Press fn to…" system setting. **Mitigation: prototype early in Phase 1; fallback trigger is a Ctrl-based combo or double-tap (upstream added double-tap in July) with the same toggle semantics — the muscle memory that matters most is tap-toggle-tap, per Sara.**
4. **R4 — Rant-length latency.** One-shot transcription of long audio makes stop-to-insert scale with rant length. **Mitigation: Phase 3 chunking is scoped as a requirement. Until then, accept the lag in Phases 0–2.**
5. **R5 — Cleanup pass rewrites meaning.** An LLM asked to "clean up" will paraphrase. **Mitigation: prompt constrained to spelling/casing/punctuation of listed terms; temperature 0; raw fallback on anything weird; the "raw" badge keeps Sara aware when cleanup didn't run.**
6. **R6 — macOS 26 notch rendering.** Known-fragile area (the fork fixed a zero-size-indicator bug in v0.9.9; DynamicNotchKit has no published Tahoe fixes). **Mitigation: this is why we keep the fork's indicator — it has the workarounds. Phase 0 tests it immediately.**
7. **R7 — API cost/availability.** Cleanup adds a per-dictation API call. **Accept: Haiku-class pricing on dictation-sized payloads is pennies/month; offline → raw fallback already specified.**

## 7. Non-goals (the guardrail)

Not in this project, at all, until this doc says otherwise:

- No iPhone app.
- No meeting transcription, no file/audio import.
- No multi-language input beyond English (Japanese loanwords are an English-transcription vocabulary problem, not a language mode).
- No settings UI work in v1 — the fork's existing settings window is used as-is; new config (vocab file, trigger) is file-based.
- No App Store, no signing, no notarization, no public releases. Repo is public; builds are personal.
- No live streaming transcript rendered in the notch (v1).
- No live-insert mode (v1 — parked in §3, don't preclude it in Phase 3).
- No building notch rendering from scratch. Use the fork's; DynamicNotchKit is the designated fallback.
- No upstreaming PRs to my-monkeys as a project goal (fine opportunistically, never on the critical path).

## 8. Verified inputs (updated from session research, 2026-07-27)

- **my-monkeys/OpenSuperWhisper** — MIT (byte-identical to upstream), Swift/SwiftUI, macOS 14+, v0.9.9, last commit 2026-07-26. Notch indicator: custom (boring.notch-style, `NotchMetrics.swift` reads `safeAreaInsets` + auxiliary top areas; faux-notch fallback; five position modes). Insertion: `Utils/TextInserter.swift`. Engines: whisper.cpp v1.9.1 (own fork), Parakeet/FluidAudio, Apple Speech, SenseVoice, RemoteEngine. Also: `Utils/LLMPostProcessor.swift`, custom dictionary, CLI, Sparkle, Intel + ARM builds.
- **Starmel/OpenSuperWhisper** — MIT, upstream, slower-moving (19 open PRs), no notch mode. Superseded as a candidate.
- **Handy (cjpais/Handy)** — MIT (brand assets excluded), Rust/Tauri/React, 27k stars, feature-freeze policy. Reference only.
- **DynamicNotchKit (MrKai77)** — MIT, macOS 13+, Swift 6 toolchain required, v1.1.0, 0 open issues. `DynamicNotch` generic with expanded/compact states, `.auto` floating fallback. Fallback option only; untested on Tahoe.
