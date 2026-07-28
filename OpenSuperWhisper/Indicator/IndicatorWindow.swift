import AVFoundation
import Cocoa
import Combine
import SwiftUI

enum RecordingState: Equatable {
    case idle
    case connecting
    case recording
    case decoding
    case busy
    case error(String)
    case info(String)
}

@MainActor
protocol IndicatorViewDelegate: AnyObject {
    
    func didFinishDecoding()
}

@MainActor
class IndicatorViewModel: ObservableObject {
    // Cancel confirmation: recordings at least this long ask for a second press of the
    // cancel key (within the window below) before being discarded, unless the user opted out.
    static let cancelConfirmationThreshold: TimeInterval = 10.0
    static let cancelConfirmationWindow: TimeInterval = 5.0

    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    @Published var isConfirmingCancel = false
    @Published var recorder: AudioRecorder = .shared
    @Published var isVisible = false
    /// Willow-style minimal presence (notch mode): shortly after recording starts, the full
    /// pill collapses to a small lock tab at the notch's right corner so it stops obstructing
    /// the window underneath. Expands again for anything that needs words (Esc-confirm).
    @Published var isNotchCollapsed = false

    var recordingStartedAt: Date?

    var delegate: IndicatorViewDelegate?
    private var blinkTimer: Timer?
    private var hideTimer: Timer?
    private var confirmCancelTimer: Timer?
    /// Catches a mic that never opens — see `armStartFailureWatchdog()`.
    private var startWatchdog: Timer?
    /// Drives the pill → lock-tab collapse a beat after recording starts (notch mode).
    private var collapseTimer: Timer?
    /// Keeps the "Transcribing…" pill up until the background pipeline drains.
    private var decodingWatcher: AnyCancellable?
    private var liveStreamingActive = false
    private var cancellables = Set<AnyCancellable>()
    
    private let recordingStore: RecordingStore
    private let transcriptionService: TranscriptionService
    private let transcriptionQueue: TranscriptionQueue
    
