import AppKit
import KeyboardShortcuts
import SwiftUI

/// A panel allowed to occupy the menu-bar / notch band. A plain NSPanel is clamped below
/// the menu bar by `constrainFrameRect(_:to:)`, which is why the notch pill used to sit
/// *under* the notch instead of merging with it — the window server silently pushed it
/// down ~38pt every time it was positioned flush with the screen top. (#notch-exact-fit)
private final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
class IndicatorWindowManager: IndicatorViewDelegate {
    static let shared = IndicatorWindowManager()

    /// The indicator window is sized manually (see `resizeToContent`) — NEVER via NSHostingView's
    /// `.preferredContentSize` auto-resize. That auto-resize animates the window frame on macOS 26
    /// (`NSHostingView.updateAnimatedWindowSize`) and recurses into layout until the main-thread
    /// stack overflows (#11/#15/#19). Must stay empty; `IndicatorLayoutRecursionTests` guards it.
    nonisolated static let hostingSizingOptions: NSHostingSizingOptions = []

    var window: NSWindow?
    var viewModel: IndicatorViewModel?

    // The window auto-sizes to its content (so the live caption pill grows with the text).
    // We keep the bottom edge anchored near the caret so it grows upward, not over the caret.
    private var anchorBottomY: CGFloat = 0
    private var anchorCenterX: CGFloat = 0
    // Notch mode anchors the *top* edge instead (the pill hangs from the screen top, growing down).
    private var anchorFromTop = false
    private var anchorTopY: CGFloat = 0
    private var resizeObserver: NSObjectProtocol?
    /// The in-flight exit animation, if any — so a re-show can abort it (see `cancelPendingHide`).
    private var hideTask: Task<Void, Never>?

    private init() {}

    func show(nearPoint point: NSPoint? = nil) -> IndicatorViewModel {

        KeyboardShortcuts.enable(.cancelRecording)

        // The previous recording's exit animation may still be running (rapid re-record).
        // Put the panel away NOW, without waiting it out: everything below re-anchors the
        // frame, and moving a panel that's still on screen is exactly what made the bar
        // appear to travel in from the screen edge. (#indicator-entrance-travel)
        cancelPendingHide()

        // A hotkey press while the previous clip is still transcribing: morph the pill that's
        // already on screen back to recording rather than tearing it down and replaying the
        // entrance. Same window, same view model, no frame move — and the transcription it was
        // reporting on keeps draining in DictationPipeline, which the "N queued" badge shows.
        if let current = viewModel, current.state == .decoding, window?.isVisible == true {
            current.prepareForReuse()
            return current
        }

        // Neutralize the outgoing view model BEFORE replacing it. A flash/error pill
        // (showInfo/showError/showBusyMessage) arms a delayed auto-hide timer; if show()
        // merely overwrites `viewModel`, that orphaned timer keeps running and its
        // didFinishDecoding() → hide() later tears down the *new, live* recording's pill
        // and posts indicatorWindowDidHide — which clears ShortcutManager.activeVm
        // mid-recording. The hotkey toggle then thinks nothing is recording, so the next
        // press "starts" — and the shared AudioRecorder, already recording, restarts
        // (stop+start). That's the unstoppable-recording / #chord-double-fire symptom:
        // one physical press, but a stop AND a start, from a single keyDown.
        viewModel?.cleanup()

        // Create new view model
        let newViewModel = IndicatorViewModel()
        newViewModel.delegate = self
        viewModel = newViewModel
        
        if window == nil {
            // Create window if it doesn't exist - using NSPanel for full-screen compatibility
            // (NotchPanel: an NSPanel that may sit flush with the screen top — see above)
            let panel = NotchPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            
            panel.isFloatingPanel = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            // Fully click-through by default, matching the my-monkeys baseline: the
            // indicator never intercepts clicks meant for the app underneath. When the
            // opt-in on-bubble Stop/Cancel buttons are enabled, this is flipped per
            // show() below so they're tappable.
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            // Belt-and-suspenders: the window is sized manually + non-animated via
            // `resizeToContent` (#19), and this also stops AppKit from animating the frame on
            // its own. Size changes should snap, never animate (macOS 26 recursion guard).
            panel.animationBehavior = .none

            // Level + behavior BEFORE any positioning or ordering: a freshly created panel
            // still at the default level can be constrained by the window server while it's
            // ordered in (menu-bar avoidance); at .screenSaver it may occupy the menu-bar/
            // notch band. The assignments further down re-assert these every show(), but
            // the first show() must not position a normal-level window. (#notch-too-tall)
            panel.level = .screenSaver
            panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]

            self.window = panel
        }
        
