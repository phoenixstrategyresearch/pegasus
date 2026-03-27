import Foundation
import UIKit
import UserNotifications
import Contacts
import EventKit
import AVFoundation
import Vision
import NaturalLanguage
import AVFAudio
import CoreMotion
import MessageUI
import Messages
import CoreLocation
import CoreImage
import LocalAuthentication
import CryptoKit
// Translation framework used conditionally at runtime

/// Manages the embedded Python runtime and runs the Hermes agent directly.
/// All IPC is file-based — no HTTP servers or sockets needed (iOS sandbox safe).
class EmbeddedPython: ObservableObject {
    static let shared = EmbeddedPython()

    @Published var isReady = false
    @Published var isInitializing = false
    @Published var initStatus: String = ""
    @Published var error: String?

    // Cloud LLM settings (stored in UserDefaults, configured in SettingsView)
    static var useCloudLLM: Bool {
        UserDefaults.standard.bool(forKey: "useCloudLLM")
    }
    static var openAIAPIKey: String? {
        let key = UserDefaults.standard.string(forKey: "openaiAPIKey")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty ?? true) ? nil : key
    }
    static var openAIModel: String {
        UserDefaults.standard.string(forKey: "openaiModel") ?? "gpt-5.4"
    }
    static var cloudMaxTokens: Int {
        let val = UserDefaults.standard.double(forKey: "cloudMaxTokens")
        let tokens = val > 0 ? Int(val) : 16384
        // OpenAI models cap at 128000 completion tokens
        return min(tokens, 128000)
    }
    static var cloudReasoningEffort: String {
        UserDefaults.standard.string(forKey: "cloudReasoningEffort") ?? "none"
    }

    private var initialized = false
    private let pythonQueue = DispatchQueue(label: "com.pegasus.python")
    private var watcherThread: Thread?
    private var watcherRunning = false
    private var currentGenerationID: UUID?
    private var currentTimer: DispatchSourceTimer?

    // File paths for IPC between Swift and Python
    private var streamFile: String { NSTemporaryDirectory() + "pegasus_stream.jsonl" }
    private var logFile: String { NSTemporaryDirectory() + "pegasus_python.log" }
    static let swiftLogFile = NSTemporaryDirectory() + "pegasus_swift.log"

    /// Append a line to the Swift log (visible in Terminal tab).
    static func swiftLog(_ message: String) {
        let ts = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return f.string(from: Date())
        }()
        let line = "[\(ts)] \(message)\n"
        NSLog("%@", message)  // also goes to console
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: swiftLogFile) {
                if let fh = FileHandle(forWritingAtPath: swiftLogFile) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: swiftLogFile))
            }
        }
    }

    /// Read the Swift log file contents (for terminal view).
    func readSwiftLog() -> String {
        return (try? String(contentsOfFile: Self.swiftLogFile, encoding: .utf8)) ?? ""
    }
    private var llmRequestFile: String { NSTemporaryDirectory() + "pegasus_llm_request.json" }
    private var llmResponseFile: String { NSTemporaryDirectory() + "pegasus_llm_response.json" }
    // Legacy single-file paths (kept for backward compat)
    private var iosActionFile: String { NSTemporaryDirectory() + "pegasus_ios_action.json" }
    private var iosActionResultFile: String { NSTemporaryDirectory() + "pegasus_ios_action_result.json" }

    // iOS action watcher
    private var iosActionWatcherRunning = false

    /// Read the Python log file contents (for terminal view).
    func readPythonLog() -> String {
        return (try? String(contentsOfFile: logFile, encoding: .utf8)) ?? ""
    }

    /// Initialize Python and start the Hermes agent.
    func startAgent() {
        NSLog("[EmbeddedPython] startAgent() called — initialized=%d, isLoaded=%d", initialized ? 1 : 0, LocalLLMEngine.shared.isLoaded ? 1 : 0)

        guard !initialized else {
            NSLog("[EmbeddedPython] startAgent() skipped — already initialized")
            return
        }
        let cloudMode = Self.useCloudLLM && Self.openAIAPIKey != nil
        guard cloudMode || LocalLLMEngine.shared.isLoaded else {
            NSLog("[EmbeddedPython] startAgent() skipped — no model loaded and cloud mode off")
            DispatchQueue.main.async { self.error = "Load a model or enable Cloud LLM in Settings" }
            return
        }
        NSLog("[EmbeddedPython] cloudMode=%d", cloudMode ? 1 : 0)

        NSLog("[EmbeddedPython] Starting LLM watcher and Python init...")
        DispatchQueue.main.async {
            self.isInitializing = true
            self.initStatus = "Starting LLM watcher..."
        }

        // Start the LLM request watcher (replaces HTTP server)
        startLLMWatcher()
        // Start the iOS action watcher (handles send_message, open_url, etc.)
        startIOSActionWatcher()

        DispatchQueue.main.async {
            self.initStatus = "Initializing Python runtime..."
        }

        pythonQueue.asyncAfter(deadline: .now() + 0.5) {
            self.initializePython()
        }
    }

    func stopAgent() {
        stopLLMWatcher()
        initialized = false
        DispatchQueue.main.async { self.isReady = false }
    }

    /// Retry agent initialization (resets state and calls startAgent again).
    func retryInit() {
        NSLog("[EmbeddedPython] retryInit() called")
        initialized = false
        DispatchQueue.main.async {
            self.isReady = false
            self.error = nil
        }
        startAgent()
    }

    // MARK: - LLM Request Watcher (replaces HTTP server)

    /// Watches for LLM request files written by Python agent.
    /// Uses a dedicated Thread (not GCD timer) for reliable polling on iOS.
    private func startLLMWatcher() {
        // Clean up stale files
        try? FileManager.default.removeItem(atPath: llmRequestFile)
        try? FileManager.default.removeItem(atPath: llmResponseFile)

        let reqPath = llmRequestFile
        let resPath = llmResponseFile
        NSLog("[LLM-IPC] Watching for requests at: %@", reqPath)
        NSLog("[LLM-IPC] Will write responses to: %@", resPath)
        logToFile("[LLM-IPC] Watcher started, polling for: \(reqPath)")

        watcherRunning = true
        let thread = Thread { [weak self] in
            NSLog("[LLM-IPC] Watcher thread started")
            self?.logToFile("[LLM-IPC] Watcher thread running")
            var checkCount = 0
            while self?.watcherRunning == true {
                checkCount += 1
                if checkCount == 1 || checkCount % 200 == 0 {
                    // Log every ~20 seconds (200 × 0.1s)
                    let exists = FileManager.default.fileExists(atPath: reqPath)
                    NSLog("[LLM-IPC] Watcher check #%d, file exists: %d", checkCount, exists ? 1 : 0)
                    if checkCount == 1 {
                        self?.logToFile("[LLM-IPC] First watcher check, file exists: \(exists)")
                        // List tmp dir contents
                        let tmpDir = NSTemporaryDirectory()
                        if let files = try? FileManager.default.contentsOfDirectory(atPath: tmpDir) {
                            let pegasusFiles = files.filter { $0.contains("pegasus") }
                            self?.logToFile("[LLM-IPC] Pegasus files in tmp: \(pegasusFiles)")
                        }
                    }
                }
                self?.checkForLLMRequest()
                Thread.sleep(forTimeInterval: 0.1)
            }
            NSLog("[LLM-IPC] Watcher thread stopped")
        }
        thread.name = "com.pegasus.llm-watcher"
        thread.qualityOfService = .userInitiated
        thread.start()
        watcherThread = thread
        NSLog("[LLM-IPC] Watcher thread launched")
    }

    private func stopLLMWatcher() {
        watcherRunning = false
        watcherThread = nil
    }

    // MARK: - iOS Action Watcher

    /// Watches for iOS action requests from Python (send_message, open_url, etc.)
    private func startIOSActionWatcher() {
        iosActionWatcherRunning = true
        let thread = Thread { [weak self] in
            NSLog("[iOS-Action] Watcher thread started")
            while self?.iosActionWatcherRunning == true {
                self?.checkForIOSAction()
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
        thread.name = "com.pegasus.ios-action-watcher"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func checkForIOSAction() {
        let fm = FileManager.default
        let tmpDir = NSTemporaryDirectory()

        // Scan for any pending iOS action request files (supports parallel calls)
        guard let files = try? fm.contentsOfDirectory(atPath: tmpDir) else { return }
        let requestFiles = files.filter { $0.hasPrefix("pegasus_ios_action_") && $0.hasSuffix(".json") && !$0.contains("result") }

        for requestFileName in requestFiles {
            let requestPath = tmpDir + requestFileName
            guard let data = fm.contents(atPath: requestPath),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let action = request["action"] as? String,
                  let payload = request["payload"] as? [String: Any] else { continue }

            let reqId = request["id"] as? String ?? ""
            try? fm.removeItem(atPath: requestPath)

            processIOSAction(action: action, payload: payload, reqId: reqId)
        }

        // Also check legacy single-file path for backward compat
        guard fm.fileExists(atPath: iosActionFile),
              let data = fm.contents(atPath: iosActionFile),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = request["action"] as? String,
              let payload = request["payload"] as? [String: Any] else { return }

        let reqId = request["id"] as? String ?? ""
        try? fm.removeItem(atPath: iosActionFile)

        processIOSAction(action: action, payload: payload, reqId: reqId)
    }

    private func processIOSAction(action: String, payload: [String: Any], reqId: String) {
        NSLog("[iOS-Action] Received action: %@ (id: %@)", action, reqId)

        var result: [String: Any] = ["status": "ok"]

        switch action {

        // MARK: Messaging
        case "send_message":
            let to = payload["to"] as? String ?? ""
            let body = payload["body"] as? String ?? ""
            let attachments = payload["attachments"] as? [String] ?? []
            // Present in-app composer on main thread — non-blocking
            DispatchQueue.main.async {
                PegasusMessageSender.shared.presentAndAutoSend(to: to, body: body, attachmentPaths: attachments)
            }
            result = ["status": "sent", "to": to, "method": "in_app_composer", "attachments": attachments.count, "note": "Message sent successfully. Do NOT call open_url or any other tool."]

        case "send_email":
            let to = payload["to"] as? String ?? ""
            let subject = (payload["subject"] as? String ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let body = (payload["body"] as? String ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "mailto:\(to)?subject=\(subject)&body=\(body)") {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
                result = ["status": "opened_composer", "to": to]
            } else {
                result = ["error": "Invalid email"]
            }

        case "make_call":
            let number = payload["number"] as? String ?? ""
            if let url = URL(string: "tel:\(number)") {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
                result = ["status": "calling", "number": number]
            } else {
                result = ["error": "Invalid number"]
            }

        case "facetime":
            let contact = payload["contact"] as? String ?? ""
            let video = payload["video"] as? Bool ?? true
            let scheme = video ? "facetime" : "facetime-audio"
            if let url = URL(string: "\(scheme):\(contact)") {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
                result = ["status": "calling", "contact": contact, "video": video]
            } else {
                result = ["error": "Invalid contact"]
            }

        // MARK: URLs & Apps
        case "open_url":
            let urlString = payload["url"] as? String ?? ""
            if let url = URL(string: urlString) {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
                result = ["status": "opened", "url": urlString]
            } else {
                result = ["error": "Invalid URL"]
            }

        case "open_maps":
            let query = (payload["query"] as? String ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "maps://?q=\(query)") {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
                result = ["status": "opened_maps", "query": payload["query"] as? String ?? ""]
            }

        case "open_settings":
            if let url = URL(string: UIApplication.openSettingsURLString) {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
                result = ["status": "opened_settings"]
            }

        case "run_shortcut":
            let name = (payload["name"] as? String ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "shortcuts://run-shortcut?name=\(name)") {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
                result = ["status": "running_shortcut", "name": payload["name"] as? String ?? ""]
            }

        // MARK: Notifications & Alarms
        case "notify":
            let title = payload["title"] as? String ?? "Pegasus"
            let body = payload["body"] as? String ?? ""
            let delay = payload["delay"] as? Int ?? 0
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let trigger = delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(delay), repeats: false) : nil
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(req) { error in
                if let error { NSLog("[iOS-Action] Notification error: %@", error.localizedDescription) }
            }
            result = ["status": "scheduled", "title": title, "delay": delay]

        case "set_alarm":
            let hour = payload["hour"] as? Int ?? 7
            let minute = payload["minute"] as? Int ?? 0
            let label = (payload["label"] as? String ?? "Pegasus Alarm").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "clock-alarm://alarm?hour=\(hour)&minute=\(minute)&label=\(label)") {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
                result = ["status": "opened_clock", "time": "\(hour):\(String(format: "%02d", minute))"]
            }

        case "set_timer":
            let seconds = payload["seconds"] as? Int ?? 60
            if let url = URL(string: "clock-timer://timer?seconds=\(seconds)") {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
                result = ["status": "opened_timer", "seconds": seconds]
            }

        // MARK: Clipboard
        case "clipboard":
            let clipAction = payload["action"] as? String ?? "get"
            if clipAction == "set" {
                let text = payload["text"] as? String ?? ""
                DispatchQueue.main.async { UIPasteboard.general.string = text }
                result = ["status": "copied", "length": text.count]
            } else {
                let text = UIPasteboard.general.string ?? ""
                result = ["status": "ok", "text": String(text.prefix(5000))]
            }

        // MARK: Contacts
        case "read_contacts":
            let search = payload["search"] as? String ?? ""
            result = readContacts(search: search)

        // MARK: Calendar
        case "read_calendar":
            let days = payload["days"] as? Int ?? 7
            result = readCalendar(days: days)

        // MARK: Reminders
        case "read_reminders":
            let listName = payload["list"] as? String ?? ""
            result = readReminders(listName: listName)

        case "create_reminder":
            let title = payload["title"] as? String ?? ""
            let listName = payload["list"] as? String ?? ""
            result = createReminder(title: title, listName: listName)

        // MARK: Device Info
        case "get_battery":
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            let stateRaw = UIDevice.current.batteryState
            let state: String
            switch stateRaw {
            case .charging: state = "charging"
            case .full: state = "full"
            case .unplugged: state = "unplugged"
            default: state = "unknown"
            }
            result = ["level": Int(level * 100), "state": state]

        case "get_device_info":
            let device = UIDevice.current
            let processInfo = ProcessInfo.processInfo
            var storage: [String: Any] = [:]
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
                if let total = attrs[.systemSize] as? Int64 { storage["total_gb"] = Int(total / 1_073_741_824) }
                if let free = attrs[.systemFreeSize] as? Int64 { storage["free_gb"] = Int(free / 1_073_741_824) }
            }
            result = [
                "model": device.model,
                "name": device.name,
                "system": "\(device.systemName) \(device.systemVersion)",
                "ram_gb": Int(processInfo.physicalMemory / 1_073_741_824),
                "processors": processInfo.activeProcessorCount,
                "storage": storage
            ]

        // MARK: Screen & Appearance
        case "get_screen_info":
            DispatchQueue.main.sync {
                let screen = UIScreen.main
                result = [
                    "width": Int(screen.bounds.width),
                    "height": Int(screen.bounds.height),
                    "scale": screen.scale,
                    "brightness": screen.brightness
                ]
            }

        case "set_brightness":
            let level = payload["level"] as? Double ?? 0.5
            DispatchQueue.main.async { UIScreen.main.brightness = CGFloat(level) }
            result = ["status": "ok", "brightness": level]

        case "flashlight":
            let on = payload["on"] as? Bool ?? true
            toggleFlashlight(on: on)
            result = ["status": "ok", "flashlight": on]

        // MARK: Haptics
        case "haptic":
            let style = payload["style"] as? String ?? "medium"
            DispatchQueue.main.async {
                switch style {
                case "light": UIImpactFeedbackGenerator(style: .light).impactOccurred()
                case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
                case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
                case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
                default: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
            result = ["status": "ok", "style": style]

        // MARK: Share
        case "share":
            let text = payload["text"] as? String ?? ""
            let urlStr = payload["url"] as? String
            var items: [Any] = [text]
            if let u = urlStr, let url = URL(string: u) { items.append(url) }
            DispatchQueue.main.async {
                let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let root = scene.windows.first?.rootViewController {
                    root.present(vc, animated: true)
                }
            }
            result = ["status": "share_sheet_opened"]

        // MARK: App Store / Music
        case "open_app_store":
            let appId = payload["app_id"] as? String ?? ""
            if let url = URL(string: "itms-apps://apple.com/app/id\(appId)") {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
                result = ["status": "opened"]
            }

        case "play_music":
            let query = (payload["query"] as? String ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "music://music.apple.com/search?term=\(query)") {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
                result = ["status": "opened_music"]
            }

        // MARK: OCR — Read text from images
        case "ocr_image":
            let imagePath = payload["path"] as? String ?? ""
            result = performOCR(imagePath: imagePath)

        // MARK: TTS — Text-to-Speech
        case "speak":
            let text = payload["text"] as? String ?? ""
            let rate = payload["rate"] as? Double ?? 0.5
            let language = payload["language"] as? String ?? "en-US"
            performTTS(text: text, rate: Float(rate), language: language)
            result = ["status": "speaking", "length": text.count]

        case "stop_speaking":
            stopTTS()
            result = ["status": "stopped"]

        // MARK: Voice Recording
        case "start_recording":
            VoiceRecorder.shared.startRecording()
            result = ["status": "recording"]

        case "stop_recording":
            if let path = VoiceRecorder.shared.stopRecording() {
                result = ["status": "stopped", "path": path, "duration": VoiceRecorder.shared.recordingDuration]
            } else {
                result = ["error": "No recording in progress"]
            }

        // MARK: Speech-to-Text (Whisper)
        case "transcribe":
            let audioPath = payload["path"] as? String ?? ""
            let language = payload["language"] as? String ?? "auto"
            if audioPath.isEmpty {
                result = ["error": "No audio file path provided"]
            } else {
                let text = WhisperEngine.shared.transcribe(wavPath: audioPath, language: language)
                result = ["status": "ok", "text": text]
            }

        // MARK: Embeddings — Generate text embeddings using NLEmbedding
        case "embed_text":
            let text = payload["text"] as? String ?? ""
            let texts = payload["texts"] as? [String]
            result = generateEmbeddings(text: text, texts: texts)

        // MARK: Semantic Search — Find similar text using NLEmbedding
        case "semantic_distance":
            let text1 = payload["text1"] as? String ?? ""
            let text2 = payload["text2"] as? String ?? ""
            result = semanticDistance(text1: text1, text2: text2)

        // MARK: CoreMotion — Device Motion
        case "get_motion":
            result = getMotionData()

        case "get_steps":
            let days = payload["days"] as? Int ?? 1
            result = getStepData(days: days)

        case "get_activity":
            result = getCurrentActivity()

        // MARK: CoreLocation — Real GPS
        case "get_location":
            let fetcher = LocationFetcher()
            let loc = fetcher.fetchLocation(timeout: 10)
            result = loc

        // MARK: CoreImage — QR/Barcode Scanning
        case "scan_qr":
            let path = payload["path"] as? String ?? ""
            guard !path.isEmpty, let image = CIImage(contentsOf: URL(fileURLWithPath: path)) else {
                result = ["error": "Could not load image at path"]
                break
            }
            let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            let features = detector?.features(in: image) ?? []
            let codes = features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            result = ["status": "ok", "codes": codes, "count": codes.count]

        // MARK: LocalAuthentication — Face ID / Touch ID
        case "authenticate":
            let reason = payload["reason"] as? String ?? "Authenticate with Pegasus"
            let context = LAContext()
            var authError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else {
                result = ["error": "Biometrics not available: \(authError?.localizedDescription ?? "unknown")"]
                break
            }
            let sem = DispatchSemaphore(value: 0)
            var authResult: [String: Any] = [:]
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, error in
                if success {
                    authResult = ["status": "ok", "authenticated": true]
                } else {
                    authResult = ["status": "failed", "authenticated": false, "error": error?.localizedDescription ?? "unknown"]
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 30)
            result = authResult

        // MARK: CryptoKit — AES-GCM Encrypt/Decrypt
        case "encrypt":
            let text = payload["text"] as? String ?? ""
            let password = payload["password"] as? String ?? ""
            guard !text.isEmpty, !password.isEmpty else {
                result = ["error": "text and password are required"]
                break
            }
            let key = deriveKey(from: password)
            guard let data = text.data(using: .utf8),
                  let sealed = try? AES.GCM.seal(data, using: key) else {
                result = ["error": "Encryption failed"]
                break
            }
            result = ["status": "ok", "ciphertext": sealed.combined!.base64EncodedString()]

        case "decrypt":
            let ciphertext = payload["ciphertext"] as? String ?? ""
            let password = payload["password"] as? String ?? ""
            guard !ciphertext.isEmpty, !password.isEmpty,
                  let combined = Data(base64Encoded: ciphertext) else {
                result = ["error": "ciphertext (base64) and password are required"]
                break
            }
            let key = deriveKey(from: password)
            do {
                let box = try AES.GCM.SealedBox(combined: combined)
                let decrypted = try AES.GCM.open(box, using: key)
                result = ["status": "ok", "text": String(data: decrypted, encoding: .utf8) ?? ""]
            } catch {
                result = ["error": "Decryption failed: \(error.localizedDescription)"]
            }

        // MARK: Translation
        case "translate":
            let text = payload["text"] as? String ?? ""
            let sourceLang = payload["source"] as? String ?? ""
            let targetLang = payload["target"] as? String ?? "en"
            // Detect source language if "auto"
            var detectedLang = sourceLang
            if sourceLang.isEmpty || sourceLang == "auto" {
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(text)
                detectedLang = recognizer.dominantLanguage?.rawValue ?? "unknown"
            }
            // Translation requires the Translation framework with SwiftUI context.
            // For now, return language detection result and suggest using the LLM for translation.
            result = [
                "detected_language": detectedLang,
                "text": text,
                "target": targetLang,
                "note": "On-device translation available via the LLM. Detected source language: \(detectedLang)."
            ]

        // MARK: Weather — Open Weather App
        case "get_weather":
            if let url = URL(string: "weather://") {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
                result = ["status": "opened_weather_app"]
            } else {
                result = ["error": "Could not open Weather app"]
            }

        // MARK: Calendar — Create Event
        case "create_event":
            let title = payload["title"] as? String ?? ""
            let startStr = payload["start"] as? String ?? ""
            let endStr = payload["end"] as? String ?? ""
            let location = payload["location"] as? String
            let notes = payload["notes"] as? String
            let store = EKEventStore()
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm"
            guard let startDate = df.date(from: startStr), let endDate = df.date(from: endStr) else {
                result = ["error": "Invalid date format. Use 'yyyy-MM-dd HH:mm'"]
                break
            }
            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = startDate
            event.endDate = endDate
            event.location = location
            event.notes = notes
            event.calendar = store.defaultCalendarForNewEvents
            do {
                try store.save(event, span: .thisEvent)
                result = ["status": "created", "title": title, "start": startStr, "end": endStr]
            } catch {
                result = ["error": "Failed to create event: \(error.localizedDescription)"]
            }

        // MARK: Reminders — Delete/Complete
        case "delete_reminder":
            let title = payload["title"] as? String ?? ""
            let store = EKEventStore()
            let predicate = store.predicateForReminders(in: nil)
            let sem = DispatchSemaphore(value: 0)
            var deleteResult: [String: Any] = ["error": "Reminder not found"]
            store.fetchReminders(matching: predicate) { reminders in
                if let match = reminders?.first(where: { ($0.title ?? "").lowercased() == title.lowercased() }) {
                    match.isCompleted = true
                    do {
                        try store.save(match, commit: true)
                        deleteResult = ["status": "completed", "title": title]
                    } catch {
                        deleteResult = ["error": "Failed: \(error.localizedDescription)"]
                    }
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 5)
            result = deleteResult

        // MARK: Contacts — Create Contact
        case "create_contact":
            let name = payload["name"] as? String ?? ""
            let phone = payload["phone"] as? String
            let email = payload["email"] as? String
            let contact = CNMutableContact()
            let parts = name.split(separator: " ", maxSplits: 1)
            contact.givenName = String(parts.first ?? "")
            if parts.count > 1 { contact.familyName = String(parts[1]) }
            if let phone = phone {
                contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))]
            }
            if let email = email {
                contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)]
            }
            let saveReq = CNSaveRequest()
            saveReq.add(contact, toContainerWithIdentifier: nil)
            do {
                try CNContactStore().execute(saveReq)
                result = ["status": "created", "name": name]
            } catch {
                result = ["error": "Failed to create contact: \(error.localizedDescription)"]
            }

        // MARK: Device Sensors — Brightness
        case "get_brightness_and_volume":
            var brightness: CGFloat = 0
            DispatchQueue.main.sync { brightness = UIScreen.main.brightness }
            result = ["status": "ok", "brightness": Double(brightness), "volume": "not_accessible_programmatically"]

        default:
            result = ["error": "Unknown action: \(action)"]
        }

        // Write result back for Python to read (use per-request file if ID present)
        let responseFile: String
        if !reqId.isEmpty {
            responseFile = NSTemporaryDirectory() + "pegasus_ios_action_result_\(reqId).json"
        } else {
            responseFile = iosActionResultFile
        }
        if let resultData = try? JSONSerialization.data(withJSONObject: result),
           let resultString = String(data: resultData, encoding: .utf8) {
            try? resultString.write(toFile: responseFile, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - iOS API Helpers

    private func readContacts(search: String) -> [String: Any] {
        let store = CNContactStore()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        var contacts: [[String: Any]] = []
        do {
            let predicate = search.isEmpty ? CNContact.predicateForContactsInContainer(withIdentifier: store.defaultContainerIdentifier()) : CNContact.predicateForContacts(matchingName: search)
            let results = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
            for c in results.prefix(50) {
                var entry: [String: Any] = [
                    "name": "\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)
                ]
                if let phone = c.phoneNumbers.first?.value.stringValue { entry["phone"] = phone }
                if let email = c.emailAddresses.first?.value as String? { entry["email"] = email }
                contacts.append(entry)
            }
            return ["status": "ok", "count": contacts.count, "contacts": contacts]
        } catch {
            return ["error": "Contacts access denied. Grant permission in Settings > Privacy > Contacts."]
        }
    }

    private func readCalendar(days: Int) -> [String: Any] {
        let store = EKEventStore()
        let calendars = store.calendars(for: .event)
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let events = store.events(matching: predicate)
        var items: [[String: Any]] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        for e in events.prefix(50) {
            items.append([
                "title": e.title ?? "",
                "start": df.string(from: e.startDate),
                "end": df.string(from: e.endDate),
                "location": e.location ?? "",
                "calendar": e.calendar.title
            ])
        }
        return ["status": "ok", "count": items.count, "events": items]
    }

    private func readReminders(listName: String) -> [String: Any] {
        let store = EKEventStore()
        let calendars = store.calendars(for: .reminder)
        let filtered = listName.isEmpty ? calendars : calendars.filter { $0.title.lowercased().contains(listName.lowercased()) }
        let predicate = store.predicateForReminders(in: filtered.isEmpty ? nil : filtered)
        var items: [[String: Any]] = []
        let semaphore = DispatchSemaphore(value: 0)
        store.fetchReminders(matching: predicate) { reminders in
            for r in (reminders ?? []).prefix(50) {
                items.append([
                    "title": r.title ?? "",
                    "completed": r.isCompleted,
                    "list": r.calendar.title,
                    "priority": r.priority
                ])
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return ["status": "ok", "count": items.count, "reminders": items]
    }

    private func createReminder(title: String, listName: String) -> [String: Any] {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        if !listName.isEmpty {
            if let cal = store.calendars(for: .reminder).first(where: { $0.title.lowercased() == listName.lowercased() }) {
                reminder.calendar = cal
            } else {
                reminder.calendar = store.defaultCalendarForNewReminders()
            }
        } else {
            reminder.calendar = store.defaultCalendarForNewReminders()
        }
        do {
            try store.save(reminder, commit: true)
            return ["status": "created", "title": title]
        } catch {
            return ["error": "Failed to create reminder: \(error.localizedDescription)"]
        }
    }

    // MARK: - OCR via VisionKit

    private func performOCR(imagePath: String) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: imagePath) else {
            return ["error": "Image file not found: \(imagePath)"]
        }

        guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath)),
              let image = UIImage(data: imageData),
              let cgImage = image.cgImage else {
            return ["error": "Could not load image"]
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ["error": "OCR failed: \(error.localizedDescription)"]
        }

        guard let observations = request.results else {
            return ["error": "No text recognized"]
        }

        var lines: [String] = []
        var fullText = ""
        for observation in observations {
            if let candidate = observation.topCandidates(1).first {
                lines.append(candidate.string)
                fullText += candidate.string + "\n"
            }
        }

        return [
            "status": "ok",
            "text": fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            "lines": lines,
            "line_count": lines.count
        ]
    }

    // MARK: - TTS via AVSpeechSynthesizer

    private var speechSynthesizer: AVSpeechSynthesizer?
    private lazy var motionManager: CMMotionManager = {
        let m = CMMotionManager()
        m.deviceMotionUpdateInterval = 0.1
        return m
    }()
    private lazy var pedometer = CMPedometer()
    private lazy var activityManager = CMMotionActivityManager()

    private func performTTS(text: String, rate: Float, language: String) {
        DispatchQueue.main.async { [weak self] in
            let synthesizer = AVSpeechSynthesizer()
            self?.speechSynthesizer = synthesizer

            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = rate
            utterance.voice = AVSpeechSynthesisVoice(language: language)
            utterance.pitchMultiplier = 1.0
            utterance.volume = 1.0

            synthesizer.speak(utterance)
        }
    }

    private func stopTTS() {
        DispatchQueue.main.async { [weak self] in
            self?.speechSynthesizer?.stopSpeaking(at: .immediate)
            self?.speechSynthesizer = nil
        }
    }

    // MARK: - Embeddings via NLEmbedding

    private func generateEmbeddings(text: String, texts: [String]?) -> [String: Any] {
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else {
            return ["error": "NLEmbedding not available for English"]
        }

        if let texts = texts {
            // Batch mode: generate embeddings for multiple texts
            var results: [[String: Any]] = []
            for t in texts.prefix(100) {
                if let vector = embedding.vector(for: t.lowercased()) {
                    results.append(["text": t, "vector": vector.prefix(50).map { $0 }])
                } else {
                    // For phrases/sentences, compute average of word embeddings
                    let words = t.lowercased().split(separator: " ").map(String.init)
                    var avgVector: [Double]?
                    var count = 0
                    for word in words {
                        if let v = embedding.vector(for: word) {
                            if avgVector == nil {
                                avgVector = Array(v)
                            } else {
                                for i in 0..<min(avgVector!.count, v.count) {
                                    avgVector![i] += v[i]
                                }
                            }
                            count += 1
                        }
                    }
                    if let avg = avgVector, count > 0 {
                        let normalized = avg.map { $0 / Double(count) }
                        results.append(["text": t, "vector": normalized.prefix(50).map { $0 }])
                    } else {
                        results.append(["text": t, "vector": []])
                    }
                }
            }
            return ["status": "ok", "embeddings": results, "dimension": embedding.dimension]
        } else {
            // Single text mode
            let words = text.lowercased().split(separator: " ").map(String.init)
            var avgVector: [Double]?
            var count = 0
            for word in words {
                if let v = embedding.vector(for: word) {
                    if avgVector == nil {
                        avgVector = Array(v)
                    } else {
                        for i in 0..<min(avgVector!.count, v.count) {
                            avgVector![i] += v[i]
                        }
                    }
                    count += 1
                }
            }
            if let avg = avgVector, count > 0 {
                let normalized = avg.map { $0 / Double(count) }
                return ["status": "ok", "vector": normalized.prefix(50).map { $0 }, "dimension": embedding.dimension]
            }
            return ["error": "Could not generate embedding for text"]
        }
    }

    private func semanticDistance(text1: String, text2: String) -> [String: Any] {
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else {
            return ["error": "NLEmbedding not available"]
        }

        let distance = embedding.distance(between: text1.lowercased(), and: text2.lowercased())
        let similarity = 1.0 - min(distance, 2.0) / 2.0 // Normalize to [0, 1]

        return [
            "status": "ok",
            "distance": distance,
            "similarity": similarity,
            "text1": text1,
            "text2": text2
        ]
    }

    private func toggleFlashlight(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    // MARK: - CoreMotion Helpers

    private func getMotionData() -> [String: Any] {
        guard motionManager.isDeviceMotionAvailable else {
            return ["error": "Device motion not available"]
        }
        let sem = DispatchSemaphore(value: 0)
        var motionResult: [String: Any] = ["error": "Timed out"]
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            self?.motionManager.stopDeviceMotionUpdates()
            guard let m = motion else {
                motionResult = ["error": error?.localizedDescription ?? "No motion data"]
                sem.signal()
                return
            }
            motionResult = [
                "status": "ok",
                "attitude": ["pitch": m.attitude.pitch, "roll": m.attitude.roll, "yaw": m.attitude.yaw],
                "user_acceleration": ["x": m.userAcceleration.x, "y": m.userAcceleration.y, "z": m.userAcceleration.z],
                "gravity": ["x": m.gravity.x, "y": m.gravity.y, "z": m.gravity.z]
            ]
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        return motionResult
    }

    private func getStepData(days: Int) -> [String: Any] {
        guard CMPedometer.isStepCountingAvailable() else {
            return ["error": "Step counting not available"]
        }
        let sem = DispatchSemaphore(value: 0)
        var stepResult: [String: Any] = ["error": "Timed out"]
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -max(days, 1), to: now)!
        pedometer.queryPedometerData(from: start, to: now) { data, error in
            guard let d = data else {
                stepResult = ["error": error?.localizedDescription ?? "No pedometer data"]
                sem.signal()
                return
            }
            stepResult = [
                "status": "ok",
                "steps": d.numberOfSteps.intValue,
                "distance_meters": d.distance?.doubleValue ?? 0,
                "floors_ascended": d.floorsAscended?.intValue ?? 0,
                "floors_descended": d.floorsDescended?.intValue ?? 0,
                "days": days
            ]
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        return stepResult
    }

    private func getCurrentActivity() -> [String: Any] {
        guard CMMotionActivityManager.isActivityAvailable() else {
            return ["error": "Activity recognition not available"]
        }
        let sem = DispatchSemaphore(value: 0)
        var actResult: [String: Any] = ["error": "Timed out"]
        let now = Date()
        let start = Calendar.current.date(byAdding: .minute, value: -5, to: now)!
        activityManager.queryActivityStarting(from: start, to: now, to: .main) { activities, error in
            guard let activity = activities?.last else {
                actResult = ["error": error?.localizedDescription ?? "No activity data"]
                sem.signal()
                return
            }
            var types: [String] = []
            if activity.walking { types.append("walking") }
            if activity.running { types.append("running") }
            if activity.automotive { types.append("driving") }
            if activity.cycling { types.append("cycling") }
            if activity.stationary { types.append("stationary") }
            if types.isEmpty { types.append("unknown") }
            actResult = [
                "status": "ok",
                "activities": types,
                "confidence": ["low", "medium", "high"][activity.confidence.rawValue]
            ]
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        return actResult
    }

    // MARK: - CryptoKit Helpers

    private func deriveKey(from password: String) -> SymmetricKey {
        let hash = SHA256.hash(data: Data(password.utf8))
        return SymmetricKey(data: hash)
    }

    /// Log a message to the Python log file (appears in Terminal view).
    private func logToFile(_ message: String) {
        let line = "[swift] \(message)\n"
        if let data = line.data(using: .utf8),
           let handle = FileHandle(forWritingAtPath: logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? line.write(toFile: logFile, atomically: false, encoding: .utf8)
        }
    }

    private func checkForLLMRequest() {
        let fm = FileManager.default
        // Skip .tmp files — Python writes to .tmp then renames atomically
        let tmpFile = llmRequestFile + ".tmp"
        if fm.fileExists(atPath: tmpFile) { return }
        guard fm.fileExists(atPath: llmRequestFile) else { return }

        NSLog("[LLM-IPC] Found request file!")
        logToFile("[LLM-IPC] Found request file at \(llmRequestFile)")

        // Small delay to ensure atomic rename is fully visible
        Thread.sleep(forTimeInterval: 0.05)

        // Read and remove request file
        guard let data = fm.contents(atPath: llmRequestFile) else {
            NSLog("[LLM-IPC] ERROR: Could not read request file")
            logToFile("[LLM-IPC] ERROR: Could not read request file")
            try? fm.removeItem(atPath: llmRequestFile)
            writeErrorResponse("Could not read LLM request file")
            return
        }

        // Try to parse JSON — retry once on failure (race condition safety)
        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[LLM-IPC] ERROR: JSON is not a dictionary (%d bytes)", data.count)
                logToFile("[LLM-IPC] ERROR: JSON is not a dictionary")
                try? fm.removeItem(atPath: llmRequestFile)
                writeErrorResponse("LLM request JSON is not a dictionary")
                return
            }
            json = parsed
        } catch {
            // First failure — wait and retry once in case file was mid-write
            NSLog("[LLM-IPC] JSON parse failed, retrying after 200ms... (%d bytes)", data.count)
            Thread.sleep(forTimeInterval: 0.2)
            if let retryData = fm.contents(atPath: llmRequestFile),
               let retryParsed = try? JSONSerialization.jsonObject(with: retryData) as? [String: Any] {
                NSLog("[LLM-IPC] Retry succeeded! (%d bytes)", retryData.count)
                json = retryParsed
            } else {
                NSLog("[LLM-IPC] ERROR: JSON parse failed after retry: %@ (%d bytes)", error.localizedDescription, data.count)
                let preview = String(data: data.prefix(500), encoding: .utf8) ?? "binary"
                logToFile("[LLM-IPC] ERROR: JSON parse failed: \(error.localizedDescription)\nPreview: \(preview)")
                try? fm.removeItem(atPath: llmRequestFile)
                writeErrorResponse("JSON parse failed on Swift side: \(error.localizedDescription)")
                return
            }
        }

        // Extract messages - handle both dict and mixed arrays
        let messagesRaw: [[String: Any]]
        if let msgs = json["messages"] as? [[String: Any]] {
            messagesRaw = msgs
        } else if let msgsAny = json["messages"] as? [Any] {
            // Some messages might have tool_calls that prevent simple cast
            messagesRaw = msgsAny.compactMap { $0 as? [String: Any] }
            if messagesRaw.isEmpty {
                NSLog("[LLM-IPC] ERROR: No valid messages in array of %d items", msgsAny.count)
                logToFile("[LLM-IPC] ERROR: messages array has \(msgsAny.count) items but none are dicts")
                try? fm.removeItem(atPath: llmRequestFile)
                writeErrorResponse("No valid messages in LLM request")
                return
            }
        } else {
            NSLog("[LLM-IPC] ERROR: No messages field in request (%d bytes)", data.count)
            logToFile("[LLM-IPC] ERROR: No messages field in request")
            try? fm.removeItem(atPath: llmRequestFile)
            writeErrorResponse("No messages field in LLM request")
            return
        }

        // Remove request file immediately so we don't process it twice
        try? fm.removeItem(atPath: llmRequestFile)

        NSLog("[LLM-IPC] Processing LLM request (%d messages)...", messagesRaw.count)
        logToFile("[LLM-IPC] Processing request (\(messagesRaw.count) messages)")
        let startTime = CFAbsoluteTimeGetCurrent()

        // Extract tools for Hermes prompt injection
        let tools = json["tools"] as? [[String: Any]]

        // CLOUD MODE: Forward request to OpenAI API (no Hermes injection needed)
        if Self.useCloudLLM, let apiKey = Self.openAIAPIKey {
            NSLog("[LLM-IPC] Cloud mode — forwarding to OpenAI API (%@)", Self.openAIModel)
            logToFile("[LLM-IPC] Cloud mode: forwarding to OpenAI (\(Self.openAIModel))")
            callOpenAI(requestJSON: json, apiKey: apiKey, startTime: startTime)
            return
        }

        // LOCAL MODE: Build messages with Hermes tool injection
        var messages: [(role: String, content: String)] = []
        for msg in messagesRaw {
            let role = msg["role"] as? String ?? "user"
            var content = msg["content"] as? String ?? ""

            if role == "system" && tools != nil && !tools!.isEmpty {
                content = injectToolSchemas(systemPrompt: content, tools: tools!)
            }

            messages.append((role: role, content: content))
        }

        let engine = LocalLLMEngine.shared
        guard engine.isLoaded else {
            logToFile("[LLM-IPC] ERROR: No model loaded")
            writeErrorResponse("No model loaded")
            return
        }

        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        NSLog("[LLM-IPC] Prompt: %d chars, %d messages", totalChars, messages.count)
        logToFile("[LLM-IPC] Starting inference: \(totalChars) chars, \(messages.count) messages")

        // Run inference synchronously on this thread
        var fullResponse = ""
        var tokenCount = 0
        let semaphore = DispatchSemaphore(value: 0)

        engine.chat(messages: messages, dispatchToMain: false, onToken: { [weak self] token in
            fullResponse += token
            tokenCount += 1
            if tokenCount == 1 {
                let prefillTime = CFAbsoluteTimeGetCurrent() - startTime
                NSLog("[LLM-IPC] First token after %.1fs", prefillTime)
                self?.logToFile("[LLM-IPC] First token after \(String(format: "%.1f", prefillTime))s")
            }
        }, onDone: { [weak self] in
            let totalTime = CFAbsoluteTimeGetCurrent() - startTime
            NSLog("[LLM-IPC] Done: %d tokens in %.1fs", tokenCount, totalTime)
            self?.logToFile("[LLM-IPC] Done: \(tokenCount) tokens in \(String(format: "%.1f", totalTime))s")
            semaphore.signal()
        })

        NSLog("[LLM-IPC] Waiting for inference to complete...")
        let waitResult = semaphore.wait(timeout: .now() + 600) // 10 minute max for inference
        if waitResult == .timedOut {
            NSLog("[LLM-IPC] ERROR: Inference timed out after 600s")
            logToFile("[LLM-IPC] ERROR: Inference timed out after 600s")
            LocalLLMEngine.shared.stopGenerating()
            writeErrorResponse("Inference timed out after 10 minutes")
            return
        }
        NSLog("[LLM-IPC] Inference complete, writing response...")

        // Log raw response for debugging
        NSLog("[LLM-IPC] Raw response (%d chars): %@", fullResponse.count, String(fullResponse.prefix(500)))
        logToFile("[LLM-IPC] Raw response: \(String(fullResponse.prefix(300)))")

        // Parse Hermes tool calls from the response
        let (textContent, toolCalls) = parseHermesToolCalls(fullResponse)

        // Build OpenAI-format response
        var message: [String: Any] = ["role": "assistant"]

        if !toolCalls.isEmpty {
            // Discard narration text when tool calls are present
            // Small models often narrate ("Let me search for that") before calling tools
            message["content"] = NSNull()
            var tcArray: [[String: Any]] = []
            for (i, tc) in toolCalls.enumerated() {
                tcArray.append([
                    "id": "call_\(i)_\(Int.random(in: 1000...9999))",
                    "type": "function",
                    "function": [
                        "name": tc.name,
                        "arguments": tc.arguments,
                    ]
                ])
            }
            message["tool_calls"] = tcArray
        } else {
            var clean = textContent
            for tag in ["<|im_end|>", "<|im_start|>"] {
                clean = clean.replacingOccurrences(of: tag, with: "")
            }
            // Strip think blocks
            while let openRange = clean.range(of: "<think>"),
                  let closeRange = clean.range(of: "</think>", range: openRange.upperBound..<clean.endIndex) {
                clean = String(clean[clean.startIndex..<openRange.lowerBound])
                    + String(clean[closeRange.upperBound...])
            }
            if let thinkEnd = clean.range(of: "</think>") {
                clean = String(clean[thinkEnd.upperBound...])
            }
            clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                clean = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                NSLog("[LLM-IPC] WARNING: cleaned response was empty, using raw response")
            }
            NSLog("[LLM-IPC] Final text response (%d chars): %@", clean.count, String(clean.prefix(200)))
            message["content"] = clean
        }

        let response: [String: Any] = [
            "id": "chatcmpl-\(UUID().uuidString.prefix(8))",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": "local-model",
            "choices": [
                [
                    "index": 0,
                    "message": message,
                    "finish_reason": toolCalls.isEmpty ? "stop" : "tool_calls",
                ]
            ],
            "usage": [
                "prompt_tokens": 0,
                "completion_tokens": tokenCount,
                "total_tokens": tokenCount,
            ]
        ]

        if let responseData = try? JSONSerialization.data(withJSONObject: response) {
            do {
                try responseData.write(to: URL(fileURLWithPath: llmResponseFile), options: .atomic)
                NSLog("[LLM-IPC] Response written (%d bytes)", responseData.count)
                logToFile("[LLM-IPC] Response written (\(responseData.count) bytes)")
            } catch {
                NSLog("[LLM-IPC] ERROR writing response: %@", error.localizedDescription)
                logToFile("[LLM-IPC] ERROR writing response: \(error)")
            }
        } else {
            logToFile("[LLM-IPC] ERROR: Failed to serialize response")
            writeErrorResponse("Failed to serialize response")
        }
    }

    // MARK: - OpenAI API Call

    /// Forward the Python agent's request to OpenAI API and write the response back.
    /// Called synchronously on the watcher thread.
    private func callOpenAI(requestJSON: [String: Any], apiKey: String, startTime: CFAbsoluteTime) {
        let model = Self.openAIModel
        let effort = Self.cloudReasoningEffort
        let useResponsesAPI = effort != "none" && model.hasPrefix("gpt-5")

        // Build the request body
        var body: [String: Any]
        let endpoint: String

        if useResponsesAPI {
            // Responses API — supports reasoning + tools together
            endpoint = "https://api.openai.com/v1/responses"
            body = buildResponsesAPIBody(from: requestJSON, model: model, effort: effort)
        } else {
            // Chat Completions API — standard path
            endpoint = "https://api.openai.com/v1/chat/completions"
            body = requestJSON
            body["model"] = model
            body.removeValue(forKey: "max_tokens")
            body["max_completion_tokens"] = Self.cloudMaxTokens
            if let tools = body["tools"] as? [[String: Any]], tools.isEmpty {
                body.removeValue(forKey: "tools")
                body.removeValue(forKey: "tool_choice")
            }
        }

        guard let url = URL(string: endpoint),
              let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            writeErrorResponse("Failed to build OpenAI request")
            return
        }

        let apiName = useResponsesAPI ? "Responses" : "ChatCompletions"
        NSLog("[LLM-IPC] OpenAI %@ request: %d bytes to %@ (effort=%@)", apiName, jsonData.count, model, effort)
        logToFile("[LLM-IPC] OpenAI \(apiName): \(jsonData.count) bytes to \(model) (effort=\(effort))")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData
        request.timeoutInterval = 600

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?

        URLSession.shared.dataTask(with: request) { data, httpResponse, error in
            responseData = data
            responseError = error
            if let httpResp = httpResponse as? HTTPURLResponse {
                NSLog("[LLM-IPC] OpenAI HTTP status: %d", httpResp.statusCode)
            }
            semaphore.signal()
        }.resume()

        let waitResult = semaphore.wait(timeout: .now() + 660)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        if waitResult == .timedOut {
            NSLog("[LLM-IPC] OpenAI request timed out after 660s")
            logToFile("[LLM-IPC] OpenAI request timed out after 660s")
            writeErrorResponse("OpenAI API request timed out")
            return
        }

        if let error = responseError {
            NSLog("[LLM-IPC] OpenAI error: %@", error.localizedDescription)
            logToFile("[LLM-IPC] OpenAI error: \(error.localizedDescription)")
            writeErrorResponse("OpenAI API error: \(error.localizedDescription)")
            return
        }

        guard let data = responseData else {
            writeErrorResponse("No response from OpenAI API")
            return
        }

        // Check for API error responses
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorObj = json["error"] as? [String: Any],
           let errorMsg = errorObj["message"] as? String {
            NSLog("[LLM-IPC] OpenAI API error: %@", errorMsg)
            logToFile("[LLM-IPC] OpenAI API error: \(errorMsg)")
            writeErrorResponse("OpenAI: \(errorMsg)")
            return
        }

        // Convert Responses API output to Chat Completions format (Python expects this)
        let outputData: Data
        if useResponsesAPI {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let converted = convertResponsesAPIToChatCompletions(json),
                  let convData = try? JSONSerialization.data(withJSONObject: converted) else {
                writeErrorResponse("Failed to parse Responses API output")
                return
            }
            outputData = convData
        } else {
            outputData = data
        }

        // Write response for Python to pick up
        do {
            let resURL = URL(fileURLWithPath: llmResponseFile)
            try outputData.write(to: resURL, options: .atomic)
            let verifySize = (try? FileManager.default.attributesOfItem(atPath: llmResponseFile)[.size] as? Int) ?? -1
            NSLog("[LLM-IPC] OpenAI response written (%d bytes, %.1fs, verified=%d)", outputData.count, elapsed, verifySize)
            logToFile("[LLM-IPC] OpenAI response written (\(outputData.count) bytes, \(String(format: "%.1f", elapsed))s, verified=\(verifySize))")
        } catch {
            NSLog("[LLM-IPC] ERROR writing OpenAI response: %@", error.localizedDescription)
            writeErrorResponse("Failed to write OpenAI response: \(error)")
        }
    }

    // MARK: - Responses API Helpers

    /// Build a Responses API request body from a Chat Completions-style request.
    private func buildResponsesAPIBody(from chatReq: [String: Any], model: String, effort: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_output_tokens": Self.cloudMaxTokens,
            "reasoning": ["effort": effort],
        ]

        // Convert messages to Responses API input format
        var input: [[String: Any]] = []
        if let messages = chatReq["messages"] as? [[String: Any]] {
            for msg in messages {
                let role = msg["role"] as? String ?? "user"
                let content = msg["content"] as? String ?? ""

                if role == "system" {
                    // Responses API uses "developer" instead of "system"
                    input.append(["role": "developer", "content": content])
                } else if role == "assistant" {
                    // Add assistant content if present
                    if !content.isEmpty {
                        input.append(["role": "assistant", "content": content])
                    }
                    // Convert tool_calls to function_call items
                    if let toolCalls = msg["tool_calls"] as? [[String: Any]] {
                        for tc in toolCalls {
                            let fn = tc["function"] as? [String: Any] ?? [:]
                            let callId = tc["id"] as? String ?? UUID().uuidString
                            input.append([
                                "type": "function_call",
                                "call_id": callId,
                                "name": fn["name"] as? String ?? "",
                                "arguments": fn["arguments"] as? String ?? "{}",
                            ])
                        }
                    }
                } else if role == "tool" {
                    // Convert tool result to function_call_output
                    let callId = msg["tool_call_id"] as? String ?? ""
                    input.append([
                        "type": "function_call_output",
                        "call_id": callId,
                        "output": content,
                    ])
                } else {
                    // user messages pass through
                    input.append(["role": role, "content": content])
                }
            }
        }
        body["input"] = input

        // Convert tools — Responses API uses same schema but slightly different wrapper
        if let tools = chatReq["tools"] as? [[String: Any]], !tools.isEmpty {
            var responsesTools: [[String: Any]] = []
            for tool in tools {
                if let fn = tool["function"] as? [String: Any] {
                    var rTool: [String: Any] = [
                        "type": "function",
                        "name": fn["name"] as? String ?? "",
                    ]
                    if let desc = fn["description"] as? String { rTool["description"] = desc }
                    if let params = fn["parameters"] { rTool["parameters"] = params }
                    responsesTools.append(rTool)
                }
            }
            body["tools"] = responsesTools
        }

        return body
    }

    /// Convert a Responses API response to Chat Completions format (for Python compatibility).
    private func convertResponsesAPIToChatCompletions(_ resp: [String: Any]) -> [String: Any]? {
        let output = resp["output"] as? [[String: Any]] ?? []

        var content = ""
        var toolCalls: [[String: Any]] = []

        for item in output {
            let itemType = item["type"] as? String ?? ""

            if itemType == "message" {
                // Extract text from content array
                if let contentArr = item["content"] as? [[String: Any]] {
                    for c in contentArr {
                        let cType = c["type"] as? String ?? ""
                        if cType == "output_text" || cType == "text" {
                            let text = c["text"] as? String ?? ""
                            content += text
                        }
                    }
                }
            } else if itemType == "function_call" {
                let tc: [String: Any] = [
                    "id": item["call_id"] as? String ?? UUID().uuidString,
                    "type": "function",
                    "function": [
                        "name": item["name"] as? String ?? "",
                        "arguments": item["arguments"] as? String ?? "{}",
                    ]
                ]
                toolCalls.append(tc)
            }
        }

        let finishReason = toolCalls.isEmpty ? "stop" : "tool_calls"
        var message: [String: Any] = ["role": "assistant", "content": content]
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls
        }

        return [
            "id": resp["id"] as? String ?? "resp-converted",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": Self.openAIModel,
            "choices": [[
                "index": 0,
                "message": message,
                "finish_reason": finishReason,
            ]]
        ]
    }

    private func writeErrorResponse(_ message: String) {
        let response: [String: Any] = [
            "id": "chatcmpl-error",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": "local-model",
            "choices": [
                [
                    "index": 0,
                    "message": ["role": "assistant", "content": "Error: \(message)"],
                    "finish_reason": "stop",
                ]
            ],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: response) {
            try? data.write(to: URL(fileURLWithPath: llmResponseFile), options: .atomic)
        }
    }

    // MARK: - Hermes Tool Call Parsing

    struct ToolCall {
        let name: String
        let arguments: String
    }

    private func parseHermesToolCalls(_ text: String) -> (String, [ToolCall]) {
        var toolCalls: [ToolCall] = []
        var textContent = text

        while let openRange = textContent.range(of: "<tool_call>"),
              let closeRange = textContent.range(of: "</tool_call>", range: openRange.upperBound..<textContent.endIndex) {

            let jsonStr = String(textContent[openRange.upperBound..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let data = jsonStr.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = obj["name"] as? String {
                let args = obj["arguments"] ?? [:]
                if let argsData = try? JSONSerialization.data(withJSONObject: args),
                   let argsStr = String(data: argsData, encoding: .utf8) {
                    toolCalls.append(ToolCall(name: name, arguments: argsStr))
                }
            }

            textContent = String(textContent[textContent.startIndex..<openRange.lowerBound])
                + String(textContent[closeRange.upperBound...])
        }

        textContent = textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return (textContent, toolCalls)
    }

    // MARK: - Hermes Tool Schema Injection

    private func injectToolSchemas(systemPrompt: String, tools: [[String: Any]]) -> String {
        // Use compact (non-prettyPrinted) JSON for tool schemas — saves tokens
        guard let toolsJSON = try? JSONSerialization.data(withJSONObject: tools, options: []),
              let toolsStr = String(data: toolsJSON, encoding: .utf8) else {
            return systemPrompt
        }

        // Note: no leading whitespace — raw string sent directly to model
        let hermesToolPrompt = """

You are an AI agent with tool-calling capabilities. You MUST use tools when the task requires them.

## Available Tools
<tools>
\(toolsStr)
</tools>

## How to Call Tools
To call a tool, output ONLY a JSON object inside <tool_call></tool_call> tags. Nothing else. No explanation before or after.

Example - searching the web:
<tool_call>
{"name": "web_search", "arguments": {"query": "latest news about topic"}}
</tool_call>

Example - fetching a webpage:
<tool_call>
{"name": "web_fetch", "arguments": {"url": "https://example.com"}}
</tool_call>

Example - reading a file:
<tool_call>
{"name": "file_read", "arguments": {"path": "notes.txt"}}
</tool_call>

## CRITICAL RULES

1. WHEN TO USE TOOLS (MANDATORY):
   - User asks to research, look up, search, or find information -> use web_search
   - User asks about current events, news, prices, weather, live data -> use web_search
   - User gives a URL or asks to visit/read/scrape a website -> use web_fetch
   - User asks to read, write, create, or edit files -> use file_read / file_write
   - User asks to save or recall something -> use memory_read / memory_write
   - User asks to run code or calculate something complex -> use python_exec
   - User asks to list files or check what's in the workspace -> use file_list

2. WHEN NOT TO USE TOOLS:
   - Simple greetings like "hi", "hello", "how are you"
   - Casual conversation and small talk
   - Questions you can answer confidently from training knowledge alone

3. FORMAT RULES:
   - Output the <tool_call> tags with ONLY the JSON inside. No text before, no text after.
   - Do NOT say "I'll search for that" or "Let me look that up" - just call the tool directly.
   - Do NOT narrate what tool you're using. Just call it silently.
   - After receiving a tool result, synthesize the information into a clear, helpful response.
   - Strip out any HTML tags, image URLs, or raw markup from your final response. Present clean text only.

4. RESPONSE QUALITY:
   - After getting web results, summarize the key information clearly.
   - Never dump raw HTML, URLs of images, or markdown image links in your response.
   - Present information in a clean, readable format.
   - If a web search returns no useful results, say so and try a different query.
"""

        return systemPrompt + "\n\n" + hermesToolPrompt
    }

    // MARK: - Direct Agent Calls (no HTTP)

    /// Run the Hermes agent with streaming events via file-based IPC.
    func runAgentStreaming(message: String, onEvent: @escaping (StreamEvent) -> Void) {
        NSLog("[EmbeddedPython] runAgentStreaming called, isReady=%d", isReady ? 1 : 0)
        guard isReady else {
            onEvent(.error("Python agent not ready"))
            return
        }

        // IMPORTANT: Interrupt any in-progress agent BEFORE queuing new work
        // This writes the interrupt file so python_exec's poll loop and agent's
        // LLM polling loop break out, freeing the pythonQueue
        let interruptFile = NSTemporaryDirectory() + "pegasus_interrupt"
        if currentGenerationID != nil {
            try? "1".write(toFile: interruptFile, atomically: true, encoding: .utf8)
            // Also write fake LLM response to unblock any stuck LLM poll
            writeErrorResponse("[Superseded]")
            // Clean up any pending request
            try? FileManager.default.removeItem(atPath: llmRequestFile)
        }

        // Cancel any previous generation's timer
        currentTimer?.cancel()
        currentTimer = nil

        // Assign a new generation ID — stale completions check this
        let genID = UUID()
        currentGenerationID = genID

        // Clear stream file
        try? "".write(toFile: streamFile, atomically: true, encoding: .utf8)
        // Clear interrupt file so the NEW run doesn't immediately abort
        try? FileManager.default.removeItem(atPath: interruptFile)

        var lastReadLength = 0
        var isDone = false

        var lastEventTime = CFAbsoluteTimeGetCurrent()
        var lastProgressReport: Int = 0
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        self.currentTimer = timer
        timer.schedule(deadline: .now() + 0.15, repeating: 0.1)
        timer.setEventHandler { [self] in
            // If a newer generation started, stop this timer
            guard currentGenerationID == genID else {
                isDone = true
                timer.cancel()
                return
            }
            guard !isDone else { return }

            let content = (try? String(contentsOfFile: streamFile, encoding: .utf8)) ?? ""
            guard content.count > lastReadLength else {
                // No new data — show progress sparingly (every 10s)
                let elapsed = Int(CFAbsoluteTimeGetCurrent() - lastEventTime)
                if elapsed >= 10 && elapsed / 10 > lastProgressReport {
                    lastProgressReport = elapsed / 10
                    DispatchQueue.main.async {
                        onEvent(.event(type: "status", content: "Processing (\(elapsed)s)..."))
                    }
                }
                return
            }

            // Get only the new portion of the file
            let startIdx = content.index(content.startIndex, offsetBy: lastReadLength)
            let newContent = String(content[startIdx...])

            // Only process up to the last complete line (ending with \n)
            guard let lastNewline = newContent.lastIndex(of: "\n") else { return }
            let processable = String(newContent[...lastNewline])
            lastReadLength += processable.count

            // Process each complete line
            for line in processable.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                guard let data = trimmed.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = event["type"] as? String else { continue }

                let eventContent = event["content"] as? String ?? ""
                lastEventTime = CFAbsoluteTimeGetCurrent()

                if type == "done" {
                    isDone = true
                    DispatchQueue.main.async { onEvent(.done) }
                    timer.cancel()
                    return
                } else if type == "error" {
                    isDone = true
                    DispatchQueue.main.async { onEvent(.error(eventContent)) }
                    timer.cancel()
                    return
                } else {
                    DispatchQueue.main.async {
                        onEvent(.event(type: type, content: eventContent))
                    }
                }
            }
        }
        timer.resume()

        // Run Python agent on the dedicated queue
        pythonQueue.async { [self] in
            let escaped = message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "")

            let sf = streamFile
            let lf = logFile

            let script = """
            import json as _json
            try:
                _msg = '\(escaped)'
                with open('\(sf)', 'a', encoding='utf-8') as _sf:
                    for _evt in _pegasus_agent.run_streaming(_msg):
                        _sf.write(_json.dumps(_evt, ensure_ascii=False) + '\\n')
                        _sf.flush()
                    _sf.write('{"type":"done","content":""}\\n')
                    _sf.flush()
            except Exception as _e:
                import traceback as _tb
                _err = str(_e)
                try:
                    with open('\(sf)', 'a', encoding='utf-8') as _sf:
                        _sf.write(_json.dumps({"type":"error","content":_err}, ensure_ascii=False) + '\\n')
                        _sf.flush()
                except:
                    pass
                try:
                    with open('\(lf)', 'a', encoding='utf-8') as _lf:
                        _lf.write(_tb.format_exc() + '\\n')
                except:
                    pass
            """

            let gstate = PyGILState_Ensure()
            PyRun_SimpleString(script)
            PyGILState_Release(gstate)

            // If this generation was superseded, don't touch the callback
            guard self.currentGenerationID == genID else {
                NSLog("[EmbeddedPython] Generation %@ superseded, skipping completion", genID.uuidString)
                return
            }

            // Give timer time to process remaining events
            Thread.sleep(forTimeInterval: 0.5)

            if !isDone {
                isDone = true
                timer.cancel()
                let streamContent = (try? String(contentsOfFile: sf, encoding: .utf8)) ?? ""
                let logContent = (try? String(contentsOfFile: lf, encoding: .utf8)) ?? ""
                var errorMsg = "Unknown error"
                for line in streamContent.components(separatedBy: "\n").reversed() {
                    if let data = line.data(using: .utf8),
                       let evt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let type = evt["type"] as? String {
                        if type == "text", let content = evt["content"] as? String, content.hasPrefix("Error:") {
                            errorMsg = content
                            break
                        }
                    }
                }
                if errorMsg == "Unknown error" {
                    for line in logContent.components(separatedBy: "\n").reversed() {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty && !trimmed.hasPrefix("[stdout]") {
                            errorMsg = trimmed
                            break
                        }
                    }
                }
                DispatchQueue.main.async {
                    onEvent(.error(errorMsg))
                }
            }
        }
    }

    /// Reset the Python agent's conversation history.
    /// Cancel the current streaming generation so a new one can start.
    func cancelCurrentGeneration() {
        currentGenerationID = nil
        currentTimer?.cancel()
        currentTimer = nil
        // Clear the stream file so old events don't leak into new session
        try? "".write(toFile: streamFile, atomically: true, encoding: .utf8)
        NSLog("[EmbeddedPython] Current generation cancelled")
    }

    func resetAgent() {
        cancelCurrentGeneration()
        // Write interrupt + fake response to unblock any stuck Python polling FIRST
        let interruptFile = NSTemporaryDirectory() + "pegasus_interrupt"
        try? "1".write(toFile: interruptFile, atomically: true, encoding: .utf8)
        // Clean up pending request
        try? FileManager.default.removeItem(atPath: llmRequestFile)
        // Write fake response to unblock Python's polling loop
        writeErrorResponse("[Reset]")
        // Clear the stream file
        try? "".write(toFile: streamFile, atomically: true, encoding: .utf8)
        // Clear the python log
        try? "".write(toFile: logFile, atomically: true, encoding: .utf8)

        guard isReady else { return }
        pythonQueue.async {
            let gstate = PyGILState_Ensure()
            PyRun_SimpleString("_pegasus_agent.reset()")
            PyGILState_Release(gstate)
            NSLog("[EmbeddedPython] Agent conversation history cleared")
        }
    }

    func compactAgent(completion: @escaping (String) -> Void) {
        guard isReady else {
            completion("Python agent not ready")
            return
        }
        let resultFile = NSTemporaryDirectory() + "pegasus_compact_result.txt"
        try? FileManager.default.removeItem(atPath: resultFile)

        pythonQueue.async {
            let gstate = PyGILState_Ensure()
            let code = """
            try:
                _result = _pegasus_agent.compact()
                with open('\(resultFile)', 'w') as f:
                    f.write(_result)
            except Exception as e:
                with open('\(resultFile)', 'w') as f:
                    f.write('Compact error: ' + str(e))
            """
            PyRun_SimpleString(code)
            PyGILState_Release(gstate)

            let result = (try? String(contentsOfFile: resultFile, encoding: .utf8)) ?? "Compact completed."
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// Dispatch a single tool call via Python's tool registry. Synchronous.
    func dispatchTool(name: String, argumentsJSON: String) -> String {
        guard isReady else {
            return "{\"error\": \"Python agent not ready\"}"
        }

        let outputFile = NSTemporaryDirectory() + "pegasus_tool_result.txt"
        try? "".write(toFile: outputFile, atomically: true, encoding: .utf8)

        let escapedArgs = argumentsJSON
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let escapedName = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        let script = """
        import json as _json
        try:
            from hermes_bridge.tool_registry import registry as _reg
            _args = _json.loads('\(escapedArgs)')
            _result = _reg.dispatch('\(escapedName)', _args)
            _out = _json.dumps(_result, ensure_ascii=True, default=str)
            with open('\(outputFile)', 'w', encoding='utf-8') as _f:
                _f.write(_out)
        except Exception as _e:
            with open('\(outputFile)', 'w', encoding='utf-8') as _f:
                _f.write(_json.dumps({"error": str(_e)}, ensure_ascii=True))
        """

        // Run synchronously on Python queue
        let semaphore = DispatchSemaphore(value: 0)
        pythonQueue.async {
            let gstate = PyGILState_Ensure()
            PyRun_SimpleString(script)
            PyGILState_Release(gstate)
            semaphore.signal()
        }
        semaphore.wait()

        return (try? String(contentsOfFile: outputFile, encoding: .utf8)) ?? "{\"error\": \"no output\"}"
    }

    /// Run the agent synchronously (non-streaming).
    func runAgent(message: String, completion: @escaping (String) -> Void) {
        guard isReady else {
            completion("Error: Python agent not ready")
            return
        }

        let outputFile = NSTemporaryDirectory() + "pegasus_output.txt"

        pythonQueue.async {
            let escaped = message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "")

            let script = """
            try:
                _msg = '\(escaped)'
                _result = _pegasus_agent.run(_msg)
                with open('\(outputFile)', 'w', encoding='utf-8') as _f:
                    _f.write(_result)
            except Exception as _e:
                import traceback as _tb
                with open('\(outputFile)', 'w', encoding='utf-8') as _f:
                    _f.write('Error: ' + str(_e) + '\\n' + _tb.format_exc())
            """

            let gstate = PyGILState_Ensure()
            PyRun_SimpleString(script)
            PyGILState_Release(gstate)

            let result = (try? String(contentsOfFile: outputFile, encoding: .utf8)) ?? "Error: no output from agent"
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    // MARK: - Python Initialization

    private func initializePython() {
        guard let resourcePath = Bundle.main.resourcePath else {
            DispatchQueue.main.async {
                self.isInitializing = false
                self.error = "Cannot find app resources"
            }
            return
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dataDir = docs.appendingPathComponent("pegasus_data").path
        let workspaceDir = docs.appendingPathComponent("pegasus_workspace").path
        let modelsDir = docs.appendingPathComponent("models").path

        for dir in [dataDir, workspaceDir, modelsDir] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let packagesPath = (resourcePath as NSString).appendingPathComponent("app_packages")
        let stdlibBase = (resourcePath as NSString).appendingPathComponent("python-stdlib")
        let stdlibPath = (stdlibBase as NSString).appendingPathComponent("python3.13")
        let dynloadPath = (stdlibPath as NSString).appendingPathComponent("lib-dynload")

        let tmpDir = NSTemporaryDirectory()
        setenv("PYTHONHOME", stdlibBase, 1)
        setenv("PYTHONPATH", "\(stdlibPath):\(dynloadPath):\(resourcePath):\(packagesPath)", 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        setenv("TMPDIR", tmpDir, 1)  // Critical: Python must use same tmp dir as Swift
        setenv("PYTHONIOENCODING", "utf-8", 1)
        setenv("PYTHONCOERCECLOCALE", "0", 1)
        setenv("PEGASUS_DATA_DIR", dataDir, 1)
        setenv("PEGASUS_WORKSPACE_DIR", workspaceDir, 1)
        setenv("PEGASUS_MODELS_DIR", modelsDir, 1)
        // Tell Python agent whether we're in cloud mode
        let modelName = Self.useCloudLLM ? Self.openAIModel : "local-model"
        setenv("PEGASUS_MODEL", modelName, 1)
        NSLog("[EmbeddedPython] TMPDIR set to: %@", tmpDir)

        let fm = FileManager.default
        guard fm.fileExists(atPath: (stdlibPath as NSString).appendingPathComponent("os.py")) else {
            let msg = "Python stdlib not found at \(stdlibPath)"
            NSLog("[EmbeddedPython] %@", msg)
            DispatchQueue.main.async { self.isInitializing = false; self.error = msg }
            return
        }

        let hermesBridgePath = (resourcePath as NSString).appendingPathComponent("hermes_bridge")
        guard fm.fileExists(atPath: (hermesBridgePath as NSString).appendingPathComponent("__init__.py")) else {
            let msg = "hermes_bridge not found at \(hermesBridgePath)"
            NSLog("[EmbeddedPython] %@", msg)
            DispatchQueue.main.async { self.isInitializing = false; self.error = msg }
            return
        }

        DispatchQueue.main.async { self.initStatus = "Calling Py_Initialize()..." }
        NSLog("[EmbeddedPython] Calling Py_Initialize()...")

        Py_Initialize()

        DispatchQueue.main.async { self.initStatus = "Python initialized, running setup..." }
        NSLog("[EmbeddedPython] Py_Initialize() returned successfully")

        try? "".write(toFile: logFile, atomically: true, encoding: .utf8)

        let escaped = { (s: String) in s.replacingOccurrences(of: "'", with: "\\'") }
        let lf = logFile

        let setupScript = """
        import sys, os, io

        class _LogWriter:
            def __init__(self, path, prefix=''):
                self._path = path
                self._prefix = prefix
            def write(self, text):
                if text.strip():
                    try:
                        with open(self._path, 'a', encoding='utf-8') as f:
                            f.write(self._prefix + text + '\\n')
                    except:
                        pass
            def flush(self):
                pass

        sys.stdout = _LogWriter('\(lf)', '[stdout] ')
        sys.stderr = _LogWriter('\(lf)', '[stderr] ')

        print(f'Python version: {sys.version}')

        for p in ['\(escaped(resourcePath))', '\(escaped(packagesPath))']:
            if p not in sys.path:
                sys.path.insert(0, p)

        print('Importing modules...')
        from hermes_bridge.tool_registry import registry
        from hermes_bridge.memory_manager import memory
        from hermes_bridge.skill_manager import skills
        from hermes_bridge.cron_manager import cron
        from hermes_bridge.agent_runner import AgentRunner
        from hermes_bridge import tools_builtin
        print('All modules imported.')

        _pegasus_model = os.environ.get('PEGASUS_MODEL', 'local-model')
        _pegasus_agent = AgentRunner(model=_pegasus_model)
        import tempfile
        print(f'Agent created (model={_pegasus_model}, file-based IPC)')
        print(f'TMPDIR={os.environ.get("TMPDIR", "NOT SET")}')
        print(f'tempdir={tempfile.gettempdir()}')

        cron.set_agent(_pegasus_agent)
        cron.start()

        tools = registry.list_tools()
        print(f'Tools: {[t["name"] for t in tools]}')
        print('Agent initialization complete!')
        """

        NSLog("[EmbeddedPython] Running setup script...")
        let result = PyRun_SimpleString(setupScript)
        NSLog("[EmbeddedPython] Setup script returned: %d", result)

        _ = PyEval_SaveThread()

        if let log = try? String(contentsOfFile: logFile, encoding: .utf8), !log.isEmpty {
            NSLog("[EmbeddedPython] Python log:\n%@", log)
        }

        if result == 0 {
            let log = (try? String(contentsOfFile: logFile, encoding: .utf8)) ?? ""
            if log.contains("Agent initialization complete!") {
                self.initialized = true
                DispatchQueue.main.async {
                    self.isReady = true
                    self.isInitializing = false
                    self.initStatus = "Agent ready"
                    self.error = nil
                    NSLog("[EmbeddedPython] Hermes agent READY (file-based IPC)")
                }
            } else {
                let lastLines = log.components(separatedBy: "\n").suffix(5).joined(separator: "\n")
                DispatchQueue.main.async {
                    self.isInitializing = false
                    self.initStatus = "Init incomplete"
                    self.error = "Python init incomplete: \(lastLines)"
                    NSLog("[EmbeddedPython] Init incomplete. Log:\n%@", log)
                }
            }
        } else {
            let log = (try? String(contentsOfFile: logFile, encoding: .utf8)) ?? "no log output"
            DispatchQueue.main.async {
                self.isInitializing = false
                self.initStatus = "Init failed"
                self.error = "Python init failed (code \(result)): \(log.suffix(200))"
                NSLog("[EmbeddedPython] Python init FAILED with code %d. Log:\n%@", result, log)
            }
        }
    }
}

// MARK: - LocationFetcher — One-shot CLLocationManager wrapper

private class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let semaphore = DispatchSemaphore(value: 0)
    private var locationResult: [String: Any] = ["error": "Location fetch timed out"]

    func fetchLocation(timeout: TimeInterval) -> [String: Any] {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest

        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            // Wait briefly for authorization
            Thread.sleep(forTimeInterval: 1.0)
        }

        let currentStatus = manager.authorizationStatus
        guard currentStatus == .authorizedWhenInUse || currentStatus == .authorizedAlways else {
            return ["error": "Location permission not granted. Status: \(currentStatus.rawValue)"]
        }

        manager.requestLocation()
        _ = semaphore.wait(timeout: .now() + timeout)
        return locationResult
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        locationResult = [
            "status": "ok",
            "latitude": loc.coordinate.latitude,
            "longitude": loc.coordinate.longitude,
            "altitude": loc.altitude,
            "horizontal_accuracy": loc.horizontalAccuracy,
            "speed": loc.speed,
            "timestamp": ISO8601DateFormatter().string(from: loc.timestamp)
        ]
        semaphore.signal()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationResult = ["error": "Location error: \(error.localizedDescription)"]
        semaphore.signal()
    }
}

// MARK: - Message Sender via Critical Messaging API
//
// Uses MSCriticalSMSMessenger (iOS 18.4+) to send SMS without any UI.
// Entitlement: com.apple.developer.messages.critical-messaging (self-assigned)
// Constraint: send() only works from background — we handle this automatically.
// MARK: - Message Sending
// Primary: Shortcuts x-callback-url (silent, no UI, "Show When Run" OFF)
// Fallback: MFMessageComposeViewController (one-tap composer)

class PegasusMessageSender: NSObject, MFMessageComposeViewControllerDelegate {
    static let shared = PegasusMessageSender()

    /// Whether to use Shortcuts for silent sending (default: true)
    var useShortcutsSend: Bool {
        get { UserDefaults.standard.object(forKey: "useShortcutsSend") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "useShortcutsSend") }
    }

    /// The name of the Shortcut to invoke
    static let shortcutName = "Send Pegasus Message"

    private func log(_ msg: String) {
        EmbeddedPython.swiftLog("[MsgSend] \(msg)")
    }

    /// Outbox folder inside the existing pegasus_workspace (visible in Files app)
    static var outboxDirectory: URL {
        BackendService.workspaceDirectory.appendingPathComponent("outbox")
    }

    /// Create the outbox folder so it's visible in Files > On My iPhone > Pegasus
    static func ensureOutboxExists() {
        try? FileManager.default.createDirectory(at: outboxDirectory, withIntermediateDirectories: true)
    }

    /// Send a message. Tries Shortcuts first (silent), falls back to composer.
    /// Call on main thread.
    func presentAndAutoSend(to recipient: String, body: String, attachmentPaths: [String] = []) {
        log("Sending to \(recipient): \(body)" + (attachmentPaths.isEmpty ? "" : " + \(attachmentPaths.count) attachment(s)"))

        if useShortcutsSend {
            sendViaShortcut(to: recipient, body: body, attachmentPaths: attachmentPaths)
        } else {
            presentComposer(to: recipient, body: body, attachmentPaths: attachmentPaths)
        }
    }

    // MARK: - Shortcuts (Silent Send)

    private func sendViaShortcut(to recipient: String, body: String, attachmentPaths: [String] = []) {
        // Stage attachments to outbox (inside pegasus_workspace, always visible in Files)
        let outbox = Self.outboxDirectory
        Self.ensureOutboxExists()
        // Clear old outbox files
        if let existing = try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil) {
            for file in existing { try? FileManager.default.removeItem(at: file) }
        }
        var stagedCount = 0
        for path in attachmentPaths {
            let src = URL(fileURLWithPath: path)
            let dst = outbox.appendingPathComponent(src.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: src, to: dst)
                stagedCount += 1
                log("Staged to outbox: \(src.lastPathComponent)")
            } catch {
                log("Failed to stage \(src.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Copy recipient to clipboard
        UIPasteboard.general.string = recipient
        log("Copied recipient to clipboard")

        // Ensure there's always a message body — Send Message stalls without one
        let messageBody = body.isEmpty ? (attachmentPaths.isEmpty ? " " : attachmentPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")) : body

        // Open shortcut
        guard let encodedName = Self.shortcutName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedBody = messageBody.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            log("Failed to encode shortcut URL — falling back to composer")
            presentComposer(to: recipient, body: body, attachmentPaths: attachmentPaths)
            return
        }

        let callbackSuccess = "pegasus://shortcut-sent"
        let callbackError = "pegasus://shortcut-error"
        guard let successEncoded = callbackSuccess.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let errorEncoded = callbackError.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            presentComposer(to: recipient, body: body, attachmentPaths: attachmentPaths)
            return
        }

        let urlString = "shortcuts://x-callback-url/run-shortcut?name=\(encodedName)&input=text&text=\(encodedBody)&x-success=\(successEncoded)&x-error=\(errorEncoded)"

        guard let url = URL(string: urlString) else {
            log("Invalid shortcut URL — falling back to composer")
            presentComposer(to: recipient, body: body, attachmentPaths: attachmentPaths)
            return
        }

        log("Opening Shortcuts: \(Self.shortcutName)" + (stagedCount > 0 ? " (\(stagedCount) file(s) in outbox)" : ""))

        UIApplication.shared.open(url, options: [:]) { success in
            if success {
                self.log("Shortcuts URL opened — message sending silently")
            } else {
                self.log("Shortcuts URL failed — shortcut may not exist. Falling back to composer.")
                DispatchQueue.main.async {
                    self.presentComposer(to: recipient, body: body, attachmentPaths: attachmentPaths)
                }
            }
        }
    }

    // MARK: - Composer Fallback (One-Tap)

    private func presentComposer(to recipient: String, body: String, attachmentPaths: [String] = []) {
        guard MFMessageComposeViewController.canSendText() else {
            log("Device cannot send text")
            return
        }

        guard let rootVC = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows.first?.rootViewController else {
            log("No root VC")
            return
        }

        let composer = MFMessageComposeViewController()
        composer.recipients = [recipient]
        composer.body = body
        composer.messageComposeDelegate = self

        // Attach files if provided
        for path in attachmentPaths {
            let url = URL(fileURLWithPath: path)
            if let data = try? Data(contentsOf: url) {
                let uti = Self.utiForExtension(url.pathExtension)
                let filename = url.lastPathComponent
                composer.addAttachmentData(data, typeIdentifier: uti, filename: filename)
                log("Attached: \(filename)")
            }
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        topVC.present(composer, animated: true) {
            self.log("Composer ready — tap Send (blue arrow) to send")
        }
    }

    private static func utiForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "public.jpeg"
        case "png": return "public.png"
        case "gif": return "com.compuserve.gif"
        case "heic": return "public.heic"
        case "mp4", "m4v": return "public.mpeg-4"
        case "mov": return "com.apple.quicktime-movie"
        case "pdf": return "com.adobe.pdf"
        case "txt": return "public.plain-text"
        default: return "public.data"
        }
    }

    // MARK: - Delegate

    func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        let status = result == .sent ? "sent" : result == .cancelled ? "cancelled" : "failed"
        log("Composer result: \(status)")
        controller.dismiss(animated: true)
    }

}
