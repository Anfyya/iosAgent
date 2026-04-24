import LocalAIWorkspace
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var newWorkspaceName = ""
    @State private var showProviderEditor = false
    @State private var editingProvider: ProviderProfile?
    @State private var providerAPIKey = ""
    @State private var renameWorkspace: Workspace?
    @State private var renameWorkspaceName = ""
    @State private var newItemPath = ""
    @State private var newFolderPath = ""
    @State private var renamePathValue = ""

    var body: some View {
        TabView(selection: $model.selectedTab) {
            projectsView
                .tabItem { Label(AppTab.projects.title, systemImage: AppTab.projects.systemImage) }
                .tag(AppTab.projects)

            workspaceView
                .tabItem { Label(AppTab.workspace.title, systemImage: AppTab.workspace.systemImage) }
                .tag(AppTab.workspace)

            chatView
                .tabItem { Label(AppTab.chat.title, systemImage: AppTab.chat.systemImage) }
                .tag(AppTab.chat)

            patchesView
                .tabItem { Label(AppTab.patches.title, systemImage: AppTab.patches.systemImage) }
                .tag(AppTab.patches)

            contextView
                .tabItem { Label(AppTab.context.title, systemImage: AppTab.context.systemImage) }
                .tag(AppTab.context)

            cacheView
                .tabItem { Label(AppTab.cache.title, systemImage: AppTab.cache.systemImage) }
                .tag(AppTab.cache)

            settingsView
                .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage) }
                .tag(AppTab.settings)
        }
        .alert("Error", isPresented: .constant(model.lastErrorMessage != nil), actions: {
            Button("OK") { model.lastErrorMessage = nil }
        }, message: {
            Text(model.lastErrorMessage ?? "")
        })
        .sheet(isPresented: $showProviderEditor) {
            ProviderProfileEditorSheet(
                profile: editingProvider ?? ProviderProfile(
                    id: UUID().uuidString,
                    name: "",
                    apiStyle: .openAICompatible,
                    baseURL: "",
                    endpoint: "/chat/completions",
                    auth: AuthConfiguration(type: .bearer),
                    supportsStreaming: true,
                    supportsToolCalling: true,
                    supportsJSONMode: false,
                    supportsVision: false,
                    supportsReasoning: false,
                    supportsPromptCache: false,
                    supportsExplicitCacheControl: false,
                    supportsWebSearch: false,
                    modelProfiles: [
                        ModelProfile(
                            id: "",
                            displayName: "",
                            supportsReasoning: false,
                            supportsCache: false,
                            cacheStrategy: .noProviderCacheInfo,
                            supportsTools: true,
                            supportsStreaming: true,
                            maxContextTokens: 128_000,
                            maxOutputTokens: 4_096
                        )
                    ]
                ),
                apiKey: providerAPIKey,
                onSave: { profile, apiKey in
                    model.saveProvider(profile, apiKey: apiKey)
                    showProviderEditor = false
                    providerAPIKey = ""
                },
                onTest: { profile, apiKey in
                    Task { await model.testConnection(profile: profile, apiKey: apiKey) }
                }
            )
        }
    }

    private var projectsView: some View {
        NavigationStack {
            List {
                Section("Create Workspace") {
                    TextField("Workspace name", text: $newWorkspaceName)
                    Button("Create") {
                        guard !newWorkspaceName.isEmpty else { return }
                        model.createWorkspace(named: newWorkspaceName)
                        newWorkspaceName = ""
                    }
                }

                Section("Workspaces") {
                    ForEach(model.workspaces) { workspace in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                model.selectedWorkspaceID = workspace.id
                                model.refreshWorkspaceState()
                                model.selectedTab = .workspace
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(workspace.name)
                                        Text(workspace.rootPath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.selectedWorkspaceID == workspace.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            .buttonStyle(.plain)

                            HStack {
                                Button("Rename") {
                                    renameWorkspace = workspace
                                    renameWorkspaceName = workspace.name
                                }
                                Button("Delete", role: .destructive) {
                                    model.deleteWorkspace(workspace)
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Projects")
            .sheet(item: $renameWorkspace) { workspace in
                NavigationStack {
                    Form {
                        TextField("Name", text: $renameWorkspaceName)
                    }
                    .navigationTitle("Rename")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { renameWorkspace = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                model.renameWorkspace(workspace, to: renameWorkspaceName)
                                renameWorkspace = nil
                            }
                        }
                    }
                }
            }
        }
    }

    private var workspaceView: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let workspace = model.selectedWorkspace {
                    GlassPanel {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(workspace.name)
                                .font(.title2.bold())
                            Text(workspace.rootPath)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                            if let provider = model.activeProvider {
                                Text("Provider: \(provider.name)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack {
                        TextField("Filter files", text: $model.fileSearchQuery)
                            .textFieldStyle(.roundedBorder)
                        Button("Refresh") { model.refreshWorkspaceState() }
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Files")
                                .font(.headline)
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(model.filteredWorkspaceFiles, id: \.path) { entry in
                                        Button {
                                            if !entry.isDirectory { try? model.openFile(entry.path) }
                                        } label: {
                                            HStack {
                                                Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                                                Text(entry.path)
                                                    .font(.system(.body, design: .monospaced))
                                                Spacer()
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button("Rename") {
                                                model.pendingRenamePath = entry.path
                                                renamePathValue = entry.path
                                            }
                                            Button("Delete", role: .destructive) {
                                                model.pendingDeletePath = entry.path
                                            }
                                        }
                                    }
                                }
                            }

                            TextField("New file path", text: $newItemPath)
                            Button("Create File") {
                                model.createFile(at: newItemPath)
                                newItemPath = ""
                            }
                            TextField("New folder path", text: $newFolderPath)
                            Button("Create Folder") {
                                model.createFolder(at: newFolderPath)
                                newFolderPath = ""
                            }
                        }
                        .frame(maxWidth: 280, alignment: .topLeading)

                        VStack(alignment: .leading, spacing: 8) {
                            if let path = model.selectedFilePath {
                                Text(path)
                                    .font(.headline)
                                TextEditor(text: Binding(
                                    get: { model.editorText },
                                    set: {
                                        model.editorText = $0
                                        model.hasUnsavedChanges = true
                                    }
                                ))
                                .font(.system(.body, design: .monospaced))
                                Button(model.hasUnsavedChanges ? "Save Changes" : "Saved") {
                                    model.saveSelectedFile()
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                ContentUnavailableView("No File Selected", systemImage: "doc")
                            }
                        }
                    }

                    HStack {
                        TextField("Search content", text: $model.contentSearchQuery)
                            .textFieldStyle(.roundedBorder)
                        Button("Search") { model.searchContent() }
                    }
                    List(model.contentSearchResults, id: \.path) { match in
                        VStack(alignment: .leading) {
                            Text("\(match.path):\(match.lineNumber)")
                                .font(.caption.monospaced())
                            Text(match.line)
                        }
                    }
                    .frame(maxHeight: 200)
                } else {
                    ContentUnavailableView("No Workspace", systemImage: "folder.badge.questionmark")
                }
            }
            .padding()
            .navigationTitle("Workspace")
            .confirmationDialog("Delete item?", isPresented: .constant(model.pendingDeletePath != nil), actions: {
                Button("Delete", role: .destructive) { model.deletePendingPath() }
                Button("Cancel", role: .cancel) { model.pendingDeletePath = nil }
            }, message: {
                Text(model.pendingDeletePath ?? "")
            })
            .sheet(isPresented: .constant(model.pendingRenamePath != nil), onDismiss: { model.pendingRenamePath = nil }) {
                NavigationStack {
                    Form { TextField("New path", text: $renamePathValue) }
                        .navigationTitle("Rename")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { model.pendingRenamePath = nil }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Save") { model.renameSelectedPath(to: renamePathValue) }
                            }
                        }
                }
            }
        }
    }

    private var chatView: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    TextField("Ask the AI to work on the selected workspace", text: $model.chatInput, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    Button("Start Task") {
                        Task { await model.startChat() }
                    }
                    .buttonStyle(.borderedProminent)

                    if let run = model.currentRun {
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Status: \(run.status.rawValue)")
                                    .font(.headline)
                                ForEach(run.toolCalls) { call in
                                    Text("• \(call.name)")
                                }
                                if let answer = run.finalAnswer {
                                    Text(answer)
                                }
                            }
                        }

                        if run.status == .waitingForUser, let question = run.pendingQuestion?.arguments["question"] {
                            GlassPanel {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(question.stringValue)
                                        .font(.headline)
                                    TextField("Your answer", text: $model.questionAnswer)
                                        .textFieldStyle(.roundedBorder)
                                    Button("Send Answer") {
                                        Task { await model.answerQuestion() }
                                    }
                                }
                            }
                        }

                        if run.status == .waitingForPermission, let request = run.pendingPermissionRequest {
                            GlassPanel {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Permission needed: \(request.name)")
                                        .font(.headline)
                                    Text(run.pendingPermissionDecision?.reason ?? "")
                                    Text(request.arguments.map { "\($0.key): \($0.value.debugText)" }.joined(separator: "\n"))
                                        .font(.system(.footnote, design: .monospaced))
                                    HStack {
                                        Button("Allow Once") {
                                            Task { await model.resumePermission(approved: true) }
                                        }
                                        Button("Deny", role: .destructive) {
                                            Task { await model.resumePermission(approved: false) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Chat")
        }
    }

    private var patchesView: some View {
        NavigationStack {
            List {
                ForEach(model.patchQueue) { proposal in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(proposal.title)
                                Text(proposal.reason)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(proposal.status.rawValue)
                                .font(.caption)
                        }
                        Text("\(proposal.changedFiles) files · \(proposal.changedLines) lines")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(proposal.changes, id: \.path) { change in
                            DiffViewer(diff: change.diff ?? change.newContent ?? "")
                                .frame(maxHeight: 180)
                        }
                        if proposal.status == .pendingReview {
                            HStack {
                                Button("Apply") { model.applyPatch(proposal) }
                                Button("Reject", role: .destructive) { model.rejectPatch(proposal) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Patch Review")
        }
    }

    private var contextView: some View {
        NavigationStack {
            ScrollView {
                if let snapshot = model.currentContextSnapshot {
                    VStack(alignment: .leading, spacing: 12) {
                        metric("prefixHash", snapshot.prefixHash)
                        metric("repoSnapshotHash", snapshot.repoSnapshotHash)
                        metric("fileTreeHash", snapshot.fileTreeHash)
                        metric("toolSchemaHash", snapshot.toolSchemaHash)
                        metric("projectRulesHash", snapshot.projectRulesHash)
                        Text("Included files: \(snapshot.includedFiles.count)")
                        Text(snapshot.includedFiles.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                        if !snapshot.ignoredFiles.isEmpty {
                            Text("Ignored files")
                                .font(.headline)
                            Text(snapshot.ignoredFiles.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                    .padding()
                } else {
                    ContentUnavailableView("No Context Yet", systemImage: "text.redaction")
                }
            }
            .navigationTitle("Context")
        }
    }

    private var cacheView: some View {
        NavigationStack {
            ScrollView {
                if let record = model.cacheRecord {
                    VStack(alignment: .leading, spacing: 12) {
                        metric("Provider", record.provider)
                        metric("Model", record.model)
                        metric("Prompt Tokens", "\(record.promptTokens)")
                        metric("Completion Tokens", "\(record.completionTokens)")
                        metric("Cached Tokens", "\(record.cachedTokens)")
                        metric("Hit Rate", String(format: "%.1f%%", record.cacheHitRate * 100))
                        metric("Prefix Hash", record.prefixHash)
                        metric("Repo Snapshot", record.repoSnapshotHash)
                        metric("Latency", "\(record.latencyMs)ms")
                        if record.cachedTokens == 0 {
                            Text("Provider 未返回缓存 token，此处仅显示 prefix hash 估算。")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                } else {
                    ContentUnavailableView("No Cache Records", systemImage: "speedometer")
                }
            }
            .navigationTitle("Cache")
        }
    }

    private var settingsView: some View {
        NavigationStack {
            List {
                Section("Provider Profiles") {
                    ForEach(model.providerProfiles) { profile in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name)
                            Text(profile.baseURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Edit") {
                                    editingProvider = profile
                                    providerAPIKey = ""
                                    showProviderEditor = true
                                }
                                Button("Use") {
                                    model.assignProvider(profile.id)
                                }
                                Button("Delete", role: .destructive) {
                                    model.deleteProvider(profile, deleteSecret: false)
                                }
                            }
                            .font(.caption)
                        }
                    }
                    Button("Add Provider") {
                        editingProvider = nil
                        providerAPIKey = ""
                        showProviderEditor = true
                    }
                }

                if let status = model.lastConnectionStatus {
                    Section("Connection") {
                        Text(status)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        GlassPanel {
            VStack(alignment: .leading) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.body, design: .monospaced))
            }
        }
    }
}

private struct ProviderProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ProviderProfile
    @State private var apiKey: String
    let onSave: (ProviderProfile, String?) -> Void
    let onTest: (ProviderProfile, String?) -> Void

    init(profile: ProviderProfile, apiKey: String, onSave: @escaping (ProviderProfile, String?) -> Void, onTest: @escaping (ProviderProfile, String?) -> Void) {
        _profile = State(initialValue: profile)
        _apiKey = State(initialValue: apiKey)
        self.onSave = onSave
        self.onTest = onTest
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    TextField("Name", text: $profile.name)
                    Picker("API Style", selection: $profile.apiStyle) {
                        ForEach(APIStyle.allCases, id: \.self) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    TextField("Base URL", text: $profile.baseURL)
                        .textInputAutocapitalization(.never)
                    TextField("Endpoint", text: $profile.endpoint)
                        .textInputAutocapitalization(.never)
                    Picker("Auth Type", selection: $profile.auth.type) {
                        ForEach(AuthType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    TextField("Auth key name", text: Binding(
                        get: { profile.auth.keyName ?? "" },
                        set: { profile.auth.keyName = $0.isEmpty ? nil : $0 }
                    ))
                    SecureField("API Key", text: $apiKey)
                }

                Section("Model") {
                    TextField("Model ID", text: Binding(
                        get: { profile.modelProfiles.first?.id ?? "" },
                        set: { profile.modelProfiles[0].id = $0 }
                    ))
                    TextField("Display Name", text: Binding(
                        get: { profile.modelProfiles.first?.displayName ?? "" },
                        set: { profile.modelProfiles[0].displayName = $0 }
                    ))
                    Toggle("Supports tools", isOn: Binding(
                        get: { profile.modelProfiles.first?.supportsTools ?? false },
                        set: { profile.modelProfiles[0].supportsTools = $0 }
                    ))
                    Toggle("Supports streaming", isOn: Binding(
                        get: { profile.modelProfiles.first?.supportsStreaming ?? false },
                        set: { profile.modelProfiles[0].supportsStreaming = $0 }
                    ))
                    Toggle("Supports reasoning", isOn: Binding(
                        get: { profile.modelProfiles.first?.supportsReasoning ?? false },
                        set: { profile.modelProfiles[0].supportsReasoning = $0 }
                    ))
                    Toggle("Supports cache", isOn: Binding(
                        get: { profile.modelProfiles.first?.supportsCache ?? false },
                        set: { profile.modelProfiles[0].supportsCache = $0 }
                    ))
                }
            }
            .navigationTitle("Provider")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Test") { onTest(profile, apiKey) }
                    Button("Save") {
                        onSave(profile, apiKey.isEmpty ? nil : apiKey)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct DiffViewer: View {
    let diff: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), id: \.self) { line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(background(for: line))
                }
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("@@") { return .yellow.opacity(0.18) }
        if line.hasPrefix("+") { return .green.opacity(0.18) }
        if line.hasPrefix("-") { return .red.opacity(0.18) }
        return .clear
    }
}

private extension JSONValue {
    var stringValue: String {
        switch self {
        case let .string(value):
            return value
        default:
            return "\(rawValue)"
        }
    }

    var debugText: String {
        switch self {
        case let .string(value): value
        case let .integer(value): String(value)
        case let .number(value): String(value)
        case let .bool(value): String(value)
        case let .object(value): value.map { "\($0): \($1.debugText)" }.joined(separator: ", ")
        case let .array(value): value.map(\.debugText).joined(separator: ", ")
        case .null: "null"
        }
    }
}
