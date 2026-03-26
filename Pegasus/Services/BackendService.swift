import Foundation
import Combine

/// Manages communication with the Python backend.
class BackendService: ObservableObject {
    @Published var backendHost = UserDefaults.standard.string(forKey: "backendHost") ?? "127.0.0.1"
    private var baseURL: String { "http://\(backendHost):5005" }
    #if os(macOS)
    private var pythonProcess: Process?
    #endif

    @Published var isBackendRunning = false
    @Published var isModelLoaded = false
    @Published var isModelLoading = false
    @Published var modelInfo: ModelInfo?
    @Published var modelError: String?
    @Published var availableModels: [ModelFile] = []

    struct ModelInfo: Codable {
        let status: String
        let n_ctx: Int?
        let n_vocab: Int?
        let error: String?
    }

    struct ModelFile: Codable, Identifiable {
        let name: String
        let path: String
        let size_mb: Double
        var id: String { name }
    }

    struct StatusResponse: Codable {
        let agent: String
        let model: ModelInfo
        let llm_url: String?
        let history_length: Int
    }

    // MARK: - Backend Lifecycle

    func startBackend() {
        NSLog("[BackendService] startBackend()")
        // Auto-start agent in cloud mode (no local model needed)
        if EmbeddedPython.useCloudLLM, EmbeddedPython.openAIAPIKey != nil {
            NSLog("[BackendService] Cloud mode enabled — starting agent without local model")
            EmbeddedPython.shared.startAgent()
        }
    }

    // MARK: - API Calls

    func checkStatus() {
        get("/status") { (result: Result<StatusResponse, Error>) in
            DispatchQueue.main.async {
                switch result {
                case .success(let status):
                    self.isBackendRunning = true
                    self.isModelLoaded = status.model.status == "loaded"
                    self.isModelLoading = status.model.status == "loading"
                    self.modelInfo = status.model
                    self.modelError = status.model.error
                case .failure:
                    self.isBackendRunning = false
                }
            }
        }
    }

    func fetchModels() {
        // Scan local device storage for models (no remote backend)
        DispatchQueue.main.async {
            self.availableModels = Self.scanLocalModels()
        }
    }

