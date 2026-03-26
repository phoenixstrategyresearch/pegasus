import Foundation
import AVFoundation

/// On-device speech-to-text engine using whisper.cpp with Metal acceleration.
/// Transcribes audio files into text entirely offline.
class WhisperEngine {
    static let shared = WhisperEngine()

    private var ctx: OpaquePointer?
    private let queue = DispatchQueue(label: "com.pegasus.whisper", qos: .userInitiated)
    private(set) var isLoaded = false
    private(set) var modelName = ""

    /// Load a whisper GGUF model from the given path.
    func load(path: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.doUnload()

            NSLog("[Whisper] Loading model: %@", (path as NSString).lastPathComponent)

            var params = whisper_context_default_params()
            params.use_gpu = true
            params.flash_attn = true

            guard let context = whisper_init_from_file_with_params(path, params) else {
                NSLog("[Whisper] Failed to load model")
                return
            }

            self.ctx = context
            self.isLoaded = true
            self.modelName = (path as NSString).lastPathComponent
            NSLog("[Whisper] Model loaded successfully: %@", self.modelName)
        }
    }

    /// Load the bundled tiny model from app resources.
    func loadBundledModel() {
        guard let path = Bundle.main.path(forResource: "ggml-tiny", ofType: "bin") else {
            NSLog("[Whisper] Bundled model ggml-tiny.bin not found in bundle")
            return
        }
        load(path: path)
    }

    func unload() {
        queue.async { [weak self] in
            self?.doUnload()
        }
    }

    private func doUnload() {
        if let c = ctx {
            whisper_free(c)
        }
        ctx = nil
        isLoaded = false
        modelName = ""
    }

    deinit {
        doUnload()
    }

    /// Transcribe a WAV file at the given path. Returns transcribed text.
    /// The WAV must be 16kHz mono 16-bit PCM (use VoiceRecorder which records in this format).
    func transcribe(wavPath: String, language: String = "auto") -> String {
        guard isLoaded, let ctx else {
            return "[Whisper not loaded]"
        }

        guard let samples = loadWAVSamples(path: wavPath) else {
            return "[Error: Could not read WAV file at \(wavPath)]"
        }

        let durationSec = Float(samples.count) / 16000.0
        NSLog("[Whisper] Transcribing %d samples (%.1fs of audio)", samples.count, durationSec)

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        // Configure language
        if language != "auto" {
            params.language = (language as NSString).utf8String
        }

        // Performance settings for iPhone
        let cpuCount = ProcessInfo.processInfo.processorCount
        params.n_threads = Int32(max(cpuCount - 1, 1))
        params.translate = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_realtime = false
        params.print_special = false
        params.no_context = true
        params.single_segment = false

        let startTime = CFAbsoluteTimeGetCurrent()

        let result = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        NSLog("[Whisper] Transcription completed in %.2fs (%.1fx realtime)", elapsed, Double(durationSec) / elapsed)

        guard result == 0 else {
            return "[Whisper: transcription failed with code \(result)]"
        }

        var text = ""
        let nSegments = whisper_full_n_segments(ctx)
        for i in 0..<nSegments {
            if let seg = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: seg)
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("[Whisper] Result: %@", String(trimmed.prefix(200)))
        return trimmed
    }

    /// Synchronous transcribe on the whisper queue. Use from background threads.
    func transcribeSync(wavPath: String, language: String = "auto") -> String {
        var result = ""
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            result = self?.transcribe(wavPath: wavPath, language: language) ?? "[Whisper not available]"
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 120)
        return result
    }

    /// Load an audio file and return Float32 PCM samples at 16kHz mono, normalized to [-1, 1].
    /// Uses AVAudioFile which handles WAV/CAF/any format AVFoundation supports.
    private func loadWAVSamples(path: String) -> [Float]? {
        let url = URL(fileURLWithPath: path)

        guard let audioFile = try? AVAudioFile(forReading: url) else {
            NSLog("[Whisper] Cannot open audio file: %@", path)
            return nil
        }

        let srcFormat = audioFile.processingFormat
        let srcFrames = AVAudioFrameCount(audioFile.length)
        NSLog("[Whisper] Audio: %.0f Hz, %d ch, %d frames", srcFormat.sampleRate, srcFormat.channelCount, srcFrames)

        // Target format: 16kHz mono Float32 (what whisper.cpp expects)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            NSLog("[Whisper] Cannot create target format")
            return nil
        }

        // If already 16kHz mono, read directly
        if Int(srcFormat.sampleRate) == 16000 && srcFormat.channelCount == 1 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: srcFrames) else { return nil }
            do {
                try audioFile.read(into: buffer)
            } catch {
                NSLog("[Whisper] Read error: %@", error.localizedDescription)
                return nil
            }

            // Convert to Float32 if needed
            if srcFormat.commonFormat == .pcmFormatFloat32 {
                guard let floatData = buffer.floatChannelData else { return nil }
                return Array(UnsafeBufferPointer(start: floatData[0], count: Int(buffer.frameLength)))
            }

            // For Int16 source, convert via converter
            guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else { return nil }
            let outFrames = srcFrames
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return nil }
            var error: NSError?
            converter.convert(to: outBuffer, error: &error) { _, status in
                status.pointee = .haveData
                return buffer
            }
            if let error { NSLog("[Whisper] Convert error: %@", error.localizedDescription); return nil }
            guard let floatData = outBuffer.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: floatData[0], count: Int(outBuffer.frameLength)))
        }

        // Need sample rate / channel conversion
        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            NSLog("[Whisper] Cannot create converter")
            return nil
        }

        // Read source into buffer
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: srcFrames) else { return nil }
        do {
            try audioFile.read(into: srcBuffer)
        } catch {
            NSLog("[Whisper] Read error: %@", error.localizedDescription)
            return nil
        }

        let outFrames = AVAudioFrameCount(Double(srcFrames) * 16000.0 / srcFormat.sampleRate)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return nil }

        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            status.pointee = .haveData
            return srcBuffer
        }
        if let error {
            NSLog("[Whisper] Conversion error: %@", error.localizedDescription)
            return nil
        }

        guard let floatData = outBuffer.floatChannelData else { return nil }
        let samples = Array(UnsafeBufferPointer(start: floatData[0], count: Int(outBuffer.frameLength)))
        NSLog("[Whisper] Loaded %d samples (%.1fs at 16kHz)", samples.count, Float(samples.count) / 16000.0)
        return samples
    }
}
