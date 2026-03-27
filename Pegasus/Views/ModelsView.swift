import SwiftUI

struct ModelsView: View {
    @EnvironmentObject var backend: BackendService
    @State private var showingImporter = false
    @State private var isLoadingModel = false
    @AppStorage("contextSize") private var contextSize = 4096.0
    @State private var statusMessage = ""

    // Cloud LLM
    @AppStorage("useCloudLLM") private var useCloudLLM = false
    @AppStorage("openaiAPIKey") private var apiKey = ""
    @AppStorage("openaiModel") private var cloudModel = "gpt-5.4"
    @AppStorage("cloudMaxTokens") private var cloudMaxTokens = 16384.0
    @AppStorage("cloudReasoningEffort") private var cloudReasoningEffort = "none"
    @State private var isTestingAPI = false
    @State private var apiStatus: APIStatus = .unknown

    enum APIStatus {
        case unknown, checking, online, error(String)
    }

    private let cloudModels: [(String, String, String)] = [
        ("GPT-5.4", "gpt-5.4", "$2.50 / $15"),
        ("GPT-5.4 mini", "gpt-5.4-mini", "$0.75 / $3"),
        ("GPT-5.2", "gpt-5.2", "$1.75 / $7"),
        ("GPT-4o", "gpt-4o", "$2.50 / $10"),
    ]

    private let reasoningEfforts = ["none", "low", "medium", "high", "xhigh"]

    private let maxTokenPresets: [(String, Double)] = [
        ("4K", 4096),
        ("8K", 8192),
        ("16K", 16384),
        ("32K", 32768),
        ("64K", 65536),
        ("128K", 128000),
    ]

    private let contextPresets: [(String, Double)] = [
        ("2K", 2048),
        ("4K", 4096),
        ("8K", 8192),
        ("16K", 16384),
        ("32K", 32768),
        ("64K", 65536),
        ("128K", 131072),
    ]

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Active Model Status
                statusSection

                // MARK: - Cloud LLM
                cloudToggleSection
                if useCloudLLM {
                    cloudAPISection
                    cloudModelPickerSection
                    cloudSettingsSection
                }

