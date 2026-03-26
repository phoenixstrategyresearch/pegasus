import SwiftUI

/// Live terminal view showing backend logs, agent activity, and cron job output.
/// Hermes handles cron scheduling via its built-in cron tools — this view
/// lets you see everything that's happening in real time.
struct TerminalView: View {
    @EnvironmentObject var backend: BackendService
    @State private var logLines: [LogLine] = []
    @State private var cronJobs: [BackendService.CronJob] = []
    @State private var selectedJobId: String?
    @State private var jobLogs: [BackendService.CronLogEntry] = []
    @State private var autoScroll = true
    @State private var filter: LogFilter = .all
    @State private var lastClearedAt: Date?

    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    enum LogFilter: String, CaseIterable {
        case all = "All"
        case agent = "Agent"
        case cron = "Cron"
        case system = "System"
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let timestamp: String
        let source: String  // "agent", "cron", "system"
        let text: String
        let isError: Bool
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filter bar
                filterBar

                // Cron jobs ribbon (if any)
                if !cronJobs.isEmpty {
                    cronRibbon
                }

                // Terminal output
                terminal
            }
            .navigationTitle("Terminal")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        logLines = []
                        lastClearedAt = Date()
                        // Also clear the Python log file so old entries don't reappear
                        let logPath = NSTemporaryDirectory() + "pegasus_python.log"
                        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
                        // Clear stream file too
                        let streamPath = NSTemporaryDirectory() + "pegasus_stream.jsonl"
                        try? "".write(toFile: streamPath, atomically: true, encoding: .utf8)
                        // Interrupt any stuck agent and clean up all IPC files
                        backend.interruptAgent()
                        // Reset the agent conversation so it starts fresh
                        backend.resetConversation {}
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Toggle(isOn: $autoScroll) {
                        Image(systemName: "arrow.down.to.line")
                    }
                    .toggleStyle(.button)
                    .tint(autoScroll ? .green : .gray)
                }
            }
            .onAppear { refresh() }
            .onReceive(timer) { _ in refresh() }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LogFilter.allCases, id: \.self) { f in
                    Button {
                        filter = f
                    } label: {
                        Text(f.rawValue)
                            .font(.system(size: 11, weight: filter == f ? .bold : .regular, design: .monospaced))
                            .foregroundColor(filter == f ? .black : .green)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                filter == f
                                    ? Color.green
                                    : Color.green.opacity(0.15)
                            )
                            .clipShape(Capsule())
                    }
                }
                Spacer()
                // Status indicators
                HStack(spacing: 6) {
                    let python = EmbeddedPython.shared
                    Circle()
                        .fill(python.isReady ? .green : (python.isInitializing ? .orange : .red))
                        .frame(width: 6, height: 6)
                    Text(python.isReady ? "AGENT" : (python.isInitializing ? "INIT" : "NO AGENT"))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(python.isReady ? .green : (python.isInitializing ? .orange : .red))

                    if EmbeddedPython.useCloudLLM && EmbeddedPython.openAIAPIKey != nil {
                        Circle()
                            .fill(.cyan)
                            .frame(width: 6, height: 6)
                        Text("CLOUD")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan)
                    } else if backend.isModelLoading {
                        ProgressView()
                            .scaleEffect(0.5)
                        Text("LOADING")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.orange)
                    } else if backend.isModelLoaded {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text("MODEL")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.green)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
    }

    // MARK: - Cron Ribbon

    private var cronRibbon: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(cronJobs) { job in
                    Button {
                        if selectedJobId == job.id {
                            selectedJobId = nil
                            jobLogs = []
                        } else {
                            selectedJobId = job.id
                            fetchJobLogs(job.id)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(job.enabled ? .green : .gray)
                                .frame(width: 6, height: 6)
                            Text(job.name)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                            Text("(\(job.interval))")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.green.opacity(0.6))
                        }
                        .foregroundColor(selectedJobId == job.id ? .black : .green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            selectedJobId == job.id
                                ? Color.green
                                : Color.green.opacity(0.1)
                        )
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .background(Color(red: 0.1, green: 0.1, blue: 0.12))
        .overlay(
            Rectangle().fill(Color.green.opacity(0.2)).frame(height: 0.5),
            alignment: .bottom
        )
    }

    // MARK: - Terminal

    private var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // System status at top
                    systemHeader

                    // If a cron job is selected, show its logs
                    if selectedJobId != nil {
                        cronJobLogs
                    }

                    // Live log lines
                    ForEach(filteredLines) { line in
                        logLineView(line)
                            .id(line.id)
                    }

                    if filteredLines.isEmpty && selectedJobId == nil {
                        Text("Waiting for activity...")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.green.opacity(0.4))
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onChange(of: logLines.count) {
                if autoScroll, let last = filteredLines.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
        .frame(maxHeight: .infinity)
    }

    private var systemHeader: some View {
        let python = EmbeddedPython.shared
        let isCloud = EmbeddedPython.useCloudLLM && EmbeddedPython.openAIAPIKey != nil
        let agentStatus: String = {
            if python.isReady { return isCloud ? "hermes (cloud: \(EmbeddedPython.openAIModel))" : "hermes (embedded)" }
            if python.isInitializing { return "initializing: \(python.initStatus)" }
            if let err = python.error { return "error: \(err)" }
            if backend.isModelLoaded || isCloud { return "waiting for agent init..." }
            return "not running"
        }()
        let modelStatus: String = {
            if isCloud { return "cloud: \(EmbeddedPython.openAIModel) (online)" }
            if backend.isModelLoaded { return "on-device (loaded)" }
            if backend.isModelLoading { return "loading..." }
            return "none"
        }()

        return VStack(alignment: .leading, spacing: 1) {
            Text("pegasus terminal v1.2 (build \(Self.buildTime))")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.green)
            Text("agent: \(agentStatus)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(python.isReady ? .green.opacity(0.7) :
                    (python.error != nil ? .red.opacity(0.7) :
                        (python.isInitializing ? .orange.opacity(0.7) : .green.opacity(0.5))))
            Text("model: \(modelStatus)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(isCloud ? .cyan.opacity(0.7) : .green.opacity(0.5))
            Text(String(repeating: "─", count: 50))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.green.opacity(0.2))
        }
        .padding(.bottom, 4)
    }

    private var cronJobLogs: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let job = cronJobs.first(where: { $0.id == selectedJobId }) {
                Text("── cron:\(job.name) (every \(job.interval), \(job.run_count) runs) ──")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
            }
            if jobLogs.isEmpty {
                Text("  No runs yet — waiting for first execution...")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.green.opacity(0.4))
            }
            ForEach(Array(jobLogs.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 0) {
                    Text("[\(formatTime(entry.timestamp))]")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.green.opacity(0.5))
                    if let response = entry.output.response, !response.isEmpty {
                        Text(response)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.green)
                            .textSelection(.enabled)
                    }
                    if let stdout = entry.output.stdout, !stdout.isEmpty {
                        Text(stdout)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.green)
                            .textSelection(.enabled)
                    }
                    if let stderr = entry.output.stderr, !stderr.isEmpty {
                        Text(stderr)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.yellow)
                            .textSelection(.enabled)
                    }
                    if let error = entry.output.error, !error.isEmpty {
                        Text("ERROR: \(error)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            Text(String(repeating: "─", count: 50))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.cyan.opacity(0.2))
                .padding(.top, 2)
        }
        .padding(.bottom, 4)
    }

    private func logLineView(_ line: LogLine) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(line.timestamp)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.green.opacity(0.4))
                .frame(width: 60, alignment: .leading)
            Text("[\(line.source)]")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(sourceColor(line.source))
                .frame(width: 48, alignment: .leading)
            Text(line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(line.isError ? .red : .green)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
    }

    // MARK: - Helpers

    private var filteredLines: [LogLine] {
        switch filter {
        case .all: return logLines
        case .agent: return logLines.filter { $0.source == "agent" }
        case .cron: return logLines.filter { $0.source == "cron" }
        case .system: return logLines.filter { $0.source == "system" }
        }
    }

    private func sourceColor(_ source: String) -> Color {
        switch source {
        case "agent": return .cyan
        case "cron": return .yellow
        case "system": return .orange
        default: return .green
        }
    }

    private func refresh() {
        // Suppress refresh for 5 seconds after clearing to prevent old status re-appearing
        if let cleared = lastClearedAt, Date().timeIntervalSince(cleared) < 5 {
            return
        }

        let python = EmbeddedPython.shared

        // Add system status lines for state changes
        if backend.isModelLoading {
            addSystemLog("Model loading in progress...")
        }
        if backend.isModelLoaded && !python.isReady && !python.isInitializing && python.error == nil {
            addSystemLog("Model loaded. Waiting for agent initialization...")
        }
        if let error = backend.modelError {
            addSystemLog("Model error: \(error)", isError: true)
        }

        // Show Python agent status
        if python.isInitializing {
            addSystemLog("Python agent: \(python.initStatus)")
        }
        if python.isReady {
            addSystemLog("Hermes agent running (embedded, direct mode)")
        } else if let err = python.error {
            addSystemLog("Python agent error: \(err)", isError: true)
        }

        // Show Python log file contents
        let pyLog = python.readPythonLog()
        if !pyLog.isEmpty {
            for line in pyLog.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    addLogLine(source: "agent", text: trimmed, isError: trimmed.contains("[stderr]") || trimmed.lowercased().contains("error"))
                }
            }
        }
    }

    private func addSystemLog(_ text: String, isError: Bool = false) {
        addLogLine(source: "system", text: text, isError: isError)
    }

    private func addLogLine(source: String, text: String, isError: Bool = false) {
        let ts = currentTime()
        if !logLines.contains(where: { $0.text == text && $0.source == source }) {
            logLines.append(LogLine(timestamp: ts, source: source, text: text, isError: isError))
        }
    }

    private static let buildTime: String = {
        let f = DateFormatter()
        f.dateFormat = "MMdd-HHmm"
        return f.string(from: Date())
    }()

    private func fetchJobLogs(_ jobId: String) {
        backend.fetchCronLogs(jobId: jobId) { self.jobLogs = $0 }
    }

    private func formatTime(_ ts: String) -> String {
        if let tIdx = ts.firstIndex(of: "T") {
            let time = ts[ts.index(after: tIdx)...]
            if let dotIdx = time.firstIndex(of: ".") {
                return String(time[..<dotIdx])
            }
            return String(time.prefix(8))
        }
        return ts
    }

    private func currentTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
