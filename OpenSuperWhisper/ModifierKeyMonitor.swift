import AppKit
import Carbon
import Foundation

enum ModifierKey: String, CaseIterable, Identifiable, Codable {
    case none = "none"
    case leftCommand = "leftCommand"
    case rightCommand = "rightCommand"
    case leftOption = "leftOption"
    case rightOption = "rightOption"
    case leftShift = "leftShift"
    case rightShift = "rightShift"
    case leftControl = "leftControl"
    case rightControl = "rightControl"
    case fn = "fn"
    /// Fn held together with either Control. The only chord in this list: every other
    /// case is a single modifier identified by its key code, so the monitor has to
    /// match this one on flags instead (see `triggerKeyCodes`).
    case fnControl = "fnControl"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .none: return "None"
        case .leftCommand: return "Left ⌘ Command"
        case .rightCommand: return "Right ⌘ Command"
        case .leftOption: return "Left ⌥ Option"
        case .rightOption: return "Right ⌥ Option"
        case .leftShift: return "Left ⇧ Shift"
        case .rightShift: return "Right ⇧ Shift"
        case .leftControl: return "Left ⌃ Control"
        case .rightControl: return "Right ⌃ Control"
        case .fn: return "Fn"
        case .fnControl: return "Fn + ⌃ Control"
        }
    }
    
    var shortSymbol: String {
        switch self {
        case .none: return ""
        case .leftCommand: return "⌘"
        case .rightCommand: return "⌘"
        case .leftOption: return "⌥"
        case .rightOption: return "⌥"
        case .leftShift: return "⇧"
        case .rightShift: return "⇧"
        case .leftControl: return "⌃"
        case .rightControl: return "⌃"
        case .fn: return "fn"
        case .fnControl: return "fn⌃"
        }
    }
    
    var keyCode: UInt16 {
        switch self {
        case .none: return 0
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftShift: return 56
        case .rightShift: return 60
        case .leftControl: return 59
        case .rightControl: return 62
        case .fn: return 63
        case .fnControl: return 63
        }
    }

    /// Every key code that can make or break this trigger. A single modifier has one;
    /// the Fn+Control chord has three, because releasing *either* half ends it and
    /// `handleFlagsChanged` would otherwise never see the Control key's event.
    var triggerKeyCodes: Set<UInt16> {
        switch self {
        case .none: return []
        case .fnControl: return [63, 59, 62]  // fn, left ⌃, right ⌃
        default: return [keyCode]
        }
    }
    
    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .none: return []
        case .leftCommand, .rightCommand: return .command
        case .leftOption, .rightOption: return .option
        case .leftShift, .rightShift: return .shift
        case .leftControl, .rightControl: return .control
        case .fn: return .function
        case .fnControl: return [.function, .control]
        }
    }
    
    var cgEventFlag: CGEventFlags {
        switch self {
        case .none: return []
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftOption, .rightOption: return .maskAlternate
        case .leftShift, .rightShift: return .maskShift
        case .leftControl, .rightControl: return .maskControl
        case .fn: return .maskSecondaryFn
        case .fnControl: return [.maskSecondaryFn, .maskControl]
        }
    }
    
    var isCommandOrOption: Bool {
        switch self {
        case .leftCommand, .rightCommand, .leftOption, .rightOption:
            return true
        default:
            return false
        }
    }
}

/// Watches for the trigger modifier (or Fn+Control chord) via **NSEvent monitors**, not a
/// CGEventTap.
///
/// This class used a CGEventTap through two "durable" fixes, and macOS killed it both times:
///
/// 1. Tap on the main run loop → main-thread stalls (AppleScript/AX work at record-start)
///    tripped the tap watchdog; macOS disabled it and dropped the chord's release events.
/// 2. Tap on a dedicated `.userInteractive` thread → **still** died. Logged 2026-07-27: the
///    tap timed out while the thread was idle, `CGEvent.tapEnable` inside the
///    `tapDisabledByTimeout` callback claimed success, the state resync was correct
///    ("modifier still held: false") — and yet no event was ever delivered again. The next
///    press was invisible; recording could not be stopped.
///
/// NSEvent monitors have no watchdog and no disable path. Under a main-thread stall their
/// events arrive *late* instead of being dropped forever — the edge detector stays in sync
/// and the stop lands as soon as the stall clears. That trade is strictly better for a
/// dictation trigger.
///
/// A **global** monitor sees events only while some *other* app is active; a **local** one
/// covers events delivered to Osier itself (Settings window open, etc.). Exactly one of the
/// two fires per event, so edges can't double-fire. Global monitors require the
/// Accessibility grant the app already demands for text insertion.
class ModifierKeyMonitor {
    static let shared = ModifierKeyMonitor()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var selectedModifierKey: ModifierKey = .none
    private var isModifierPressed = false

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private init() {}

    func start(modifierKey: ModifierKey) {
        stop()
        guard modifierKey != .none else { return }

        selectedModifierKey = modifierKey
        // Seed from the live flags so a modifier already held at start() doesn't
        // desync the edge detector (first observed event would otherwise look like
        // a release with wasPressed == false and be swallowed).
        isModifierPressed = NSEvent.modifierFlags.contains(modifierKey.modifierFlag)

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        if globalMonitor == nil {
            print("ModifierKeyMonitor: Failed to install global monitor. Check Accessibility permission.")
        }
        print("ModifierKeyMonitor: Started monitoring for \(modifierKey.displayName) (NSEvent monitors)")
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        isModifierPressed = false
        print("ModifierKeyMonitor: Stopped")
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard selectedModifierKey.triggerKeyCodes.contains(event.keyCode) else { return }

        // `contains` on an OptionSet is a superset test, so a multi-flag chord only
        // counts as pressed while *every* one of its modifiers is held.
        let isPressed = event.modifierFlags.contains(selectedModifierKey.modifierFlag)

        // TEMPORARY DIAGNOSTIC (#chord-double-fire): keep until a few days of dictation
        // confirm the NSEvent transport holds up, then remove.
        print("ModifierKeyMonitor: keyCode=\(event.keyCode) flags=0x\(String(event.modifierFlags.rawValue, radix: 16)) isPressed=\(isPressed) wasPressed=\(isModifierPressed)")

        // Monitor handlers are delivered on the main thread — invoke callbacks directly.
        if isPressed && !isModifierPressed {
            isModifierPressed = true
            onKeyDown?()
        } else if !isPressed && isModifierPressed {
            isModifierPressed = false
            onKeyUp?()
        }
    }

    deinit {
        stop()
    }
}