    static func scanLocalModels() -> [ModelFile] {
        let dir = modelsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return [] }
        return files.compactMap { url in
            guard url.pathExtension == "gguf" else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return ModelFile(
                name: url.lastPathComponent,
                path: url.path,
                size_mb: Double(size) / 1024.0 / 1024.0
            )
        }
    }

    struct LoadModelResponse: Codable {
        let status: String?
        let url: String?
        let error: String?
    }

    func loadModel(path: String, nCtx: Int = 4096, completion: @escaping (Bool) -> Void) {
        print("[Pegasus] loadModel path: \(path)")
        print("[Pegasus] fileExists: \(FileManager.default.fileExists(atPath: path))")

        // Check if this is a local file (on-device) or remote backend
        if FileManager.default.fileExists(atPath: path) {
            // On-device loading with llama.cpp
            print("[Pegasus] Loading on-device with context=\(nCtx)")
            isModelLoading = true
            modelError = nil
            let engine = LocalLLMEngine.shared
            engine.load(path: path, contextSize: nCtx)
            pollLocalModel(completion: completion)
        } else {
            // Remote backend loading
            let body: [String: Any] = [
                "model_path": path,
                "n_ctx": nCtx,
                "n_gpu_layers": -1,
                "chat_format": "chatml",
            ]
            post("/model/load", body: body) { (result: Result<LoadModelResponse, Error>) in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let resp) where resp.status == "loading" || resp.status == "loaded":
                        self.isModelLoading = true
                        self.modelError = nil
                        self.pollRemoteModel(completion: completion)
                    default:
                        self.isModelLoaded = false
                        self.isModelLoading = false
                        if case .success(let resp) = result {
                            self.modelError = resp.error
                        }
                        completion(false)
                    }
                }
            }
        }
    }

    private func pollLocalModel(attempts: Int = 0, completion: @escaping (Bool) -> Void) {
        guard attempts < 120 else {
            isModelLoading = false
            modelError = "Timed out loading model"
            completion(false)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let engine = LocalLLMEngine.shared
            if engine.isLoaded {
                self.isModelLoaded = true
                self.isModelLoading = false
                self.modelError = nil
                // Start the embedded Hermes agent
                NSLog("[BackendService] Model loaded — calling startAgent()")
                EmbeddedPython.shared.startAgent()
                completion(true)
            } else if let err = engine.loadError {
                self.isModelLoaded = false
                self.isModelLoading = false
                self.modelError = err
                completion(false)
            } else {
                self.pollLocalModel(attempts: attempts + 1, completion: completion)
            }
        }
    }

    private func pollRemoteModel(attempts: Int = 0, completion: @escaping (Bool) -> Void) {
        guard attempts < 120 else {
            isModelLoading = false
            modelError = "Timed out waiting for model to load"
            completion(false)
            return
        }

        checkStatus()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if self.isModelLoaded {
                self.isModelLoading = false
                self.modelError = nil
                completion(true)
            } else if self.modelError != nil {
                self.isModelLoading = false
                completion(false)
            } else {
                self.pollRemoteModel(attempts: attempts + 1, completion: completion)
            }
        }
    }

    func unloadModel() {
        let engine = LocalLLMEngine.shared
        if engine.isLoaded {
            engine.unload()
            isModelLoaded = false
            modelInfo = nil
        } else {
            post("/model/unload", body: [:]) { (_: Result<[String: String], Error>) in
                DispatchQueue.main.async {
                    self.isModelLoaded = false
                    self.modelInfo = nil
                }
            }
        }
    }

    // Track chat history for on-device ChatML conversations
    private static let onDeviceSystemPrompt = """
You are Pegasus - a private AI agent running on-device. No cloud. No surveillance. Just results.

You have persistent memory, skills, a full shell (70+ commands), package management, web access, and file tools. You remember across sessions and get sharper over time.

Rules:
- ACT, DON'T NARRATE. Call tools silently and immediately.
- Be direct. No filler. Answer precisely.
- After tool results, synthesize into clean insights.
- You have shell_exec (ls, grep, find, curl, wget, python, pip, sed, awk, tar, zip, pipes, redirects).
- Install packages with pip_install or shell_exec('pip install X').
- Use web_search for any lookup. Use web_fetch for URLs.
- Store important info with memory_write. It persists across sessions.
"""

    private var chatHistory: [(role: String, content: String)] = [
        (role: "system", content: BackendService.onDeviceSystemPrompt)
    ]

    func sendMessage(_ message: String, completion: @escaping (String) -> Void) {
        // Route through agent API if available (embedded or remote)
        if EmbeddedPython.shared.isReady || isBackendRunning {
            let body = ["message": message]
            post("/chat", body: body) { (result: Result<[String: String], Error>) in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let resp):
                        completion(resp["response"] ?? "No response")
                    case .failure(let error):
                        completion("Error: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            // Fallback: raw on-device chat
            let engine = LocalLLMEngine.shared
            chatHistory.append((role: "user", content: message))
            var response = ""
            engine.chat(messages: chatHistory, onToken: { token in
                response += token
            }, onDone: {
                self.chatHistory.append((role: "assistant", content: response))
                completion(response)
            })
        }
    }

    func sendMessageStreaming(_ message: String, onEvent: @escaping (StreamEvent) -> Void) {
        // Route 1: Embedded Hermes agent (Python on-device) — direct call, no HTTP
        // Route 2: Remote backend (HTTP to port 5005)
        // Route 3: Raw on-device chat (fallback, no tools)
        let engine = LocalLLMEngine.shared
        let python = EmbeddedPython.shared

        NSLog("[BackendService] sendMessageStreaming: python.isReady=%d, isBackendRunning=%d, engine.isLoaded=%d",
              python.isReady ? 1 : 0, isBackendRunning ? 1 : 0, engine.isLoaded ? 1 : 0)

        if python.isReady {
            // Call Python agent directly via file-based IPC (no HTTP)
            NSLog("[BackendService] Routing to Python agent")
            python.runAgentStreaming(message: message, onEvent: onEvent)
            return
        }

        if isBackendRunning {
            // Remote backend via HTTP
            NSLog("[BackendService] Routing to remote backend")
            sendMessageViaAgent(message, onEvent: onEvent)
            return
        }

        // Cloud LLM: always prefer Python agent (has tools + routes to OpenAI via callOpenAI)
        if EmbeddedPython.useCloudLLM, EmbeddedPython.openAIAPIKey != nil {
            if !python.isReady {
                NSLog("[BackendService] Cloud mode - agent not ready (initializing=%d, error=%@)",
                      python.isInitializing ? 1 : 0, python.error ?? "none")
                onEvent(.event(type: "status", content: "Agent tools loading..."))
                // Try starting if not already
                if !python.isInitializing {
                    python.retryInit()
                }
                DispatchQueue.global().async {
                    var waited = 0
                    while !python.isReady && waited < 30 {
                        Thread.sleep(forTimeInterval: 1)
                        waited += 1
                    }
                    if python.isReady {
                        NSLog("[BackendService] Agent ready after %ds, routing to Python agent", waited)
                        python.runAgentStreaming(message: message, onEvent: onEvent)
                    } else {
                        NSLog("[BackendService] Agent not ready after 30s, using direct cloud chat")
                        self.sendMessageCloudChat(message, apiKey: EmbeddedPython.openAIAPIKey!, onEvent: onEvent)
                    }
                }
                return
            }
        }

        if engine.isLoaded {
            // Fallback: raw on-device chat without tools
            NSLog("[BackendService] Routing to raw chat (no Python agent)")
            // Notify user that agent tools aren't available yet
            let python = EmbeddedPython.shared
            if python.isInitializing {
                onEvent(.event(type: "status", content: "Agent still loading, using basic chat..."))
            } else if !python.isReady {
                onEvent(.event(type: "status", content: "Agent not ready, using basic chat..."))
            }
            sendMessageRawChat(message, onEvent: onEvent)
            return
        }

        // No model loaded and no backend — error
        onEvent(.error("No model loaded. Go to Models tab to load a GGUF model, or enable Cloud LLM in Settings."))
    }

    /// Send via remote backend HTTP API (port 5005)
    private func sendMessageViaAgent(_ message: String, onEvent: @escaping (StreamEvent) -> Void) {
        guard let url = URL(string: "\(baseURL)/chat/stream") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["message": message])
        request.timeoutInterval = 120

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }

            // If the remote API is unreachable, fall back to raw chat
            if error != nil || data == nil {
                print("[BackendService] Remote API unreachable, falling back to raw chat")
                DispatchQueue.main.async {
                    self.sendMessageRawChat(message, onEvent: onEvent)
                }
                return
            }

            let text = String(data: data!, encoding: .utf8) ?? ""
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("data: ") {
                    let payload = String(trimmed.dropFirst(6))
                    if payload == "[DONE]" {
                        DispatchQueue.main.async { onEvent(.done) }
                        return
                    }
                    if let jsonData = payload.data(using: .utf8),
                       let event = try? JSONDecoder().decode(RawStreamEvent.self, from: jsonData) {
                        DispatchQueue.main.async {
                            onEvent(.event(type: event.type, content: event.content))
                        }
                    }
                }
            }
        }
        task.resume()
    }

    /// Fallback: raw on-device chat (no tools, no agent)
    private func sendMessageRawChat(_ message: String, onEvent: @escaping (StreamEvent) -> Void) {
        let engine = LocalLLMEngine.shared
        chatHistory.append((role: "user", content: message))
        var fullResponse = ""
        var rawBuffer = ""
        var insideThink = false

        engine.chat(messages: chatHistory, onToken: { token in
            rawBuffer += token

            while true {
                if !insideThink {
                    if let openRange = rawBuffer.range(of: "<think>") {
                        // Emit any text before the think tag
                        let before = String(rawBuffer[rawBuffer.startIndex..<openRange.lowerBound])
                        if !before.isEmpty {
                            let clean = Self.stripSpecialTokens(before)
                            if !clean.isEmpty {
                                fullResponse += clean
                                onEvent(.event(type: "text", content: clean))
                            }
                        }
                        rawBuffer = String(rawBuffer[openRange.upperBound...])
                        insideThink = true
                    } else if rawBuffer.contains("<") && !rawBuffer.contains(">") && rawBuffer.count < 10 {
                        // Might be a partial <think> tag, wait for more
                        break
                    } else {
                        // No think tag — emit as text
                        var clean = Self.stripSpecialTokens(rawBuffer)
                        if fullResponse.isEmpty {
                            clean = clean.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
                        }
                        if !clean.isEmpty {
                            fullResponse += clean
                            onEvent(.event(type: "text", content: clean))
                        }
                        rawBuffer = ""
                        break
                    }
                } else {
                    // Inside <think> block — look for </think>
                    if let closeRange = rawBuffer.range(of: "</think>") {
                        let thinkContent = String(rawBuffer[rawBuffer.startIndex..<closeRange.lowerBound])
                        if !thinkContent.isEmpty {
                            onEvent(.event(type: "thinking", content: thinkContent))
                        }
                        rawBuffer = String(rawBuffer[closeRange.upperBound...])
                        insideThink = false
                    } else if rawBuffer.count > 8 && !rawBuffer.hasSuffix("<") {
                        // Emit thinking content progressively (keep last few chars for partial tag)
                        let safe = String(rawBuffer.dropLast(8))
                        if !safe.isEmpty {
                            onEvent(.event(type: "thinking", content: safe))
                            rawBuffer = String(rawBuffer.suffix(8))
                        }
                        break
                    } else {
                        break
                    }
                }
            }
        }, onDone: {
            // Flush remaining buffer
            if !rawBuffer.isEmpty {
                if insideThink {
                    onEvent(.event(type: "thinking", content: rawBuffer))
                } else {
                    let clean = Self.stripSpecialTokens(rawBuffer)
                    if !clean.isEmpty {
                        fullResponse += clean
                        onEvent(.event(type: "text", content: clean))
                    }
                }
            }
            self.chatHistory.append((role: "assistant", content: fullResponse))
            onEvent(.done)
        })
    }

    // MARK: - Cloud Chat Tool Schemas

    /// OpenAI-format tool schemas for cloud mode (when Python agent is unavailable)
    private static let cloudToolSchemas: [[String: Any]] = [
        ["type": "function", "function": [
            "name": "web_search",
            "description": "Search the web using DuckDuckGo. Use for any research, lookup, or current events question.",
            "parameters": ["type": "object", "properties": [
                "query": ["type": "string", "description": "Search query"]
            ], "required": ["query"]]
        ]],
        ["type": "function", "function": [
            "name": "web_fetch",
            "description": "Fetch and read content from a URL. Use when user provides a URL or asks to scrape a website.",
            "parameters": ["type": "object", "properties": [
                "url": ["type": "string", "description": "URL to fetch"]
            ], "required": ["url"]]
        ]],
        ["type": "function", "function": [
            "name": "python_exec",
            "description": "Execute Python code in the workspace directory. All workspace files are accessible. Use pip_install first if you need a package like openpyxl. Set 'result' variable to return a value.",
            "parameters": ["type": "object", "properties": [
                "code": ["type": "string", "description": "Python code to execute. Set 'result' variable to return a value."]
            ], "required": ["code"]]
        ]],
        ["type": "function", "function": [
            "name": "file_read",
            "description": "Read a file from the workspace.",
            "parameters": ["type": "object", "properties": [
                "path": ["type": "string", "description": "Relative path to file"]
            ], "required": ["path"]]
        ]],
        ["type": "function", "function": [
            "name": "file_write",
            "description": "Write content to a file in the workspace.",
            "parameters": ["type": "object", "properties": [
                "path": ["type": "string", "description": "Relative path to file"],
                "content": ["type": "string", "description": "Content to write"]
            ], "required": ["path", "content"]]
        ]],
        ["type": "function", "function": [
            "name": "file_list",
            "description": "List files and directories in the workspace.",
            "parameters": ["type": "object", "properties": [
                "path": ["type": "string", "description": "Relative directory path (default: root)"]
            ], "required": []]
        ]],
        ["type": "function", "function": [
            "name": "memory_write",
            "description": "Write to persistent memory. Stores information across sessions.",
            "parameters": ["type": "object", "properties": [
                "target": ["type": "string", "description": "memory or user"],
                "action": ["type": "string", "description": "add, replace, or remove"],
                "content": ["type": "string", "description": "Content to store"]
            ], "required": ["target", "action", "content"]]
        ]],
        ["type": "function", "function": [
            "name": "pip_install",
            "description": "Install a Python package from PyPI. Works on iOS without pip or shell. Downloads wheel and extracts it. Only pure-Python packages supported.",
            "parameters": ["type": "object", "properties": [
                "package": ["type": "string", "description": "Package name (e.g. 'openpyxl', 'requests')"],
                "version": ["type": "string", "description": "Optional specific version"]
            ], "required": ["package"]]
        ]],
        ["type": "function", "function": [
            "name": "shell_exec",
            "description": "Execute shell commands. Supports ls, cat, grep, find, head, tail, cp, mv, rm, mkdir, curl, wget, sed, wc, sort, python, pip install, pipes (|), chains (&&), and redirects (>, >>). All commands run in the workspace.",
            "parameters": ["type": "object", "properties": [
                "command": ["type": "string", "description": "Shell command (e.g. 'ls -la', 'grep -r pattern .', 'cat file.txt | head -20')"],
                "timeout": ["type": "integer", "description": "Timeout in seconds (default 30)"]
            ], "required": ["command"]]
        ]],
    ]

    /// Dispatch a tool call locally via Python agent
    private func dispatchCloudTool(name: String, arguments: [String: Any]) -> String {
        let python = EmbeddedPython.shared
        let argsJSON = (try? JSONSerialization.data(withJSONObject: arguments))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return python.dispatchTool(name: name, argumentsJSON: argsJSON)
    }

    /// Direct cloud chat with OpenAI API with native tool calling
    private func sendMessageCloudChat(_ message: String, apiKey: String, onEvent: @escaping (StreamEvent) -> Void) {
        let model = EmbeddedPython.openAIModel

        let cloudSystemPrompt = """
You are Pegasus - a private AI agent running on-device. No cloud dependency. No surveillance. Just results. You have persistent memory, skills, a full shell, package management, web access, and file tools. ACT, DON'T NARRATE - call tools silently and immediately. After tool results, synthesize into clean insights. You have shell_exec with 70+ commands (ls, grep, find, curl, wget, python, pip, sed, awk, tar, zip, pipes, redirects, chains). Install packages with pip_install or shell_exec('pip install X'). Be direct. No filler.
"""
        if chatHistory.isEmpty || chatHistory[0].role != "system" {
            chatHistory.insert((role: "system", content: cloudSystemPrompt), at: 0)
        }
        chatHistory.append((role: "user", content: message))

        // Non-streaming call with tools to handle tool_calls loop
        cloudChatWithTools(model: model, apiKey: apiKey, maxIterations: 5, onEvent: onEvent)
    }

    /// Run a cloud chat loop that handles tool calls.
    /// Builds messages manually as JSON strings to guarantee correct format.
    private func cloudChatWithTools(model: String, apiKey: String, maxIterations: Int, onEvent: @escaping (StreamEvent) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Build messages as raw JSON string to avoid any Swift dict serialization issues
            // Start with chatHistory (only system/user/assistant, no tool messages)
            var jsonMessages: [String] = []
            for entry in self.chatHistory {
                if entry.role == "tool" { continue }
                let escaped = self.jsonEscape(entry.content)
                jsonMessages.append("{\"role\":\"\(entry.role)\",\"content\":\"\(escaped)\"}")
            }

            for iteration in 0..<maxIterations {
                NSLog("[CloudChat] Iteration %d, %d messages", iteration, jsonMessages.count)

                DispatchQueue.main.async {
                    onEvent(.event(type: "status", content: iteration == 0 ? "Thinking..." : "Analyzing results..."))
                }

                // Build tools JSON
                guard let toolsData = try? JSONSerialization.data(withJSONObject: Self.cloudToolSchemas),
                      let toolsJSON = String(data: toolsData, encoding: .utf8) else { return }

                let messagesJSON = "[" + jsonMessages.joined(separator: ",") + "]"
                let bodyJSON = "{\"model\":\"\(model)\",\"messages\":\(messagesJSON),\"tools\":\(toolsJSON),\"tool_choice\":\"auto\",\"temperature\":0.7,\"max_completion_tokens\":4096}"

                guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return }

                NSLog("[CloudChat] Sending %d bytes", bodyJSON.count)
                if iteration > 0 {
                    NSLog("[CloudChat] Body: %@", String(bodyJSON.prefix(3000)))
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.httpBody = bodyJSON.data(using: .utf8)
                request.timeoutInterval = 120

                let semaphore = DispatchSemaphore(value: 0)
                var responseData: Data?
                var responseError: Error?
                URLSession.shared.dataTask(with: request) { data, _, error in
                    responseData = data
                    responseError = error
                    semaphore.signal()
                }.resume()
                semaphore.wait()

                if let error = responseError {
                    DispatchQueue.main.async { onEvent(.error("API error: \(error.localizedDescription)")) }
                    return
                }

                guard let data = responseData else {
                    DispatchQueue.main.async { onEvent(.error("No response data")) }
                    return
                }

                // Log raw response for debugging
                let rawResp = String(data: data.prefix(1000), encoding: .utf8) ?? "?"
                NSLog("[CloudChat] Response: %@", rawResp)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let choice = choices.first,
                      let respMessage = choice["message"] as? [String: Any] else {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let err = json["error"] as? [String: Any],
                       let msg = err["message"] as? String {
                        DispatchQueue.main.async { onEvent(.error("OpenAI: \(msg)")) }
                    } else {
                        DispatchQueue.main.async { onEvent(.error("Invalid API response")) }
                    }
                    return
                }

                let content = respMessage["content"] as? String ?? ""
                let toolCalls = respMessage["tool_calls"] as? [[String: Any]]

                // No tool calls = final response
                if toolCalls == nil || toolCalls!.isEmpty {
                    self.chatHistory.append((role: "assistant", content: content))
                    DispatchQueue.main.async {
                        onEvent(.event(type: "text", content: content))
                        onEvent(.done)
                    }
                    return
                }

                // Build assistant message JSON string directly (guaranteed correct format)
                var tcJsonParts: [String] = []
                for tc in toolCalls! {
                    guard let tcFunc = tc["function"] as? [String: Any],
                          let tcName = tcFunc["name"] as? String,
                          let tcId = tc["id"] as? String else { continue }
                    let argsStr = self.jsonEscape(tcFunc["arguments"] as? String ?? "{}")
                    tcJsonParts.append("{\"id\":\"\(tcId)\",\"type\":\"function\",\"function\":{\"name\":\"\(tcName)\",\"arguments\":\"\(argsStr)\"}}")
                }

                let assistantJSON = "{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[\(tcJsonParts.joined(separator: ","))]}"
                jsonMessages.append(assistantJSON)
                NSLog("[CloudChat] Added assistant msg with %d tool_calls", tcJsonParts.count)

                // Dispatch each tool call
                for tc in toolCalls! {
                    guard let tcFunc = tc["function"] as? [String: Any],
                          let tcName = tcFunc["name"] as? String,
                          let tcId = tc["id"] as? String else { continue }

                    let argsStr = tcFunc["arguments"] as? String ?? "{}"
                    let args = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8)) as? [String: Any]) ?? [:]

                    NSLog("[CloudChat] Tool: %@(%@)", tcName, String(argsStr.prefix(100)))
                    DispatchQueue.main.async {
                        onEvent(.event(type: "tool_call", content: tcName))
                    }

                    let result = self.dispatchCloudTool(name: tcName, arguments: args)
                    let truncated = result.count > 3000 ? String(result.prefix(3000)) + "\n[truncated]" : result

                    DispatchQueue.main.async {
                        onEvent(.event(type: "tool_result", content: String(truncated.prefix(200))))
                    }

                    // Add tool result as raw JSON string
                    let toolJSON = "{\"role\":\"tool\",\"tool_call_id\":\"\(tcId)\",\"content\":\"\(self.jsonEscape(truncated))\"}"
                    jsonMessages.append(toolJSON)
                }
            }

            self.chatHistory.append((role: "assistant", content: "[Used tools but reached max iterations]"))
            DispatchQueue.main.async {
                onEvent(.event(type: "text", content: "[Max tool iterations reached]"))
                onEvent(.done)
            }
        }
    }

    /// Escape a string for JSON embedding
    private func jsonEscape(_ s: String) -> String {
        var result = s
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "\"", with: "\\\"")
        result = result.replacingOccurrences(of: "\n", with: "\\n")
        result = result.replacingOccurrences(of: "\r", with: "\\r")
        result = result.replacingOccurrences(of: "\t", with: "\\t")
        // Remove control characters
        result = result.unicodeScalars.filter { $0.value >= 32 || $0.value == 10 || $0.value == 9 }
            .map { String($0) }.joined()
        return result
    }

    func resetConversation(completion: @escaping () -> Void) {
        // Reset Swift-side chat history
        chatHistory = [
            (role: "system", content: Self.onDeviceSystemPrompt)
        ]
        // Reset Python agent conversation history
        EmbeddedPython.shared.resetAgent()
        // Reset remote backend (if connected)
        post("/reset", body: [:]) { (_: Result<[String: String], Error>) in
            DispatchQueue.main.async { completion() }
        }
    }

    func interruptAgent() {
        // Stop the LLM engine immediately
        LocalLLMEngine.shared.stopGenerating()
        // Signal the Python agent to stop its loop
        let interruptFile = NSTemporaryDirectory() + "pegasus_interrupt"
        try? "1".write(toFile: interruptFile, atomically: true, encoding: .utf8)
        // Invalidate the current generation so the old timer/completion stop
        EmbeddedPython.shared.cancelCurrentGeneration()
        // Clean up any pending LLM request file
        try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "pegasus_llm_request.json")
        // Write a fake error response to unblock the Python polling loop immediately
        // (it may be stuck waiting for a response file that will never come)
        let errorResponse: [String: Any] = [
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": "[Stopped]"],
                "finish_reason": "stop"
            ]]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: errorResponse) {
            let responsePath = NSTemporaryDirectory() + "pegasus_llm_response.json"
            try? data.write(to: URL(fileURLWithPath: responsePath), options: .atomic)
        }
        // Clear the Python log so terminal doesn't re-read stale entries
        let logPath = NSTemporaryDirectory() + "pegasus_python.log"
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
        post("/interrupt", body: [:]) { (_: Result<[String: String], Error>) in }
    }

    // MARK: - Cron Jobs

    struct CronJob: Codable, Identifiable {
        let id: String
        let name: String
        let command: String
        let interval: String
        let job_type: String
        let enabled: Bool
        let created_at: String
        let last_run: String?
        let last_result: CronResult?
        let run_count: Int
    }

    struct CronResult: Codable {
        let type: String?
        let response: String?
        let stdout: String?
        let stderr: String?
        let returncode: Int?
        let error: String?
    }

    struct CronLogEntry: Codable {
        let timestamp: String
        let name: String
        let output: CronResult
    }

    func fetchCronJobs(completion: @escaping ([CronJob]) -> Void) {
        struct Resp: Codable { let jobs: [CronJob] }
        get("/cron") { (result: Result<Resp, Error>) in
            DispatchQueue.main.async {
                completion((try? result.get())?.jobs ?? [])
            }
        }
    }

    func createCronJob(name: String, command: String, interval: String, jobType: String, completion: @escaping (Bool) -> Void) {
        let body: [String: Any] = [
            "name": name,
            "command": command,
            "interval": interval,
            "job_type": jobType,
        ]
        post("/cron/create", body: body) { (result: Result<[String: String], Error>) in
            DispatchQueue.main.async {
                completion((try? result.get()) != nil)
            }
        }
    }

    func deleteCronJob(jobId: String, completion: @escaping () -> Void) {
        post("/cron/delete", body: ["job_id": jobId]) { (_: Result<[String: String], Error>) in
            DispatchQueue.main.async { completion() }
        }
    }

    func toggleCronJob(jobId: String, enabled: Bool, completion: @escaping () -> Void) {
        let body: [String: Any] = ["job_id": jobId, "enabled": enabled]
        post("/cron/toggle", body: body) { (_: Result<[String: String], Error>) in
            DispatchQueue.main.async { completion() }
        }
    }

    func fetchCronLogs(jobId: String, tail: Int = 50, completion: @escaping ([CronLogEntry]) -> Void) {
        struct Resp: Codable { let job_id: String; let logs: [CronLogEntry] }
        get("/cron/logs/\(jobId)?tail=\(tail)") { (result: Result<Resp, Error>) in
            DispatchQueue.main.async {
                completion((try? result.get())?.logs ?? [])
            }
        }
    }

    // MARK: - File Management (SOUL.md, MEMORY.md, USER.md)

    func readDataFile(_ filename: String, completion: @escaping (String) -> Void) {
        let path = Self.dataDirectory.appendingPathComponent(filename)
        DispatchQueue.global().async {
            let content = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
            DispatchQueue.main.async { completion(content) }
        }
    }

    func writeDataFile(_ filename: String, content: String, completion: @escaping (Bool) -> Void) {
        let dir = Self.dataDirectory
        let path = dir.appendingPathComponent(filename)
        DispatchQueue.global().async {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try content.write(to: path, atomically: true, encoding: .utf8)
                DispatchQueue.main.async { completion(true) }
            } catch {
                print("Write failed: \(error)")
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    static var dataDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pegasus_data")
    }

    static var modelsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models")
    }

    // MARK: - File Import

    func importFile(from sourceURL: URL, to directory: URL, completion: @escaping (Bool, String) -> Void) {
        // MUST start security-scoped access on the calling thread before dispatching
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        let filename = sourceURL.lastPathComponent
        NSLog("[ImportFile] Source: %@, path: %@, accessing=%d, exists=%d",
              filename, sourceURL.path, accessing ? 1 : 0,
              FileManager.default.fileExists(atPath: sourceURL.path) ? 1 : 0)

        // Read data NOW while we have security-scoped access (before async dispatch)
        var fileData: Data?
        do {
            fileData = try Data(contentsOf: sourceURL)
            NSLog("[ImportFile] Read %d bytes from source", fileData?.count ?? 0)
        } catch {
            NSLog("[ImportFile] Failed to read source data: %@", error.localizedDescription)
        }

        DispatchQueue.global().async {
            defer {
                if accessing { sourceURL.stopAccessingSecurityScopedResource() }
            }

            let fm = FileManager.default
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                NSLog("[ImportFile] Failed to create directory: %@", error.localizedDescription)
            }

            let dest = directory.appendingPathComponent(filename)

            // Remove existing file at destination
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }

            // Strategy 1: Write pre-read data (most reliable for security-scoped URLs)
            if let data = fileData {
                do {
                    try data.write(to: dest, options: .atomic)
                    NSLog("[ImportFile] Data write succeeded: %@ (%d bytes)", filename, data.count)
                    DispatchQueue.main.async { completion(true, filename) }
                    return
                } catch {
                    NSLog("[ImportFile] Data write failed: %@", error.localizedDescription)
                }
            }

            // Strategy 2: Direct copy
            do {
                try fm.copyItem(at: sourceURL, to: dest)
                NSLog("[ImportFile] Direct copy succeeded: %@", filename)
                DispatchQueue.main.async { completion(true, filename) }
                return
            } catch {
                NSLog("[ImportFile] Direct copy failed: %@", error.localizedDescription)
            }

            // Strategy 3: NSFileCoordinator
            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            var copySuccess = false

            coordinator.coordinate(readingItemAt: sourceURL, options: [.forUploading], error: &coordError) { readURL in
                do {
                    if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                    try fm.copyItem(at: readURL, to: dest)
                    copySuccess = true
                    NSLog("[ImportFile] Coordinated copy succeeded: %@", filename)
                } catch {
                    NSLog("[ImportFile] Coordinated copy failed: %@", error.localizedDescription)
                }
            }

            if copySuccess {
                DispatchQueue.main.async { completion(true, filename) }
                return
            }

            NSLog("[ImportFile] All methods failed for %@", filename)
            DispatchQueue.main.async { completion(false, "Could not import \(filename)") }
        }
    }

    // MARK: - Text Filtering

    static func stripSpecialTokens(_ text: String) -> String {
        var s = text
        for tag in ["<|im_start|>", "<|im_end|>", "<|im_start|>assistant", "<|im_start|>user", "<|im_start|>system"] {
            s = s.replacingOccurrences(of: tag, with: "")
        }
        // Strip markdown image syntax ![alt](url)
        if let regex = try? NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\([^)]*\\)", options: []) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        // Strip bare image URLs
        if let regex = try? NSRegularExpression(pattern: "https?://\\S+\\.(png|jpg|jpeg|gif|svg|webp|ico)\\S*", options: .caseInsensitive) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s
    }

    // MARK: - HTTP Helpers

    private func get<T: Codable>(_ path: String, completion: @escaping (Result<T, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)\(path)") else { return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data else { return }
            do {
                let decoded = try JSONDecoder().decode(T.self, from: data)
                completion(.success(decoded))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func post<T: Codable>(_ path: String, body: [String: Any], completion: @escaping (Result<T, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)\(path)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data else { return }
            do {
                let decoded = try JSONDecoder().decode(T.self, from: data)
                completion(.success(decoded))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}

// MARK: - Stream Event Types

enum StreamEvent {
    case event(type: String, content: String)
    case done
    case error(String)
}

struct RawStreamEvent: Codable {
    let type: String
    let content: String
}

// MARK: - OpenAI SSE Stream Delegate

/// Handles streaming responses from OpenAI API via Server-Sent Events.
class OpenAIStreamDelegate: NSObject, URLSessionDataDelegate {
    private var buffer = ""
    private var fullResponse = ""
    private let onEvent: (StreamEvent) -> Void
    private let onComplete: (String) -> Void

    init(onEvent: @escaping (StreamEvent) -> Void, onComplete: @escaping (String) -> Void) {
        self.onEvent = onEvent
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        buffer += chunk

        // Parse SSE lines
        while let newlineRange = buffer.range(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newlineRange.lowerBound])
            buffer = String(buffer[newlineRange.upperBound...])

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data: ") else { continue }
            let payload = String(trimmed.dropFirst(6))

            if payload == "[DONE]" {
                DispatchQueue.main.async {
                    self.onComplete(self.fullResponse)
                    self.onEvent(.done)
                }
                return
            }

            guard let jsonData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { continue }

            if let content = delta["content"] as? String, !content.isEmpty {
                fullResponse += content
                DispatchQueue.main.async {
                    self.onEvent(.event(type: "text", content: content))
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                self.onEvent(.error("OpenAI API error: \(error.localizedDescription)"))
            }
        } else if fullResponse.isEmpty {
            // Non-streaming error response (e.g. auth failure)
            DispatchQueue.main.async {
                let errorMsg = self.buffer.isEmpty ? "Empty response from OpenAI" : self.buffer
                self.onEvent(.error(errorMsg))
            }
        }
    }
}
