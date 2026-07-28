import AppKit
import SwiftUI

/// The Osier mark — the "speaking strand".
///
/// A circular woven O: three willow strands that weave over and under each other into a ring,
/// with one horizontal strand crossing the middle that is a small speech waveform. The ring is
/// the basket; the waveform is the voice running through it.
///
/// One parametric source renders every size and state — 16pt in the menu bar, 22pt in the notch
/// pill, 1024pt for the app icon — so there is nothing baked except the generated `.icns`.
///
/// **The weave is real geometry, not a drawn trick.** Each strand's radius oscillates around the
/// ring (`r(θ) = R + A·sin(kθ + offset)`), and the three strands are offset in phase, so they
/// genuinely cross one another. Over-under comes from punching each strand's casing out of what
/// was already drawn (`.destinationOut`) before stroking it — which means the weave holds on any
/// background, black notch or cream window, with no background colour passed in.
///
/// Colour rule: the ring is *always* green. Only the middle strand changes — rust while
/// recording, and nowhere else in the app is rust used at all. See `Osier`.
struct SpeakingStrand: View {

    enum State: Equatable {
        /// At rest. Everything green, the middle strand nearly flat.
        case idle
        /// Capturing audio. The middle strand turns rust and ripples.
        case recording
        /// Working on the audio. A slow green ripple — busy, but not listening.
        case transcribing
        /// Capture held. The strand freezes mid-ripple and a pause glyph sits over it.
        ///
        /// The app has no pause feature today (`RecordingState` has no such case). This is
        /// rendered and ready so that wiring one is a state mapping, not a design problem.
        case paused
        /// Something went wrong. The middle strand becomes a small exclamation. The ring stays
        /// green — no red alarm styling. An error should read as calm, not as a klaxon.
        case error
    }

    var state: State = .idle
    /// Ring colour. Green in every state; the caller varies it only for contrast against its
    /// own background (e.g. `newGrowth` on the black notch pill).
    var ring: Color = Osier.mark
    /// Middle-strand colour when *not* recording. Recording always forces `Osier.recording`.
    var strand: Color = Osier.mark

    /// Cycles per second of the waveform ripple. Slow on purpose — this is a calm app.
    private var rippleRate: Double {
        switch state {
        case .recording: return 0.85
        case .transcribing: return 0.4
        default: return 0
        }
    }

    var body: some View {
        if rippleRate > 0 {
            // Per-frame redraw only while there is something to animate. The mark always sits
            // in a fixed frame, so this can never feed a size change back into the layout —
            // which matters on the notch pill, where an animated resize once recursed into a
            // stack overflow (see the note in IndicatorWindow.body).
            TimelineView(.animation) { timeline in
                canvas(phase: timeline.date.timeIntervalSinceReferenceDate * rippleRate * 2 * .pi)
            }
        } else {
            // Frozen mid-stride rather than at zero, so a paused or idle mark still looks like
            // a woven object caught at rest instead of a flat diagram.
            canvas(phase: state == .paused ? 1.9 : 0)
        }
    }

    private func canvas(phase: Double) -> some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            // Everything below is expressed as a fraction of `side`, which is what lets the
            // same code carry from a 16pt menu-bar glyph to a 1024pt icon.
            //
            // The weave only reads if the strands travel further radially than they are thick —
            // otherwise three near-identical circles merge into one lumpy ring. Hence depth
            // comfortably exceeding weight.
            let weight = side * 0.062          // strand thickness
            let casing = weight * 2.0          // punched gap that reads as "under"
            let weaveDepth = side * 0.078      // how far each strand wanders radially
            let radius = side * 0.5 - weaveDepth - weight * 0.5 - side * 0.012

            let strandColor: Color = state == .recording ? Osier.recording : strand

            // MARK: Middle strand — the voice
            //
            // Drawn *first*, so the ring's casing punches cut through it and it reads as running
            // under the weave and out the far side, rather than sitting on top of the ring like a
            // cancellation bar. Its ends are tucked under the ring band for the same reason.

            if state != .error {
                // Reaches the outer extreme of the ring band, so both ends finish *underneath*
                // woven strand rather than stopping bluntly in one of the weave's gaps.
                let wave = waveform(center: center, span: radius + weaveDepth * 0.95,
                                    phase: phase, height: Double(side) * amplitude)
                context.stroke(wave, with: .color(strandColor),
                               style: StrokeStyle(lineWidth: weight, lineCap: .round,
                                                  lineJoin: .round))
            }

            // MARK: Ring — three strands, plaited

            drawPlaitedRing(in: &context, center: center, radius: radius, depth: weaveDepth,
                            weight: weight, casing: casing, color: ring)

            // MARK: State glyphs — inside the ring, on top of everything

