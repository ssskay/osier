import XCTest
@testable import OpenSuperWhisper

final class WhisperTests: XCTestCase {
    private var whisperManager: WhisperManager!
    private let modelPath = "/Users/user/dev/whisper.cpp/models/ggml-base.en.bin"
    private let testAudioURL = Bundle.module.url(forResource: "test_audio", withExtension: "wav")!
    
    override func setUpWithError() throws {
        // Initialization will be done in each test case
    }
    
    override func tearDownWithError() throws {
        whisperManager = nil
    }
    
    func testTranscription() async throws {
        // Initialize WhisperManager
        whisperManager = await WhisperManager(modelPath: modelPath)
        
        let audioURL = testAudioURL
        print("Starting transcription test with audio file: \(audioURL.path)")
        
        // Start transcription
        await whisperManager.transcribe(audioURL)
        
        // Wait for the transcription to complete with timeout
        let timeout = Date().addingTimeInterval(30) // 30 seconds timeout
        var transcriptionCompleted = false
        
        while await !transcriptionCompleted && Date() < timeout {
            if !await whisperManager.isTranscribing {
                transcriptionCompleted = true
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 second
            print("Waiting for transcription to complete...")
        }
        
        if !transcriptionCompleted {
            XCTFail("Transcription timed out after 30 seconds")
            return
        }
        
        // Check the result
        let transcription = await whisperManager.transcription
        print("Transcription result: \(transcription)")
        XCTAssertFalse(transcription.isEmpty, "Transcription result should not be empty")
    }
} 