import SwiftUI

struct FilesView: View {
    @EnvironmentObject var backend: BackendService
    @State private var soulContent = ""
    @State private var memoryContent = ""
    @State private var userContent = ""
    @State private var selectedFile: EditableFile?
    @State private var showingImporter = false
    @State private var saveStatus = ""
    @State private var workspaceFiles: [WorkspaceFile] = []
    @State private var showShareSheet = false
    @State private var shareURL: URL?

    struct WorkspaceFile: Identifiable {
        let id = UUID()
        let name: String
        let path: String
        let size: Int64
        let isDirectory: Bool
    }

    enum EditableFile: String, CaseIterable, Identifiable {
        case soul = "SOUL.md"
        case memory = "MEMORY.md"
        case user = "USER.md"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .soul: return "Soul / Personality"
            case .memory: return "Agent Memory"
            case .user: return "User Profile"
            }
        }

        var description: String {
            switch self {
            case .soul: return "Defines the agent's identity, personality, and core behavior. Replaces the default system prompt."
            case .memory: return "Agent's persistent notes — observations, learned patterns, environment details. Auto-managed but editable."
            case .user: return "What the agent knows about you — preferences, communication style, workflow habits."
            }
        }

        var icon: String {
            switch self {
            case .soul: return "sparkles"
            case .memory: return "brain"
            case .user: return "person.fill"
            }
        }

        var localLimit: Int {
            switch self {
            case .soul: return 5000
            case .memory: return 2200
            case .user: return 1375
            }
        }

        var cloudLimit: Int {
            switch self {
            case .soul: return 20000
            case .memory: return 20000
            case .user: return 10000
            }
        }

        var characterLimit: Int {
            let cloud = UserDefaults.standard.bool(forKey: "useCloudLLM")
            return cloud ? cloudLimit : localLimit
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(EditableFile.allCases) { file in
                        Button {
                            selectedFile = file
                            loadFile(file)
                        } label: {
                            HStack {
                                Image(systemName: file.icon)
                                    .foregroundColor(.orange)
                                    .frame(width: 30)
                                VStack(alignment: .leading) {
                                    Text(file.title)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text(file.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Agent Configuration")
                }

                Section {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Upload File to Workspace", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        loadWorkspaceFiles()
                    } label: {
                        Label("Refresh Files", systemImage: "arrow.clockwise")
                    }
                } header: {
                    Text("Workspace")
                } footer: {
                    Text("Files the agent can read, write, and generate.")
                }

                if !workspaceFiles.isEmpty {
                    Section {
                        ForEach(workspaceFiles) { file in
                            Button {
                                shareURL = URL(fileURLWithPath: file.path)
                                showShareSheet = true
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: file.isDirectory ? "folder.fill" : fileIcon(for: (file.name as NSString).pathExtension))
                                        .foregroundColor(file.isDirectory ? .blue : .orange)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(file.name)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        if !file.isDirectory {
                                            Text(formatSize(file.size))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .onDelete { indexSet in
                            deleteFiles(at: indexSet)
                        }
                    } header: {
                        Text("Workspace Files (\(workspaceFiles.count))")
                    }
                }

                if !saveStatus.isEmpty {
                    Section {
                        Text(saveStatus)
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }
            .navigationTitle("Files")
            .sheet(item: $selectedFile) { file in
                FileEditorView(
                    file: file,
                    content: bindingForFile(file),
                    onSave: { content in
                        saveFile(file, content: content)
                    }
                )
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = shareURL {
                    ShareSheet(items: [url])
                }
            }
            .onAppear {
                loadWorkspaceFiles()
            }
        }
    }

    private func loadFile(_ file: EditableFile) {
        backend.readDataFile(file.rawValue) { content in
            switch file {
            case .soul: soulContent = content
            case .memory: memoryContent = content
            case .user: userContent = content
            }
        }
    }

    private func saveFile(_ file: EditableFile, content: String) {
        backend.writeDataFile(file.rawValue, content: content) { success in
            saveStatus = success ? "\(file.rawValue) saved" : "Failed to save"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                saveStatus = ""
            }
        }
    }

    private func bindingForFile(_ file: EditableFile) -> Binding<String> {
        switch file {
        case .soul: return $soulContent
        case .memory: return $memoryContent
        case .user: return $userContent
        }
    }

    private func loadWorkspaceFiles() {
        let workspaceDir = BackendService.dataDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("pegasus_workspace")
        DispatchQueue.global().async {
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(
                at: workspaceDir,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                DispatchQueue.main.async { workspaceFiles = [] }
                return
            }

            var files: [WorkspaceFile] = []
            for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                files.append(WorkspaceFile(
                    name: url.lastPathComponent,
                    path: url.path,
                    size: Int64(values?.fileSize ?? 0),
                    isDirectory: values?.isDirectory ?? false
                ))
            }
            DispatchQueue.main.async { workspaceFiles = files }
        }
    }

    private func fileIcon(for ext: String) -> String {
        switch ext.lowercased() {
        case "txt", "md", "log": return "doc.text.fill"
        case "py", "swift", "js", "ts", "html", "css", "json", "xml", "yml", "yaml":
            return "chevron.left.forwardslash.chevron.right"
        case "csv", "xlsx", "xls": return "tablecells.fill"
        case "pdf": return "doc.richtext.fill"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo.fill"
        default: return "doc.fill"
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes > 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        } else if bytes > 1024 {
            return "\(bytes / 1024) KB"
        }
        return "\(bytes) bytes"
    }

    private func deleteFiles(at offsets: IndexSet) {
        let fm = FileManager.default
        for index in offsets {
            let file = workspaceFiles[index]
            try? fm.removeItem(atPath: file.path)
        }
        workspaceFiles.remove(atOffsets: offsets)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        let workspaceDir = BackendService.dataDirectory.deletingLastPathComponent()
            .appendingPathComponent("pegasus_workspace")
        for url in urls {
            backend.importFile(from: url, to: workspaceDir) { success, name in
                saveStatus = success ? "Uploaded \(name)" : "Failed: \(name)"
                if success { loadWorkspaceFiles() }
            }
        }
    }
}

struct FileEditorView: View {
    let file: FilesView.EditableFile
    @Binding var content: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: file.icon)
                    Text(file.title)
                        .font(.headline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(content.count)/\(file.characterLimit)")
                            .font(.caption)
                            .foregroundColor(content.count > file.characterLimit ? .red : .secondary)
                        HStack(spacing: 8) {
                            Label("\(file.localLimit)", systemImage: "cpu")
                            Label("\(file.cloudLimit)", systemImage: "cloud")
                        }
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    }
                }
                .padding()

                Divider()

                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)

                if file == .soul && content.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Leave empty to use the default personality, or write your own:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Load Template") {
                            content = soulTemplate
                        }
                        .font(.caption)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(content)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
    }

    private var soulTemplate: String {
        """
        You are Pegasus, a powerful local AI agent running entirely on-device.

        ## Personality
        - Direct and efficient
        - Curious about technical problems
        - Willing to take initiative with tools

        ## Behavior
        - Break complex tasks into steps
        - Use tools proactively — don't ask permission for every action
        - Create skills for workflows you'll repeat
        - Remember user preferences across sessions
        """
    }
}
