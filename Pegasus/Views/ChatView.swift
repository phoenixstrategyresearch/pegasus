import SwiftUI
import AVFAudio

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: Role
    var content: String
    let timestamp: Date
    var toolInfo: String?
    var filePath: String?

    enum Role: String, Codable {
        case user, assistant, tool, system, thinking, file
    }

    init(role: Role, content: String, toolInfo: String? = nil, filePath: String? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.toolInfo = toolInfo
        self.filePath = filePath
    }
}

// MARK: - Chat Mode

enum ChatMode: String, CaseIterable {
    case cloud = "cloud"
    case local = "local"

    var label: String {
        switch self {
        case .cloud: return "Cloud"
        case .local: return "Local"
        }
    }

    var icon: String {
        switch self {
        case .cloud: return "cloud.fill"
        case .local: return "cpu"
        }
    }
}

// MARK: - Chat Persistence

struct ChatStore {
    private static func fileURL(for mode: ChatMode) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let filename = mode == .cloud ? "pegasus_chat_cloud.json" : "pegasus_chat_local.json"
        return dir.appendingPathComponent(filename)
    }

    // Legacy single-file URL for migration
    private static var legacyFileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("pegasus_chat.json")
    }

    static func save(_ messages: [ChatMessage], mode: ChatMode) {
        let toSave = messages.filter { $0.role == .user || $0.role == .assistant || $0.role == .system || $0.role == .file }
        guard let data = try? JSONEncoder().encode(toSave) else { return }
        try? data.write(to: fileURL(for: mode), options: .atomic)
    }

    static func load(mode: ChatMode) -> [ChatMessage] {
        // Try mode-specific file first
        if let data = try? Data(contentsOf: fileURL(for: mode)),
           let msgs = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            return msgs
        }
        // Migrate legacy file to cloud (was the default before)
        if mode == .cloud,
           let data = try? Data(contentsOf: legacyFileURL),
           let msgs = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            try? FileManager.default.removeItem(at: legacyFileURL)
            if let encoded = try? JSONEncoder().encode(msgs) {
                try? encoded.write(to: fileURL(for: .cloud), options: .atomic)
            }
            return msgs
        }
        return []
    }

    static func clear(mode: ChatMode) {
        try? FileManager.default.removeItem(at: fileURL(for: mode))
    }
}

enum AgentPhase {
    case thinking, toolCall, toolResult, searching, fetching
}

// MARK: - Dual Chat View (wrapper with mode toggle)

struct ChatView: View {
    @EnvironmentObject var backend: BackendService
    @AppStorage("chatMode") private var chatMode: String = "cloud"

    private var mode: ChatMode {
        get { ChatMode(rawValue: chatMode) ?? .cloud }
    }

    var body: some View {
        ZStack {
            ChatPanel(mode: .cloud)
                .opacity(mode == .cloud ? 1 : 0)
                .allowsHitTesting(mode == .cloud)

            ChatPanel(mode: .local)
                .opacity(mode == .local ? 1 : 0)
                .allowsHitTesting(mode == .local)
        }
        .overlay(alignment: .topTrailing) {
            modeToggle
                .padding(.top, 68)
                .padding(.trailing, 8)
        }
    }

    private var modeToggle: some View {
        HStack(spacing: 0) {
            ForEach(ChatMode.allCases, id: \.self) { m in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        chatMode = m.rawValue
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: m.icon)
                            .font(.system(size: 9))
                        Text(m.label)
                            .font(.system(size: 10, weight: mode == m ? .bold : .medium))
                    }
                    .foregroundColor(mode == m ? .white : Color(red: 0.3, green: 0.3, blue: 0.35))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        mode == m
                            ? AnyView(Capsule().fill(m == .cloud ? Color.blue.opacity(0.85) : Color.green.opacity(0.7)))
                            : AnyView(Capsule().fill(Color.clear))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
        )
    }
}

// MARK: - Chat Panel (single mode instance)

