//
//  WhisperContext.swift
//  OpenSuperWhisper
//
//  Created by user on 07.02.2025.
//

import Foundation

//  MARK: - C struct wrapper

public class WhisperContext {
    private var ctx: OpaquePointer?
    public var state: OpaquePointer?

    /// Initializes a new WhisperContext from a model file.
    ///
    /// - Parameters:
    ///   - modelURL: The URL to the Whisper model file.
    ///   - useGPU: Whether to use GPU if available (default: false)
    /// - Returns: A new `WhisperContext` instance, or `nil` if initialization fails.
    public init?(modelURL: URL, useGPU: Bool = false) {
        var cparams = whisper_context_default_params()
        cparams.use_gpu = useGPU
        ctx = whisper_init_from_file_with_params(modelURL.path, cparams)
        if ctx == nil { return nil }
        state = whisper_init_state(ctx)
        if state == nil {
            whisper_free(ctx)
            return nil
        }
    }

    deinit {
        whisper_free_state(state)
        whisper_free(ctx)
    }

    /// Get timings
    public func getTimings() -> whisper_timings {
        return whisper_get_timings(ctx).pointee
    }

    /// Reset timings
    public func resetTimings() {
        whisper_reset_timings(ctx)
    }

    // MARK: - Dunction defination

    /// Processes audio data and returns the transcribed text.
    ///
    /// - Parameters:
    ///   - samples: An array of audio samples in float32 format.
    ///   - params: A `WhisperFullParams` struct configuring the transcription process.
    /// - Returns: The transcribed text as a single string, or `nil` if processing fails.
    public func processAudio(samples: [Float], params: whisper_full_params) -> String? {
        let result = whisper_full_with_state(ctx, state, params, samples, Int32(samples.count))
        
        guard result == 0 else {
            print("Failed to process audio")
            return nil
        }
        
        let nSegments = whisper_full_n_segments_from_state(state)
        var transcribedText = ""
        
        for i in 0..<nSegments {
            if let text = whisper_full_get_segment_text_from_state(state, i) {
                transcribedText += String(cString: text)
            }
        }
        
        return transcribedText
    }

    /// Retrieves the number of text segments generated from the last processing.
    ///
    /// - Returns: The number of text segments.
    public func getNumberOfSegments() -> Int {
        return Int(whisper_full_n_segments_from_state(state))
    }

    /// Retrieves the transcribed text for a specific segment.
    ///
    /// - Parameter segmentIndex: The index of the segment.
    /// - Returns: The transcribed text for the segment, or `nil` if the index is invalid.
    public func getTextForSegment(segmentIndex: Int) -> String? {
        guard segmentIndex < getNumberOfSegments() else { return nil }

        if let text = whisper_full_get_segment_text_from_state(state, Int32(segmentIndex)) {
            return String(cString: text)
        }

        return nil
    }

    /// Retrieves the start timestamp for a specific segment.
    ///
    /// - Parameter segmentIndex: The index of the segment.
    /// - Returns: The start timestamp of the segment in milliseconds, or nil if the index is invalid.
    public func getStartTimeForSegment(segmentIndex: Int) -> Int64? {
        guard segmentIndex < getNumberOfSegments() else { return nil }
        return whisper_full_get_segment_t0_from_state(state, Int32(segmentIndex))
    }

    /// Retrieves the end timestamp for a specific segment.
    ///
    /// - Parameter segmentIndex: The index of the segment.
    /// - Returns: The end timestamp of the segment in milliseconds, or nil if the index is invalid.
    public func getEndTimeForSegment(segmentIndex: Int) -> Int64? {
        guard segmentIndex < getNumberOfSegments() else { return nil }
        return whisper_full_get_segment_t1_from_state(state, Int32(segmentIndex))
    }

    /// Retrieves detailed information about each segment, including start time, end time, and text.
    ///
    /// - Returns: An array of `(startTime: Int64, endTime: Int64, text: String)` tuples,
    ///   where `startTime` and `endTime` are in milliseconds, and `text` is the transcribed text for the segment.
    ///   Returns an empty array if no segments are available or if an error occurs.
    public func getAllSegmentDetails() -> [(startTime: Int64, endTime: Int64, text: String)] {
        let nSegments = getNumberOfSegments()
        var segments: [(startTime: Int64, endTime: Int64, text: String)] = []

        for i in 0..<nSegments {
            guard let startTime = getStartTimeForSegment(segmentIndex: i),
                  let endTime = getEndTimeForSegment(segmentIndex: i),
                  let text = getTextForSegment(segmentIndex: i)
            else {
                continue // Skip if any data is missing for the segment
            }
            segments.append((startTime: startTime, endTime: endTime, text: text))
        }

        return segments
    }

    // MARK: - Static defination

    /// Converts an array of audio data from URL to float samples.
    /// - Parameters:
    ///    - fileURL: URL path
    /// - Returns: PCM samples
    public static func convertAudioFileToPCM(fileURL: URL) -> [Float]? {
        let fileManager = FileManager.default
        
        // Check if the file exists
        guard fileManager.fileExists(atPath: fileURL.path) else {
            print("Error: File does not exist at \(fileURL.path)")
            return nil
        }
        
        // Check if the file is readable
        guard fileManager.isReadableFile(atPath: fileURL.path) else {
            print("Error: File is not readable at \(fileURL.path)")
            return nil
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            // Convert 16-bit PCM to float
            let samples = data.withUnsafeBytes {
                Array($0.bindMemory(to: Int16.self)).map { Float($0) / Float(Int16.max) }
            }
            return samples
        } catch {
            print("Error loading audio file: \(error)")
            return nil
        }
    }

    /// Gets a human-readable string describing the model type.
    public func getReadableModelType() -> String? {
        guard let modelTypeCStr = whisper_model_type_readable(ctx) else {
            return nil
        }
        return String(cString: modelTypeCStr)
    }
}

public extension WhisperContext {

    /// Example usage of the `WhisperContext` class.
    class func performExampleUsage() {
        let models = WhisperModelManager.shared.getAvailableModels()
        guard let modelURL = models.first else {
            print("No models available")
            return
        }

        guard let audioURL = Bundle.main.url(forResource: "jfk", withExtension: "wav") else {
            print("Audio file not found")
            return
        }

        // Initialize WhisperContext
        guard let context = WhisperContext(modelURL: modelURL, useGPU: false) else {
            print("Failed to initialize WhisperContext.")
            return
        }

        // Load and convert audio data
        guard let samples = WhisperContext.convertAudioFileToPCM(fileURL: audioURL) else {
            print("Failed to convert audio to PCM.")
            return
        }

        // Set up processing parameters
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.single_segment = true // For continuous transcription, set to false.
        params.no_timestamps = true

        // Process audio and get the transcribed text
        if let transcribedText = context.processAudio(samples: samples, params: params) {
            print("Transcribed Text: \(transcribedText)")

            // Get and print detailed segment information
            let segmentDetails = context.getAllSegmentDetails()
            if !segmentDetails.isEmpty {
                print("\nDetailed Segment Information:")
                for segment in segmentDetails {
                    print("Start Time: \(segment.startTime)ms, End Time: \(segment.endTime)ms, Text: \(segment.text)")
                }
            } else {
                print("No detailed segment information available.")
            }

            // Optional: Get additional information like model type
            if let modelType = context.getReadableModelType() {
                print("\nModel Type: \(modelType)")
            }

        } else {
            print("Transcription failed.")
        }
    }
}
