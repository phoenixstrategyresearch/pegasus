import Foundation
import Network
import llama

/// Minimal OpenAI-compatible HTTP server that wraps LocalLLMEngine.
/// The embedded Python agent connects here for LLM inference.
class LocalOpenAIServer {
    static let shared = LocalOpenAIServer()

    private var listener: NWListener?
    private let port: UInt16 = 8080
    private let queue = DispatchQueue(label: "com.pegasus.openai-server", attributes: .concurrent)
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            print("[OpenAIServer] Failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[OpenAIServer] Listening on port \(self.port)")
                self.isRunning = true
            case .failed(let error):
                print("[OpenAIServer] Failed: \(error)")
                self.isRunning = false
            default:
                break
            }
        }
        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveFullRequest(connection: connection, accumulated: Data())
    }

    private func receiveFullRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }

            // Check if we have the full HTTP request (headers + body)
            if let request = self.parseHTTPRequest(buffer) {
                self.routeRequest(request, connection: connection)
            } else if !isComplete && error == nil {
                // Need more data
                self.receiveFullRequest(connection: connection, accumulated: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    // MARK: - HTTP Parsing

    struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }

        // Find header/body separator
        guard let separatorRange = str.range(of: "\r\n\r\n") else { return nil }

        let headerPart = String(str[str.startIndex..<separatorRange.lowerBound])
        let lines = headerPart.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }

        let method = parts[0]
        let path = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Calculate body start offset in bytes
        let headerBytes = headerPart.utf8.count + 4 // +4 for \r\n\r\n
        let bodyData = data.count > headerBytes ? data[headerBytes...] : Data()

        // Check if we have the full body
        if let contentLength = headers["content-length"], let length = Int(contentLength) {
            if bodyData.count < length { return nil } // need more data
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: Data(bodyData))
    }

    // MARK: - Routing

    private func routeRequest(_ request: HTTPRequest, connection: NWConnection) {
        if request.method == "OPTIONS" {
            sendResponse(connection: connection, status: 200, body: [:])
            return
        }

        if request.method == "GET" && request.path == "/v1/models" {
            let engine = LocalLLMEngine.shared
            let models: [[String: Any]] = [
                [
                    "id": "local-model",
                    "object": "model",
                    "owned_by": "local",
                    "ready": engine.isLoaded,
                ]
            ]
            sendResponse(connection: connection, status: 200, body: ["object": "list", "data": models])
            return
        }

        if request.method == "POST" && request.path == "/v1/chat/completions" {
            handleChatCompletion(request, connection: connection)
            return
        }

        sendResponse(connection: connection, status: 404, body: ["error": "Not found"])
    }

    // MARK: - Chat Completions

    private func handleChatCompletion(_ request: HTTPRequest, connection: NWConnection) {
        print("[OpenAIServer] Received chat completion request (\(request.body.count) bytes)")
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let messagesRaw = json["messages"] as? [[String: Any]] else {
            print("[OpenAIServer] Failed to parse request body")
            sendResponse(connection: connection, status: 400, body: ["error": "Invalid request"])
            return
        }

        // Extract tools if provided (for Hermes tool-calling prompt injection)
        let tools = json["tools"] as? [[String: Any]]
        print("[OpenAIServer] Messages: \(messagesRaw.count), Tools: \(tools?.count ?? 0)")

        // Build messages array, injecting tool schemas into system prompt
        var messages: [(role: String, content: String)] = []

        for msg in messagesRaw {
            let role = msg["role"] as? String ?? "user"
            var content = msg["content"] as? String ?? ""

            // Inject Hermes tool-calling instructions into system message
            if role == "system" && tools != nil && !tools!.isEmpty {
                content = injectToolSchemas(systemPrompt: content, tools: tools!)
            }

            messages.append((role: role, content: content))
        }

        let engine = LocalLLMEngine.shared
        guard engine.isLoaded else {
            print("[OpenAIServer] No model loaded!")
            sendResponse(connection: connection, status: 503, body: [
                "error": ["message": "No model loaded", "type": "server_error"]
            ])
            return
        }

        // Log total prompt size
        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        print("[OpenAIServer] Total prompt: \(totalChars) chars across \(messages.count) messages")
        print("[OpenAIServer] Starting inference...")
        let startTime = CFAbsoluteTimeGetCurrent()

        // Run inference synchronously (this blocks the queue thread, which is fine)
        var fullResponse = ""
        var tokenCount = 0
        let semaphore = DispatchSemaphore(value: 0)

        engine.chat(messages: messages, dispatchToMain: false, onToken: { token in
            fullResponse += token
            tokenCount += 1
            if tokenCount == 1 {
                let prefillTime = CFAbsoluteTimeGetCurrent() - startTime
                print("[OpenAIServer] First token after \(String(format: "%.1f", prefillTime))s")
            }
        }, onDone: {
            let totalTime = CFAbsoluteTimeGetCurrent() - startTime
            print("[OpenAIServer] Done: \(tokenCount) tokens in \(String(format: "%.1f", totalTime))s")
            semaphore.signal()
        })

        semaphore.wait()

        // Parse Hermes tool calls from the response
        let (textContent, toolCalls) = parseHermesToolCalls(fullResponse)

        // Build OpenAI-format response
        var message: [String: Any] = ["role": "assistant"]

        if !toolCalls.isEmpty {
            message["content"] = textContent.isEmpty ? NSNull() : textContent
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
            // Strip any leftover special tokens from text
            var clean = textContent
            for tag in ["<|im_end|>", "<|im_start|>"] {
                clean = clean.replacingOccurrences(of: tag, with: "")
            }
            // Strip think blocks: remove everything from <think> to </think>
            while let openRange = clean.range(of: "<think>"),
                  let closeRange = clean.range(of: "</think>", range: openRange.upperBound..<clean.endIndex) {
                clean = String(clean[clean.startIndex..<openRange.lowerBound])
                    + String(clean[closeRange.upperBound...])
            }
            // Fallback: if only </think> remains (no matching <think>)
            if let thinkEnd = clean.range(of: "</think>") {
                clean = String(clean[thinkEnd.upperBound...])
            }
            clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
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
                "completion_tokens": 0,
                "total_tokens": 0,
            ]
        ]

        sendResponse(connection: connection, status: 200, body: response)
    }

    // MARK: - Hermes Tool Call Parsing

    struct ToolCall {
        let name: String
        let arguments: String // JSON string
    }

    private func parseHermesToolCalls(_ text: String) -> (String, [ToolCall]) {
        var toolCalls: [ToolCall] = []
        var textContent = text

        // Find all <tool_call>...</tool_call> blocks
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

            // Remove the tool_call block from text
            textContent = String(textContent[textContent.startIndex..<openRange.lowerBound])
                + String(textContent[closeRange.upperBound...])
        }

        textContent = textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return (textContent, toolCalls)
    }

    // MARK: - Hermes Tool Schema Injection

    private func injectToolSchemas(systemPrompt: String, tools: [[String: Any]]) -> String {
        // Build compact tool descriptions instead of full JSON schemas
        var toolLines: [String] = []
        for tool in tools {
            guard let fn = tool["function"] as? [String: Any],
                  let name = fn["name"] as? String,
                  let desc = fn["description"] as? String else { continue }

            var paramStr = ""
            if let params = fn["parameters"] as? [String: Any],
               let props = params["properties"] as? [String: Any] {
                let required = (params["required"] as? [String]) ?? []
                let paramParts: [String] = props.keys.sorted().compactMap { key in
                    guard let prop = props[key] as? [String: Any],
                          let type = prop["type"] as? String else { return nil }
                    let req = required.contains(key) ? "" : "?"
                    return "\(key): \(type)\(req)"
                }
                paramStr = "(\(paramParts.joined(separator: ", ")))"
            }

            toolLines.append("- \(name)\(paramStr): \(desc)")
        }

        let hermesToolPrompt = """

        You are a function calling AI model. Here are your tools:
        <tools>
        \(toolLines.joined(separator: "\n"))
        </tools>

        To call a tool, output a JSON object inside <tool_call></tool_call> tags:
        <tool_call>
        {"name": "<function-name>", "arguments": {"arg": "value"}}
        </tool_call>
        """

        return systemPrompt + "\n\n" + hermesToolPrompt
    }

    // MARK: - HTTP Response

    private func sendResponse(connection: NWConnection, status: Int, body: [String: Any]) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 503: statusText = "Service Unavailable"
        default: statusText = "Error"
        }

        let bodyData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let header = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(bodyData.count)\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type, Authorization\r
        Connection: close\r
        \r

        """

        var responseData = Data(header.utf8)
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
