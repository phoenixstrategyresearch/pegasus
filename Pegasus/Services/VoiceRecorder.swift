import Foundation
import AVFoundation

/// Records audio from the microphone and saves as WAV files for whisper.cpp processing.
class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = VoiceRecorder()

    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingURL: URL?

    /// Path to the last recorded WAV file (16kHz mono 16-bit PCM).
    var lastRecordingPath: String? { recordingURL?.path }

    /// Start recording from the microphone.
    func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            NSLog("[VoiceRecorder] Failed to configure audio session: %@", error.localizedDescription)
            return
        }

        let tmpDir = NSTemporaryDirectory()
        let url = URL(fileURLWithPath: tmpDir).appendingPathComponent("pegasus_voice_\(Int(Date().timeIntervalSince1970)).wav")
        recordingURL = url

        // Record at 16kHz mono 16-bit PCM — exactly what whisper.cpp wants
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.delegate = self
            recorder?.record()
            isRecording = true
            recordingDuration = 0

            // Update duration every 0.5s
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.recordingDuration = self?.recorder?.currentTime ?? 0
            }

            NSLog("[VoiceRecorder] Recording started: %@", url.path)
        } catch {
            NSLog("[VoiceRecorder] Failed to start recording: %@", error.localizedDescription)
        }
    }

    /// Stop recording and return the path to the WAV file.
    func stopRecording() -> String? {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false

        NSLog("[VoiceRecorder] Recording stopped (%.1fs)", recordingDuration)
        return recordingURL?.path
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            NSLog("[VoiceRecorder] Recording finished unsuccessfully")
        }
    }

    /// Convert an audio file to 16kHz mono WAV using AVFoundation.
    /// Use this to prepare audio files not recorded by VoiceRecorder.
    static func convertTo16kHz(inputPath: String, completion: @escaping (String?) -> Void) {
        let inputURL = URL(fileURLWithPath: inputPath)
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pegasus_converted_\(Int(Date().timeIntervalSince1970)).wav")

        guard let inputFile = try? AVAudioFile(forReading: inputURL) else {
            NSLog("[VoiceRecorder] Cannot read input file: %@", inputPath)
            completion(nil)
            return
        }

        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

        guard let converter = AVAudioConverter(from: inputFile.processingFormat, to: outputFormat) else {
            NSLog("[VoiceRecorder] Cannot create converter")
            completion(nil)
            return
        }

        let frameCount = AVAudioFrameCount(inputFile.length)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: frameCount) else {
            completion(nil)
            return
        }

        do {
            try inputFile.read(into: inputBuffer)
        } catch {
            NSLog("[VoiceRecorder] Read error: %@", error.localizedDescription)
            completion(nil)
            return
        }

        let outputFrameCount = AVAudioFrameCount(Double(frameCount) * 16000.0 / inputFile.processingFormat.sampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            completion(nil)
            return
        }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, status in
            status.pointee = .haveData
            return inputBuffer
        }

        if let error {
            NSLog("[VoiceRecorder] Conversion error: %@", error.localizedDescription)
            completion(nil)
            return
        }

        do {
            let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputFormat.settings)
            try outputFile.write(from: outputBuffer)
            NSLog("[VoiceRecorder] Converted to 16kHz: %@", outputURL.path)
            completion(outputURL.path)
        } catch {
            NSLog("[VoiceRecorder] Write error: %@", error.localizedDescription)
            completion(nil)
        }
    }
}