    init() {
        self.recordingStore = RecordingStore.shared
        self.transcriptionService = TranscriptionService.shared
        self.transcriptionQueue = TranscriptionQueue.shared
        
        recorder.$isConnecting
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnecting in
                guard let self = self else { return }
                if isConnecting {
                    self.state = .connecting
                    self.stopBlinking()
                }
            }
            .store(in: &cancellables)
        
        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self = self else { return }
                if isRecording {
                    self.state = .recording
                    self.startBlinking()
                }
            }
            .store(in: &cancellables)
    }
    
    var isTranscriptionBusy: Bool {
        transcriptionService.isTranscribing || transcriptionQueue.isProcessing
    }
    
    func showBusyMessage() {
        state = .busy

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.didFinishDecoding()
            }
        }
    }

    /// `startRecording()` flips to `.recording` optimistically and opens the mic in a
    /// detached task, so a failure there (permission denied, device taken by another app)
    /// never reaches the state machine: `AudioRecorder` just drops `isRecording` and
    /// `isConnecting` back to false, and the Combine bindings above only react to the
    /// *true* edge. The pill then sits in the notch reading "Recording…" forever.
    ///
    /// So: shortly after a start, if the recorder claims to be neither recording nor
    /// connecting while we still believe it is, treat it as a failed start. This is the
    /// `Listening → Error` transition SPEC.md §4 requires for mic failure.
    private func armStartFailureWatchdog() {
        startWatchdog?.invalidate()
        startWatchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard case .recording = self.state else { return }
                guard !self.recorder.isRecording, !self.recorder.isConnecting else { return }
                self.stopBlinking()
                self.showError("Microphone unavailable — check Privacy & Security ▸ Microphone")
            }
        }
    }

    func showError(_ message: String) {
        startWatchdog?.invalidate()
        startWatchdog = nil
        state = .error(message)

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.didFinishDecoding()
            }
        }
    }

    /// Brief, non-alarming notice (e.g. when there was no editable field to paste into).
    func showInfo(_ message: String) {
        state = .info(message)

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.didFinishDecoding()
            }
        }
    }
    
    func startRecording() {
        // No busy check: a previous dictation may still be transcribing in the background
        // (DictationPipeline). Recording is decoupled from transcription, so a new recording
        // can always start — that's the point of parallel recording. (parallel-recording)

        // No input device — surface it instead of optimistically showing "recording" and silently
        // capturing nothing (#157). `getActiveMicrophone()` reads the cached device, so this stays
        // off the blocking AVFoundation path that the hotkey tap must avoid (#freeze).
        guard MicrophoneService.shared.getActiveMicrophone() != nil else {
            showError("No microphone available")
            return
        }

        // Capture where the dictation is happening (frontmost app, browser site/URL,
        // window title) and apply any context-aware model rule before recording. This
        // runs AppleScript/Accessibility synchronously on the main thread; it's quick,
        // but see the note in RecordingContext.captureFrontmost. (F2/F3)
        RecordingContext.shared.captureFrontmost()
        ContextModelSwitcher.applyForCurrentContext()

        // Show recording immediately and optimistically. Whether the mic needs a
        // connection is decided off the main thread inside `recorder.startRecording()`
        // (it touches AVFoundation/CoreAudio, which can stall); the recorder then
        // publishes `isConnecting`/`isRecording` and the Combine bindings above
        // flip this to `.connecting` when needed. Querying it here would put that
        // blocking call on the main thread — and the hotkey tap runs there (#freeze).
        state = .recording
        startBlinking()
        recordingStartedAt = Date()

        Task.detached { [recorder] in
            recorder.startRecording()
        }
        armStartFailureWatchdog()

        // Notch mode: pop the full pill for a beat so the start is unmistakable, then
        // collapse to the minimal lock tab. Guarded on state so a recording that already
        // stopped (or errored) can't be collapsed retroactively.
        isNotchCollapsed = false
        if AppPreferences.shared.indicatorPosition == "notch" {
            collapseTimer?.invalidate()
            collapseTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, case .recording = self.state else { return }
                    self.isNotchCollapsed = true
                }
            }
        }

        // Live transcription (Parakeet only): stream in parallel with the WAV recorder so the
        // indicator can show the text as the user speaks. Falls back to the file pass on stop.
        // Skipped while ANY transcription is in flight — the background dictation pipeline OR the
        // file-drop `TranscriptionQueue` (`isTranscriptionBusy`) — since the live stream and that
        // pass would otherwise contend on the same engine. The file pass on stop still produces
        // the text; only the on-bubble preview is dropped for this clip. (parallel-recording review)
        if Self.shouldUseLiveStreaming && !DictationPipeline.shared.isProcessing && !isTranscriptionBusy {
            liveStreamingActive = true
            let terms = (AppPreferences.shared.customDictionaryEnabled && AppPreferences.shared.customDictionaryBoostEnabled)
                ? CustomDictionary.boostTerms(entries: AppPreferences.shared.customDictionaryEntries)
                : []
            Task { @MainActor in
                do {
                    try await StreamingTranscriptionController.shared.start(boostTerms: terms)
                } catch {
                    print("Live streaming start failed: \(error)")
                    self.liveStreamingActive = false
                }
            }
        }
    }

    /// Decides what a cancel request should do. Returns `true` when the recording
    /// should be discarded immediately; returns `false` (and arms a short confirmation
    /// window) when a long recording needs a confirming second press, so an accidental
    /// tap doesn't throw away a long dictation.
    func handleCancelRequest() -> Bool {
        guard state == .recording,
              // Nothing to press a second time when cancel is unbound — discard outright.
              ShortcutManager.cancelShortcutDescription != nil,
              !AppPreferences.shared.escCancelWithoutConfirmation,
              !isConfirmingCancel,
              let startedAt = recordingStartedAt,
              Date().timeIntervalSince(startedAt) >= Self.cancelConfirmationThreshold
        else {
            return true
        }

        isConfirmingCancel = true
        confirmCancelTimer?.invalidate()
        confirmCancelTimer = Timer.scheduledTimer(withTimeInterval: Self.cancelConfirmationWindow, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.resetCancelConfirmation()
            }
        }
        return false
    }

    private func resetCancelConfirmation() {
        confirmCancelTimer?.invalidate()
        confirmCancelTimer = nil
        isConfirmingCancel = false
    }

    static var shouldUseLiveStreaming: Bool {
        AppPreferences.shared.liveTranscriptionEnabled && AppPreferences.shared.selectedEngine == "fluidaudio"
    }

    /// Real duration of a saved audio file, in seconds (0 if it can't be read).
    nonisolated static func audioDuration(of url: URL) async -> TimeInterval {
        guard let seconds = try? await AVURLAsset(url: url).load(.duration) else { return 0 }
        let value = CMTimeGetSeconds(seconds)
        return value.isFinite ? value : 0
    }

    func startDecoding() {
        resetCancelConfirmation()
        stopBlinking()
        collapseTimer?.invalidate()
        collapseTimer = nil
        isNotchCollapsed = false

        // Grab the live-streaming preview text (if any) BEFORE cancelling the stream, then hand
        // off. A very short clip can come back empty from the offline file pass even when the
        // sliding-window preview caught it — the pipeline uses this as its fallback. (#short-dictation)
        var streamedFallback = ""
        if liveStreamingActive {
            liveStreamingActive = false
            streamedFallback = StreamingTranscriptionController.shared.liveCaption
            Task { await StreamingTranscriptionController.shared.cancel() }
        }

        guard let tempURL = recorder.stopRecording() else {
            print("!!! Not found record url !!!")
            delegate?.didFinishDecoding()
            return
        }

        // Snapshot the record-start context AND the active model now (both still belong to THIS
        // recording — the next recording's captureFrontmost / model switch hasn't run yet) so the
        // history row and the transcription model stay accurate even though the clip is transcribed
        // later, in the background. (parallel-recording, #model-snapshot)
        let ctx = RecordingContext.shared
        let snapshot = DictationPipeline.ContextSnapshot(
            appName: ctx.appName, windowTitle: ctx.windowTitle, fullURL: ctx.fullURL)
        let modelOption = ModelCatalog.activeOption()

        // Hand the clip to the background pipeline: it transcribes, saves and pastes on a serial
        // queue in recording-start order, so the user can immediately start the next recording
        // instead of waiting for this one to finish. (parallel-recording)
        DictationPipeline.shared.enqueue(
            tempURL: tempURL,
            startedAt: recordingStartedAt ?? Date(),
            streamedFallback: streamedFallback,
            context: snapshot,
            modelOption: modelOption)

        // Stay up as "Transcribing…" instead of vanishing into dead air until the text pastes.
        // The pill hides when the pipeline goes quiet (below); a hotkey press before then
        // re-arms this same pill for a new recording (`prepareForReuse`) and leaves the
        // in-flight transcription alone — it lives in DictationPipeline, not here.
        state = .decoding
        watchPipelineUntilIdle()
    }

    /// Hides the pill once the background pipeline has drained: `pendingCount == 0 &&
    /// !isProcessing`, so a backlog of several clips keeps showing "Transcribing…" until the
    /// last one lands. Guarded on `.decoding` — an error/info flash that took over the pill
    /// owns its own auto-hide timer, and a re-armed recording must not be torn down.
    private func watchPipelineUntilIdle() {
        let pipeline = DictationPipeline.shared
        decodingWatcher = pipeline.$pendingCount
            .combineLatest(pipeline.$isProcessing)
            .receive(on: RunLoop.main)
            .sink { [weak self] pending, isProcessing in
                guard let self, case .decoding = self.state else { return }
                guard pending == 0, !isProcessing else { return }
                self.decodingWatcher = nil
                self.delegate?.didFinishDecoding()
            }
    }

    /// Re-arm this pill for a fresh recording without tearing the window down, so a hotkey
    /// press during "Transcribing…" starts recording instantly in the SAME pill — no second
    /// window, no replayed entrance animation.
    func prepareForReuse() {
        decodingWatcher = nil
        hideTimer?.invalidate()
        hideTimer = nil
        resetCancelConfirmation()
        isNotchCollapsed = false
    }

    static func applyPostProcessing(_ text: String) -> String {
        guard AppPreferences.shared.addSpaceAfterSentence else { return text }
        // Some models emit run-on sentences with no space after the period ("regularly.Using" — #107).
        // Insert one when a lowercase word-end is immediately followed by sentence punctuation and an
        // uppercase letter; the lowercase/uppercase guard leaves decimals (3.14) and acronyms (U.S.A) alone.
        var result = text.replacingOccurrences(
            of: "([a-z])([.!?])([A-Z])",
            with: "$1$2 $3",
            options: .regularExpression)
        // Trailing space after a finished sentence so the next dictation doesn't run into it.
        if let lastChar = result.last, lastChar.isPunctuation {
            result += " "
        }
        return result
    }
    
    private func startBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            // Update UI on the main thread
            Task { @MainActor in
                guard let self = self else { return }
                self.isBlinking.toggle()
            }
        }
    }
    
    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
    }

    func cleanup() {
        stopBlinking()
        resetCancelConfirmation()
        recordingStartedAt = nil
        decodingWatcher = nil
        hideTimer?.invalidate()
        hideTimer = nil
        startWatchdog?.invalidate()
        startWatchdog = nil
        collapseTimer?.invalidate()
        collapseTimer = nil
        cancellables.removeAll()
    }

    func cancelRecording() {
        hideTimer?.invalidate()
        hideTimer = nil
        startWatchdog?.invalidate()
        startWatchdog = nil
        collapseTimer?.invalidate()
        collapseTimer = nil
        recorder.cancelRecording()
        if liveStreamingActive {
            liveStreamingActive = false
            Task { await StreamingTranscriptionController.shared.cancel() }
        }
    }

    @MainActor
    func hideWithAnimation() async {
        await withCheckedContinuation { continuation in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                self.isVisible = false
            } completion: {
                continuation.resume()
            }
        }
    }
}