struct ChatPanel: View {
    let mode: ChatMode
    @EnvironmentObject var backend: BackendService
    @State private var inputText = ""
    @State private var messages: [ChatMessage] = []
    @State private var isLoading = false
    @State private var streamingResponseID: UUID?
    @State private var streamingThinkingID: UUID?
    @State private var showingFilePicker = false
    @AppStorage("showThinking") private var showThinking = false
    @State private var agentStatus = ""
    @State private var agentPhase: AgentPhase = .thinking
    @FocusState private var inputFocused: Bool
    @StateObject private var voiceRecorder = VoiceRecorder.shared
    @State private var isVoiceMode = false
    @State private var lastToolCallName = ""

    var body: some View {
        VStack(spacing: 0) {
            // Leopard title bar
            LeopardTitleBar(title: "Pegasus")

            // Brushed metal toolbar
            HStack(spacing: 0) {
                // Toolbar buttons — equal width, aligned
                HStack(spacing: 0) {
                    toolbarButton(
                        icon: "arrow.counterclockwise",
                        label: "New",
                        isActive: false
                    ) {
                        backend.interruptAgent()
                        isLoading = false
                        resetConversation()
                    }

                    toolbarButton(
                        icon: "stop.fill",
                        label: "Stop",
                        isActive: false
                    ) {
                        backend.interruptAgent()
                        isLoading = false
                        streamingResponseID = nil
                        streamingThinkingID = nil
                    }

                    toolbarButton(
                        icon: "eraser.fill",
                        label: "Clear",
                        isActive: false
                    ) {
                        backend.interruptAgent()
                        messages = []
                        isLoading = false
                        streamingResponseID = nil
                        streamingThinkingID = nil
                        agentStatus = ""
                        agentPhase = .thinking
                        backend.resetConversation {}
                    }

                    toolbarButton(
                        icon: showThinking ? "brain.head.profile.fill" : "brain.head.profile",
                        label: "Think",
                        isActive: showThinking
                    ) {
                        showThinking.toggle()
                    }
                }

                Spacer()

                // Model badge
                modelBadge
                    .padding(.trailing, 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(BrushedMetalBackground().clipped())
            .overlay(
                Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1),
                alignment: .bottom
            )

            // Messages area
            ZStack {
                Color.white

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                                if msg.role == .thinking {
                                    if showThinking {
                                        ThinkingBubble(content: msg.content)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 4)
                                            .background(index % 2 == 0 ? Color.leopardStripe1 : Color.leopardStripe2)
                                            .id(msg.id)
                                    }
                                } else {
                                    LeopardChatBubble(message: msg, index: index)
                                        .id(msg.id)
                                }
                            }
                            if isLoading {
                                HStack {
                                    AgentStatusIndicator(
                                        phase: agentPhase,
                                        status: agentStatus
                                    )
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .id("loading")
                            }
                            // Invisible anchor at the bottom for reliable scrolling
                            Color.clear.frame(height: 1).id("bottom")
                        }
                    }
                    .onChange(of: messages.count) {
                        scrollToBottom(proxy)
                    }
                    .onChange(of: isLoading) {
                        scrollToBottom(proxy)
                    }
                }
                .onTapGesture {
                    inputFocused = false
                }
            }

            // Input bar
            HStack(spacing: 10) {
                Button {
                    showingFilePicker = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 18))
                        .foregroundColor(Color(red: 0.3, green: 0.3, blue: 0.35))
                }

                TextField("Message Pegasus...", text: $inputText, axis: .vertical)
                    .textFieldStyle(LeopardTextFieldStyle())
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit { sendMessage() }

                // Voice input button
                Button(action: toggleVoiceRecording) {
                    Image(systemName: voiceRecorder.isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(
                            ZStack {
                                Circle().fill(voiceRecorder.isRecording ? Color.red : Color.orange)
                                Circle().fill(
                                    LinearGradient(
                                        colors: [.white.opacity(0.4), .clear],
                                        startPoint: .top,
                                        endPoint: .center
                                    )
                                )
                            }
                        )
                }

                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(
                            ZStack {
                                Circle().fill(canSend ? Color.leopardAccent : Color.gray)
                                Circle().fill(
                                    LinearGradient(
                                        colors: [.white.opacity(0.4), .clear],
                                        startPoint: .top,
                                        endPoint: .center
                                    )
                                )
                            }
                        )
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .overlay {
            if isVoiceMode {
                VoiceRecordingOverlay(
                    duration: voiceRecorder.recordingDuration,
                    isRecording: voiceRecorder.isRecording,
                    onStop: { toggleVoiceRecording() }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isVoiceMode)
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .onAppear {
            if messages.isEmpty {
                messages = ChatStore.load(mode: mode)
            }
        }
        .onChange(of: messages.count) {
            ChatStore.save(messages, mode: mode)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pegasusShortcutTriggered)) { notification in
            // Only handle on the active panel
            let activeMode = ChatMode(rawValue: UserDefaults.standard.string(forKey: "chatMode") ?? "cloud") ?? .cloud
            guard activeMode == mode else { return }

            guard let userInfo = notification.userInfo else { return }
            let shortcutMode = userInfo["mode"] as? String ?? "text"
            let query = userInfo["query"] as? String ?? ""

            if shortcutMode == "voice" {
                toggleVoiceRecording()
            } else if !query.isEmpty {
                inputText = query
                sendMessage()
            }
        }
    }

    private var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if mode == .cloud {
            return hasText && !isLoading && EmbeddedPython.openAIAPIKey != nil
        } else {
            return hasText && !isLoading && (backend.isModelLoaded || EmbeddedPython.shared.isReady)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    @ViewBuilder
    private var modelBadge: some View {
        let python = EmbeddedPython.shared

        if mode == .cloud {
            let hasKey = EmbeddedPython.openAIAPIKey != nil
            HStack(spacing: 4) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 9))
                Text(hasKey ? EmbeddedPython.openAIModel : "No API key")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(hasKey ? Color.blue.opacity(0.85) : Color.gray.opacity(0.6))
            )
        } else if backend.isModelLoaded {
            let name = LocalLLMEngine.shared.modelDescription
                .components(separatedBy: " (").first ?? "Local"
            HStack(spacing: 4) {
                Circle().fill(python.isReady ? .green : .yellow)
                    .frame(width: 5, height: 5)
                Text(name)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundColor(Color(red: 0.25, green: 0.25, blue: 0.3))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color(red: 0.88, green: 0.88, blue: 0.9))
            )
        } else if backend.isModelLoading {
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.5)
                Text("Loading...")
                    .font(.system(size: 10, design: .rounded))
            }
            .foregroundColor(Color(red: 0.4, green: 0.35, blue: 0.2))
        } else {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text("No model")
                    .font(.system(size: 10, design: .rounded))
            }
            .foregroundColor(Color(red: 0.5, green: 0.35, blue: 0.15))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.orange.opacity(0.15))
            )
        }
    }

    private func toolbarButton(icon: String, label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 16)
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
            }
            .foregroundColor(isActive
                ? Color.leopardAccent
                : Color(red: 0.3, green: 0.3, blue: 0.33))
            .frame(width: 52, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)
        inputText = ""
        inputFocused = false
        isLoading = true
        streamingResponseID = nil
        streamingThinkingID = nil

        agentStatus = "Sending to model..."
        agentPhase = .thinking

        // Set the mode for this request
        UserDefaults.standard.set(mode == .cloud, forKey: "useCloudLLM")

        backend.sendMessageStreaming(text) { event in
            switch event {
            case .event(let type, let content):
                switch type {
                case "text":
                    streamingThinkingID = nil
                    agentStatus = ""

                    if let sid = streamingResponseID,
                       let idx = messages.lastIndex(where: { $0.id == sid }) {
                        messages[idx].content += content
                    } else {
                        let msg = ChatMessage(role: .assistant, content: content)
                        streamingResponseID = msg.id
                        messages.append(msg)
                    }
                    isLoading = false

                case "tool_call":
                    streamingResponseID = nil
                    streamingThinkingID = nil
                    // Parse tool name for status display
                    let toolName = content.components(separatedBy: "(").first ?? "tool"
                    let cleanName = toolName.trimmingCharacters(in: .whitespaces)
                    if cleanName.contains("web_search") {
                        agentPhase = .searching
                        agentStatus = "Searching the web..."
                    } else if cleanName.contains("web_fetch") {
                        agentPhase = .fetching
                        agentStatus = "Fetching page..."
                    } else if cleanName.contains("file_read") {
                        agentPhase = .toolCall
                        agentStatus = "Reading file..."
                    } else if cleanName.contains("file_write") {
                        agentPhase = .toolCall
                        agentStatus = "Writing file..."
                    } else if cleanName.contains("create_package") {
                        agentPhase = .toolCall
                        agentStatus = "Creating package..."
                    } else if cleanName.contains("memory") {
                        agentPhase = .toolCall
                        agentStatus = "Accessing memory..."
                    } else if cleanName.contains("python_exec") {
                        agentPhase = .toolCall
                        agentStatus = "Running code..."
                    } else {
                        agentPhase = .toolCall
                        agentStatus = "Using \(cleanName)..."
                    }
                    // Show compact tool info, not raw content
                    lastToolCallName = cleanName
                    messages.append(ChatMessage(role: .tool, content: cleanName, toolInfo: "calling"))

                case "tool_result":
                    streamingResponseID = nil
                    streamingThinkingID = nil
                    agentPhase = .toolResult
                    agentStatus = "Processing result..."

                    // Detect python_exec execution timeout — only reset for code execution hangs
                    // NOT for LLM/API timeouts (those are recoverable)
                    if content.contains("timed out") && lastToolCallName == "python_exec" {
                        backend.interruptAgent()
                        backend.resetConversation {}
                        messages.append(ChatMessage(
                            role: .system,
                            content: "Code execution timed out. Agent stopped and conversation reset to prevent loops."
                        ))
                        isLoading = false
                        agentStatus = ""
                        streamingResponseID = nil
                        streamingThinkingID = nil
                        ChatStore.save(messages, mode: mode)
                        break
                    }

                    // Check if this result is from file_write — show file card
                    if lastToolCallName == "file_write",
                       let data = content.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let path = json["path"] as? String {
                        let bytes = json["bytes_written"] as? Int ?? 0
                        let workspaceDir = BackendService.dataDirectory
                            .deletingLastPathComponent()
                            .appendingPathComponent("pegasus_workspace")
                        let fullPath = workspaceDir.appendingPathComponent(path).path
                        let sizeStr = bytes > 1024 ? "\(bytes / 1024) KB" : "\(bytes) bytes"
                        messages.append(ChatMessage(
                            role: .file,
                            content: "\(path)\n\(sizeStr)",
                            filePath: fullPath
                        ))
                    } else if lastToolCallName == "create_package",
                              let data = content.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let name = json["name"] as? String {
                        let bytes = json["bytes_written"] as? Int ?? 0
                        let status = json["status"] as? String ?? "created"
                        let importable = json["importable"] as? Bool ?? false
                        let sizeStr = bytes > 1024 ? "\(bytes / 1024) KB" : "\(bytes) bytes"
                        let statusIcon = importable ? "Ready" : "Error"
                        let fullPath = json["path"] as? String ?? ""
                        messages.append(ChatMessage(
                            role: .file,
                            content: "\(name).py\n\(sizeStr) - \(statusIcon)",
                            filePath: fullPath
                        ))
                    } else {
                        let displayContent = content.count > 200 ? String(content.prefix(200)) + "..." : content
                        messages.append(ChatMessage(role: .tool, content: displayContent, toolInfo: "result"))
                    }

                case "thinking":
                    agentPhase = .thinking
                    agentStatus = "Reasoning..."
                    if let tid = streamingThinkingID,
                       let idx = messages.lastIndex(where: { $0.id == tid }) {
                        messages[idx].content += content
                    } else {
                        let msg = ChatMessage(role: .thinking, content: content)
                        streamingThinkingID = msg.id
                        messages.append(msg)
                    }

                case "status":
                    agentStatus = content
                    agentPhase = .thinking

                default:
                    break
                }
            case .done:
                streamingThinkingID = nil
                streamingResponseID = nil
                agentStatus = ""
                isLoading = false
                ChatStore.save(messages, mode: mode)
            case .error(let msg):
                streamingThinkingID = nil
                streamingResponseID = nil
                agentStatus = ""
                if msg.contains("Execution timed out") || msg.contains("Code execution timed out") {
                    // Only auto-reset for python_exec hangs, not LLM/API timeouts
                    backend.interruptAgent()
                    backend.resetConversation {}
                    messages.append(ChatMessage(
                        role: .system,
                        content: "Code execution timed out. Agent stopped and conversation reset."
                    ))
                } else if msg.contains("timed out") {
                    // LLM/API timeout — show error but don't nuke the conversation
                    messages.append(ChatMessage(role: .system, content: "Request timed out. Try again or simplify your request."))
                } else {
                    messages.append(ChatMessage(role: .system, content: "Error: \(msg)"))
                }
                isLoading = false
            }
        }
    }

    private func resetConversation() {
        // Reset UI immediately — don't wait for Python queue (may be blocked)
        messages = []
        streamingResponseID = nil
        streamingThinkingID = nil
        agentStatus = ""
        agentPhase = .thinking
        isLoading = false
        ChatStore.clear(mode: mode)
        // Reset agent in background (will complete when Python queue unblocks)
        backend.resetConversation {}
    }

    private func toggleVoiceRecording() {
        if voiceRecorder.isRecording {
            // Stop recording and transcribe
            let duration = voiceRecorder.recordingDuration
            guard let path = voiceRecorder.stopRecording() else { return }
            isVoiceMode = false
            isLoading = true
            agentStatus = "Transcribing speech..."
            agentPhase = .thinking

            // Call WhisperEngine directly from Swift — no Python IPC needed
            DispatchQueue.global(qos: .userInitiated).async {
                let text = WhisperEngine.shared.transcribeSync(wavPath: path)

                DispatchQueue.main.async {
                    self.isLoading = false
                    self.agentStatus = ""

                    if !text.isEmpty && !text.hasPrefix("[") {
                        // Got transcription — send it as a message
                        self.inputText = text
                        self.sendMessage()
                    } else {
                        self.messages.append(ChatMessage(role: .system, content: text.isEmpty ? "No speech detected." : text))
                    }
                }
            }
        } else {
            // Request microphone permission and start recording
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.voiceRecorder.startRecording()
                        self.isVoiceMode = true
                    } else {
                        self.messages.append(ChatMessage(role: .system, content: "Microphone access denied. Enable it in Settings > Privacy > Microphone."))
                    }
                }
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let filename = url.lastPathComponent
            let dataDir = BackendService.dataDirectory
            let workspaceDir = dataDir.deletingLastPathComponent()
                .appendingPathComponent("pegasus_workspace")

            // Route special files to pegasus_data instead of workspace
            let specialDataFiles = ["SOUL.md", "MEMORY.md", "USER.md"]
            let isSkill = filename == "SKILL.md" || filename.hasSuffix(".skill")
            let isDataFile = specialDataFiles.contains(filename)

            let targetDir: URL
            var contextMsg: String

            if isDataFile {
                targetDir = dataDir
                contextMsg = "Imported \(filename) to agent data."
                if filename == "SOUL.md" {
                    contextMsg += " The agent identity has been updated."
                } else if filename == "MEMORY.md" {
                    contextMsg += " Agent memory has been updated."
                } else if filename == "USER.md" {
                    contextMsg += " User profile has been updated."
                }
            } else if isSkill {
                let skillName = filename.replacingOccurrences(of: ".skill", with: "")
                    .replacingOccurrences(of: "SKILL.md", with: "imported_skill")
                targetDir = dataDir.appendingPathComponent("skills").appendingPathComponent(skillName)
                contextMsg = "Imported skill: \(skillName)."
            } else {
                targetDir = workspaceDir
                contextMsg = "I've attached a file to the workspace: \(filename). "
            }

            NSLog("[ChatView] Importing file: %@ -> %@ (special=%d, skill=%d)", filename, targetDir.path, isDataFile ? 1 : 0, isSkill ? 1 : 0)

            backend.importFile(from: url, to: targetDir) { success, name in
                if success {
                    NSLog("[ChatView] File imported: %@", name)
                    if isDataFile {
                        messages.append(ChatMessage(role: .assistant, content: contextMsg))
                    } else {
                        inputText = contextMsg
                    }
                } else {
                    NSLog("[ChatView] File import failed: %@", name)
                    messages.append(ChatMessage(role: .assistant, content: "Failed to import file: \(name)"))
                }
            }
        case .failure(let error):
            NSLog("[ChatView] File picker error: %@", error.localizedDescription)
            messages.append(ChatMessage(role: .assistant, content: "File picker error: \(error.localizedDescription)"))
        }
    }
}

