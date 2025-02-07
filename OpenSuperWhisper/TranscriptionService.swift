import Foundation

class TranscriptionService: ObservableObject {
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcribedText = ""
    
    private var context: WhisperContext?
    
    init() {
        if let modelPath = UserDefaults.standard.string(forKey: "selectedModelPath") {
            context = WhisperContext(modelURL: URL(fileURLWithPath: modelPath))
        }
    }
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        guard let context = self.context ?? createContext() else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        DispatchQueue.main.async {
            self.isTranscribing = true
        }
        
        defer {
            DispatchQueue.main.async {
                self.isTranscribing = false
            }
        }
        
        guard let samples = WhisperContext.convertAudioFileToPCM(fileURL: url) else {
            throw TranscriptionError.audioConversionFailed
        }
        
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.single_segment = false
        params.no_timestamps = !settings.viewModel.showTimestamps
        params.suppress_blank = settings.viewModel.suppressBlankAudio
        params.translate = settings.viewModel.translateToEnglish
        
        if let languageStr = strdup(settings.viewModel.selectedLanguage) {
            params.language = UnsafePointer(languageStr)
            
            defer {
                free(languageStr)
            }
            
            if let text = context.processAudio(samples: samples, params: params) {
                let cleanedText = text
                    .replacingOccurrences(of: "[MUSIC]", with: "")
                    .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                let finalText = cleanedText.isEmpty ? "No speech detected in the audio" : cleanedText
                
                DispatchQueue.main.async {
                    self.transcribedText = finalText
                }
                
                return finalText
            } else {
                throw TranscriptionError.processingFailed
            }
        } else {
            throw TranscriptionError.languageAllocationFailed
        }
    }
    
    private func createContext() -> WhisperContext? {
        guard let modelPath = UserDefaults.standard.string(forKey: "selectedModelPath") else {
            return nil
        }
        
        context = WhisperContext(modelURL: URL(fileURLWithPath: modelPath))
        return context
    }
}

enum TranscriptionError: Error {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed
    case languageAllocationFailed
} 