                // MARK: - On-Device
                onDeviceSettingsSection
                localModelsSection
                importSection
            }
            .leopardListStyle()
            .navigationTitle("Models")
            .onAppear {
                backend.fetchModels()
                if useCloudLLM && !apiKey.isEmpty {
                    testAPIKey()
                }
            }
            .refreshable { backend.fetchModels() }
            .overlay {
                if isLoadingModel {
                    loadingOverlay
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
        }
    }

    // MARK: - Status Section

    private var statusSection: some View {
        Section {
            // Active model row
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(activeStatusColor.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: activeStatusIcon)
                        .font(.system(size: 18))
                        .foregroundColor(activeStatusColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(activeModelName)
                        .font(.headline)
                    Text(activeStatusText)
                        .font(.caption)
                        .foregroundColor(activeStatusColor)
                }

                Spacer()

                if useCloudLLM && apiStatusIsOnline {
                    Text("ONLINE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green)
                        .clipShape(Capsule())
                } else if backend.isModelLoaded && !useCloudLLM {
                    Text("LOADED")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green)
                        .clipShape(Capsule())
                } else if backend.isModelLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .padding(.vertical, 4)

            // Agent status
            HStack(spacing: 8) {
                let python = EmbeddedPython.shared
                Circle()
                    .fill(python.isReady ? .green : (python.isInitializing ? .orange : .gray))
                    .frame(width: 8, height: 8)
                Text(python.isReady ? "Agent ready" : (python.isInitializing ? "Agent initializing..." : "Agent idle"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if python.isReady {
                    Text("\(useCloudLLM ? "cloud" : "on-device") tools")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Unload / disconnect
            if backend.isModelLoaded && !useCloudLLM {
                Button("Unload Model") {
                    backend.unloadModel()
                    backend.resetConversation {}
                    statusMessage = ""
                }
                .foregroundColor(.red)
                .font(.subheadline)
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let error = backend.modelError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        } header: {
            Text("Active Model")
        }
    }

    // MARK: - Cloud Section

    // MARK: - Cloud Toggle

    private var cloudToggleSection: some View {
        Section {
            Toggle(isOn: $useCloudLLM) {
                HStack(spacing: 10) {
                    Image(systemName: "cloud.fill")
                        .foregroundColor(.blue)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Cloud LLM")
                            .font(.subheadline.weight(.medium))
                        Text("Use OpenAI API instead of on-device model")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onChange(of: useCloudLLM) {
                // Reset session when switching between cloud and local
                backend.resetConversation {}
                if useCloudLLM && !apiKey.isEmpty {
                    testAPIKey()
                    if !EmbeddedPython.shared.isReady {
                        EmbeddedPython.shared.startAgent()
                    }
                }
            }
        } header: {
            Text("Cloud LLM (OpenAI)")
        } footer: {
            if useCloudLLM {
                Text("All agent tools, memory, and skills work with cloud models. Requires internet.")
            }
        }
    }

    // MARK: - Cloud API Key

    private var cloudAPISection: some View {
        Section {
            HStack {
                Image(systemName: "key.fill")
                    .foregroundColor(.secondary)
                    .frame(width: 24)
                SecureField("sk-proj-...", text: $apiKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit {
                        testAPIKey()
                    }
            }

            HStack(spacing: 8) {
                switch apiStatus {
                case .unknown:
                    Circle().fill(.gray).frame(width: 8, height: 8)
                    Text("Enter API key and tap Test")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .checking:
                    ProgressView().scaleEffect(0.6)
                    Text("Checking...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .online:
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Connected to OpenAI")
                        .font(.caption)
                        .foregroundColor(.green)
                case .error(let msg):
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
                Spacer()
                if !apiKey.isEmpty {
                    Button("Test") {
                        testAPIKey()
                    }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.borderedProminent)
                    .tint(.leopardAccent)
                    .controlSize(.small)
                }
            }
        } header: {
            Text("API Key")
        }
    }

    // MARK: - Cloud Model Picker

    private var cloudModelPickerSection: some View {
        Section {
            ForEach(cloudModels, id: \.1) { name, id, price in
                Button {
                    cloudModel = id
                    backend.resetConversation {}
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name)
                                .font(.subheadline.weight(cloudModel == id ? .semibold : .regular))
                            Text(price + " per 1M tokens")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if cloudModel == id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.leopardAccent)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Cloud Model")
        }
    }

    // MARK: - Cloud Model Settings

    private var cloudSettingsSection: some View {
        Section {
            // Reasoning Effort
            VStack(alignment: .leading, spacing: 8) {
                Text("Reasoning Effort")
                    .font(.subheadline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(reasoningEfforts, id: \.self) { effort in
                            Button {
                                cloudReasoningEffort = effort
                            } label: {
                                Text(effort)
                                    .font(.system(size: 12, weight: cloudReasoningEffort == effort ? .bold : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(cloudReasoningEffort == effort ? Color.leopardAccent : Color(UIColor.tertiarySystemFill))
                                    )
                                    .foregroundColor(cloudReasoningEffort == effort ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical, 4)

            // Max Output Tokens
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Max Output Tokens")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(cloudMaxTokens))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(maxTokenPresets, id: \.1) { label, value in
                            Button {
                                cloudMaxTokens = value
                            } label: {
                                Text(label)
                                    .font(.system(size: 12, weight: cloudMaxTokens == value ? .bold : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(cloudMaxTokens == value ? Color.leopardAccent : Color(UIColor.tertiarySystemFill))
                                    )
                                    .foregroundColor(cloudMaxTokens == value ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Cloud Settings")
        } footer: {
            Text("Reasoning effort controls thinking depth. Higher = smarter but slower/costlier. Max output caps response length (GPT-5.4 supports up to 128K).")
        }
    }

    // MARK: - On-Device Settings

    private var onDeviceSettingsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Context Window")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(contextSize)) tokens")
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(contextPresets, id: \.1) { label, value in
                            Button {
                                contextSize = value
                            } label: {
                                Text(label)
                                    .font(.system(size: 12, weight: contextSize == value ? .bold : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(contextSize == value ? Color.leopardAccent : Color(UIColor.tertiarySystemFill))
                                    )
                                    .foregroundColor(contextSize == value ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Slider(value: $contextSize, in: 2048...131072, step: 1024)
                    .tint(.leopardAccent)
                    .onAppear {
                        if contextSize < 2048 { contextSize = 2048 }
                        if contextSize > 131072 { contextSize = 131072 }
                    }

                Text("4K–8K recommended. 64K+ requires a model trained for long context and uses significant RAM.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("On-Device Settings")
        }
    }

    // MARK: - Local Models

    private var localModelsSection: some View {
        Section {
            ForEach(backend.availableModels) { model in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                            .font(.body)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text(formatSize(model.size_mb))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if model.size_mb > 4000 {
                                Text("Large")
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.15))
                                    .foregroundColor(.orange)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                    }
                    Spacer()
                    Button("Load") {
                        loadModel(path: model.path)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.leopardAccent)
                    .disabled(isLoadingModel || backend.isModelLoading)
                }
            }

            if backend.availableModels.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cube.box")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("No models found")
                        .foregroundColor(.secondary)
                    Text("Import a .gguf file or place one in Documents/models/")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
        } header: {
            Text("On-Device Models")
        }
    }

    private var importSection: some View {
        Section {
            Button {
                showingImporter = true
            } label: {
                Label("Import GGUF Model", systemImage: "square.and.arrow.down")
            }
        }
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.leopardAccent)
                Text("Loading model...")
                    .font(.headline)
                Text("This may take a minute")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(32)
            .background(.ultraThickMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .ignoresSafeArea()
    }

    // MARK: - Computed Properties

    private var activeModelName: String {
        if useCloudLLM {
            return cloudModels.first(where: { $0.1 == cloudModel })?.0 ?? cloudModel
        }
        if backend.isModelLoaded, let desc = LocalLLMEngine.shared.modelDescription.components(separatedBy: " (").first, !desc.isEmpty {
            return desc
        }
        if backend.isModelLoading { return "Loading..." }
        return "No Model"
    }

    private var activeStatusText: String {
        if useCloudLLM {
            switch apiStatus {
            case .online: return "Cloud · OpenAI API"
            case .checking: return "Checking connection..."
            case .error(let msg): return msg
            case .unknown: return apiKey.isEmpty ? "Set API key below" : "Checking..."
            }
        }
        if backend.isModelLoaded {
            return "On-device · \(Int(contextSize)) ctx · Metal GPU"
        }
        if backend.isModelLoading { return "Loading model..." }
        return "Load a model or enable Cloud LLM"
    }

    private var activeStatusColor: Color {
        if useCloudLLM {
            switch apiStatus {
            case .online: return .green
            case .checking: return .orange
            case .error: return .red
            case .unknown: return .gray
            }
        }
        if backend.isModelLoaded { return .green }
        if backend.isModelLoading { return .orange }
        return .gray
    }

    private var activeStatusIcon: String {
        if useCloudLLM { return "cloud.fill" }
        if backend.isModelLoaded { return "cpu.fill" }
        if backend.isModelLoading { return "arrow.down.circle" }
        return "cube.transparent"
    }

    private var apiStatusIsOnline: Bool {
        if case .online = apiStatus { return true }
        return false
    }

    // MARK: - Actions

    private func testAPIKey() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        // Store trimmed version back
        if trimmedKey != apiKey { apiKey = trimmedKey }
        apiStatus = .checking

        guard let url = URL(string: "https://api.openai.com/v1/models") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if error != nil {
                    apiStatus = .error("Connection failed")
                    return
                }
                guard let httpResp = response as? HTTPURLResponse else {
                    apiStatus = .error("No response")
                    return
                }
                switch httpResp.statusCode {
                case 200:
                    apiStatus = .online
                case 401:
                    // Log the response body for debugging
                    if let data = data, let body = String(data: data, encoding: .utf8) {
                        NSLog("[OpenAI] Auth failed: %@", body)
                    }
                    apiStatus = .error("Invalid API key")
                case 403:
                    // Project-scoped keys may get 403 on /v1/models but still work for chat
                    apiStatus = .online
                case 429:
                    // Rate limited means the key IS valid
                    apiStatus = .online
                default:
                    apiStatus = .error("HTTP \(httpResp.statusCode)")
                }
            }
        }.resume()
    }

    private func formatSize(_ mb: Double) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }

    private func loadModel(path: String) {
        isLoadingModel = true
        statusMessage = "Loading on device..."
        // Reset conversation when loading a new model
        backend.resetConversation {}
        backend.loadModel(path: path, nCtx: Int(contextSize)) { success in
            isLoadingModel = false
            if success {
                statusMessage = "Model loaded successfully"
                backend.fetchModels()
            } else {
                statusMessage = backend.modelError ?? "Failed to load model"
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        backend.importFile(from: url, to: BackendService.modelsDirectory) { success, name in
            if success {
                statusMessage = "Imported \(name)"
                backend.fetchModels()
            } else {
                statusMessage = "Import failed: \(name)"
            }
        }
    }
}