/// The Osier mark, standing in for what used to be a blinking red dot.
///
/// The dot pulsed on a timer to say "still listening"; the mark says it by rippling its voice
/// strand instead, which is both calmer and more specific — a *voice* running through the weave
/// rather than a generic recording light. `viewModel.isBlinking` still drives the state machine's
/// other consumers and is simply no longer needed here.
struct RecordingIndicator: View {
    var state: SpeakingStrand.State = .recording
    /// The notch pill is black in every appearance, so the ring needs the brighter green there.
    var onDark: Bool

    var body: some View {
        SpeakingStrand(state: state,
                       ring: onDark ? Osier.newGrowth : Osier.mark,
                       strand: onDark ? Osier.newGrowth : Osier.mark)
    }
}

/// How long the current recording has been running, in mono digits so the pill doesn't twitch
/// as the numbers change width.
///
/// Ticks off a `TimelineView` rather than a `Timer`, so it costs nothing when the pill isn't on
/// screen and there is no timer to remember to invalidate.
///
/// In notch mode this is only visible while the pill is expanded: a second into recording the
/// pill deliberately collapses to the lock tab (`isNotchCollapsed`), and that minimal-presence
/// behaviour is untouched here.
struct ElapsedTime: View {
    let startedAt: Date
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(startedAt)))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(color)
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A thin bar that drains left-to-right over the confirmation window, showing how long the
/// "press Esc again to cancel" prompt stays armed. Straw-gold rather than a system orange —
/// a caution, and inside the palette.
struct CancelConfirmationBar: View {
    @State private var progress: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Osier.caution)
                .frame(width: geo.size.width * progress, height: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 2)
        .padding(.horizontal, 12)
        .padding(.bottom, 3)
        .onAppear {
            withAnimation(.linear(duration: IndicatorViewModel.cancelConfirmationWindow)) {
                progress = 0
            }
        }
    }
}

