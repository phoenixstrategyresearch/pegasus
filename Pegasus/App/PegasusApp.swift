import SwiftUI
import AVFoundation
import BackgroundTasks

@main
struct PegasusApp: App {
    @StateObject private var backend = BackendService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.pegasus.agent.refresh",
            using: nil
        ) { task in
            Self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.pegasus.agent.processing",
            using: nil
        ) { task in
            Self.handleProcessingTask(task: task as! BGProcessingTask)
        }

        // Stop inference and free memory when app is terminated
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("[Pegasus] App terminating — unloading model and stopping all processing")
            LocalLLMEngine.shared.stopGenerating()
            LocalLLMEngine.shared.unload()
            WhisperEngine.shared.unload()
            EmbeddedPython.shared.stopAgent()
            BackgroundKeepAlive.shared.stop()
        }

        // Free model memory when iOS sends memory pressure warnings
        // This fires before iOS force-kills the app
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("[Pegasus] Memory warning — unloading model to avoid OOM kill")
            LocalLLMEngine.shared.stopGenerating()
            LocalLLMEngine.shared.unload()
            WhisperEngine.shared.unload()
            EmbeddedPython.shared.stopAgent()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(backend)
                .onAppear {
                    backend.startBackend()
                    BackgroundKeepAlive.shared.start()
                    WhisperEngine.shared.loadBundledModel()
                }
                .onOpenURL { url in
                    handleDeepLink(url: url)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                print("[Pegasus] Entering background — keep-alive active")
                BackgroundKeepAlive.shared.start()
                scheduleBackgroundTasks()
            case .active:
                print("[Pegasus] Returning to foreground")
            default:
                break
            }
        }
    }

    private func scheduleBackgroundTasks() {
        let refreshRequest = BGAppRefreshTaskRequest(identifier: "com.pegasus.agent.refresh")
        refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 60)

        let processingRequest = BGProcessingTaskRequest(identifier: "com.pegasus.agent.processing")
        processingRequest.requiresExternalPower = false
        processingRequest.requiresNetworkConnectivity = false
        processingRequest.earliestBeginDate = Date(timeIntervalSinceNow: 120)

        do {
            try BGTaskScheduler.shared.submit(refreshRequest)
            try BGTaskScheduler.shared.submit(processingRequest)
        } catch {
            print("[Pegasus] Failed to schedule background tasks: \(error)")
        }
    }

    static func handleAppRefresh(task: BGAppRefreshTask) {
        let request = BGAppRefreshTaskRequest(identifier: "com.pegasus.agent.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
        task.setTaskCompleted(success: true)
    }

    static func handleProcessingTask(task: BGProcessingTask) {
        let request = BGProcessingTaskRequest(identifier: "com.pegasus.agent.processing")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 120)
        try? BGTaskScheduler.shared.submit(request)
        task.setTaskCompleted(success: true)
    }

    /// Handle pegasus:// deep links.
    /// Supported URLs:
    ///   pegasus://voice       — open app and start voice recording
    ///   pegasus://ask?q=...   — open app and send a query
    private func handleDeepLink(url: URL) {
        guard url.scheme == "pegasus" else { return }
        let host = url.host ?? ""
        let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.reduce(into: [String: String]()) { $0[$1.name] = $1.value } ?? [:]

        switch host {
        case "voice":
            NotificationCenter.default.post(
                name: .pegasusShortcutTriggered,
                object: nil,
                userInfo: ["source": "deeplink", "mode": "voice"]
            )
        case "ask":
            let query = params["q"] ?? ""
            NotificationCenter.default.post(
                name: .pegasusShortcutTriggered,
                object: nil,
                userInfo: ["source": "deeplink", "mode": "text", "query": query]
            )
        default:
            print("[Pegasus] Unknown deep link: \(url)")
        }
    }
}

/// Keeps the app alive in background using a silent audio session.
class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    private var audioEngine: AVAudioEngine?
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
            try session.setActive(true)
        } catch {
            print("[KeepAlive] Audio session error: \(error)")
            return
        }

        let engine = AVAudioEngine()
        let mixer = engine.mainMixerNode
        mixer.outputVolume = 0.0

        let player = AVAudioPlayerNode()
        engine.attach(player)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.connect(player, to: mixer, format: format)

        let frameCount: AVAudioFrameCount = 44100
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        do {
            try engine.start()
            player.play()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            self.audioEngine = engine
            print("[KeepAlive] Silent audio session started")
        } catch {
            print("[KeepAlive] Engine start error: \(error)")
        }
    }

    func stop() {
        audioEngine?.stop()
        audioEngine = nil
        started = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