// MARK: - Leopard-styled Chat Bubble

struct LeopardChatBubble: View {
    let message: ChatMessage
    let index: Int
    @State private var showShareSheet = false

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 3) {
                if message.role == .tool {
                    HStack(spacing: 4) {
                        Image(systemName: message.toolInfo == "calling" ? "gearshape.fill" : "wrench.fill")
                            .font(.system(size: 9))
                        Text(message.toolInfo ?? "tool")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(Color(red: 0.4, green: 0.3, blue: 0.6))
                }

                if message.role == .file {
                    fileCardView
                } else {
                    MarkdownText(message.content, baseColor: textColor)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(bubbleBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(borderColor, lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                }

                Text(message.timestamp, style: .time)
                    .font(.system(size: 9))
                    .foregroundColor(Color(red: 0.6, green: 0.6, blue: 0.63))
            }
            .frame(maxWidth: 300, alignment: message.role == .user ? .trailing : .leading)

            if message.role != .user { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(index % 2 == 0 ? Color.leopardStripe1 : Color.leopardStripe2)
        .sheet(isPresented: $showShareSheet) {
            if let path = message.filePath {
                ShareSheet(items: [URL(fileURLWithPath: path)])
            }
        }
    }

    @ViewBuilder
    private var fileCardView: some View {
        let parts = message.content.components(separatedBy: "\n")
        let fileName = parts.first ?? "file"
        let fileSize = parts.count > 1 ? parts[1] : ""
        let ext = (fileName as NSString).pathExtension.lowercased()
        let icon = fileIcon(for: ext)

        Button {
            showShareSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(fileColor(for: ext))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.18))
                        .lineLimit(1)
                    Text(fileSize)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .background(
                ZStack {
                    Color(red: 0.95, green: 0.97, blue: 1.0)
                    LinearGradient(
                        colors: [Color.white.opacity(0.6), Color.white.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .center
                    )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.blue.opacity(0.25), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
    }

    private func fileIcon(for ext: String) -> String {
        switch ext {
        case "txt", "md", "log": return "doc.text.fill"
        case "py", "swift", "js", "ts", "html", "css", "json", "xml", "yml", "yaml":
            return "chevron.left.forwardslash.chevron.right"
        case "csv": return "tablecells.fill"
        case "xlsx", "xls": return "tablecells.fill"
        case "pdf": return "doc.richtext.fill"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo.fill"
        default: return "doc.fill"
        }
    }

    private func fileColor(for ext: String) -> Color {
        switch ext {
        case "py": return Color(red: 0.2, green: 0.4, blue: 0.7)
        case "swift": return .orange
        case "js", "ts": return Color(red: 0.9, green: 0.7, blue: 0.1)
        case "html", "css": return Color(red: 0.8, green: 0.3, blue: 0.2)
        case "json", "xml", "yml", "yaml": return Color(red: 0.5, green: 0.5, blue: 0.5)
        case "csv", "xlsx", "xls": return Color(red: 0.1, green: 0.6, blue: 0.3)
        case "pdf": return .red
        case "png", "jpg", "jpeg", "gif", "svg": return Color(red: 0.3, green: 0.5, blue: 0.8)
        case "txt", "md", "log": return Color(red: 0.4, green: 0.4, blue: 0.5)
        default: return Color(red: 0.45, green: 0.5, blue: 0.6)
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        switch message.role {
        case .user:
            ZStack {
                Color.leopardBubbleUser
                LinearGradient(
                    colors: [Color.white.opacity(0.3), Color.white.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .center
                )
            }
        case .assistant:
            ZStack {
                Color.leopardBubbleBot
                LinearGradient(
                    colors: [Color.white.opacity(0.6), Color.white.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .center
                )
            }
        case .tool:
            Color(red: 0.9, green: 0.88, blue: 0.95).opacity(0.8)
        case .system:
            Color(red: 0.95, green: 0.88, blue: 0.88)
        case .thinking:
            Color(red: 0.94, green: 0.94, blue: 0.97)
        case .file:
            Color(red: 0.95, green: 0.97, blue: 1.0)
        }
    }

    private var textColor: Color {
        switch message.role {
        case .user: return .white
        case .assistant: return Color(red: 0.15, green: 0.15, blue: 0.18)
        case .tool: return Color(red: 0.3, green: 0.25, blue: 0.45)
        case .system: return Color(red: 0.6, green: 0.15, blue: 0.1)
        case .thinking: return Color(red: 0.45, green: 0.45, blue: 0.55)
        case .file: return Color(red: 0.15, green: 0.15, blue: 0.18)
        }
    }

    private var borderColor: Color {
        switch message.role {
        case .user: return Color.blue.opacity(0.4)
        case .assistant: return Color.gray.opacity(0.3)
        case .tool: return Color.purple.opacity(0.2)
        case .system: return Color.red.opacity(0.2)
        case .thinking: return Color.purple.opacity(0.15)
        case .file: return Color.blue.opacity(0.25)
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Voice Recording Overlay

struct VoiceRecordingOverlay: View {
    let duration: TimeInterval
    let isRecording: Bool
    let onStop: () -> Void

    @State private var pulseScale: CGFloat = 1.0
    @State private var ringScale: CGFloat = 0.8
    @State private var ringOpacity: Double = 0.6

    var body: some View {
        ZStack {
            // Dim background
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { onStop() }

            VStack(spacing: 24) {
                Spacer()

                // Pulsing rings
                ZStack {
                    // Outer pulse ring
                    Circle()
                        .stroke(Color.red.opacity(ringOpacity * 0.3), lineWidth: 3)
                        .frame(width: 180, height: 180)
                        .scaleEffect(ringScale + 0.4)

                    // Middle pulse ring
                    Circle()
                        .stroke(Color.red.opacity(ringOpacity * 0.5), lineWidth: 4)
                        .frame(width: 140, height: 140)
                        .scaleEffect(ringScale + 0.2)

                    // Inner glow
                    Circle()
                        .fill(Color.red.opacity(0.15))
                        .frame(width: 120, height: 120)
                        .scaleEffect(pulseScale)

                    // Mic icon
                    VStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 44, weight: .medium))
                            .foregroundColor(.white)
                            .scaleEffect(pulseScale)

                        // Duration
                        Text(formatDuration(duration))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .monospacedDigit()
                    }
                }

                Text("Listening...")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))

                Spacer()

                // Done button
                Button(action: onStop) {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14))
                        Text("Done")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(width: 160, height: 52)
                    .background(
                        Capsule().fill(Color.red)
                    )
                    .shadow(color: .red.opacity(0.4), radius: 10, y: 4)
                }
                .padding(.bottom, 60)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulseScale = 1.15
            }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                ringScale = 1.0
                ringOpacity = 1.0
            }
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