/// Pointing-hand cursor while hovering (macOS 14 predates SwiftUI's .pointerStyle).
/// Pops on disappear too, so the cursor never sticks when the bubble goes away
/// mid-hover (e.g. after clicking Stop).
private struct PointerCursorModifier: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
    }
}

extension View {
    func pointerCursorOnHover() -> some View { modifier(PointerCursorModifier()) }
}

/// Clips the bubble to its own silhouette — or not at all, when `shape` is nil (notch mode,
/// where the morphing lock tab must be free to draw outside the pill's content box).
private struct BubbleClip: ViewModifier {
    let shape: AnyShape?

    func body(content: Content) -> some View {
        if let shape {
            content.clipShape(shape)
        } else {
            content
        }
    }
}

/// Clips at the view's *top edge only*, so the notch pill can slide down out of the notch:
/// whatever is still "inside" the bezel simply isn't drawn. The other three sides are pushed
/// well past the bounds (negative padding grows the rectangle) so the settled pill's shadow is
/// never clipped. Render-only — no window is moved or resized (#notch-too-tall).
///
/// Applied only in notch mode: the other positions rise from below and their bubble uses a
/// blur material, which is best left out of an extra compositing layer.
private struct TopEdgeRevealMask: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.mask {
                Rectangle()
                    .padding(EdgeInsets(top: 0, leading: -80, bottom: -240, trailing: -80))
            }
        } else {
            content
        }
    }
}

/// Reports the indicator bubble's laid-out size (before the entrance render transforms) so the
/// window manager can size the panel itself — see the note on `.onPreferenceChange` below.
private struct IndicatorContentSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct IndicatorWindow: View {
    @ObservedObject var viewModel: IndicatorViewModel
    /// Called whenever the bubble's intrinsic size changes. The manager resizes the hosting
    /// window to match, *non-animated* (see `.onPreferenceChange` below for why).
    var onContentResize: (CGSize) -> Void = { _ in }
    @ObservedObject private var streaming = StreamingTranscriptionController.shared
    @ObservedObject private var notch = NotchTuning.shared
    // Surfaces how many earlier clips are still transcribing in the background, so starting a new
    // recording while others are queued shows the backlog. (parallel-recording #3)
    @ObservedObject private var pipeline = DictationPipeline.shared
    @Environment(\.colorScheme) private var colorScheme
    