            if state == .error {
                drawExclamation(in: &context, center: center, side: side,
                                weight: weight, casing: casing, color: strandColor)
            } else if state == .paused {
                drawPauseGlyph(in: &context, center: center, side: side,
                               weight: weight, casing: casing, color: strandColor)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Vertical reach of the waveform, as a fraction of the mark's size. Idle is close to flat —
    /// a strand at rest, not a silent microphone.
    private var amplitude: Double {
        switch state {
        case .idle: return 0.045
        case .recording: return 0.135
        case .transcribing: return 0.075
        case .paused: return 0.105
        case .error: return 0
        }
    }

    // MARK: - Geometry

    /// Number of strands in the plait, and how many times they cross on the way round.
    ///
    /// Five crossings keeps each over-under large enough to survive at menu-bar size; more turns
    /// the ring into a gear, fewer makes the silhouette go polygonal.
    private static let strandCount = 3
    private static let weaves = 5.0

    /// Radius of strand `index` at angle `θ`. The three strands are evenly offset in phase, so at
    /// any point around the ring one is swinging outward while another swings in — which is what
    /// a plait actually is.
    private static func strandRadius(_ angle: Double, index: Int,
                                     radius: CGFloat, depth: CGFloat) -> Double {
        let offset = Double(index) * 2 * .pi / Double(strandCount)
        return Double(radius) + Double(depth) * sin(weaves * angle + offset)
    }

    /// Draws the plaited ring with **physically correct over-under**.
    ///
    /// Two passes, and the split matters:
    ///
    /// 1. **Base** — all three strands as continuous closed loops. Nothing is erased, so every
    ///    strand stays unbroken all the way round.
    /// 2. **Weave** — the ring is divided into the contiguous arcs over which one strand is the
    ///    outermost, and each of those arcs is punched clear and re-stroked. The punch separates
    ///    the outer strand from the ones beneath it with a clean gap, which is what the eye reads
    ///    as over-and-under.
    ///
    /// Doing the punching *per contiguous arc* rather than per small segment is the whole trick: a
    /// per-segment punch erases the neighbouring segment of the same strand a moment after drawing
    /// it, and the ring shatters into confetti. There are only `weaves × strandCount` crossings, so
    /// the arcs are long and the strands stay whole between them.
    private func drawPlaitedRing(in context: inout GraphicsContext, center: CGPoint,
                                 radius: CGFloat, depth: CGFloat, weight: CGFloat,
                                 casing: CGFloat, color: Color) {
        let stroke = StrokeStyle(lineWidth: weight, lineCap: .round)

        // Pass 1 — continuous strands.
        for index in 0 ..< Self.strandCount {
            context.stroke(strandArc(center: center, from: 0, to: 2 * .pi, index: index,
                                     radius: radius, depth: depth, steps: 200),
                           with: .color(color), style: stroke)
        }

        // Pass 2 — lift the outermost strand at each crossing.
        // A little overhang past each crossing so the gap clears the strand underneath rather
        // than stopping exactly on it.
        let overhang = 2 * Double.pi / (Self.weaves * Double(Self.strandCount)) * 0.16

        for (index, start, end) in outermostArcs(radius: radius, depth: depth) {
            let arc = strandArc(center: center, from: start - overhang, to: end + overhang,
                                index: index, radius: radius, depth: depth)

            context.blendMode = .destinationOut
            context.stroke(arc, with: .color(.black),
                           style: StrokeStyle(lineWidth: casing, lineCap: .round))
            context.blendMode = .normal
            context.stroke(arc, with: .color(color), style: stroke)
        }
    }

    /// Walks the ring and returns the contiguous angular runs over which each strand is the
    /// outermost — one entry per crossing, in order.
    private func outermostArcs(radius: CGFloat, depth: CGFloat) -> [(Int, Double, Double)] {
        let samples = 360

        func outermost(at angle: Double) -> Int {
            (0 ..< Self.strandCount).max {
                Self.strandRadius(angle, index: $0, radius: radius, depth: depth)
                    < Self.strandRadius(angle, index: $1, radius: radius, depth: depth)
            } ?? 0
        }

        var arcs: [(Int, Double, Double)] = []
        var current = outermost(at: 0)
        var start = 0.0

        for sample in 1 ... samples {
            let angle = Double(sample) / Double(samples) * 2 * .pi
            let winner = outermost(at: angle)
            if winner != current {
                arcs.append((current, start, angle))
                current = winner
                start = angle
            }
        }
        arcs.append((current, start, 2 * .pi))
        return arcs
    }

    /// One arc of a single strand, between two angles.
    private func strandArc(center: CGPoint, from: Double, to: Double, index: Int,
                           radius: CGFloat, depth: CGFloat, steps: Int = 24) -> Path {
        var path = Path()
        for step in 0 ... steps {
            let angle = from + (to - from) * Double(step) / Double(steps)
            let r = Self.strandRadius(angle, index: index, radius: radius, depth: depth)
            let point = CGPoint(x: Double(center.x) + r * cos(angle),
                                y: Double(center.y) + r * sin(angle))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// The speech waveform: irregular, never symmetric bars.
    ///
    /// Three sine components at deliberately incommensurate frequencies sum into something that
    /// never visibly repeats, tapered by an envelope so the strand settles flat where it meets
    /// the ring instead of being chopped off mid-peak.
    private func waveform(center: CGPoint, span: CGFloat,
                          phase: Double, height: Double) -> Path {
        let steps = 160
        var path = Path()

        for step in 0 ... steps {
            let t = Double(step) / Double(steps)          // 0…1 across the strand
            let x = center.x - span + CGFloat(t) * span * 2

            // Taper to nothing at both ends.
            let envelope = pow(sin(t * .pi), 0.65)

            let wave = 0.62 * sin(t * 12.9 + phase)
                     + 0.28 * sin(t * 21.7 + phase * 1.6 + 2.1)
                     + 0.19 * sin(t * 34.3 + phase * 0.7 + 4.2)

            let y = center.y - CGFloat(wave * envelope * height)
            if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    /// Error: a short exclamation in place of the waveform. Ring untouched, no red.
    private func drawExclamation(in context: inout GraphicsContext, center: CGPoint,
                                 side: CGFloat, weight: CGFloat, casing: CGFloat,
                                 color: Color) {
        let stemTop = center.y - side * 0.15
        let stemBottom = center.y + side * 0.045
        let dotY = center.y + side * 0.135

        var stem = Path()
        stem.move(to: CGPoint(x: center.x, y: stemTop))
        stem.addLine(to: CGPoint(x: center.x, y: stemBottom))

        let dot = Path(ellipseIn: CGRect(x: center.x - weight * 0.5, y: dotY - weight * 0.5,
                                         width: weight, height: weight))

        context.blendMode = .destinationOut
        context.stroke(stem, with: .color(.black),
                       style: StrokeStyle(lineWidth: casing, lineCap: .round))
        context.fill(dot.strokedPath(StrokeStyle(lineWidth: casing - weight)), with: .color(.black))
        context.blendMode = .normal
        context.stroke(stem, with: .color(color),
                       style: StrokeStyle(lineWidth: weight, lineCap: .round))
        context.fill(dot, with: .color(color))
    }

    /// Paused: two bars over the frozen strand.
    private func drawPauseGlyph(in context: inout GraphicsContext, center: CGPoint,
                                side: CGFloat, weight: CGFloat, casing: CGFloat,
                                color: Color) {
        let gap = side * 0.055
        let reach = side * 0.085

        for direction in [-1.0, 1.0] {
            let x = center.x + CGFloat(direction) * gap
            var bar = Path()
            bar.move(to: CGPoint(x: x, y: center.y - reach))
            bar.addLine(to: CGPoint(x: x, y: center.y + reach))

            context.blendMode = .destinationOut
            context.stroke(bar, with: .color(.black),
                           style: StrokeStyle(lineWidth: casing, lineCap: .round))
            context.blendMode = .normal
            context.stroke(bar, with: .color(color),
                           style: StrokeStyle(lineWidth: weight, lineCap: .round))
        }
    }
}

// MARK: - AppKit bridge

extension SpeakingStrand {
    /// Renders the mark to an `NSImage` — for the status item and anywhere else AppKit needs a
    /// picture rather than a view.
    ///
    /// `isTemplate` hands the glyph to the menu bar as a mask, so macOS tints it for light/dark
    /// menu bars and for the highlighted (clicked) state automatically. Colour is discarded in
    /// that mode, which is why the recording state passes `isTemplate: false` — rust in the menu
    /// bar has to survive as rust.
    @MainActor
    static func image(state: State = .idle, size: CGFloat,
                      ring: Color = Osier.mark, strand: Color = Osier.mark,
                      isTemplate: Bool) -> NSImage? {
        let renderer = ImageRenderer(
            content: SpeakingStrand(state: state, ring: ring, strand: strand)
                .frame(width: size, height: size))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        guard let cgImage = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
        image.isTemplate = isTemplate
        return image
    }
}

// MARK: - Preview

#Preview("Speaking strand") {
    VStack(spacing: 28) {
        ForEach([("idle", SpeakingStrand.State.idle),
                 ("recording", .recording),
                 ("transcribing", .transcribing),
                 ("paused", .paused),
                 ("error", .error)], id: \.0) { label, state in
            HStack(spacing: 22) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(Osier.inkSoft)
                    .frame(width: 84, alignment: .trailing)

                // On cream, as in the main window.
                SpeakingStrand(state: state).frame(width: 26, height: 26)
                SpeakingStrand(state: state).frame(width: 64, height: 64)

                // On black, as in the notch pill.
                SpeakingStrand(state: state, ring: Osier.newGrowth, strand: Osier.newGrowth)
                    .frame(width: 26, height: 26)
                    .padding(10)
                    .background(Color.black)
            }
        }
    }
    .padding(30)
    .background(Osier.surface)
}
