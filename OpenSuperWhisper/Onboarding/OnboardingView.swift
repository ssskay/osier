//
//  OnboardingView.swift
//  OpenSuperWhisper
//
//  Created by user on 08.02.2025.
//

import SwiftUI

class OnboardingViewModel: ObservableObject {
    @Published var selectedLanguage: String
    @Published var selectedGGMLModel: URL? {
        didSet {
            if let url = selectedGGMLModel {
                setModelPath(url)
            }
        }
    }
    @Published var availableModels: [URL] = []

    init() {
        self.selectedLanguage = AppPreferences.shared.whisperLanguage
        loadAvailableModels()
    }

    private func loadAvailableModels() {
        // Load available models from a predefined directory or source
        // This is a placeholder implementation
        let modelsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("Models")
        if let modelsDirectory = modelsDirectory {
            do {
                availableModels = try FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)
            } catch {
                print("Error loading models: \(error)")
            }
        }
    }

    func setModelPath(_ url: URL) {
        AppPreferences.shared.selectedModelPath = url.path
    }

    func setLanguage(_ language: String) {
        selectedLanguage = language
        AppPreferences.shared.whisperLanguage = language
    }
}

struct OnboardingView: View {
    @StateObject private var viewModel = OnboardingViewModel()
    @Binding var isPresented: Bool
    
    var body: some View {
        Text(/*@START_MENU_TOKEN@*/"Hello, World!"/*@END_MENU_TOKEN@*/)
    }
}

#Preview {
    OnboardingView(isPresented: .constant(true))
}
