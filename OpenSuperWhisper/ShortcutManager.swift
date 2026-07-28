import AppKit
import ApplicationServices
import Carbon
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", default: .init(.backtick, modifiers: .option))
    /// Cancel the in-progress recording. Deliberately has NO default: Escape belongs to
    /// whatever app you're dictating into (dismissing a sheet, leaving vim insert mode), and
    /// cancelling a recording is rare. Opt in from Settings ▸ Cancel recording (optional).
    /// The raw value stays "escape" so an explicitly chosen binding survives the rename.
    static let cancelRecording = Self("escape")
}

class ShortcutManager {
    static let shared = ShortcutManager()

    /// Presentable name of the bound cancel key ("⎋", "⌘.", …), or nil when cancel is
    /// unbound — which is the default. Drives the indicator's cancel hint, so the pill
    /// never advertises a key that does nothing.
    @MainActor
    static var cancelShortcutDescription: String? {
        KeyboardShortcuts.getShortcut(for: .cancelRecording)?.description
    }

    private var activeVm: IndicatorViewModel?
    private var holdWorkItem: DispatchWorkItem?
    private let holdThreshold: TimeInterval = 0.3
    private var holdMode = false
    private var useModifierOnlyHotkey = false
    private var useMouseButtonHotkey = false

    private init() {
        print("ShortcutManager init")

        setupKeyboardShortcuts()
        setupRecordingTrigger()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeySettingsChanged),
            name: .hotkeySettingsChanged,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(indicatorWindowDidHide),
            name: .indicatorWindowDidHide,
            object: nil
        )
    }
    
    @objc private func indicatorWindowDidHide() {
        activeVm = nil
        holdMode = false
    }
    
    @objc private func hotkeySettingsChanged() {
        setupRecordingTrigger()
    }
    
    /// UserDefaults flag for the one-time removal of the old Escape binding (below).
    private static let clearedLegacyCancelKey = "didClearLegacyEscapeCancelBinding"

    /// `.cancelRecording` used to default to plain Escape, and `KeyboardShortcuts.Name`
    /// writes its `default:` straight into UserDefaults the first time the name is
    /// constructed — so dropping the default is not enough on an upgrade: the stored Esc
    /// would survive and keep swallowing the key. Clear it once, and only when it is still
    /// exactly plain Escape, so a deliberate ⌘Esc / ⌘. choice is left alone.
    private func clearLegacyEscapeBindingOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.clearedLegacyCancelKey) else { return }
        defaults.set(true, forKey: Self.clearedLegacyCancelKey)

        if KeyboardShortcuts.getShortcut(for: .cancelRecording) == .init(.escape) {
            KeyboardShortcuts.setShortcut(nil, for: .cancelRecording)
        }
    }

    private func setupKeyboardShortcuts() {
        clearLegacyEscapeBindingOnce()

        KeyboardShortcuts.onKeyDown(for: .toggleRecord) { [weak self] in
            self?.handleKeyDown()
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRecord) { [weak self] in
            self?.handleKeyUp()
        }

        KeyboardShortcuts.onKeyUp(for: .cancelRecording) { [weak self] in
            Task { @MainActor in
                // requestCancel() discards immediately for short recordings, but a long
                // one arms a confirmation and returns false — leave activeVm set so the
                // next press (within the window) confirms the cancel.
                if self?.activeVm != nil, IndicatorWindowManager.shared.requestCancel() {
                    self?.activeVm = nil
                }
            }
        }
        KeyboardShortcuts.disable(.cancelRecording)
    }
    
    private func setupRecordingTrigger() {
        let modifierKey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .none
        let mouseButton = MouseButton(rawValue: AppPreferences.shared.mouseButtonHotkey) ?? .none

        // The three trigger modes are mutually exclusive. Tear all of them down
        // first, then enable exactly one. A configured mouse button takes priority
        // over a modifier key, which takes priority over the regular shortcut.
        ModifierKeyMonitor.shared.stop()
        MouseButtonMonitor.shared.stop()

        if mouseButton != .none {
            useMouseButtonHotkey = true
            useModifierOnlyHotkey = false
            KeyboardShortcuts.disable(.toggleRecord)

            MouseButtonMonitor.shared.onButtonDown = { [weak self] in
                self?.handleKeyDown()
            }

            MouseButtonMonitor.shared.onButtonUp = { [weak self] in
                self?.handleKeyUp()
            }

            MouseButtonMonitor.shared.start(mouseButton: mouseButton)
            print("ShortcutManager: Using mouse-button hotkey: \(mouseButton.displayName)")
        } else if modifierKey != .none {
            useMouseButtonHotkey = false
            useModifierOnlyHotkey = true
            KeyboardShortcuts.disable(.toggleRecord)

            ModifierKeyMonitor.shared.onKeyDown = { [weak self] in
                self?.handleKeyDown()
            }

            ModifierKeyMonitor.shared.onKeyUp = { [weak self] in
                self?.handleKeyUp()
            }

            ModifierKeyMonitor.shared.start(modifierKey: modifierKey)
            print("ShortcutManager: Using modifier-only hotkey: \(modifierKey.displayName)")
        } else {
            useMouseButtonHotkey = false
            useModifierOnlyHotkey = false
            KeyboardShortcuts.enable(.toggleRecord)
            print("ShortcutManager: Using regular keyboard shortcut")
        }
    }
    
    private func handleKeyDown() {
        // TEMPORARY DIAGNOSTIC (#chord-double-fire) — pairs with the log in
        // ModifierKeyMonitor.handleFlagsChanged so we can see how many keyDowns one
        // physical press produces, and what the toggle decides each time.
        print("ShortcutManager: handleKeyDown (activeVm=\(activeVm == nil ? "nil" : "set"), holdMode=\(holdMode))")
        holdWorkItem?.cancel()
        holdMode = false
        
        let holdToRecordEnabled = AppPreferences.shared.holdToRecord
        
        Task { @MainActor in
            if self.activeVm == nil {
                Diag.mark("keyDown → start recording")
                let cursorPosition = FocusUtils.getCurrentCursorPosition()
                var caret: CGRect? = nil
                // Only "cursor" mode needs the caret; other positions anchor to
                // screen geometry, so skip the synchronous AX caret query (a
                // main-thread hang risk) when its result would be discarded.
                if FocusUtils.shouldAnchorToCaret(indicatorPosition: AppPreferences.shared.indicatorPosition) {
                    caret = Diag.measure("getCaretRect") { FocusUtils.getCaretRect() }
                }
                let indicatorPoint: NSPoint? = caret.map { FocusUtils.convertAXPointToCocoa($0.origin) } ?? cursorPosition
                let vm = Diag.measure("IndicatorWindowManager.show") {
                    IndicatorWindowManager.shared.show(nearPoint: indicatorPoint)
                }
                Diag.measure("vm.startRecording") { vm.startRecording() }
                self.activeVm = vm
            } else if !self.holdMode {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
            }
        }
        
        if holdToRecordEnabled {
            let workItem = DispatchWorkItem { [weak self] in
                self?.holdMode = true
            }
            holdWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
        }
    }
    
    private func handleKeyUp() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        
        let holdToRecordEnabled = AppPreferences.shared.holdToRecord
        
        Task { @MainActor in
            if holdToRecordEnabled && self.holdMode {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
                self.holdMode = false
            }
        }
    }
}