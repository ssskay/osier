//
//  ContentView.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import AVFoundation
import SwiftUI


struct ContentView: View {
    @StateObject private var audioRecorder = AudioRecorder()
    @StateObject private var settings = Settings()
    @StateObject private var permissionsManager = PermissionsManager()
    @State private var isSettingsPresented = false
    
    var body: some View {
        NavigationView {
            VStack {
                if !permissionsManager.isMicrophonePermissionGranted || !permissionsManager.isAccessibilityPermissionGranted {
                    PermissionsView(permissionsManager: permissionsManager)
                } else {
                    List {
                        ForEach(audioRecorder.recordings, id: \.self) { recording in
                            RecordingRow(url: recording, audioRecorder: audioRecorder)
                        }
                    }
                    
                    HStack {
                        Text("Recording Shortcut: \(settings.recordingShortcut.description)")
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Button(action: {
                            isSettingsPresented.toggle()
                        }) {
                            Image(systemName: "gear")
                                .font(.title2)
                        }
                    }
                    .padding()
                    
                    Button(action: {
                        audioRecorder.startRecording()
                    }) {
                        Image(systemName: audioRecorder.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.system(size: 64))
                            .foregroundColor(audioRecorder.isRecording ? .red : .accentColor)
                    }
                    .padding()
                }
            }
            .navigationTitle("Audio Recorder")
            .sheet(isPresented: $isSettingsPresented) {
                SettingsView(settings: settings)
            }
        }
        .onAppear {
            settings.onShortcutTriggered = {
                audioRecorder.startRecording()
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
    let url: URL
    let audioRecorder: AudioRecorder
    
    var body: some View {
        HStack {
            Text(url.lastPathComponent)
            
            Spacer()
            
            Button(action: {
                audioRecorder.playRecording(url: url)
            }) {
                Image(systemName: "play.circle")
                    .font(.title2)
            }
            
            Button(action: {
                audioRecorder.deleteRecording(url: url)
            }) {
                Image(systemName: "trash")
                    .font(.title2)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @Environment(\.presentationMode) var presentationMode
    @State private var isRecordingNewShortcut = false
    
    var body: some View {
        NavigationView {
            Form {
                Section("Recording Shortcut") {
                    HStack {
                        Text(settings.recordingShortcut.description)
                            .font(.title2)
                        
                        Spacer()
                        
                        Button(isRecordingNewShortcut ? "Press any key..." : "Change") {
                            isRecordingNewShortcut.toggle()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
            .frame(minWidth: 300, minHeight: 200)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if isRecordingNewShortcut {
                    let shortcut = Settings.KeyboardShortcut(
                        keyCode: Int(event.keyCode),
                        modifiers: Int(event.modifierFlags.rawValue)
                    )
                    settings.recordingShortcut = shortcut
                    settings.saveSettings()
                    isRecordingNewShortcut = false
                    return nil
                }
                return event
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
