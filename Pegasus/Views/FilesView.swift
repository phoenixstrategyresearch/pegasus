import SwiftUI
import QuickLook
import PhotosUI

struct FilesView: View {
    @EnvironmentObject var backend: BackendService
    @State private var soulContent = ""
    @State private var memoryContent = ""
    @State private var userContent = ""
    @State private var selectedFile: EditableFile?
    @State private var showingImporter = false
    @State private var saveStatus = ""
    @State private var workspaceFiles: [WorkspaceFile] = []
    @State private var previewURL: URL?
    @State private var showShareSheet = false
    @State private var shareURL: URL?
    @State private var showingPhotoPicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var searchText = ""
    @State private var selectedFileIDs: Set<UUID> = []
    @State private var isSelecting = false
    @State private var shareURLs: [URL] = []

    private var filteredFiles: [WorkspaceFile] {
        if searchText.isEmpty { return workspaceFiles }
        return workspaceFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    struct WorkspaceFile: Identifiable {
        let id = UUID()
        let name: String
        let path: String
        let size: Int64
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

                    PhotosPicker(
                        selection: $selectedPhotos,
                        maxSelectionCount: 20,
                        matching: .any(of: [.images, .screenshots])
                    ) {
                        Label("Import from Photo Library", systemImage: "photo.on.rectangle")
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
                        ForEach(filteredFiles) { file in
                            if isSelecting {
                                selectableFileRow(file)
                            } else {
                                fileRow(file)
                            }
                        }
                        .onDelete { indexSet in
                            let toDelete = indexSet.map { filteredFiles[$0] }
                            let ids = Set(toDelete.map { $0.id })
                            let fm = FileManager.default
                            for file in toDelete {
                                try? fm.removeItem(atPath: file.path)
                            }
                            workspaceFiles.removeAll { ids.contains($0.id) }
                        }
                    } header: {
                        HStack {
                            Text("Workspace Files (\(filteredFiles.count))")
                            Spacer()
                            Button(isSelecting ? "Done" : "Select") {
                                isSelecting.toggle()
                                if !isSelecting { selectedFileIDs.removeAll() }
                            }
                            .font(.caption)
                            .textCase(nil)
                        }
                    }
                }

                if isSelecting && !selectedFileIDs.isEmpty {
                    Section {
                        Button {
                            shareURLs = workspaceFiles
                                .filter { selectedFileIDs.contains($0.id) }
                                .map { URL(fileURLWithPath: $0.path) }
                            showShareSheet = true
                        } label: {
                            Label("Share \(selectedFileIDs.count) File\(selectedFileIDs.count == 1 ? "" : "s")", systemImage: "square.and.arrow.up")
                        }

                        Button(role: .destructive) {
                            let fm = FileManager.default
                            for file in workspaceFiles where selectedFileIDs.contains(file.id) {
                                try? fm.removeItem(atPath: file.path)
                            }
                            workspaceFiles.removeAll { selectedFileIDs.contains($0.id) }
                            selectedFileIDs.removeAll()
                        } label: {
                            Label("Delete \(selectedFileIDs.count) File\(selectedFileIDs.count == 1 ? "" : "s")", systemImage: "trash")
                        }
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
            .searchable(text: $searchText, prompt: "Search workspace files")
            .leopardListStyle()
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
                if !shareURLs.isEmpty {
                    ShareSheet(items: shareURLs)
                } else if let url = shareURL {
                    ShareSheet(items: [url])
                }
            }
            .quickLookPreview($previewURL)
            .onChange(of: selectedPhotos) {
                importPhotos()
            }
            .onAppear {
                loadWorkspaceFiles()
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ file: WorkspaceFile) -> some View {
        let ext = (file.name as NSString).pathExtension.lowercased()
        Button {
            // Tap to preview via QuickLook
            previewURL = URL(fileURLWithPath: file.path)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: fileIcon(for: ext))
                    .foregroundColor(.orange)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Text(formatSize(file.size))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    shareURLs = []
                    shareURL = URL(fileURLWithPath: file.path)
                    showShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                        .foregroundColor(.blue)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func selectableFileRow(_ file: WorkspaceFile) -> some View {
        let ext = (file.name as NSString).pathExtension.lowercased()
        let selected = selectedFileIDs.contains(file.id)
        Button {
            if selected {
                selectedFileIDs.remove(file.id)
            } else {
                selectedFileIDs.insert(file.id)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? .blue : .gray)
                    .frame(width: 24)
                Image(systemName: fileIcon(for: ext))
                    .foregroundColor(.orange)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Text(formatSize(file.size))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
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
            var files: [WorkspaceFile] = []

            // Resolve symlinks so /private/var and /var match
            let resolvedBase = workspaceDir.standardizedFileURL.resolvingSymlinksInPath()
            let basePath = resolvedBase.path

            guard let enumerator = fm.enumerator(
                at: resolvedBase,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                DispatchQueue.main.async { workspaceFiles = [] }
                return
            }

            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true { continue }

                // Get actual file size from disk
                let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
                let fileSize: Int64
                if let attrs = try? fm.attributesOfItem(atPath: resolvedURL.path),
                   let size = attrs[.size] as? Int64 {
                    fileSize = size
                } else {
                    fileSize = 0
                }

                // Relative path from workspace root
                let resolvedPath = resolvedURL.path
                var displayName: String
                if resolvedPath.hasPrefix(basePath + "/") {
                    displayName = String(resolvedPath.dropFirst(basePath.count + 1))
                } else if resolvedPath.hasPrefix(basePath) {
                    displayName = String(resolvedPath.dropFirst(basePath.count))
                    if displayName.hasPrefix("/") { displayName = String(displayName.dropFirst()) }
                } else {
                    // Fallback: just use the filename
                    displayName = url.lastPathComponent
                }

                files.append(WorkspaceFile(
                    name: displayName,
                    path: resolvedURL.path,
                    size: fileSize
                ))
            }

            files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

    private func importPhotos() {
        guard !selectedPhotos.isEmpty else { return }
        let workspaceDir = BackendService.dataDirectory.deletingLastPathComponent()
            .appendingPathComponent("pegasus_workspace")
        let fm = FileManager.default
        try? fm.createDirectory(at: workspaceDir, withIntermediateDirectories: true)

        let items = selectedPhotos
        selectedPhotos = []

        for item in items {
            item.loadTransferable(type: Data.self) { result in
                guard case .success(let data) = result, let data else { return }

                let timestamp = Int(Date().timeIntervalSince1970)
                let ext: String
                if let contentType = item.supportedContentTypes.first {
                    ext = contentType.preferredFilenameExtension ?? "jpg"
                } else {
                    ext = "jpg"
                }
                let filename = "photo_\(timestamp)_\(UUID().uuidString.prefix(4)).\(ext)"
                let dest = workspaceDir.appendingPathComponent(filename)

                do {
                    try data.write(to: dest)
                    DispatchQueue.main.async {
                        saveStatus = "Imported \(filename)"
                        loadWorkspaceFiles()
                    }
                } catch {
                    DispatchQueue.main.async {
                        saveStatus = "Failed to import photo"
                    }
                }
            }
        }
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

                ZStack(alignment: .bottom) {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .scrollDismissesKeyboard(.interactively)

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
                .frame(maxHeight: .infinity)
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
