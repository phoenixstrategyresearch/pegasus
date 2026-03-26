import Foundation
import llama

/// On-device LLM engine using llama.cpp with Metal acceleration.
/// Loads GGUF models and runs chat completions directly on iPhone.
class LocalLLMEngine: ObservableObject {
    @Published var isLoaded = false
    @Published var isLoading = false
    @Published var loadError: String?
    @Published var modelDescription = ""

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var batch: llama_batch?
    private var nCtx: Int32 = 8192

    private let queue = DispatchQueue(label: "com.pegasus.llm", qos: .userInitiated)
    private var generating = false

    static let shared = LocalLLMEngine()

    init() {
        llama_backend_init()
    }

    deinit {
        unload()
        llama_backend_free()
    }

    // MARK: - Model Loading

    func load(path: String, contextSize: Int = 8192) {
        isLoading = true
        loadError = nil

        queue.async { [weak self] in
            guard let self else { return }
            self.doUnload()

            // Verify the file exists and is readable
            let fm = FileManager.default
            guard fm.fileExists(atPath: path) else {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.loadError = "File not found: \(path)"
                }
                return
            }

            let fileSize: UInt64
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let size = attrs[.size] as? UInt64 {
                fileSize = size
            } else {
                fileSize = 0
            }
            let fileSizeMB = fileSize / (1024 * 1024)
            print("[LocalLLM] Loading model: \(path) (\(fileSizeMB) MB)")

            // Check available memory
            let totalMem = ProcessInfo.processInfo.physicalMemory
            print("[LocalLLM] Device RAM: \(totalMem / (1024*1024*1024)) GB")

            var params = llama_model_default_params()
            #if targetEnvironment(simulator)
            params.n_gpu_layers = 0
            #else
            // Full GPU offload — push everything to Metal
            params.n_gpu_layers = 99
            print("[LocalLLM] Full GPU offload (n_gpu_layers=99)")
            #endif

            // Disable mmap for large models — iOS has strict virtual memory limits
            // and mmap of files > 4GB often fails with "Cannot allocate memory"
            if fileSizeMB > 3500 {
                params.use_mmap = false
                print("[LocalLLM] Disabled mmap for large model (\(fileSizeMB) MB)")
            } else {
                params.use_mmap = true
            }

            print("[LocalLLM] Loading with n_gpu_layers=\(params.n_gpu_layers), mmap=\(params.use_mmap)")

            guard let m = llama_model_load_from_file(path, params) else {
                DispatchQueue.main.async {
                    self.isLoading = false
                    if fileSizeMB > 4000 {
                        self.loadError = "Failed to load model (\(fileSizeMB) MB). This model is too large for this device. Try a Q4_K_M quantization (~2.5 GB) which runs well on iPhone."
                    } else {
                        self.loadError = "Failed to load model (\(fileSizeMB) MB). Device may not have enough memory, or the quantization type may not be supported."
                    }
                }
                return
            }

            print("[LocalLLM] Model loaded, creating context with n_ctx=\(contextSize)")

            var ctxParams = llama_context_default_params()
            // Clamp context to model's training size to prevent OOM
            let nCtxTrain = Int(llama_model_n_ctx_train(m))
            let effectiveCtx = min(contextSize, nCtxTrain)
            if effectiveCtx < contextSize {
                print("[LocalLLM] Clamping context from \(contextSize) to \(effectiveCtx) (model n_ctx_train=\(nCtxTrain))")
            }
            // Max out for premium devices — use all CPU cores
            let cpuCount = ProcessInfo.processInfo.processorCount
            let threads = cpuCount  // all cores
            ctxParams.n_ctx = UInt32(effectiveCtx)
            ctxParams.n_batch = 512
            ctxParams.n_ubatch = 512
            ctxParams.n_threads = Int32(threads)
            ctxParams.n_threads_batch = Int32(threads)
            ctxParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
            print("[LocalLLM] Using \(threads) threads, n_batch=512, n_ctx=\(effectiveCtx) (train=\(nCtxTrain))")

            guard let ctx = llama_init_from_model(m, ctxParams) else {
                llama_model_free(m)
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.loadError = "Failed to create context"
                }
                return
            }

            self.model = m
            self.context = ctx
            self.vocab = llama_model_get_vocab(m)
            self.nCtx = Int32(effectiveCtx)

            let desc = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
            desc.initialize(repeating: 0, count: 256)
            llama_model_desc(m, desc, 256)
            let descStr = String(cString: desc)
            desc.deallocate()

            let sizeGB = String(format: "%.1f", Double(llama_model_size(m)) / 1024.0 / 1024.0 / 1024.0)

