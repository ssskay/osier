import XCTest
import FluidAudio
@testable import OpenSuperWhisper

/// Guards the confirmation gates on the custom-dictionary boosting pass.
///
/// `SlidingWindowAsrManager` is a LIVE-caption API: a window's text sits in a `volatile` slot and
/// is only promoted to `confirmed` by the *next* window that clears both `confirmationThreshold`
/// and `minContextForConfirmation`. A window that misses either gate overwrites the volatile slot
/// instead, destroying the previous window's ~11s of speech outright, and `finish()` returns only
/// `confirmed + volatile`.
///
/// Driving that API over a finished file with FluidAudio's `.default` gates (0.85 / 10s) silently
/// truncated dictations — the loss landed on the tail because the last window is always a short
/// partial chunk, the one least likely to clear the gates, with nothing after it to promote the
/// full window before it. A real 14.1s clip came back as ", you know." (11 chars) against 268
/// chars from the offline path. (#tail-truncation)
///
/// There is nothing to revise in an already-recorded file, so every window must confirm. Reverting
/// to `.default` here re-opens the data loss, hence this guard.
final class FluidAudioBoostingWindowTests: XCTestCase {

    func testEveryWindowConfirmsSoNoSpeechIsDiscarded() {
        let config = FluidAudioEngine.fileBoostingConfig

        // `shouldConfirm = confidence >= confirmationThreshold && audioSoFar >= minContextForConfirmation`.
        // Zero on both sides is what makes that true for every window, including the short final one.
        XCTAssertEqual(config.confirmationThreshold, 0,
                       "A confidence gate discards the preceding window's speech on any window that misses it.")
        XCTAssertEqual(config.minContextForConfirmation, 0,
                       "A context gate discards every window until the threshold is reached.")
    }

    /// The 11+2+2 geometry is the quality-critical part and must keep matching the offline
    /// chunking — only the confirmation gates were meant to change.
    func testWindowGeometryStillMatchesOfflineChunking() {
        let config = FluidAudioEngine.fileBoostingConfig

        XCTAssertEqual(config.chunkSeconds, 11.0)
        XCTAssertEqual(config.leftContextSeconds, 2.0)
        XCTAssertEqual(config.rightContextSeconds, 2.0)
        // left + chunk + right must fit the model's fixed 15s input, or startStreaming() throws.
        XCTAssertEqual(
            config.leftContextSeconds + config.chunkSeconds + config.rightContextSeconds, 15.0)
    }
}
