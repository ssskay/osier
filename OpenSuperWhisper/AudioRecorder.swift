import AVFoundation
import Foundation
// import whisper

class AudioRecorder: NSObject, ObservableObject {
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    @Published var isRecording = false
    @Published var recordings: [URL] = []
    
    override init() {
        super.init()
        loadRecordings()
    }
    
    func startRecording() {
        if isRecording {
            stopRecording()
            return
        }
        var cparams = whisper_context_default_params()
        print(cparams)
        
//        cparams.use_gpu = true
//        let ctx = whisper_init_from_file_with_params("", cparams)
//        whisper_pos()
        
        let audioFilename = getDocumentsDirectory().appendingPathComponent("\(Date().timeIntervalSince1970).m4a")
        
        let settings = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.record()
            isRecording = true
        } catch {
            print("Could not start recording: \(error)")
        }
    }
    
    func stopRecording() {
        audioRecorder?.stop()
        isRecording = false
        loadRecordings()
    }
    
    func playRecording(url: URL) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
        } catch {
            print("Could not play recording: \(error)")
        }
    }
    
    func deleteRecording(url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            loadRecordings()
        } catch {
            print("Could not delete recording: \(error)")
        }
    }
    
    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private func loadRecordings() {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: getDocumentsDirectory(),
                includingPropertiesForKeys: nil
            )
            recordings = urls.filter { $0.pathExtension == "m4a" }
                .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
        } catch {
            print("Could not load recordings: \(error)")
        }
    }
}