            DispatchQueue.main.async {
                self.isLoaded = true
                self.isLoading = false
                self.modelDescription = "\(descStr) (\(sizeGB) GB)"
            }
        }
    }

    func unload() {
        queue.async { [weak self] in
            self?.doUnload()
            DispatchQueue.main.async {
                self?.isLoaded = false
                self?.modelDescription = ""
            }
        }
    }

    private func doUnload() {
        if let b = batch { llama_batch_free(b) }
        batch = nil
        if let c = context { llama_free(c) }
        context = nil
        if let m = model { llama_model_free(m) }
        model = nil
        vocab = nil
    }

    // MARK: - Chat Completion

    /// Run a chat completion with ChatML format. Streams tokens via the callback.
    /// When `dispatchToMain` is true (default), callbacks are dispatched to the main queue.
    /// Set to false when calling from background contexts (e.g. the OpenAI-compatible server).
    func chat(messages: [(role: String, content: String)], dispatchToMain: Bool = true, onToken: @escaping (String) -> Void, onDone: @escaping () -> Void) {
        guard let model, let context, let vocab else {
            onToken("[Error: No model loaded]")
            onDone()
            return
        }

        generating = true

        queue.async { [weak self] in
            guard let self else { return }

            let dispatch: (@escaping () -> Void) -> Void = dispatchToMain
                ? { block in DispatchQueue.main.async { block() } }
                : { block in block() }

            // Format prompt using the model's built-in chat template (if available)
            let prompt = self.applyTemplate(messages: messages)

            // Tokenize
            let tokens = self.tokenize(text: prompt, addBos: true)
            print("[LocalLLM] Tokenized prompt: \(tokens.count) tokens (max \(self.nCtx))")

            if tokens.count >= self.nCtx {
                print("[LocalLLM] ERROR: prompt too long! \(tokens.count) >= \(self.nCtx)")
                dispatch {
                    onToken("[Error: prompt too long for context window (\(tokens.count)/\(self.nCtx) tokens)]")
                    onDone()
                }
                return
            }

            // Clear KV cache
            llama_memory_clear(llama_get_memory(context), false)
            print("[LocalLLM] Starting prefill...")

            // Create batch and fill with prompt tokens
            let batchSize = 512
            var batch = llama_batch_init(Int32(max(tokens.count, batchSize)), 0, 1)
            defer { llama_batch_free(batch) }

            // Process prompt in chunks of batchSize for efficiency
            var promptPos = 0
            while promptPos < tokens.count {
                batch.n_tokens = 0
                let chunkEnd = min(promptPos + batchSize, tokens.count)
                for i in promptPos..<chunkEnd {
                    let idx = Int(batch.n_tokens)
                    batch.token[idx] = tokens[i]
                    batch.pos[idx] = Int32(i)
                    batch.n_seq_id[idx] = 1
                    batch.seq_id[idx]![0] = 0
                    batch.logits[idx] = (i == tokens.count - 1) ? 1 : 0
                    batch.n_tokens += 1
                }

                if llama_decode(context, batch) != 0 {
                    dispatch {
                        onToken("[Error: failed to process prompt]")
                        onDone()
                    }
                    return
                }
                promptPos = chunkEnd
            }

            // Sampling setup — optimized for small models (1B-3B) on device
            let sparams = llama_sampler_chain_default_params()
            let sampler = llama_sampler_chain_init(sparams)!

            // 1. Repetition penalty: look back 64 tokens, penalize at 1.1x
            llama_sampler_chain_add(sampler, llama_sampler_init_penalties(64, 1.1, 0.0, 0.0))
            // 2. DRY sampling: catch repeated phrases/sequences (critical for small models)
            let nCtxTrain = llama_model_n_ctx_train(model)
            let breakerStrings: [String] = ["\n", ":", "\"", "*"]
            // Keep NSString refs alive for the duration of the call
            let nsBreakers = breakerStrings.map { $0 as NSString }
            var cBreakers: [UnsafePointer<CChar>?] = nsBreakers.map { $0.utf8String }
            cBreakers.withUnsafeMutableBufferPointer { buf in
                llama_sampler_chain_add(sampler, llama_sampler_init_dry(vocab, nCtxTrain, 0.8, 1.75, 2, -1, buf.baseAddress, buf.count))
            }
            // 3. min_p truncation (better than top_k/top_p for small models)
            llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05, 1))
            // 4. Temperature
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.6))
            // 5. Final distribution sampling
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
            defer { llama_sampler_free(sampler) }

            var nCur = Int32(tokens.count)
            let maxTokens = min(self.nCtx, Int32(tokens.count) + 4096)
            var tempInvalidChars: [CChar] = []

            // Generation loop
            while nCur < maxTokens && self.generating {
                let newToken = llama_sampler_sample(sampler, context, batch.n_tokens - 1)

                // Check for end of generation
                if llama_vocab_is_eog(vocab, newToken) {
                    break
                }

                // Decode token to text
                let piece = self.tokenToPiece(token: newToken)
                tempInvalidChars.append(contentsOf: piece)

                if let str = String(validatingUTF8: tempInvalidChars + [0]) {
                    tempInvalidChars.removeAll()
                    if !str.isEmpty {
                        dispatch { onToken(str) }
                    }
                }

                // Prepare next batch
                batch.n_tokens = 0
                batch.token[0] = newToken
                batch.pos[0] = nCur
                batch.n_seq_id[0] = 1
                batch.seq_id[0]![0] = 0
                batch.logits[0] = 1
                batch.n_tokens = 1

                nCur += 1

                if llama_decode(context, batch) != 0 {
                    dispatch { onToken("\n[Error: decode failed]") }
                    break
                }
            }

            // Flush remaining chars
            if !tempInvalidChars.isEmpty {
                let str = String(cString: tempInvalidChars + [0])
                if !str.isEmpty {
                    dispatch { onToken(str) }
                }
            }

            self.generating = false
            dispatch { onDone() }
        }
    }

    func stopGenerating() {
        generating = false
    }

    // MARK: - Chat Template

    /// Apply the model's built-in chat template to format messages.
    /// Falls back to ChatML if no template, or plain text for base models.
    private func applyTemplate(messages: [(role: String, content: String)]) -> String {
        guard let model else {
            return messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n") + "\nassistant:"
        }

        // Check if model has a chat template
        let tmplPtr = llama_model_chat_template(model, nil)
        guard tmplPtr != nil else {
            // No template — use ChatML fallback
            print("[LocalLLM] No chat template in model, using ChatML fallback")
            return formatChatML(messages: messages)
        }

        // Build llama_chat_message array
        var llamaMsgs = messages.map { msg -> llama_chat_message in
            let role = strdup(msg.role)!
            let content = strdup(msg.content)!
            return llama_chat_message(role: role, content: content)
        }
        defer {
            for msg in llamaMsgs {
                free(UnsafeMutablePointer(mutating: msg.role))
                free(UnsafeMutablePointer(mutating: msg.content))
            }
        }

        // First call: get required buffer size
        let needed = llama_chat_apply_template(
            tmplPtr,
            &llamaMsgs, llamaMsgs.count,
            true,
            nil, 0
        )

        guard needed > 0 else {
            print("[LocalLLM] Template apply failed, using ChatML fallback")
            return formatChatML(messages: messages)
        }

        let bufSize = Int(needed) + 1
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bufSize)
        buf.initialize(repeating: 0, count: bufSize)
        defer { buf.deallocate() }

        let written = llama_chat_apply_template(
            tmplPtr,
            &llamaMsgs, llamaMsgs.count,
            true,
            buf, Int32(bufSize)
        )

        guard written > 0 else {
            print("[LocalLLM] Template apply returned 0, using ChatML fallback")
            return formatChatML(messages: messages)
        }

        let result = String(cString: buf)
        print("[LocalLLM] Using model's built-in chat template (\(result.count) chars)")
        return result
    }

    private func formatChatML(messages: [(role: String, content: String)]) -> String {
        var prompt = ""
        for msg in messages {
            prompt += "<|im_start|>\(msg.role)\n\(msg.content)<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"
        return prompt
    }

    // MARK: - Tokenization

    private func tokenize(text: String, addBos: Bool) -> [llama_token] {
        guard let vocab else { return [] }
        let utf8Count = text.utf8.count
        let n = utf8Count + (addBos ? 1 : 0) + 1
        let buf = UnsafeMutablePointer<llama_token>.allocate(capacity: n)
        defer { buf.deallocate() }

        let count = llama_tokenize(vocab, text, Int32(utf8Count), buf, Int32(n), addBos, true)
        return (0..<Int(count)).map { buf[$0] }
    }

    private func tokenToPiece(token: llama_token) -> [CChar] {
        guard let vocab else { return [] }
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 64)
        buf.initialize(repeating: 0, count: 64)
        defer { buf.deallocate() }

        let n = llama_token_to_piece(vocab, token, buf, 64, 0, false)
        if n < 0 {
            let buf2 = UnsafeMutablePointer<CChar>.allocate(capacity: Int(-n))
            buf2.initialize(repeating: 0, count: Int(-n))
            defer { buf2.deallocate() }
            let n2 = llama_token_to_piece(vocab, token, buf2, -n, 0, false)
            return Array(UnsafeBufferPointer(start: buf2, count: Int(n2)))
        }
        return Array(UnsafeBufferPointer(start: buf, count: Int(n)))
    }
}
