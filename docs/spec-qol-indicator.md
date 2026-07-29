# Spec: Indicator quality-of-life fixes

Three changes to the notch/floating recording indicator. Line numbers refer to current working tree (2026-07-28).

---

## 1. Show a "transcribing" state after recording stops

**Problem:** When recording stops, the pill vanishes immediately and there's dead air until the transcript pastes. No feedback that transcription is in progress.

**Good news:** The UI already exists and is dead code. `RecordingState.decoding` renders a spinner + "Transcribing..." at `OpenSuperWhisper/Indicator/IndicatorWindow.swift:716-726`, but nothing ever sets it — `IndicatorViewModel.startDecoding()` (`IndicatorWindow.swift:258-302`) enqueues to `DictationPipeline` and immediately calls `delegate?.didFinishDecoding()` (`:301`), which tears the window down.

**Change:**

1. In `IndicatorViewModel.startDecoding()`: after enqueueing, set `state = .decoding` instead of calling `didFinishDecoding()` immediately.
2. Add a completion signal from `DictationPipeline` — today `process(_:)` (`DictationPipeline.swift:110-234`) returns silently on success. Simplest: post a `NotificationCenter` notification (e.g. `.dictationPipelineDidFinishItem`) or add a `@Published lastCompletedAt`, observed by `IndicatorViewModel`. On completion (success or failure), call `didFinishDecoding()` to run the existing hide animation.
3. **Preserve rapid re-record.** The immediate teardown exists so the next hotkey press starts a fresh recording (`ShortcutManager.handleKeyDown()` `:132-172` checks `activeVm`). Requirements:
   - Hotkey press while pill shows `.decoding` must start a new recording immediately — the pill switches back to `.recording` state (same window, don't spawn a second), and the in-flight transcription continues in the pipeline unaffected.
   - The existing "N queued" badge (`IndicatorWindow.swift:677-687`, driven by `pipeline.pendingCount`) keeps working.
4. If the queue has multiple items, keep showing `.decoding` until `pendingCount == 0 && !isProcessing`, then hide.
5. Existing failure flashes from `DictationPipeline` (`:139, 194, 215, 232` via `IndicatorWindowManager.flash`) should reuse the live pill if it's still up (set `.error`/`.info` on it) rather than spawning a new one; if the pill is gone, `flash` behaves as today.

**Acceptance:**
- Stop recording → pill morphs to spinner + "Transcribing..." with no gap → hides when text is inserted.
- Hotkey during transcribing → new recording starts instantly, no visual glitch.
- No regression to error/info flashes.

---

## 2. Fix entrance animation (bar travels in from the left)

**Problem:** On show, the bar sometimes enters from the left edge, slides to the bottom/center, then settles — instead of appearing in place with the intended slide-down-out-of-notch animation.

**Diagnosis (no explicit horizontal animation exists — this is window-frame movement while visible):** The SwiftUI entrance is vertical-only (`IndicatorWindow.swift:816-836`) and `panel.animationBehavior = .none` (`IndicatorWindowManager.swift:82`). The travel comes from `IndicatorWindowManager.swift`:

- Panel is created at `NSRect(x: 0, y: 0, ...)` — screen bottom-left (`:62-67`) — and only moved to final position by `reposition()` (`:188`).
- `hide()` awaits a ~0.3s animation before `orderOut` (`:312-338`). If `show()` runs during that window (rapid re-show), it re-hosts content and repositions a panel that is **still on screen**, so the user sees it jump/travel from its old position.
- `resizeToContent` (`:225-238`) + `reposition()` (`:240-260`) do a two-step shuffle on every size change: `setContentSize` keeps the left edge, then `setFrameOrigin` recenters. In non-notch mode the bubble resizes 200→380 when the caption arrives, moving the window sideways each time.

**Change:**

1. In `show()`: compute and set the final frame (position **and** size) in a single `setFrame(_:display:false)` **before** `orderFront`. Never order the panel in at the placeholder (0,0) frame.
2. If `show()` is called while a hide animation is in flight: cancel the hide, `orderOut` immediately (skip the exit animation), reset `viewModel.isVisible = false`, set the final frame, then order in and run the normal entrance. The panel must never be visible while its frame moves to the anchor.
3. In `reposition()`/`resizeToContent`: apply size + recentered origin as one atomic `setFrame` call instead of `setContentSize` followed by `setFrameOrigin`.
4. Remove the `#notch-too-tall` diagnostics (`Diag.mark` at `:251-259`) once verified — already flagged for removal in HANDOFF.md §3.

**Acceptance:**
- Cold show: bar appears at final X immediately; only animation is the slide-down out of the notch.
- Stop + immediately re-trigger repeatedly: no leftward travel, no jump from previous position.
- Non-notch (cursor) mode: bubble growth doesn't drag the window across the screen — it recenters without visible sliding (or accept an animated recenter, but never from (0,0)).

---

## 3. Unbind Escape from cancel

**Problem:** Escape cancels an in-progress recording, but Sara wants Escape for its normal purpose in whatever app she's in. She rarely cancels recordings.

**Where it lives:**
- Global hotkey: `KeyboardShortcuts.Name.escape` defined with default `.escape` at `ShortcutManager.swift:9-12`; handler + self-heal of a cleared binding at `:54-82`; enabled/disabled with the pill at `IndicatorWindowManager.swift:41` / `:313`.
- Local monitor (main window): `ContentView.swift:44-45, 209, 248-264` — reads the same bound shortcut.
- UI strings: "Press Esc to cancel" hint (`IndicatorWindow.swift:667-671`) and `CancelConfirmationBar` two-press flow (`:221-239, 400-419`).

**Change (keep cancel machinery, remove the default binding):**

1. Change the default for `KeyboardShortcuts.Name.escape` to `nil` (no default shortcut). Rename the constant to `.cancelRecording` for honesty (optional).
2. **Remove the self-heal** at `ShortcutManager.swift:59-61` that re-adds Escape when the binding is cleared. Also clear any persisted binding once on upgrade (KeyboardShortcuts persists in UserDefaults, so the old Escape binding will survive the default change — reset it explicitly, one-time migration).
3. Keep the Settings picker (`Settings.swift:1212-1219`) so a cancel key can be opted into later; label it "Cancel recording (optional)".
4. Make the hint text and two-press confirmation conditional: if no cancel shortcut is bound, don't show "Press Esc to cancel" or the `CancelConfirmationBar`. If one is bound, show its actual key name instead of hard-coded "Esc".
5. `ContentView` local monitor already no-ops when no shortcut is bound — verify, no change expected.

**Acceptance:**
- With pill up, pressing Escape does nothing to the recording and reaches the frontmost app normally.
- No "Press Esc to cancel" hint appears.
- Binding a key in Settings restores cancel behavior with correct hint text.

---

## Order of work

Do #3 first (small, isolated), then #2 (window manager only), then #1 (touches view model + pipeline). Each is independently shippable; commit separately.