    /// Tint over the blur material used by the floating (non-notch) bubble. Wicker cream on
    /// light, deep warm gray on dark — kept translucent so the material still reads as glass.
    ///
    /// The notch pill does not use this: it stays pure black so it reads as the physical bezel
    /// continuing downward, which is the whole illusion the notch layout is built on.
    private var backgroundColor: Color {
        Osier.surface.opacity(colorScheme == .dark ? 0.42 : 0.55)
    }

    // Text tones.
    //
    // The notch pill is black under *both* appearances, so it can't use the appearance-reactive
    // ink tokens — on a light system appearance those resolve to dark willow green and would
    // disappear against the black. The `onNotch` tones are fixed light values for exactly that
    // case; everywhere else follows the system appearance as normal.
    private var ink: Color { isNotchMode ? Osier.onNotch : Osier.ink }
    private var inkSoft: Color { isNotchMode ? Osier.onNotchSoft : Osier.inkSoft }
    private var inkFaint: Color { isNotchMode ? Osier.onNotchFaint : Osier.inkFaint }

    /// Wider while live-recording so the growing caption fits inside the bubble; compact otherwise.
    /// Extra width for any enabled on-bubble buttons (Spacer 8 + a 24pt control each) so
    /// they never squeeze the "Recording…" label or the live caption — applies to every
    /// layout, including the notch pill (its base width has no room to spare).
    private var buttonExtraWidth: CGFloat {
        guard viewModel.state == .recording else { return 0 }
        var extra: CGFloat = 0
        if AppPreferences.shared.showStopButtonOnIndicator { extra += 32 }
        if AppPreferences.shared.showCancelButtonOnIndicator { extra += 32 }
        return extra
    }

    private var bubbleWidth: CGFloat {
        if isNotchMode {
            // Idle width is tunable; it only expands once there is actual caption text to show.
            let hasCaption = !streaming.confirmedText.isEmpty || !streaming.volatileText.isEmpty
            return (hasCaption ? max(notch.width, 440) : notch.width) + buttonExtraWidth
        }
        // Live mode starts compact too — the pill only widens once caption text actually
        // arrives (same rule as notch mode). Starting at 380 made the bubble appear at
        // its "final" size the moment recording began.
        let live = viewModel.state == .recording && IndicatorViewModel.shouldUseLiveStreaming
        let hasCaption = !streaming.confirmedText.isEmpty || !streaming.volatileText.isEmpty
        let base: CGFloat = (live && hasCaption) ? 380 : 200
        return base + buttonExtraWidth
    }
    
    private var isNotchMode: Bool { AppPreferences.shared.indicatorPosition == "notch" }

    /// How far the notch pill starts above its resting place — its full height plus a hair, so
    /// it begins completely hidden behind the mask (i.e. "inside" the notch) and slides down
    /// into view. The window itself never moves; this is a render-only offset.
    private var notchEntranceTravel: CGFloat { CGFloat(notch.height) + 8 }

    /// Willow-style minimal presence: after the initial pop, the recording pill collapses to a
    /// small lock tab at the notch's right corner and everything else goes transparent (the
    /// window itself keeps its size — it's click-through, so only the drawn tab is visible).
    /// Stays expanded whenever the pill has something to *say*: Esc-cancel confirmation, a live
    /// caption, or tappable on-bubble buttons.
    private var isCollapsedTab: Bool {
        isNotchMode
            && viewModel.state == .recording
            && viewModel.isNotchCollapsed
            && !viewModel.isConfirmingCancel
            && streaming.confirmedText.isEmpty && streaming.volatileText.isEmpty
            && !anyIndicatorButton
    }

    /// Collapsed lock-tab geometry.
    private var lockTabWidth: CGFloat { 34 }
    private var lockTabHeight: CGFloat { CGFloat(notch.topInset) + 16 }

