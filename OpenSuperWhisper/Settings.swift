import AppKit
import Carbon
import Combine
import Foundation
import SwiftUI

class SettingsViewModel: ObservableObject {
    @Published var selectedModelURL: URL? {
        didSet {
            if let url = selectedModelURL {
                UserDefaults.standard.set(url.path, forKey: "selectedModelPath")
            }
        }
    }
    @Published var availableModels: [URL] = []
    @Published var selectedLanguage: String {
        didSet {
            UserDefaults.standard.set(selectedLanguage, forKey: "whisperLanguage")
        }
    }
    @Published var translateToEnglish: Bool {
        didSet {
            UserDefaults.standard.set(translateToEnglish, forKey: "translateToEnglish")
        }
    }
    @Published var suppressBlankAudio: Bool {
        didSet {
            UserDefaults.standard.set(suppressBlankAudio, forKey: "suppressBlankAudio")
        }
    }
    @Published var showTimestamps: Bool {
        didSet {
            UserDefaults.standard.set(showTimestamps, forKey: "showTimestamps")
        }
    }
    
    // New settings
    @Published var temperature: Double {
        didSet {
            UserDefaults.standard.set(temperature, forKey: "temperature")
        }
    }
    @Published var noSpeechThreshold: Double {
        didSet {
            UserDefaults.standard.set(noSpeechThreshold, forKey: "noSpeechThreshold")
        }
    }
    @Published var initialPrompt: String {
        didSet {
            UserDefaults.standard.set(initialPrompt, forKey: "initialPrompt")
        }
    }
    @Published var useBeamSearch: Bool {
        didSet {
            UserDefaults.standard.set(useBeamSearch, forKey: "useBeamSearch")
        }
    }
    @Published var beamSize: Int {
        didSet {
            UserDefaults.standard.set(beamSize, forKey: "beamSize")
        }
    }
    @Published var debugMode: Bool {
        didSet {
            UserDefaults.standard.set(debugMode, forKey: "debugMode")
        }
    }
    
    let availableLanguages = [
        "auto", "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar", "sv", "it", "id", "hi", "fi"
    ]
    
    let languageNames = [
        "auto": "Auto-detect",
        "en": "English",
        "zh": "Chinese",
        "de": "German",
        "es": "Spanish",
        "ru": "Russian",
        "ko": "Korean",
        "fr": "French",
        "ja": "Japanese",
        "pt": "Portuguese",
        "tr": "Turkish",
        "pl": "Polish",
        "ca": "Catalan",
        "nl": "Dutch",
        "ar": "Arabic",
        "sv": "Swedish",
        "it": "Italian",
        "id": "Indonesian",
        "hi": "Hindi",
        "fi": "Finnish"
    ]
    
    init() {
        self.selectedLanguage = UserDefaults.standard.string(forKey: "whisperLanguage") ?? "auto"
        self.translateToEnglish = UserDefaults.standard.bool(forKey: "translateToEnglish")
        self.suppressBlankAudio = UserDefaults.standard.bool(forKey: "suppressBlankAudio")
        self.showTimestamps = UserDefaults.standard.bool(forKey: "showTimestamps")
        
        // Initialize new settings
        self.temperature = UserDefaults.standard.double(forKey: "temperature") != 0 ? UserDefaults.standard.double(forKey: "temperature") : 0.0
        self.noSpeechThreshold = UserDefaults.standard.double(forKey: "noSpeechThreshold") != 0 ? UserDefaults.standard.double(forKey: "noSpeechThreshold") : 0.6
        self.initialPrompt = UserDefaults.standard.string(forKey: "initialPrompt") ?? ""
        self.useBeamSearch = UserDefaults.standard.bool(forKey: "useBeamSearch")
        self.beamSize = UserDefaults.standard.integer(forKey: "beamSize") != 0 ? UserDefaults.standard.integer(forKey: "beamSize") : 5
        self.debugMode = UserDefaults.standard.bool(forKey: "debugMode")
        
        if let savedPath = UserDefaults.standard.string(forKey: "selectedModelPath") {
            selectedModelURL = URL(fileURLWithPath: savedPath)
        }
        loadAvailableModels()
    }
    
