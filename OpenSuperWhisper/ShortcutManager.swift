import AppKit
import ApplicationServices
import Carbon
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", default: .init(.backtick, modifiers: .option))
    static let escape = Self("escape", default: .init(.escape))
}

class ShortcutManager {
    static let shared = ShortcutManager()

    private init() {
        print("ShortcutManager init")
        
        var activeVm: IndicatorViewModel?
        
        KeyboardShortcuts.onKeyUp(for: .toggleRecord) { [weak self] in
            guard let self = self else { return }
            
            if let vm = activeVm {
                IndicatorWindowManager.shared.stopRecording()
                activeVm = nil
            } else {
                let cursorPosition = self.getCurrentCursorPosition()

                var indicatorPoint: NSPoint?

                if let carretPosition = self.getCaretRect(), let screen = self.getFocusedWindowScreen() {
                    
                    let screenHeight = screen.frame.height
                    indicatorPoint = NSPoint(x: carretPosition.origin.x, y: screenHeight - carretPosition.origin.y)
                } else {
                    indicatorPoint = cursorPosition
                }

                let point = (indicatorPoint ?? self.getCurrentCursorPosition())
                print("indicatorPoint: \(indicatorPoint)")
                let vm = IndicatorWindowManager.shared.show(nearPoint: indicatorPoint)
                vm.startRecording()
                    
                activeVm = vm
            }
        }

        KeyboardShortcuts.onKeyUp(for: .escape) { [weak self] in
            if let vm = activeVm {
                
                if vm.isRecording {
                    IndicatorWindowManager.shared.stopForce()
                    activeVm = nil

                } else {
                    IndicatorWindowManager.shared.stopRecording()
                    activeVm = nil

                }
                
            }
        }
    }

    func checkAccessibilityPermissions() -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true]
        return AXIsProcessTrustedWithOptions(options)
    }
    
    private func getCurrentCursorPosition() -> NSPoint {
        return NSEvent.mouseLocation
    }
    
    func getCaretRect() -> CGRect? {
        // Получаем системный элемент для доступа ко всему UI
        let systemElement = AXUIElementCreateSystemWide()
        
        // Получаем фокусированный элемент
        var focusedElement: CFTypeRef? // Keep as CFTypeRef? if you prefer
        let errorFocused = AXUIElementCopyAttributeValue(systemElement,
                                                         kAXFocusedUIElementAttribute as CFString,
                                                         &focusedElement)
        
        print("errorFocused: \(errorFocused)")
        guard errorFocused == .success else {
            print("Не удалось получить фокусированный элемент")
            return nil
        }
        
        guard let focusedElementCF = focusedElement else { // Optional binding to safely unwrap CFTypeRef
            print("Не удалось получить фокусированный элемент (CFTypeRef is nil)") // Extra safety check, though unlikely
            return nil
        }
        
        let element = focusedElementCF as! AXUIElement
        // Получаем выделенный текстовый диапазон у фокусированного элемента
        var selectedTextRange: AnyObject?
        let errorRange = AXUIElementCopyAttributeValue(element,
                                                       kAXSelectedTextRangeAttribute as CFString,
                                                       &selectedTextRange)
        guard errorRange == .success,
              let textRange = selectedTextRange
        else {
            print("Не удалось получить диапазон выделенного текста")
            return nil
        }
        
        // Используем параметризованный атрибут для получения границ диапазона (положение каретки)
        var caretBounds: CFTypeRef?
        let errorBounds = AXUIElementCopyParameterizedAttributeValue(element,
                                                                     kAXBoundsForRangeParameterizedAttribute as CFString,
                                                                     textRange,
                                                                     &caretBounds)
        
        print("errorbounds: \(errorBounds), caretBounds \(caretBounds)")
        guard errorBounds == .success else {
            print("Не удалось получить границы каретки")
            return nil
        }
        
        let rect = caretBounds as! AXValue

        return rect.toCGRect()
    }

    func getFocusedWindowScreen() -> NSScreen? {
        let systemWideElement = AXUIElementCreateSystemWide()
        
        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWideElement,
                                                   kAXFocusedWindowAttribute as CFString,
                                                   &focusedWindow)
        
        guard result == .success else {
            print("Не удалось получить сфокусированное окно")
            return NSScreen.main
        }
        let windowElement = focusedWindow as! AXUIElement
        
        var windowFrameValue: CFTypeRef?
        let frameResult = AXUIElementCopyAttributeValue(windowElement,
                                                        
                                                        "AXFrame" as CFString,
                                                        &windowFrameValue)
        
        guard frameResult == .success else {
            print("Не удалось получить фрейм окна")
            return NSScreen.main
        }
        let frameValue = windowFrameValue as! AXValue
        
        var windowFrame = CGRect.zero
        guard AXValueGetValue(frameValue, AXValueType.cgRect, &windowFrame) else {
            print("Не удалось извлечь CGRect из AXValue")
            return NSScreen.main
        }
        
        for screen in NSScreen.screens {
            if screen.frame.intersects(windowFrame) {
                return screen
            }
        }
        
        return NSScreen.main
    }

}

extension AXValue {
    func toCGRect() -> CGRect? {
        var rect = CGRect.zero
        var type: AXValueType = AXValueGetType(self)
        
        guard type == .cgRect else {
            print("AXValue is not of type CGRect, but \(type)") // More informative error
            return nil
        }
        
        let success = AXValueGetValue(self, .cgRect, &rect)
        
        guard success else {
            print("Failed to get CGRect value from AXValue")
            return nil
        }
        return rect
    }
}

extension IndicatorWindowManager {
    func show(nearPoint point: NSPoint) -> IndicatorViewModel {
        // Create new view model
        let newViewModel = IndicatorViewModel()
        self.viewModel = newViewModel
        
        if self.window == nil {
            // Create window if it doesn't exist
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            
            window.level = .floating
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            
            self.window = window
        }
        
        // Position window near cursor
        if let window = self.window, let screen = NSScreen.main {
            let windowFrame = window.frame
            let screenFrame = screen.frame
            
            // Try to position above cursor
            var x = point.x - windowFrame.width / 2
            var y = point.y + 10 // 20 points above cursor
            
            // Adjust if out of screen bounds
            x = max(screenFrame.minX, min(x, screenFrame.maxX - windowFrame.width))
            y = max(screenFrame.minY, min(y, screenFrame.maxY - windowFrame.height))
            
            window.setFrameOrigin(NSPoint(x: x, y: y))
            
            // Set content view
            let hostingView = NSHostingView(rootView: IndicatorWindow(viewModel: newViewModel))
            window.contentView = hostingView
        }
        
        self.window?.orderFront(nil)
        return newViewModel
    }
}
