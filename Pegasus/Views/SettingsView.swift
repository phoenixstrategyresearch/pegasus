import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var backend: BackendService
    @Environment(\.openURL) private var openURL
    @State private var skills: [SkillEntry] = []
    @State private var showingResetAlert = false
    @State private var showingDeleteSkill: SkillEntry?
    @State private var soulContent = ""
    @State private var memoryContent = ""
    @State private var userContent = ""
    @State private var showingSkillImporter = false
    @State private var customPackages: [PackageEntry] = []
    @State private var showingDeletePackage: PackageEntry?
    @State private var cliTools: [CLIToolEntry] = []
    @State private var showingDeleteCLI: CLIToolEntry?
    @State private var pipInstallText = ""
    @State private var isInstallingPip = false

    struct SkillEntry: Identifiable {
        let name: String
        let description: String
        let category: String
        let content: String
        var id: String { name }
    }

    struct PackageEntry: Identifiable {
        let name: String
        let description: String
        let type: String
        let path: String
        let content: String
        var id: String { name }
    }

    struct CLIToolEntry: Identifiable {
        let name: String
        let version: String
        let source: String   // "built-in", "pip", "custom"
        let size: String
        let path: String
        var id: String { name }
    }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                shortcutsSection
                messagingSection
                soulSection
                memorySection
                skillsSection
                packagesSection
                cliToolsSection
                advancedSection
                dangerSection
            }
            .leopardListStyle()
            .navigationTitle("Settings")
            .onAppear {
                loadSkills()
                loadSoul()
                loadMemory()
                loadCustomPackages()
                loadCLITools()
            }
            .alert("Delete Skill?", isPresented: .init(
                get: { showingDeleteSkill != nil },
                set: { if !$0 { showingDeleteSkill = nil } }
            )) {
                Button("Cancel", role: .cancel) { showingDeleteSkill = nil }
                Button("Delete", role: .destructive) {
                    if let skill = showingDeleteSkill {
                        deleteSkill(skill.name)
                    }
                    showingDeleteSkill = nil
                }
            } message: {
                Text("Delete \"\(showingDeleteSkill?.name ?? "")\"? This cannot be undone.")
            }
            .alert("Delete Package?", isPresented: .init(
                get: { showingDeletePackage != nil },
                set: { if !$0 { showingDeletePackage = nil } }
            )) {
                Button("Cancel", role: .cancel) { showingDeletePackage = nil }
                Button("Delete", role: .destructive) {
                    if let pkg = showingDeletePackage {
                        deleteCustomPackage(pkg.name)
                    }
                    showingDeletePackage = nil
                }
            } message: {
                Text("Delete package \"\(showingDeletePackage?.name ?? "")\"? The agent will no longer be able to import it.")
            }
            .alert("Uninstall CLI Tool?", isPresented: .init(
                get: { showingDeleteCLI != nil },
                set: { if !$0 { showingDeleteCLI = nil } }
            )) {
                Button("Cancel", role: .cancel) { showingDeleteCLI = nil }
                Button("Uninstall", role: .destructive) {
                    if let tool = showingDeleteCLI {
                        deleteCLITool(tool)
                    }
                    showingDeleteCLI = nil
                }
            } message: {
                Text("Uninstall \"\(showingDeleteCLI?.name ?? "")\"? The agent will no longer be able to use this tool.")
            }
            .alert("Reset All Data?", isPresented: $showingResetAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) { resetAllData() }
            } message: {
                Text("This will delete all memory, skills, and workspace files. Models will not be affected.")
            }
            .fileImporter(
                isPresented: $showingSkillImporter,
                allowedContentTypes: [.plainText, .folder, .item],
                allowsMultipleSelection: true
            ) { result in
                handleSkillImport(result)
            }
        }
    }

    // MARK: - Voice & Shortcuts Section

    private var shortcutsSection: some View {
        Group {
            Section {
                HStack {
                    Text("Speech-to-Text")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(WhisperEngine.shared.isLoaded ? .green : .gray)
                            .frame(width: 8, height: 8)
                        Text(WhisperEngine.shared.isLoaded ? WhisperEngine.shared.modelName : "Not loaded")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }

                Button {
                    if let url = URL(string: "shortcuts://") {
                        openURL(url)
                    }
                } label: {
                    Label("Open Shortcuts App", systemImage: "arrow.up.forward.app.fill")
                }
            } header: {
                Text("Voice & Shortcuts")
            } footer: {
                Text("Use the mic button in chat for voice input.")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Action Button", systemImage: "button.horizontal.top.press")
                        .font(.subheadline.weight(.medium))
                    Text("Settings → Action Button → Shortcut → choose \"Ask Pegasus\" or \"Pegasus Voice\"")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Label("Siri", systemImage: "mic.circle")
                        .font(.subheadline.weight(.medium))
                    Text("\"Hey Siri, Ask Pegasus\" or \"Hey Siri, Talk to Pegasus\"")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Label("URL Schemes", systemImage: "link")
                        .font(.subheadline.weight(.medium))
                    Group {
                        Text("pegasus://voice")
                        Text("pegasus://ask?q=your+question")
                    }
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("How to Set Up")
            } footer: {
                Text("Create a shortcut in the Shortcuts app using the \"Ask Pegasus\" or \"Pegasus Voice\" actions, then assign it to your Action Button.")
            }
        }
    }

    // MARK: - Messaging Section

    @AppStorage("useShortcutsSend") private var useShortcutsSend: Bool = true

    private var messagingSection: some View {
        Group {
            Section {
                Toggle("Silent Send via Shortcuts", isOn: $useShortcutsSend)

                HStack {
                    Text("Shortcut Name")
                    Spacer()
                    Text(PegasusMessageSender.shortcutName)
                        .foregroundColor(.secondary)
                        .font(.caption.monospaced())
                }
            } header: {
                Text("Messaging")
            } footer: {
                Text(useShortcutsSend
                     ? "Messages are sent silently via the Shortcuts app. No UI shown."
                     : "Messages open the compose screen. You must tap Send manually.")
            }

            Section {
                Button {
                    if let url = URL(string: "https://www.icloud.com/shortcuts/fca941969b5941e684665cdfb9497010") {
                        openURL(url)
                    }
                } label: {
                    Label("Install Shortcut", systemImage: "square.and.arrow.down")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("After installing, open the shortcut and set the folder to:")
                        .font(.caption).foregroundColor(.secondary)
                    Text("On My iPhone → Pegasus → pegasus_workspace → outbox")
                        .font(.caption.monospaced().weight(.medium))
                        .foregroundColor(.cyan)
                    Text("Then expand Send Message → turn Show When Run OFF")
                        .font(.caption).foregroundColor(.orange)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Shortcut Setup (one-time)")
            } footer: {
                Text("Installs the Send Pegasus Message shortcut. Sends text + file attachments via iMessage silently.")
            }
        }
    }

    // MARK: - Status Section

    private var statusSection: some View {
        Section {
            HStack {
                Text("Mode")
                Spacer()
                if EmbeddedPython.useCloudLLM {
                    HStack(spacing: 6) {
                        Image(systemName: "cloud.fill")
                            .font(.caption2)
                            .foregroundColor(.blue)
                        Text("Cloud (\(EmbeddedPython.openAIModel))")
                            .foregroundColor(.secondary)
                    }
                } else if backend.isModelLoaded {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("On-device")
                            .foregroundColor(.secondary)
                    }
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(.gray).frame(width: 8, height: 8)
                        Text("No model")
                            .foregroundColor(.secondary)
                    }
                }
            }
            HStack {
                Text("Agent")
                Spacer()
                let python = EmbeddedPython.shared
                HStack(spacing: 6) {
                    Circle()
                        .fill(python.isReady ? .green : (python.isInitializing ? .orange : .gray))
                        .frame(width: 8, height: 8)
                    Text(python.isReady ? "Ready" : (python.isInitializing ? "Initializing" : "Idle"))
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Status")
        }
    }

    // MARK: - Soul Section

    private var soulSection: some View {
        Section {
            NavigationLink {
                TextEditorView(
                    title: "SOUL.md",
                    content: $soulContent,
                    placeholder: "Define Pegasus's personality, behavior, and core directives here...",
                    onSave: { saveSoul() }
                )
            } label: {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundColor(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(soulContent.isEmpty ? "No custom identity" : "Custom SOUL active")
                            .font(.subheadline.weight(.medium))
                        Text(soulContent.isEmpty ? "Tap to create" : "\(soulContent.count) chars")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("Soul (Identity)")
        } footer: {
            Text("The SOUL.md defines Pegasus's personality and core directives.")
        }
    }

    // MARK: - Memory Section

    private var memorySection: some View {
        Group {
            Section {
                NavigationLink {
                    TextEditorView(
                        title: "Agent Memory",
                        content: $memoryContent,
                        placeholder: "Agent memory is empty. The agent stores learned preferences and patterns here.",
                        onSave: { saveMemory() }
                    )
                } label: {
                    HStack {
                        Image(systemName: "brain")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Agent Memory")
                                .font(.subheadline.weight(.medium))
                            Text(memoryContent.isEmpty ? "Empty" : "\(memoryContent.count) chars")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                NavigationLink {
                    TextEditorView(
                        title: "User Profile",
                        content: $userContent,
                        placeholder: "User profile is empty. The agent stores info about you here (name, preferences, etc).",
                        onSave: { saveUser() }
                    )
                } label: {
                    HStack {
                        Image(systemName: "person.fill")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("User Profile")
                                .font(.subheadline.weight(.medium))
                            Text(userContent.isEmpty ? "Empty" : "\(userContent.count) chars")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Button {
                    loadMemory()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("Tap to view and edit. Memory persists across sessions.")
            }
        }
    }

    // MARK: - Skills Section

    private var skillsSection: some View {
        Section {
            ForEach(skills) { skill in
                NavigationLink {
                    SkillDetailView(skill: skill, onDelete: {
                        deleteSkill(skill.name)
                    })
                } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(skill.name)
                                .font(.subheadline.weight(.medium))
                            if !skill.description.isEmpty {
                                Text(skill.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            if !skill.category.isEmpty {
                                Text(skill.category)
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.12))
                                    .foregroundColor(.orange)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if skills.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "lightbulb")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("No skills installed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Upload skill files or ask the agent to create skills for complex tasks.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Button {
                showingSkillImporter = true
            } label: {
                Label("Import Skill", systemImage: "square.and.arrow.down")
            }

            Button {
                loadSkills()
            } label: {
                Label("Refresh Skills", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
        } header: {
            HStack {
                Text("Skills")
                Spacer()
                Text("\(skills.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } footer: {
            Text("Skills are agent-learned workflows. Import SKILL.md files or ask Pegasus to create them.")
        }
    }

    // MARK: - Custom Packages Section

    private var packagesSection: some View {
        Section {
            ForEach(customPackages) { pkg in
                NavigationLink {
                    PackageDetailView(package: pkg, onDelete: {
                        showingDeletePackage = pkg
                    })
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: pkg.type == "package" ? "shippingbox.fill" : "doc.text.fill")
                            .foregroundColor(.blue)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pkg.name)
                                .font(.subheadline.weight(.medium))
                            if !pkg.description.isEmpty {
                                Text(pkg.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            Text(pkg.type)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12))
                                .foregroundColor(.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if customPackages.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "shippingbox")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("No custom packages")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Ask the agent to create reusable Python packages. They persist across sessions.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Button {
                loadCustomPackages()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
        } header: {
            HStack {
                Text("Custom Packages")
                Spacer()
                Text("\(customPackages.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } footer: {
            Text("Python packages the agent created. Importable in python_exec via `import name`.")
        }
    }

    // MARK: - CLI Tools Section

    private var cliToolsSection: some View {
        Section {
            // Built-in tools (non-deletable)
            let builtIn = cliTools.filter { $0.source == "built-in" }
            let installed = cliTools.filter { $0.source == "pip" }

            if !builtIn.isEmpty {
                DisclosureGroup {
                    ForEach(builtIn) { tool in
                        HStack {
                            Image(systemName: "terminal.fill")
                                .foregroundColor(.green)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                Text(tool.version)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "gearshape.2.fill")
                            .foregroundColor(.green)
                        Text("Built-in (\(builtIn.count))")
                            .font(.subheadline.weight(.medium))
                    }
                }
            }

            // Pip-installed tools (deletable)
            ForEach(installed) { tool in
                HStack {
                    Image(systemName: "shippingbox.fill")
                        .foregroundColor(.cyan)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                        HStack(spacing: 6) {
                            Text(tool.version)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            if !tool.size.isEmpty {
                                Text(tool.size)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Spacer()
                    Button {
                        showingDeleteCLI = tool
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }

            if installed.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("No pip packages installed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Ask the agent to install tools or use the field below.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            // Quick install field
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(.green)
                TextField("Package name (e.g. yt-dlp)", text: $pipInstallText)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .onSubmit { installPipPackage() }
                if isInstallingPip {
                    ProgressView()
                        .scaleEffect(0.7)
                } else if !pipInstallText.isEmpty {
                    Button {
                        installPipPackage()
                    } label: {
                        Text("Install")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.green)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                loadCLITools()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
        } header: {
            HStack {
                Text("CLI Tools")
                Spacer()
                Text("\(cliTools.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } footer: {
            Text("Shell tools available to the agent via shell_exec. Built-in tools are pure Python. Pip packages are auto-discovered.")
        }
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        Section {
            HStack {
                Text("Remote Host")
                Spacer()
                TextField("IP address", text: $backend.backendHost)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
                    .frame(width: 160)
                    .onChange(of: backend.backendHost) {
                        UserDefaults.standard.set(backend.backendHost, forKey: "backendHost")
                    }
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("For connecting to a remote Python backend on your Mac.")
        }
    }

    // MARK: - Danger Section

    private var dangerSection: some View {
        Section {
            Button("Reset All Data", role: .destructive) {
                showingResetAlert = true
            }
        } header: {
            Text("Danger Zone")
        }
    }

    // MARK: - Data Loading & Saving

    private func loadSkills() {
        let skillsDir = BackendService.dataDirectory
            .appendingPathComponent("skills")
        DispatchQueue.global().async {
            var result: [SkillEntry] = []
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(
                at: skillsDir, includingPropertiesForKeys: nil
            ) else {
                DispatchQueue.main.async { self.skills = [] }
                return
            }

            for dir in contents where dir.hasDirectoryPath {
                let skillFile = dir.appendingPathComponent("SKILL.md")
                guard let text = try? String(contentsOf: skillFile, encoding: .utf8) else { continue }
                let meta = parseSkillFrontmatter(text)
                result.append(SkillEntry(
                    name: meta["name"] ?? dir.lastPathComponent,
                    description: meta["description"] ?? "",
                    category: meta["category"] ?? "",
                    content: text
                ))
            }

            for dir in contents where dir.hasDirectoryPath {
                let skillFile = dir.appendingPathComponent("SKILL.md")
                if fm.fileExists(atPath: skillFile.path) { continue }
                if let subs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for sub in subs where sub.hasDirectoryPath {
                        let subSkill = sub.appendingPathComponent("SKILL.md")
                        guard let text = try? String(contentsOf: subSkill, encoding: .utf8) else { continue }
                        let meta = parseSkillFrontmatter(text)
                        result.append(SkillEntry(
                            name: meta["name"] ?? sub.lastPathComponent,
                            description: meta["description"] ?? "",
                            category: dir.lastPathComponent,
                            content: text
                        ))
                    }
                }
            }

            DispatchQueue.main.async { self.skills = result.sorted { $0.name < $1.name } }
        }
    }

    private func parseSkillFrontmatter(_ text: String) -> [String: String] {
        guard text.hasPrefix("---") else { return [:] }
        guard let endRange = text.range(of: "---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else { return [:] }
        let frontmatter = String(text[text.index(text.startIndex, offsetBy: 3)..<endRange.lowerBound])
        var result: [String: String] = [:]
        for line in frontmatter.components(separatedBy: "\n") {
            if let colonRange = line.range(of: ": ") {
                let key = String(line[line.startIndex..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let value = String(line[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                result[key] = value
            }
        }
        return result
    }

    private func deleteSkill(_ name: String) {
        let skillsDir = BackendService.dataDirectory.appendingPathComponent("skills")
        let skillDir = skillsDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: skillDir)
        // Also try with the raw name (subcategory case)
        for dir in (try? FileManager.default.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: nil)) ?? [] {
            let sub = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: sub.path) {
                try? FileManager.default.removeItem(at: sub)
            }
        }
        loadSkills()
    }

    private func loadSoul() {
        backend.readDataFile("SOUL.md") { content in
            soulContent = content
        }
    }

    private func saveSoul() {
        backend.writeDataFile("SOUL.md", content: soulContent) { _ in }
    }

    private func loadMemory() {
        backend.readDataFile("MEMORY.md") { content in
            memoryContent = content
        }
        backend.readDataFile("USER.md") { content in
            userContent = content
        }
    }

    private func saveMemory() {
        backend.writeDataFile("MEMORY.md", content: memoryContent) { _ in }
    }

    private func saveUser() {
        backend.writeDataFile("USER.md", content: userContent) { _ in }
    }

    private func resetAllData() {
        let dataDir = BackendService.dataDirectory
        try? FileManager.default.removeItem(at: dataDir)
        backend.resetConversation {}
        skills = []
        customPackages = []
        memoryContent = ""
        userContent = ""
        soulContent = ""
    }

    private func loadCustomPackages() {
        let pkgDir = BackendService.dataDirectory.appendingPathComponent("custom_packages")
        DispatchQueue.global().async {
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(
                at: pkgDir, includingPropertiesForKeys: nil
            ) else {
                DispatchQueue.main.async { customPackages = [] }
                return
            }
            var result: [PackageEntry] = []
            for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = item.lastPathComponent
                if item.hasDirectoryPath {
                    let initFile = item.appendingPathComponent("__init__.py")
                    guard fm.fileExists(atPath: initFile.path) else { continue }
                    let code = (try? String(contentsOf: initFile, encoding: .utf8)) ?? ""
                    let desc = Self.extractDocstring(code)
                    result.append(PackageEntry(name: name, description: desc, type: "package", path: item.path, content: code))
                } else if name.hasSuffix(".py") && name != "__init__.py" {
                    let modName = String(name.dropLast(3))
                    let code = (try? String(contentsOf: item, encoding: .utf8)) ?? ""
                    let desc = Self.extractDocstring(code)
                    result.append(PackageEntry(name: modName, description: desc, type: "module", path: item.path, content: code))
                }
            }
            DispatchQueue.main.async { customPackages = result }
        }
    }

    private static func extractDocstring(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        for quote in ["\"\"\"", "'''"] {
            if trimmed.hasPrefix(quote) {
                let after = trimmed.dropFirst(quote.count)
                if let end = after.range(of: quote) {
                    return String(after[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: "\n").first ?? ""
                }
            }
        }
        return ""
    }

    private func deleteCustomPackage(_ name: String) {
        let pkgDir = BackendService.dataDirectory.appendingPathComponent("custom_packages")
        let filePath = pkgDir.appendingPathComponent("\(name).py")
        let dirPath = pkgDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: filePath.path) {
            try? FileManager.default.removeItem(at: filePath)
        } else if FileManager.default.fileExists(atPath: dirPath.path) {
            try? FileManager.default.removeItem(at: dirPath)
        }
        loadCustomPackages()
    }

    // MARK: - CLI Tools Loading

    private func loadCLITools() {
        DispatchQueue.global().async {
            var result: [CLIToolEntry] = []

            // Built-in CLI adapters
            let builtins = [
                ("jq", "JSON query/filter"),
                ("sqlite3", "SQLite database CLI"),
                ("tree", "Directory tree view"),
                ("htop", "Process/resource info"),
                ("bc", "Calculator"),
                ("nc", "Netcat (network)"),
                ("json_pp", "JSON pretty-print"),
            ]
            for (name, desc) in builtins {
                result.append(CLIToolEntry(name: name, version: desc, source: "built-in", size: "", path: ""))
            }

            // Scan pip-installed packages from dist-info directories
            let dataDir = BackendService.dataDirectory.path
            let pkgDir = dataDir + "/packages"
            let fm = FileManager.default

            if fm.fileExists(atPath: pkgDir),
               let contents = try? fm.contentsOfDirectory(atPath: pkgDir) {
                for item in contents.sorted() where item.hasSuffix(".dist-info") {
                    let distInfo = pkgDir + "/" + item
                    let pkgName = item.replacingOccurrences(of: ".dist-info", with: "")

                    // Read version from METADATA
                    var version = ""
                    let metaPath = distInfo + "/METADATA"
                    if let meta = try? String(contentsOfFile: metaPath, encoding: .utf8) {
                        for line in meta.components(separatedBy: "\n") {
                            if line.hasPrefix("Version: ") {
                                version = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
                                break
                            }
                        }
                    }

                    // Calculate size
                    var totalSize: Int64 = 0
                    let baseName = pkgName.components(separatedBy: "-").first ?? pkgName
                    let possibleDirs = [baseName, baseName.replacingOccurrences(of: "-", with: "_")]
                    for dirName in possibleDirs {
                        let fullDir = pkgDir + "/" + dirName
                        if let enumerator = fm.enumerator(atPath: fullDir) {
                            while let file = enumerator.nextObject() as? String {
                                let filePath = fullDir + "/" + file
                                if let attrs = try? fm.attributesOfItem(atPath: filePath),
                                   let size = attrs[.size] as? Int64 {
                                    totalSize += size
                                }
                            }
                        }
                    }
                    let sizeStr = totalSize > 0 ? Self.formatSize(totalSize) : ""

                    let displayName = pkgName.components(separatedBy: "-").dropLast().joined(separator: "-")
                    result.append(CLIToolEntry(
                        name: displayName.isEmpty ? pkgName : displayName,
                        version: version.isEmpty ? pkgName : "v\(version)",
                        source: "pip",
                        size: sizeStr,
                        path: distInfo
                    ))
                }
            }

            DispatchQueue.main.async { self.cliTools = result }
        }
    }

    private static func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private func deleteCLITool(_ tool: CLIToolEntry) {
        guard tool.source == "pip" else { return }
        let pkgDir = BackendService.dataDirectory.path + "/packages"
        let fm = FileManager.default

        // Delete dist-info directory
        if !tool.path.isEmpty {
            try? fm.removeItem(atPath: tool.path)
        }

        // Delete the actual package directory/files
        let baseName = tool.name.replacingOccurrences(of: "-", with: "_")
        let possibleNames = [tool.name, baseName, tool.name.lowercased(), baseName.lowercased()]
        for name in possibleNames {
            let dirPath = pkgDir + "/" + name
            let filePath = pkgDir + "/" + name + ".py"
            if fm.fileExists(atPath: dirPath) {
                try? fm.removeItem(atPath: dirPath)
            }
            if fm.fileExists(atPath: filePath) {
                try? fm.removeItem(atPath: filePath)
            }
        }

        // Also try to find and delete by scanning for matching top-level dirs
        if let contents = try? fm.contentsOfDirectory(atPath: pkgDir) {
            for item in contents {
                let lower = item.lowercased()
                if lower.hasPrefix(tool.name.lowercased().replacingOccurrences(of: "-", with: "_")) &&
                   !item.hasSuffix(".dist-info") {
                    try? fm.removeItem(atPath: pkgDir + "/" + item)
                }
            }
        }

        loadCLITools()
    }

    private func installPipPackage() {
        let pkg = pipInstallText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pkg.isEmpty else { return }
        isInstallingPip = true

        // Use the embedded Python agent's dispatchTool to call pip_install
        DispatchQueue.global().async {
            let python = EmbeddedPython.shared
            let argsJSON = "{\"package\": \"\(pkg.replacingOccurrences(of: "\"", with: "\\\""))\"}"
            let _ = python.dispatchTool(name: "pip_install", argumentsJSON: argsJSON)

            DispatchQueue.main.async {
                self.isInstallingPip = false
                self.pipInstallText = ""
                self.loadCLITools()
            }
        }
    }

    private func handleSkillImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let skillsDir = BackendService.dataDirectory.appendingPathComponent("skills")
            let fm = FileManager.default

            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }

                let filename = url.lastPathComponent

                if url.hasDirectoryPath {
                    // Import entire skill folder
                    let destDir = skillsDir.appendingPathComponent(url.lastPathComponent)
                    try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                    if let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                        for item in items {
                            let dest = destDir.appendingPathComponent(item.lastPathComponent)
                            try? fm.copyItem(at: item, to: dest)
                        }
                    }
                } else if filename.hasSuffix(".md") || filename.hasSuffix(".txt") {
                    // Import as a single-file skill
                    guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    let meta = parseSkillFrontmatter(content)
                    let skillName = meta["name"] ?? filename.replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: ".txt", with: "")
                    let destDir = skillsDir.appendingPathComponent(skillName)
                    try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                    let destFile = destDir.appendingPathComponent("SKILL.md")
                    try? content.write(to: destFile, atomically: true, encoding: .utf8)
                }
            }
            loadSkills()

        case .failure(let error):
            NSLog("[SettingsView] Skill import error: %@", error.localizedDescription)
        }
    }
}

// MARK: - Text Editor View (for Memory/Soul editing)

struct TextEditorView: View {
    let title: String
    @Binding var content: String
    let placeholder: String
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editedContent = ""
    @State private var hasChanges = false

    var body: some View {
        VStack(spacing: 0) {
            if editedContent.isEmpty {
                Text(placeholder)
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            TextEditor(text: $editedContent)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: editedContent) {
                    hasChanges = editedContent != content
                }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    content = editedContent
                    onSave()
                    hasChanges = false
                    dismiss()
                }
                .disabled(!hasChanges)
                .fontWeight(hasChanges ? .bold : .regular)
            }
        }
        .onAppear {
            editedContent = content
        }
    }
}

// MARK: - Skill Detail View

struct SkillDetailView: View {
    let skill: SettingsView.SkillEntry
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text(skill.name)
                        .font(.title2.weight(.bold))

                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    if !skill.category.isEmpty {
                        Text(skill.category)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.12))
                            .foregroundColor(.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                Divider()

                // Content
                Text(skill.content)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // Delete button
                Button(role: .destructive) {
                    onDelete()
                    dismiss()
                } label: {
                    Label("Delete Skill", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding()
        }
        .navigationTitle("Skill Details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PackageDetailView: View {
    let package: SettingsView.PackageEntry
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: package.type == "package" ? "shippingbox.fill" : "doc.text.fill")
                            .foregroundColor(.blue)
                        Text(package.name)
                            .font(.title2.weight(.bold))
                    }

                    if !package.description.isEmpty {
                        Text(package.description)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 8) {
                        Text(package.type)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.12))
                            .foregroundColor(.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        Text("import \(package.name)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                Text(package.content)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button(role: .destructive) {
                    onDelete()
                    dismiss()
                } label: {
                    Label("Delete Package", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding()
        }
        .navigationTitle("Package Details")
        .navigationBarTitleDisplayMode(.inline)
    }
}