    func loadAvailableModels() {
        availableModels = WhisperModelManager.shared.getAvailableModels()
        if selectedModelURL == nil {
            selectedModelURL = availableModels.first
        }
    }
}

final class Settings: ObservableObject {
    @Published var recordingShortcut: KeyboardShortcutSettings.KeyboardShortcut
    @Published var viewModel: SettingsViewModel
    private let keyboardSettings = KeyboardShortcutSettings()
    
    init() {
        // Initialize with the current keyboard settings
        self.recordingShortcut = keyboardSettings.recordingShortcut
        self.viewModel = SettingsViewModel()
        loadSettings()
    }
    
    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "recordingShortcut"),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcutSettings.KeyboardShortcut.self, from: data)
        {
            recordingShortcut = shortcut
            keyboardSettings.recordingShortcut = shortcut
        }
    }
    
    func saveSettings() {
        if let encoded = try? JSONEncoder().encode(recordingShortcut) {
            UserDefaults.standard.set(encoded, forKey: "recordingShortcut")
            keyboardSettings.recordingShortcut = recordingShortcut
        }
    }
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) var dismiss
    @State private var isRecordingNewShortcut = false
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // Model Settings
            modelSettings
                .tabItem {
                    Label("Model", systemImage: "cpu")
                }
                .tag(0)
            
            // Transcription Settings
            transcriptionSettings
                .tabItem {
                    Label("Transcription", systemImage: "text.bubble")
                }
                .tag(1)
            
            // Advanced Settings
            advancedSettings
                .tabItem {
                    Label("Advanced", systemImage: "gear")
                }
                .tag(2)
            
            // Shortcut Settings
            shortcutSettings
                .tabItem {
                    Label("Shortcuts", systemImage: "command")
                }
                .tag(3)
        }
        .padding()
        .frame(width: 500, height: 400)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
    
    private var modelSettings: some View {
        Form {
            Section(header: Text("Whisper Model").bold()) {
                Picker("Model", selection: $viewModel.selectedModelURL) {
                    ForEach(viewModel.availableModels, id: \.self) { url in
                        Text(url.lastPathComponent)
                            .tag(url as URL?)
                    }
                }
                .pickerStyle(.menu)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Models Directory:")
                        .font(.caption)
                    Text(WhisperModelManager.shared.modelsDirectory.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
    
    private var transcriptionSettings: some View {
        Form {
            Section(header: Text("Language Settings").bold()) {
                Picker("Language", selection: $viewModel.selectedLanguage) {
                    ForEach(viewModel.availableLanguages, id: \.self) { code in
                        Text(viewModel.languageNames[code] ?? code)
                            .tag(code)
                    }
                }
                .pickerStyle(.menu)
                
                Toggle("Translate to English", isOn: $viewModel.translateToEnglish)
            }
            
            Section(header: Text("Output Options").bold()) {
                Toggle("Show Timestamps", isOn: $viewModel.showTimestamps)
                Toggle("Suppress Blank Audio", isOn: $viewModel.suppressBlankAudio)
            }
            
            Section(header: Text("Initial Prompt").bold()) {
                TextEditor(text: $viewModel.initialPrompt)
                    .frame(height: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                Text("Optional text to guide the model's transcription")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var advancedSettings: some View {
        Form {
            Section(header: Text("Decoding Strategy").bold()) {
                Toggle("Use Beam Search", isOn: $viewModel.useBeamSearch)
                    .help("Beam search can provide better results but is slower")
                    .padding(.horizontal, 16)
                
                if viewModel.useBeamSearch {
                    HStack {
                        Text("Beam Size:")
                            .padding(.leading, 16)
                        Stepper("\(viewModel.beamSize)", value: $viewModel.beamSize, in: 1...10)
                            .help("Number of beams to use in beam search")
                            .padding(.trailing, 16)
                    }
                }
            }
            
            Section(header: Text("Model Parameters").bold()) {
                VStack(alignment: .leading) {
                    Text("Temperature: \(String(format: "%.2f", viewModel.temperature))")
                        .padding(.horizontal, 16)
                    Slider(value: $viewModel.temperature, in: 0.0...1.0, step: 0.1)
                        .help("Higher values make the output more random")
                        .padding(.horizontal, 16)
                }
                
                VStack(alignment: .leading) {
                    Text("No Speech Threshold: \(String(format: "%.2f", viewModel.noSpeechThreshold))")
                        .padding(.horizontal, 16)
                    Slider(value: $viewModel.noSpeechThreshold, in: 0.0...1.0, step: 0.1)
                        .help("Threshold for detecting speech vs. silence")
                        .padding(.horizontal, 16)
                }
            }
            
            Section(header: Text("Debug Options").bold()) {
                Toggle("Debug Mode", isOn: $viewModel.debugMode)
                    .help("Enable additional logging and debugging information")
                    .padding(.horizontal, 16)
            }
        }
    }
    
    private var shortcutSettings: some View {
        Form {
            Section(header: Text("Recording Shortcut").bold()) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(settings.recordingShortcut.description)
                            .font(.system(.body, design: .monospaced))
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.gray.opacity(0.1))
                            )
                            .padding(.leading, 16)
                        
                        Spacer()
                        
                        Button("Change") {
                            isRecordingNewShortcut.toggle()
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.trailing, 16)
                    }
                    
                    if isRecordingNewShortcut {
                        Text("Press your new shortcut combination...")
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)
                    }
                }
            }
            
            Section(header: Text("Instructions").bold()) {
                Text("• Press any key combination to set as the recording shortcut")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                Text("• The shortcut will work even when the app is in the background")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                Text("• Recommended to use Command (⌘) or Option (⌥) key combinations")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }
}

class KeyboardShortcutSettings: ObservableObject {
    @Published var recordingShortcut: KeyboardShortcut
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    var onShortcutTriggered: (() -> Void)?
    
    struct KeyboardShortcut: Codable {
        var keyCode: Int
        var modifiers: Int
        
        var description: String {
            var desc = ""
            if modifiers & Int(NSEvent.ModifierFlags.command.rawValue) != 0 { desc += "⌘" }
            if modifiers & Int(NSEvent.ModifierFlags.option.rawValue) != 0 { desc += "⌥" }
            if modifiers & Int(NSEvent.ModifierFlags.shift.rawValue) != 0 { desc += "⇧" }
            if modifiers & Int(NSEvent.ModifierFlags.control.rawValue) != 0 { desc += "⌃" }
            
            let key = KeyCodeHelper.keyCodeToString(keyCode)
            return desc + key
        }
    }
    
    init() {
        // Default shortcut: Command + Backtick
        self.recordingShortcut = KeyboardShortcut(
            keyCode: kVK_ANSI_Grave,
            modifiers: Int(NSEvent.ModifierFlags.command.rawValue)
        )
        loadSettings()
        setupShortcuts()
    }
    
    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "recordingShortcut"),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data)
        {
            recordingShortcut = shortcut
        }
    }
    
    func saveSettings() {
        if let encoded = try? JSONEncoder().encode(recordingShortcut) {
            UserDefaults.standard.set(encoded, forKey: "recordingShortcut")
        }
        setupShortcuts()
    }
    
    private func setupShortcuts() {
        // Remove existing monitors if any
        if let existingMonitor = globalEventMonitor {
            NSEvent.removeMonitor(existingMonitor)
        }
        if let existingMonitor = localEventMonitor {
            NSEvent.removeMonitor(existingMonitor)
        }
        
        // Setup global monitor for when app is not active
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.handleKeyEvent(event)
        }
        
        // Setup local monitor for when app is active
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyEvent(event) == true {
                return nil // Event handled, don't pass it further
            }
            return event // Event not handled, pass it further
        }
    }
    
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let modifiers = Int(event.modifierFlags.rawValue)
        if event.keyCode == UInt16(recordingShortcut.keyCode) &&
            modifiers == recordingShortcut.modifiers {
            DispatchQueue.main.async { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.onShortcutTriggered?()
            }
            return true
        }
        return false
    }
    
    deinit {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

class KeyCodeHelper {
    static func keyCodeToString(_ keyCode: Int) -> String {
        switch keyCode {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_Grave: return "`"
        default: return "Unknown"
        }
    }
}