        // Host the SwiftUI content and size the window to it *ourselves* (see `resizeToContent`).
        // We deliberately do NOT use `sizingOptions = [.preferredContentSize]`: that auto-resize
        // runs animated on macOS 26 (NSHostingView.updateAnimatedWindowSize) and recurses into
        // layout until the main-thread stack overflows — the #11/#15/#19 crash.
        let hostingController = NSHostingController(
            rootView: IndicatorWindow(viewModel: newViewModel) { [weak self] size in
                self?.resizeToContent(size)
            }
        )
        hostingController.sizingOptions = Self.hostingSizingOptions
        window?.contentViewController = hostingController
        // Assigning a hosting controller with empty sizingOptions as the contentViewController
        // can leave the panel at 0×0 (seen on macOS 26; users reported it on macOS 15.7.x too):
        // SwiftUI then lays out in a 0×0 canvas, the content preference reports 0×0, and
        // `resizeToContent`'s `> 1` guard discards it — so the window stays 0×0 and the indicator
        // never appears in ANY position mode (#indicator-invisible). Seed a non-zero canvas
        // (non-animated, so no NSHostingView recursion-crash risk) so SwiftUI can lay out and
        // size the window.
        //
        // Notch mode goes further: the content-size preference PROVABLY never fires on this
        // machine (logged: the window stays at its seed size forever, so the pill floats
        // centred in an oversized canvas ~36pt below the notch — #notch-too-tall). So in
        // notch mode the window is simply a FIXED transparent canvas, big enough for the
        // widest state (live caption + buttons), the view pins its content to the top edge,
        // and `resizeToContent` is bypassed entirely. The window is click-through, so the
        // oversized canvas costs nothing.
        let isNotch = AppPreferences.shared.indicatorPosition == "notch"
        let seedContentSize = isNotch ? NSSize(width: 560, height: 160)
                                      : NSSize(width: 380, height: 120)

        // Accept clicks only when an on-bubble button is enabled (so it's tappable);
        // otherwise stay fully click-through (baseline). Re-evaluated each show() so
        // toggling the setting takes effect on the next recording.
        window?.ignoresMouseEvents = !(AppPreferences.shared.showStopButtonOnIndicator
            || AppPreferences.shared.showCancelButtonOnIndicator)

        // Position window - use the screen containing the point, or main screen as fallback
        let targetScreen = point.flatMap { FocusUtils.screenContaining(point: $0) } ?? NSScreen.main
        if targetScreen == nil {
            // No screen to anchor to (headless / between display changes). Still give SwiftUI a
            // non-zero canvas to lay out in, or the panel stays 0×0 forever (#indicator-invisible).
            window?.setContentSize(seedContentSize)
        }
        if let window = window, let screen = targetScreen {
            let screenFrame = screen.frame

            anchorFromTop = false
            switch AppPreferences.shared.indicatorPosition {
            case "notch":
                // Hang from the very top-center, growing downward — sitting in/around the notch
                // on notched Macs, or as a faux-notch pill on Macs without one.
                anchorFromTop = true
                anchorCenterX = screenFrame.midX
                anchorTopY = screenFrame.maxY

                // Auto-fit to the *physical* notch so the pill reads as the notch itself
                // extending (Willow-style), not a bar floating near it. NotchShape's concave
                // wings occupy `topRadius` on each side, so the straight body between them is
                // what must match the notch exactly: rect width = notch + 2×topRadius. Height
                // is the notch band plus a small visible chin below it. Also centre on the
                // notch's true midpoint (auxiliary areas), which can sit a half-point off the
                // screen's midX on odd-width panels. Recomputed per show(), so it follows
                // whichever screen the pill lands on. (#notch-exact-fit)
                if AppPreferences.shared.notchAutoFit, NotchMetrics.hasNotch(screen),
                   let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                    let tuning = NotchTuning.shared
                    let physical = NotchMetrics.notchSize(screen)
                    let fittedWidth = physical.width + 2 * tuning.topRadius
                    let fittedHeight = physical.height + CGFloat(AppPreferences.shared.notchChinHeight)
                    if abs(tuning.width - fittedWidth) > 0.5 { tuning.width = fittedWidth }
                    if abs(tuning.height - fittedHeight) > 0.5 { tuning.height = fittedHeight }
                    // The top `topInset` points of the pill hide behind the physical notch;
                    // the view pads its content down by this much so the dot/labels render
                    // in the visible chin below the bezel, not behind it.
                    tuning.topInset = physical.height
                    anchorCenterX = (left.maxX + right.minX) / 2
                } else {
                    NotchTuning.shared.topInset = 0
                }
            case "top":
                anchorCenterX = screenFrame.midX
                anchorBottomY = screenFrame.maxY - 140
            case "center":
                anchorCenterX = screenFrame.midX
                anchorBottomY = screenFrame.midY
            case "bottom":
                anchorCenterX = screenFrame.midX
                anchorBottomY = screenFrame.minY + 120
            default: // "cursor": sit just above the caret, falling back to a band near the top
                if let point = point {
                    anchorBottomY = point.y + 20
                    anchorCenterX = point.x
                } else {
                    anchorBottomY = screenFrame.maxY - 260
                    anchorCenterX = screenFrame.midX
                }
            }