    /// The pill's black silhouette, plus the lock tab that replaces it.
    ///
    /// Everything here moves **vertically only**. Interpolating the pill's width down to the
    /// tab's looks like a bar sliding across to the right corner — wrong instinct for a notch,
    /// which should only ever swallow things upward and let them back down. So the full pill
    /// keeps its width and simply retracts into the notch, and the tab drops out of the notch's
    /// right corner behind it. The mask on the whole bubble (`TopEdgeRevealMask`) is what makes
    /// "retracts into the notch" read literally: anything above the top edge isn't drawn.
    @ViewBuilder private var notchBackground: some View {
        ZStack(alignment: .topTrailing) {
            NotchShape(topRadius: notch.topRadius, bottomRadius: notch.bottomRadius)
                .fill(.black)
                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 3)
                .offset(y: isCollapsedTab ? -notchEntranceTravel : 0)

            lockTab
                // Starts tucked fully behind the bezel, so it descends rather than fades in.
                .offset(y: isCollapsedTab ? 0 : -lockTabHeight)
                // A beat behind the pill, so the two don't cross mid-air.
                .animation(.spring(response: 0.34, dampingFraction: 0.86)
                    .delay(isCollapsedTab ? 0.12 : 0), value: isCollapsedTab)
        }
    }

    /// A mini notch-shaped tab hugging the notch's lower-right corner, carrying the mark to say
    /// "still listening". The glyph lives inside the tab (not in a separate overlay) so it can't
    /// drift out of step with the shape it belongs to.
    ///
    /// This is the app's most-seen pixel — for most of a dictation it is the *only* thing on
    /// screen. It used to be a red padlock blinking on a timer, which read as a security warning
    /// rather than as recording. Now it's the mark with its voice strand in rust, rippling: the
    /// same "still live" signal, in the brand's own language.
    @ViewBuilder private var lockTab: some View {
        ZStack(alignment: .bottom) {
            NotchShape(topRadius: 6, bottomRadius: 9)
                .fill(.black)
                .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 2)
            RecordingIndicator(onDark: true)
                .frame(width: 13, height: 13)
                .padding(.bottom, 3)
        }
        .frame(width: lockTabWidth, height: lockTabHeight)
        // Tuck the tab's right edge under the notch body's right corner (the outer `topRadius`
        // band is the concave wing of the full pill's silhouette).
        .padding(.trailing, CGFloat(notch.topRadius))
    }

    /// Opt-in on-bubble controls (default off). Shown on the trailing side while
    /// recording. Stop = stop & transcribe (same as the hotkey toggle); Cancel =
    /// discard (same as the Esc cancel shortcut). Fixed-size, so they don't couple
    /// the bubble's size to the window (see the recursion-crash note above).
    private var anyIndicatorButton: Bool {
        AppPreferences.shared.showStopButtonOnIndicator
            || AppPreferences.shared.showCancelButtonOnIndicator
    }

    @ViewBuilder private var indicatorControls: some View {
        HStack(spacing: 8) {
            if AppPreferences.shared.showStopButtonOnIndicator {
                Button { IndicatorWindowManager.shared.stopRecording() } label: {
                    // Stop is the one control that acts *on the recording*, so it carries the
                    // recording colour. The only rust in the pill besides the voice strand.
                    Image(systemName: "stop.circle")
                        .font(.system(size: 19, weight: .regular))
                        .foregroundColor(Osier.recording)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursorOnHover()
                .help("Finish recording")
            }
            if AppPreferences.shared.showCancelButtonOnIndicator {
                Button { IndicatorWindowManager.shared.stopForce() } label: {
                    // Discard without transcribing. Quiet rather than alarming — the confirm
                    // step is what guards a long dictation, not a loud button.
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(inkSoft)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursorOnHover()
                .help("Cancel recording")
            }
        }
    }

    var body: some View {

        // Notch mode uses the real notch silhouette (concave top wings + rounded bottom).
        let rect: AnyShape = isNotchMode
            ? AnyShape(NotchShape(topRadius: notch.topRadius, bottomRadius: notch.bottomRadius))
            : AnyShape(RoundedRectangle(cornerRadius: 24))

        VStack(spacing: 12) {
            switch viewModel.state {
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 24)
                    
                    Text("Connecting...")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(inkSoft)
                }
            case .recording:
                // No collapsed branch here: collapsing is a morph, not a swap. The dot/label
                // stay in place and cross-fade out (`.opacity` below) while the silhouette
                // shrinks around the lock-tab overlay.
                if streaming.confirmedText.isEmpty && streaming.volatileText.isEmpty {
                    // Before any text arrives, just the mark + label, vertically centered.
                    HStack(alignment: .center, spacing: 10) {
                        RecordingIndicator(onDark: isNotchMode)
                            .frame(width: 16)
                        if viewModel.isConfirmingCancel, let cancelKey = ShortcutManager.cancelShortcutDescription {
                            // Names the *bound* key — cancel is unbound by default, and this
                            // branch is unreachable then (nothing can arm the confirmation).
                            Text("Press \(cancelKey) to cancel")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Osier.caution)
                                .transition(.opacity)
                        } else if isNotchMode {
                            // Notch mode stays minimal on purpose: the mark IS the "it's
                            // listening" signal, so the pill can sit tight against the notch
                            // instead of announcing itself in prose. Text only appears when the
                            // mark can't say it — i.e. a transcription backlog.
                            if pipeline.pendingCount > 0 {
                                Text("\(pipeline.pendingCount) queued")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(inkSoft)
                                    .transition(.opacity)
                            }
                        } else {
                            Text(pipeline.pendingCount > 0 ? "Recording… · \(pipeline.pendingCount) queued" : "Recording…")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(inkSoft)
                                .transition(.opacity)
                        }
                        if let startedAt = viewModel.recordingStartedAt, !viewModel.isConfirmingCancel {
                            ElapsedTime(startedAt: startedAt, color: inkFaint)
                        }
                        if anyIndicatorButton {
                            Spacer(minLength: 8)
                            indicatorControls
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: viewModel.isConfirmingCancel)
                } else {
                    // Once text starts, drop the label: just the mark + the text, which grows
                    // (the window resizes to fit it) so everything stays visible.
                    // Center-aligned: with the (taller) on-bubble buttons enabled, .top
                    // alignment pinned a single caption line above the vertical middle.
                    //
                    // The caption is the user's own words, so it's set in serif — the brand's
                    // one typographic rule, and the same treatment history rows get.
                    HStack(alignment: .center, spacing: 10) {
                        RecordingIndicator(onDark: isNotchMode)
                            .frame(width: 16)
                        (Text(streaming.confirmedText).foregroundColor(ink)
                            + Text(streaming.confirmedText.isEmpty ? "" : " ")
                            + Text(streaming.volatileText).foregroundColor(inkFaint))
                            .font(.system(size: 14))
                            .transcriptType()
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 300, alignment: .leading)
                        if anyIndicatorButton {
                            Spacer(minLength: 8)
                            indicatorControls
                        }
                    }
                }

            case .decoding:
                // The mark carries on rippling — in green, not rust: the app is working on the
                // audio but is no longer listening, and that distinction is exactly what rust
                // being reserved for recording is there to communicate.
                // Same 16pt footprint as the spinner it replaces, so the bubble keeps its height.
                HStack(spacing: 8) {
                    RecordingIndicator(state: .transcribing, onDark: isNotchMode)
                        .frame(width: 16, height: 16)
                        .frame(width: 24)

                    Text("Transcribing...")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(inkSoft)
                }
            case .busy:
                HStack(spacing: 8) {
                    Image(systemName: "hourglass")
                        .foregroundColor(Osier.caution)
                        .frame(width: 24)

                    Text("Processing...")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Osier.caution)
                }
            case .error(let message):
                // No red alarm and no warning triangle: the mark's strand becomes a small
                // exclamation while the ring stays green. A failed dictation is worth saying
                // plainly, not worth shouting.
                HStack(spacing: 8) {
                    RecordingIndicator(state: .error, onDark: isNotchMode)
                        .frame(width: 16, height: 16)
                        .frame(width: 24)

                    Text(message)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isNotchMode ? Osier.onNotch : Osier.error)
                }
            case .info(let message):
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundColor(isNotchMode ? Osier.newGrowth : Osier.mark)
                        .frame(width: 24)

                    Text(message)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(ink)
                }
            case .idle:
                EmptyView()
            }
        }
        // Rides up with the pill it sits in — same offset, so the dot and label leave as part
        // of the pill rather than fading out on their own. The layout underneath never changes.
        .offset(y: isCollapsedTab ? -notchEntranceTravel : 0)
        .padding(.horizontal, isNotchMode ? 22 : 24)
        // Notch mode hugs the bezel: minimal vertical padding so the dot/labels sit *right*
        // below the notch instead of in a deep bar (#notch-too-tall).
        .padding(.vertical, isNotchMode ? 4 : 12)
        // Push the content below the physical notch: the pill's top `topInset` points sit
        // behind the bezel (the window is flush with the screen top — see NotchPanel), so
        // without this the dot/labels would be centred *inside* the notch band, invisible.
        // 0 outside notch mode and on screens without a physical notch. (#notch-exact-fit)
        .padding(.top, isNotchMode ? notch.topInset : 0)
        // Width must be set *before* the background so the bubble itself fills it (not just the
        // surrounding frame). Notch content is centred; the others stay leading.
        .frame(minHeight: isNotchMode ? notch.height : 36)
        .frame(width: bubbleWidth, alignment: isNotchMode ? .center : .leading)
        // Width changes snap, never animate. The pill widens when live-caption text arrives —
        // and that same moment un-collapses the tab, so without this the width change gets
        // swept up in the collapse animation below and the pill visibly stretches sideways.
        .animation(nil, value: bubbleWidth)
        .background {
            if isNotchMode {
                notchBackground
            } else {
                rect
                    .fill(backgroundColor)
                    .background {
                        rect
                            .fill(Material.thinMaterial)
                    }
                    // Hairline in straw, so the floating bubble has a woven edge rather than
                    // dissolving into whatever is behind it.
                    .overlay(rect.stroke(Osier.hairline.opacity(0.55), lineWidth: 1))
                    .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
            }
        }
        .overlay(alignment: .bottom) {
            if viewModel.isConfirmingCancel {
                CancelConfirmationBar()
            }
        }
        // Notch mode draws its silhouette in the background layer above (which morphs), so it
        // must not be clipped at all: the full pill's shape would shave the lock tab's rounded
        // corner, and even a plain bounds clip would cut the tab off, since the tab is allowed
        // to hang lower than the pill's own content box (`lockTabHeight` vs `notch.height`).
        .modifier(BubbleClip(shape: isNotchMode ? nil : rect))
        // Ease the pill → lock-tab morph: the silhouette's frame and corner radii, plus the
        // dot ⇄ lock cross-fade, all interpolate under this one animation. Content-level only;
        // the window resize itself is deliberately non-animated — see the recursion note below.
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: isCollapsedTab)
        // Measure the bubble here, *before* the entrance transforms below, so the reported size is
        // the real layout size (scaleEffect/offset are render-only and don't affect this).
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: IndicatorContentSizeKey.self, value: proxy.size)
            }
        )
        .environment(\.colorScheme, isNotchMode ? .dark : colorScheme)
        // Entrance. Notch mode slides straight down *out of* the notch: the pill starts fully
        // tucked above its own top edge and translates into view, no scaling and no fade — the
        // mask below is what makes it a reveal rather than a floating pill. The other positions
        // keep the existing pop (scale + rise + fade from below).
        .scaleEffect(isNotchMode ? 1 : (viewModel.isVisible ? 1 : 0.5), anchor: .center)
        .offset(y: viewModel.isVisible ? 0 : (isNotchMode ? -notchEntranceTravel : 20))
        .opacity(isNotchMode ? 1 : (viewModel.isVisible ? 1 : 0))
        .modifier(TopEdgeRevealMask(active: isNotchMode))
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: viewModel.isVisible)
        // The hosting window is sized by the manager from this preference (NOT by SwiftUI's
        // `.preferredContentSize` auto-resize). That auto-resize runs *animated* whenever any
        // SwiftUI animation transaction is active during a layout pass (NSHostingView
        // .updateAnimatedWindowSize), and on macOS 26 the animated resize re-enters layout and
        // recurses until the main-thread stack overflows — the crash in #11/#15/#19. Driving the
        // size ourselves, non-animated, makes that recursion impossible, so the entrance spring
        // and the blinking dot above are free to animate without risk.
        .onPreferenceChange(IndicatorContentSizeKey.self) { size in
            onContentResize(size)
        }
        .onAppear {
            viewModel.isVisible = true
        }
        // The hosting window can be larger than the drawn bubble (notch mode uses a fixed
        // oversized canvas because the content-size feedback loop is unreliable — see
        // IndicatorWindowManager.show, #notch-too-tall). Pin the bubble to the canvas edge
        // that the window anchors: top for the notch (flush with the bezel), bottom for the
        // caret-anchored modes (grows upward). With a correctly sized window this is a no-op.
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: isNotchMode ? .top : .bottom)
    }
}

struct IndicatorWindowPreview: View {
    @StateObject private var recordingVM = {
        let vm = IndicatorViewModel()
//        vm.startRecording()
        return vm
    }()
    
    @StateObject private var decodingVM = {
        let vm = IndicatorViewModel()
        vm.startDecoding()
        return vm
    }()
    
    var body: some View {
        VStack(spacing: 20) {
            IndicatorWindow(viewModel: recordingVM)
            IndicatorWindow(viewModel: decodingVM)
        }
        .padding()
        .frame(height: 200)
        .background(Color(.windowBackgroundColor))
    }
}

#Preview {
    IndicatorWindowPreview()
}
