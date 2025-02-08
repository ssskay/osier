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

        VStack {
            Text("Welcome to OpenSuperWhisper!")
                .font(.title)
                .padding()

            // drop down to select language
            Picker("Select Language", selection: $viewModel.selectedLanguage) {
                ForEach(["English", "German", "French"], id: \.self) { language in
                    Text(language)
                }
            }
            .frame(width: 200)
        }
        Text(/*@START_MENU_TOKEN@*/"Hello, World!"/*@END_MENU_TOKEN@*/)
    }
}

struct DownloadableModel: Identifiable {
    let id = UUID() // Add an ID for Identifiable conformance
    let name: String
    let isDownloaded: Bool
    let url: URL
    let size: Int
    var speedRate: Int
    var accuracyRate: Int
    var downloadProgress: Double = 0.0 // 0 to 1
    var isSelected: Bool = false

    var sizeString: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB] // More appropriate units
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true // Let the formatter decide
        return formatter.string(fromByteCount: Int64(size) * 1000000) // Convert to MB as your size is in MB
    }

    init(name: String, isDownloaded: Bool, url: URL, size: Int, speedRate: Int, accuracyRate: Int) {
        self.name = name
        self.isDownloaded = isDownloaded
        self.url = url
        self.size = size
        self.speedRate = speedRate
        self.accuracyRate = accuracyRate
    }

    // Example mutator to simulate download progress (you'd replace this with real logic)
    mutating func updateDownloadProgress(progress: Double) {
        downloadProgress = progress
    }
}

let availableModels = [
    DownloadableModel(
        name: "ggml-large-v3-turbo-q5_0.bin",
        isDownloaded: false,
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
        size: 574,
        speedRate: 100,
        accuracyRate: 100
    ),
    DownloadableModel(
        name: "ggml-large-v3-turbo-q8_0.bin",
        isDownloaded: false,
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
        size: 874,
        speedRate: 100,
        accuracyRate: 100
    ),
    DownloadableModel(
        name: "ggml-large-v3-turbo.bin",
        isDownloaded: false,
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
        size: 1624,
        speedRate: 100,
        accuracyRate: 100
    )
]

// UI for the model
struct DownloadableItemView: View {
    @Binding var model: DownloadableModel
    @Binding var isDownloadingAny: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 12) {
                        Text(model.name)
                            .frame(width: .infinity)
                            .font(.headline)

                        Spacer()

                        VStack {
                            Text("Accuracy")

                            ProgressView(value: Double(model.accuracyRate), total: 100)
                                .progressViewStyle(LinearProgressViewStyle())
                                .frame(width: 64, height: 4)

                        }

                        VStack {
                            Text("Speed")

                            ProgressView(value: Double(model.speedRate), total: 100)
                                .progressViewStyle(LinearProgressViewStyle())
                                .frame(width: 64, height: 4)
                        }

                    }

                    Text(model.sizeString)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }

                Spacer()

                // Download status/button
                if model.isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if model.downloadProgress > 0 && model.downloadProgress < 1 {
                    ProgressView(value: model.downloadProgress)
                        .progressViewStyle(CircularProgressViewStyle())
                        .frame(width: 30, height: 30)
                } else {
                    Button(action: {
                        guard !isDownloadingAny else { return }
                        startFakeDownload()
                    }) {
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(isDownloadingAny ? .gray : .blue)
                    }
                    .disabled(isDownloadingAny)
                }
            }
            .padding(16)
        }
        .frame(width: 350)
        .padding(.vertical, 8)
        .border(model.isSelected ? Color.green : Color.clear, width: 2)
        .cornerRadius(8)
        .onTapGesture {
            model.isSelected.toggle()
        }
    }

    func startFakeDownload() {
        isDownloadingAny = true
        var progress = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            progress += 0.02
            model.updateDownloadProgress(progress: progress)

            if progress >= 1.0 {
                timer.invalidate()
                model.updateDownloadProgress(progress: 1.0)
                model.speedRate = Int.random(in: 80...100)
                model.accuracyRate = Int.random(in: 80...100)
                isDownloadingAny = false
            }
        }
    }
}

struct ModelListView: View {
    @State var availableModels: [DownloadableModel] = [
        DownloadableModel(
            name: "Turbo V3 low",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
            size: 574,
            speedRate: 100,
            accuracyRate: 100
        ),
        DownloadableModel(
            name: "Turbo V3 medium",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
            size: 874,
            speedRate: 100,
            accuracyRate: 100
        ),
        DownloadableModel(
            name: "Turbo V3 high",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
            size: 1624,
            speedRate: 100,
            accuracyRate: 100
        )
    ]
    @State private var isDownloadingAny: Bool = false

    var body: some View {
        List {
            ForEach($availableModels) { $model in
                DownloadableItemView(model: $model, isDownloadingAny: $isDownloadingAny)
            }
        }
        .listStyle(.plain)
    }
}

#Preview {
    OnboardingView(isPresented: .constant(true))
}

#Preview {
    ModelListView()
}