            // Final size AND final position in ONE frame set, while the panel is still
            // ordered out. The panel is created at (0,0) — the screen's bottom-left — so any
            // path that orders it in before this lets the user watch it fly to the anchor.
            // (#indicator-entrance-travel)
            let seedFrameSize = window.frameRect(
                forContentRect: NSRect(origin: .zero, size: seedContentSize)).size
            window.setFrame(anchoredFrame(size: seedFrameSize, screen: screen), display: false)

            // Keep the bottom edge anchored as the content (and window) grows upward.
            if resizeObserver == nil {
                resizeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main
                ) { [weak self, weak window] _ in
                    guard let self, let window, let screen = window.screen ?? NSScreen.main else { return }
                    self.reposition(window: window, screen: screen)
                }
            }
        }

        // The indicator must draw over the menu bar AND over apps in a native full-screen space
        // (dictating into a full-screen app). `.fullScreenAuxiliary` + `.canJoinAllSpaces` let the
        // panel join the full-screen space, but that's not enough on its own: a `.statusBar`/
        // `.mainMenu`-level window (25) is occluded by the full-screen app's system-elevated window,
        // so the pill goes invisible there (#notch-fullscreen). `.screenSaver` (1000) is the level
        // dedicated overlay/notch apps (Lunar, boring.notch) use to sit above full-screen content;
        // it's also comfortably above the menu bar, so the notch pill still clears it.
        window?.level = .screenSaver
        window?.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]

        window?.orderFront(nil)
        // Re-assert the frame after ordering: if the window server nudged the panel while it
        // was ordered in, this puts it back. A no-op when nothing moved. (#notch-too-tall)
        if let window = self.window, let screen = targetScreen {
            reposition(window: window, screen: screen)
        }
        return newViewModel
    }

    /// Sizes the indicator window to its SwiftUI content, *non-animated*. This replaces
    /// NSHostingView's `.preferredContentSize` auto-resize, whose animated variant recurses into
    /// layout and overflows the main-thread stack on macOS 26 (#11/#15/#19). `setContentSize`
    /// snaps in a single pass, so no SwiftUI animation can ever drive a window resize.
    private func resizeToContent(_ size: CGSize) {
        // Notch mode uses a fixed canvas with top-pinned content — never resize it, even if
        // the content-size preference decides to fire. (#notch-too-tall)
        guard AppPreferences.shared.indicatorPosition != "notch" else { return }
        guard let window, size.width > 1, size.height > 1 else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let newFrameSize = window.frameRect(forContentRect: NSRect(
            origin: .zero,
            size: NSSize(width: ceil(size.width), height: ceil(size.height)))).size
        // Size and recentred origin in ONE call. `setContentSize` keeps the LEFT edge fixed, so
        // resizing and then recentring made the bubble visibly slide sideways every time the
        // live caption grew it 200 → 380. (#indicator-entrance-travel)
        setFrameIfNeeded(window, anchoredFrame(size: newFrameSize, screen: screen))
    }

    /// Where the panel belongs, for a given size: centred on the anchor and clamped to the screen.
    /// Notch mode pins the top edge (grows down); everything else pins the bottom (grows up).
    private func anchoredFrame(size: NSSize, screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame
        let x = max(screenFrame.minX, min(anchorCenterX - size.width / 2, screenFrame.maxX - size.width))
        let y = anchorFromTop
            ? max(screenFrame.minY, anchorTopY - size.height)
            : max(screenFrame.minY, min(anchorBottomY, screenFrame.maxY - size.height))
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Re-anchor the panel at its current size.
    private func reposition(window: NSWindow, screen: NSScreen) {
        setFrameIfNeeded(window, anchoredFrame(size: window.frame.size, screen: screen))
    }

    /// Non-animated frame set, skipped when the panel is already there (sub-pixel tolerance, so
    /// SwiftUI's fractional content sizes can't ping-pong the window through its resize
    /// notification). Never animated: an animated window resize re-enters layout on macOS 26
    /// and overflows the stack (#11/#15/#19).
    private func setFrameIfNeeded(_ window: NSWindow, _ target: NSRect) {
        let current = window.frame
        guard abs(current.origin.x - target.origin.x) > 0.5
            || abs(current.origin.y - target.origin.y) > 0.5
            || abs(current.width - target.width) > 0.5
            || abs(current.height - target.height) > 0.5
        else { return }
        window.setFrame(target, display: false)
    }

    /// Briefly shows the indicator at the configured position (without recording) so the user
    /// can see where it will appear. Used by the position picker's "Preview" button.
    func preview() {
        guard viewModel == nil else { return } // don't interfere with a live recording
        let vm = show(nearPoint: FocusUtils.getCurrentCursorPosition())
        vm.state = .recording
        vm.isBlinking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.hide()
        }
    }

    /// Briefly show a status message (error / info) WITHOUT recording. Used by the background
    /// `DictationPipeline` to surface a failure, "no speech", or the "copied — press ⌘V" notice now
    /// that transcription no longer runs in a live indicator. Skipped while a recording is in
    /// progress so it never interrupts the live recording bubble. The message auto-hides via the
    /// view model's own timer (showError/showInfo). (parallel-recording #3)
    func flash(_ state: RecordingState) {
        if let current = viewModel, current.state == .recording || current.state == .connecting {
            return
        }
        // Reuse a pill that's already on screen — typically the "Transcribing…" pill belonging
        // to the very clip this notice is about — instead of tearing it down for an identical
        // replacement. Skipped when it's already animating away; then this is a cold show.
        if let current = viewModel, hideTask == nil, window?.isVisible == true {
            apply(state, to: current)
            return
        }
        apply(state, to: show(nearPoint: FocusUtils.getCurrentCursorPosition()))
    }

    private func apply(_ state: RecordingState, to viewModel: IndicatorViewModel) {
        switch state {
        case .error(let message): viewModel.showError(message)
        case .info(let message): viewModel.showInfo(message)
        default: viewModel.showBusyMessage()
        }
    }

    func stopRecording() {
        viewModel?.startDecoding()
    }
    
    func stopForce() {
        viewModel?.cancelRecording()
        viewModel?.cleanup()
        hide()
    }

    /// A cancel request. Returns `true` when the recording was actually discarded;
    /// `false` when a long recording is now waiting for a confirming second press
    /// (see `IndicatorViewModel.handleCancelRequest`).
    @discardableResult
    func requestCancel() -> Bool {
        guard let viewModel else { return false }
        guard viewModel.handleCancelRequest() else { return false }
        stopForce()
        return true
    }

    func hide() {
        KeyboardShortcuts.disable(.cancelRecording)

        // Capture the view model this hide() belongs to NOW, not when the Task first
        // runs. If a new recording's show() slips in between this call and the Task
        // starting, resolving `self.viewModel` inside the Task would grab the NEW
        // recording's vm and tear it down instead. (#chord-double-fire)
        guard let viewModel = self.viewModel else { return }

        hideTask?.cancel()
        hideTask = Task {
            await viewModel.hideWithAnimation()
            viewModel.cleanup()

            // A new recording may have started during the hide animation (rapid re-record now
            // that recording is decoupled from transcription). If show() has since installed a
            // different view model — or aborted this hide outright — this teardown belongs to
            // the *previous* recording: don't clear the window/content out from under the new
            // one, or reset the hotkey state. (parallel-recording)
            guard !Task.isCancelled, self.viewModel === viewModel else { return }

            self.finishHide()
        }
    }

    /// Abort an exit animation still in flight and put the panel away immediately, skipping the
    /// rest of the animation. Called by `show()`: the panel must never be on screen while its
    /// frame moves to a new anchor. (#indicator-entrance-travel)
    private func cancelPendingHide() {
        guard hideTask != nil else { return }
        hideTask?.cancel()
        viewModel?.isVisible = false
        // The cancelled task still runs its own cleanup() after the animation resolves; doing
        // it here too just makes sure no timer outlives this call. cleanup() is idempotent.
        viewModel?.cleanup()
        finishHide()
    }

    /// The teardown half of `hide()`: drop the content, order out, and let the hotkey state know.
    private func finishHide() {
        hideTask = nil
        window?.contentView = nil
        window?.orderOut(nil)
        viewModel = nil

        NotificationCenter.default.post(name: .indicatorWindowDidHide, object: nil)
    }
    
    func didFinishDecoding() {
        hide()
    }
}
