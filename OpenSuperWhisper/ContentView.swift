//
//  ContentView.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var audioRecorder = AudioRecorder.shared
    @StateObject private var settings = Settings.shared
    @StateObject private var permissionsManager = PermissionsManager()
    @StateObject private var transcriptionService = TranscriptionService.shared
    @StateObject private var recordingStore = RecordingStore.shared
    @State private var isSettingsPresented = false
    @State private var searchText = ""

    private var filteredRecordings: [Recording] {
        if searchText.isEmpty {
            return recordingStore.recordings
        } else {
            return recordingStore.searchRecordings(query: searchText)
        }
    }

    var body: some View {
        VStack {
            if !permissionsManager.isMicrophonePermissionGranted
                || !permissionsManager.isAccessibilityPermissionGranted
            {
                PermissionsView(permissionsManager: permissionsManager)
            } else {
                VStack(spacing: 0) {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)

                        TextField("Search in transcriptions", text: $searchText)
                            .textFieldStyle(PlainTextFieldStyle())

                        if !searchText.isEmpty {
                            Button(action: {
                                searchText = ""
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .imageScale(.medium)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(20)
                    .padding([.horizontal, .top])

                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 8) {
                            ForEach(filteredRecordings) { recording in
                                RecordingRow(recording: recording)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 16)
                    }
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color(NSColor.windowBackgroundColor).opacity(1),
                                        Color(NSColor.windowBackgroundColor).opacity(0),
                                    ]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 20)
                    }
                    VStack(spacing: 16) {
                        if !recordingStore.recordings.isEmpty {
                            HStack {
                                Spacer()
                                Button(action: {
                                    recordingStore.deleteAllRecordings()
                                }) {
                                    Text("Clear All")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)

                                Button(action: {
                                    isSettingsPresented.toggle()
                                }) {
                                    Image(systemName: "gear")
                                        .font(.title2)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding([.horizontal, .top])
                        }

                        if audioRecorder.isRecording {
                            Text(transcriptionService.currentSegment)
                                .font(.body)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(10)
                        }

                        Button(action: {
                            let viewModel = IndicatorWindowManager.shared.show()
                            viewModel.startRecording()

                            if audioRecorder.isRecording {
                                viewModel.startDecoding()
                                transcriptionService.stopTranscribing()
                            } else {
                                audioRecorder.startRecording()
                                transcriptionService.startRealTimeTranscription(settings: settings)
                            }
                        }) {
                            Image(
                                systemName: audioRecorder.isRecording
                                    ? "stop.circle.fill" : "record.circle.fill"
                            )
                            .font(.system(size: 64))
                            .foregroundColor(audioRecorder.isRecording ? .red : .accentColor)
                            .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .disabled(transcriptionService.isLoading)
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 400, idealWidth: 400)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay {
            if transcriptionService.isLoading {
                ZStack {
                    Color.black.opacity(0.3)
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Loading Whisper Model...")
                            .foregroundColor(.white)
                            .font(.headline)
                    }
                }
                .ignoresSafeArea()
            }
        }
        .fileDropHandler()
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(settings: settings)
        }
        .onAppear {
            if UserDefaults.standard.string(forKey: "selectedModelPath") == nil {
                if let defaultModel = WhisperModelManager.shared.getAvailableModels().first {
                    UserDefaults.standard.set(defaultModel.path, forKey: "selectedModelPath")
                }
            }
        }
    }
}

struct PermissionsView: View {
    @ObservedObject var permissionsManager: PermissionsManager

    var body: some View {
        VStack(spacing: 20) {
            Text("Required Permissions")
                .font(.title)
                .padding()

            PermissionRow(
                isGranted: permissionsManager.isMicrophonePermissionGranted,
                title: "Microphone Access",
                description: "Required for audio recording",
                action: { permissionsManager.openSystemPreferences(for: .microphone) }
            )

            PermissionRow(
                isGranted: permissionsManager.isAccessibilityPermissionGranted,
                title: "Accessibility Access",
                description: "Required for global keyboard shortcuts",
                action: { permissionsManager.openSystemPreferences(for: .accessibility) }
            )

            Spacer()
        }
        .padding()
    }
}

struct PermissionRow: View {
    let isGranted: Bool
    let title: String
    let description: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isGranted ? .green : .red)

                Text(title)
                    .font(.headline)

                Spacer()

                if !isGranted {
                    Button("Grant Access") {
                        action()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Text(description)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}

struct RecordingRow: View {
    let recording: Recording
    @StateObject private var audioRecorder = AudioRecorder.shared
    @StateObject private var recordingStore = RecordingStore.shared
    @State private var showTranscription = false
    @State private var isHovered = false

    private var isPlaying: Bool {
        audioRecorder.isPlaying && audioRecorder.currentlyPlayingURL == recording.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TranscriptionView(
                transcribedText: recording.transcription, isExpanded: $showTranscription
            )
            .padding(.horizontal, 4)
            .padding(.top, 8)

            Divider()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.timestamp, style: .date)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text(recording.timestamp, style: .time)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 16) {
                    if isHovered || isPlaying {
                        Button(action: {
                            if isPlaying {
                                audioRecorder.stopPlaying()
                            } else {
                                audioRecorder.playRecording(url: recording.url)
                            }
                        }) {
                            Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(isPlaying ? .red : .accentColor)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                recording.transcription, forType: .string
                            )
                        }) {
                            Image(systemName: "doc.on.doc.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy entire text")

                        Button(action: {
                            if isPlaying {
                                audioRecorder.stopPlaying()
                            }
                            withAnimation(.easeInOut(duration: 0.3)) {
                                recordingStore.deleteRecording(recording)
                            }
                        }) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .padding(.vertical, 4)
        .transition(.scale.combined(with: .opacity))
    }
}

struct TranscriptionView: View {
    let transcribedText: String
    @Binding var isExpanded: Bool

    private var lines: [String] {
        transcribedText.components(separatedBy: .newlines)
    }

    private var hasMoreLines: Bool {
        !transcribedText.isEmpty && transcribedText.count > 150
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if isExpanded {
                    TextEditor(text: .constant(transcribedText))
                        .font(.body)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 100, maxHeight: 200)
                        .scrollContentBackground(.hidden)
                } else {
                    Text(transcribedText)
                        .font(.body)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if hasMoreLines {
                                isExpanded.toggle()
                            }
                        }
                }
            }
            .padding(8)

            if hasMoreLines {
                Button(action: { isExpanded.toggle() }) {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Show less" : "Show more")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .foregroundColor(.blue)
                    .font(.footnote)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
