import LocalAIWorkspace
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var showFileImporter = false
    @State private var showZipImporter = false
    @State private var pushProtectedBranch = false

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
            githubView
                .tabItem { Label(AppTab.github.title, systemImage: AppTab.github.systemImage) }
                .tag(AppTab.github)
            settingsView
                .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage) }
                .tag(AppTab.settings)
            logsView
                .tabItem { Label(AppTab.logs.title, systemImage: AppTab.logs.systemImage) }
                .tag(AppTab.logs)
        }
        .alert("Error", isPresented: .constant(model.lastErrorMessage != nil), actions: {
            Button("OK") { model.lastErrorMessage = nil }
        }, message: {
            Text(model.lastErrorMessage ?? "")
        })
        .sheet(isPresented: $showProviderEditor) {
            ProviderProfileEditorSheet(
                profile: editingProvider ?? defaultProviderProfile(),
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
        .sheet(item: $renameWorkspace) { workspace in
            NavigationStack {
                Form { TextField("Name", text: $renameWorkspaceName) }
                    .navigationTitle("Rename Workspace")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { renameWorkspace = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                model.renameWorkspace(workspace, to: renameWorkspaceName)
                                renameWorkspace = nil
                            }
                        }
                    }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.data, .folder], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                model.importFiles(from: urls, isZip: false)
            }
        }
        .fileImporter(isPresented: $showZipImporter, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let first = urls.first {
                model.importFiles(from: [first], isZip: true)
            }
        }
        .confirmationDialog("Open another file?", isPresented: .constant(model.pendingOpenFilePath != nil), actions: {
            Button("Save and Open") { model.resolvePendingFileOpen(saveChanges: true) }
            Button("Discard Changes") { model.resolvePendingFileOpen(saveChanges: false) }
            Button("Cancel", role: .cancel) { model.pendingOpenFilePath = nil }
        }, message: {
            Text("You have unsaved changes.")
        })
    }

    private var projectsView: some View {
        NavigationStack {
            List {
                Section("Create Workspace") {
                    TextField("Workspace name", text: $newWorkspaceName)
                    Button("Create") {
                        model.createWorkspace(named: newWorkspaceName)
                        newWorkspaceName = ""
                    }
                }
                Section("Workspaces") {
                    ForEach(model.workspaces) { workspace in
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(workspace.name)
                                            .font(.headline)
                                        Text(workspace.rootPath)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.selectedWorkspaceID == workspace.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                                HStack {
                                    Button("Open") {
                                        model.selectedWorkspaceID = workspace.id
                                        model.refreshWorkspaceState()
                                        model.selectedTab = .workspace
                                    }
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
            }
            .navigationTitle("Projects")
        }
    }

    private var workspaceView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let workspace = model.selectedWorkspace {
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(workspace.name)
                                    .font(.title2.bold())
                                Text(workspace.rootPath)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.secondary)
                                HStack {
                                    if let provider = model.activeProvider { Text("Provider: \(provider.name)") }
                                    if let remote = model.githubRemoteConfig { Text("GitHub: \(remote.owner)/\(remote.repo)@\(remote.branch)") }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }

                        HStack {
                            TextField("Filter files by path", text: $model.fileSearchQuery)
                                .textFieldStyle(.roundedBorder)
                            Button("Import Files") { showFileImporter = true }
                            Button("Import ZIP") { showZipImporter = true }
                            Button("Refresh") { model.refreshWorkspaceState() }
                        }
                        if let importStatusMessage = model.importStatusMessage {
                            Text(importStatusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("File Tree")
                                .font(.headline)
                            FileTreeList(entries: model.filteredWorkspaceFiles) { path in
                                model.requestOpenFile(path)
                            } onDelete: { path in
                                model.pendingDeletePath = path
                            } onRename: { path in
                                model.pendingRenamePath = path
                                renamePathValue = path
                            }
                            .frame(minHeight: 260)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                TextField("New file path", text: $newItemPath)
                                Button("Create File") {
                                    model.createFile(at: newItemPath)
                                    newItemPath = ""
                                }
                            }
                            HStack {
                                TextField("New folder path", text: $newFolderPath)
                                Button("Create Folder") {
                                    model.createFolder(at: newFolderPath)
                                    newFolderPath = ""
                                }
                            }
                        }

                        editorPanel

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("Search content", text: $model.contentSearchQuery)
                                    .textFieldStyle(.roundedBorder)
                                Button("Search") { model.searchContent() }
                            }
                            ForEach(model.contentSearchResults, id: \.self) { match in
                                Button {
                                    model.requestOpenFile(match.path)
                                } label: {
                                    GlassPanel {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("\(match.path):\(match.lineNumber)")
                                                .font(.caption.monospaced())
                                            Text(match.line)
                                                .font(.caption)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        ContentUnavailableView("No Workspace", systemImage: "folder.badge.questionmark")
                    }
                }
                .padding()
            }
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
                        .navigationTitle("Rename Item")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.pendingRenamePath = nil } }
                            ToolbarItem(placement: .confirmationAction) { Button("Save") { model.renameSelectedPath(to: renamePathValue) } }
                        }
                }
            }
        }
    }

    private var editorPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                if let path = model.selectedFilePath {
                    HStack {
                        Text(path)
                            .font(.headline)
                        Spacer()
                        if model.hasUnsavedChanges {
                            Text("Unsaved")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    TextEditor(text: Binding(
                        get: { model.editorText },
                        set: {
                            model.editorText = $0
                            model.hasUnsavedChanges = true
                        }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 260)
                    HStack {
                        Button(model.hasUnsavedChanges ? "Save Changes" : "Saved") { model.saveSelectedFile() }
                            .buttonStyle(.borderedProminent)
                        Button("Discard") {
                            if let path = model.selectedFilePath { try? model.openFile(path) }
                        }
                    }
                } else {
                    ContentUnavailableView("No File Selected", systemImage: "doc.text")
                }
            }
        }
    }

    private var chatView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Describe the task for the selected workspace", text: $model.chatInput, axis: .vertical)
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
                                if let answer = run.finalAnswer, answer.isEmpty == false {
                                    Text(answer)
                                }
                                if run.toolCalls.isEmpty == false {
                                    Text("Tools: \(run.toolCalls.map(\.name).joined(separator: ", "))")
                                        .font(.caption)
                                }
                            }
                        }
                        if run.status == .waitingForUser, let question = run.pendingQuestion?.arguments["question"]?.stringDescription {
                            GlassPanel {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(question)
                                        .font(.headline)
                                    TextField("Your answer", text: $model.questionAnswer)
                                        .textFieldStyle(.roundedBorder)
                                    Button("Send Answer") { Task { await model.answerQuestion() } }
                                }
                            }
                        }
                        if run.status == .waitingForPermission, let request = run.pendingPermissionRequest {
                            GlassPanel {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Permission: \(request.name)")
                                        .font(.headline)
                                    Text(run.pendingPermissionDecision?.reason ?? "")
                                        .foregroundStyle(.secondary)
                                    Text(request.arguments.map { "\($0.key)=\($0.value.stringDescription)" }.sorted().joined(separator: "\n"))
                                        .font(.caption.monospaced())
                                    HStack {
                                        Button("Allow Once") { Task { await model.resumePermission(approved: true) } }
                                        Button("Deny", role: .destructive) { Task { await model.resumePermission(approved: false) } }
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
                patchSection(title: "Pending", status: .pendingReview)
                patchSection(title: "Applied", status: .applied)
                patchSection(title: "Rejected", status: .rejected)
                patchSection(title: "Failed", status: .failed)
            }
            .navigationTitle("Patch Review")
        }
    }

    private func patchSection(title: String, status: PatchProposalStatus) -> some View {
        Section(title) {
            ForEach(model.patchQueue.filter { $0.status == status }) { proposal in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(proposal.title).font(.headline)
                            Text(proposal.reason).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(proposal.status.rawValue)
                            .font(.caption)
                    }
                    Text("\(proposal.changedFiles) files · \(proposal.changedLines) lines · agent=\(proposal.agentRunID?.uuidString ?? "n/a") · snapshot=\(proposal.snapshotID?.uuidString ?? "n/a")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let errorMessage = proposal.errorMessage, errorMessage.isEmpty == false {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    ForEach(proposal.changes, id: \.self) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(change.operation.rawValue): \(change.path)")
                                .font(.caption.monospaced())
                            DiffViewer(diff: change.diff ?? change.newContent ?? (change.newPath.map { "rename -> \($0)" } ?? ""))
                                .frame(maxHeight: 180)
                        }
                    }
                    if proposal.status == .pendingReview {
                        HStack {
                            Button("Apply") { model.applyPatch(proposal) }
                            Button("Reject", role: .destructive) { model.rejectPatch(proposal) }
                            Button("Ask AI to Revise") { model.revisePatch(proposal, instruction: "Please revise this patch based on user feedback.") }
                        }
                    }
                    if proposal.snapshotID != nil {
                        Button("Restore Snapshot") { model.restoreSnapshot(for: proposal) }
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var contextView: some View {
        NavigationStack {
            ScrollView {
                if let snapshot = model.currentContextSnapshot {
                    VStack(alignment: .leading, spacing: 12) {
                        metricsGrid([
                            ("prefixHash", snapshot.prefixHash),
                            ("repoSnapshotHash", snapshot.repoSnapshotHash),
                            ("fileTreeHash", snapshot.fileTreeHash),
                            ("toolSchemaHash", snapshot.toolSchemaHash),
                            ("projectRulesHash", snapshot.projectRulesHash),
                            ("staticTokenCount", "\(snapshot.staticTokenCount)"),
                            ("dynamicTokenCount", "\(snapshot.dynamicTokenCount)")
                        ])
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Included Files (\(snapshot.includedFiles.count))").font(.headline)
                                Text(snapshot.includedFiles.joined(separator: "\n")).font(.caption.monospaced())
                            }
                        }
                        if snapshot.ignoredFiles.isEmpty == false {
                            GlassPanel {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Ignored Files (\(snapshot.ignoredFiles.count))").font(.headline)
                                    Text(snapshot.ignoredFiles.joined(separator: "\n")).font(.caption.monospaced())
                                }
                            }
                        }
                        ForEach(snapshot.blocks.sorted(by: { $0.order < $1.order })) { block in
                            DisclosureGroup {
                                Text(block.content)
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(block.type.rawValue)
                                    Text("stable=\(block.stable ? "yes" : "no") · tokens=\(block.tokenCount) · hash=\(block.contentHash)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding()
                } else {
                    ContentUnavailableView("No Context", systemImage: "text.redaction")
                }
            }
            .navigationTitle("Context")
        }
    }

    private var cacheView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let record = model.cacheRecord {
                        metricsGrid([
                            ("provider", record.provider),
                            ("model", record.model),
                            ("promptTokens", "\(record.promptTokens)"),
                            ("completionTokens", "\(record.completionTokens)"),
                            ("totalTokens", "\(record.promptTokens + record.completionTokens)"),
                            ("cachedTokens", "\(record.cachedTokens)"),
                            ("cacheMissTokens", "\(record.cacheMissTokens)"),
                            ("hitRate", String(format: "%.1f%%", record.cacheHitRate * 100)),
                            ("prefixHash", record.prefixHash),
                            ("repoSnapshotHash", record.repoSnapshotHash),
                            ("fileTreeHash", record.fileTreeHash),
                            ("toolSchemaHash", record.toolSchemaHash),
                            ("projectRulesHash", record.projectRulesHash),
                            ("staticTokenCount", "\(record.staticPrefixTokenCount)"),
                            ("dynamicTokenCount", "\(record.dynamicTokenCount)"),
                            ("latency", "\(record.latencyMs)ms")
                        ])
                        if record.cachedTokens == 0 {
                            Text(model.activeProvider?.supportsPromptCache == true ? "Provider did not return cached token fields; showing prefix-hash estimates only." : "Current provider does not declare prompt cache support.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if record.missReasons.isEmpty == false {
                            GlassPanel {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Miss Reasons").font(.headline)
                                    Text(record.missReasons.map(\.rawValue).joined(separator: "\n"))
                                        .font(.caption.monospaced())
                                }
                            }
                        }
                    }
                    SectionHeader(title: "History")
                    ForEach(model.cacheHistory) { record in
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(record.provider) / \(record.model)")
                                Text("cached=\(record.cachedTokens) prompt=\(record.promptTokens) hit=\(String(format: "%.1f%%", record.cacheHitRate * 100))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Cache")
        }
    }

    private var githubView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let workspace = model.selectedWorkspace {
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("GitHub Remote").font(.headline)
                                TextField("Owner", text: $model.remoteOwner)
                                TextField("Repo", text: $model.remoteRepo)
                                TextField("Branch", text: $model.remoteBranch)
                                SecureField("GitHub Token", text: $model.remoteToken)
                                HStack {
                                    Button("Link Repo") { Task { await model.linkGitHubRepository() } }
                                    Button("Reload") { Task { await model.refreshGitHubData() } }
                                }
                                if let remote = model.githubRemoteConfig {
                                    Text("Linked: \(remote.owner)/\(remote.repo) @ \(remote.branch)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let status = model.githubStatusMessage {
                                    Text(status)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        GlassPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Commit & Push").font(.headline)
                                TextField("Commit message", text: $model.commitMessage)
                                Button("Preview Commit Summary") { Task { await model.previewCommit() } }
                                Button("Commit & Push") {
                                    Task {
                                        let isProtectedBranch = ["main", "master"].contains(model.remoteBranch)
                                        await model.commitAndPush(confirmed: true, secondProtectedBranchConfirmation: pushProtectedBranch || !isProtectedBranch)
                                    }
                                }
                                Toggle("I confirm a protected branch push", isOn: $pushProtectedBranch)
                                if let summary = model.commitSummary {
                                    Text("Prepared SHA: \(summary.headSHA)").font(.caption)
                                    ForEach(summary.changedFiles, id: \.path) { file in
                                        Text("• \(file.path)")
                                            .font(.caption.monospaced())
                                    }
                                    if summary.skippedFiles.isEmpty == false {
                                        Text("Skipped: \(summary.skippedFiles.map { "\($0.path) (\($0.skippedReason ?? ""))" }.joined(separator: ", "))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        GlassPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Create Pull Request").font(.headline)
                                TextField("Title", text: $model.pullRequestTitle)
                                TextField("Body", text: $model.pullRequestBody, axis: .vertical)
                                Button("Create PR") { Task { await model.createPullRequest() } }
                            }
                        }

                        if let builds = model.buildConfiguration {
                            GlassPanel {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Build Buttons · \(builds.name)").font(.headline)
                                    ForEach(builds.builds) { build in
                                        Button(build.name) { Task { await model.dispatchWorkflow(build: build) } }
                                    }
                                }
                            }
                        }

                        GlassPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Workflows").font(.headline)
                                TextField("Workflow ID or file name", text: $model.selectedWorkflowIdentifier)
                                TextField("Ref", text: $model.selectedWorkflowRef)
                                TextField("Inputs JSON", text: $model.workflowInputsText, axis: .vertical)
                                Button("Trigger Workflow") { Task { await model.dispatchWorkflow() } }
                                ForEach(model.githubWorkflows) { workflow in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(workflow.name)
                                        Text("\(workflow.path) · \(workflow.state)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        GlassPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Runs / Jobs / Artifacts").font(.headline)
                                ForEach(model.workflowRuns) { run in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(run.name ?? "Run \(run.id)")
                                        Text("status=\(run.status ?? "n/a") conclusion=\(run.conclusion ?? "n/a") branch=\(run.headBranch ?? "n/a")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Divider()
                                ForEach(model.workflowJobs) { job in
                                    Text("Job: \(job.name) · \(job.status ?? "n/a") / \(job.conclusion ?? "n/a")")
                                        .font(.caption)
                                }
                                Divider()
                                ForEach(model.workflowArtifacts) { artifact in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(artifact.name)
                                        Text("size=\(artifact.sizeInBytes) · \(artifact.archiveDownloadURL)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView("Select a workspace first", systemImage: "arrow.triangle.branch")
                    }
                }
                .padding()
            }
            .navigationTitle("GitHub")
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
                                Button("Use") { model.assignProvider(profile.id) }
                                Button("Export") { model.exportProvider(profile) }
                                Button("Delete", role: .destructive) { model.deleteProvider(profile, deleteSecret: false) }
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
                Section("Provider Import / Export") {
                    TextEditor(text: $model.providerImportJSON)
                        .frame(minHeight: 120)
                    Button("Import Provider JSON") { model.importProviderProfileJSON() }
                    if model.providerExportJSON.isEmpty == false {
                        TextEditor(text: $model.providerExportJSON)
                            .frame(minHeight: 180)
                            .font(.caption.monospaced())
                    }
                }
                if let status = model.lastConnectionStatus {
                    Section("Connection") { Text(status) }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var logsView: some View {
        NavigationStack {
            List(model.auditEntries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.action)
                    if let target = entry.target { Text(target).font(.caption).foregroundStyle(.secondary) }
                    if entry.metadata.isEmpty == false {
                        Text(entry.metadata.keys.sorted().map { "\($0)=\(entry.metadata[$0]?.stringDescription ?? "")" }.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Audit Logs")
        }
    }

    private func metricsGrid(_ items: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(items, id: \.0) { item in
                GlassPanel {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.0)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.1)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
    }

    private func defaultProviderProfile() -> ProviderProfile {
        ProviderProfile(
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
                ModelProfile(id: "", displayName: "", supportsReasoning: false, supportsCache: false, cacheStrategy: .noProviderCacheInfo, supportsTools: true, supportsStreaming: true, maxContextTokens: 128_000, maxOutputTokens: 4_096)
            ]
        )
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View { Text(title).font(.headline) }
}

private struct FileTreeNode: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    var children: [FileTreeNode] = []
}

private struct FileTreeList: View {
    let entries: [WorkspaceFileEntry]
    let onOpen: (String) -> Void
    let onDelete: (String) -> Void
    let onRename: (String) -> Void
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(buildTree(from: entries), id: \.id) { node in
                    nodeView(node, depth: 0)
                }
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func nodeView(_ node: FileTreeNode, depth: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Button {
                    if node.isDirectory {
                        if expanded.contains(node.path) { expanded.remove(node.path) } else { expanded.insert(node.path) }
                    } else {
                        onOpen(node.path)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: node.isDirectory ? (expanded.contains(node.path) ? "folder.open" : "folder") : icon(for: node.path))
                        Text(node.name)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                    }
                    .padding(.leading, CGFloat(depth) * 14)
                }
                .buttonStyle(.plain)
            }
            .contextMenu {
                if node.isDirectory == false {
                    Button("Open") { onOpen(node.path) }
                }
                Button("Rename") { onRename(node.path) }
                Button("Delete", role: .destructive) { onDelete(node.path) }
            }
            if node.isDirectory, expanded.contains(node.path) || depth == 0 {
                ForEach(node.children, id: \.id) { child in
                    nodeView(child, depth: depth + 1)
                }
            }
        }
    }

    private func buildTree(from entries: [WorkspaceFileEntry]) -> [FileTreeNode] {
        func insert(_ node: inout [FileTreeNode], parts: ArraySlice<String>, fullPath: String, isDirectory: Bool) {
            guard let head = parts.first else { return }
            let tail = parts.dropFirst()
            if let index = node.firstIndex(where: { $0.name == head }) {
                if tail.isEmpty {
                    node[index] = FileTreeNode(name: head, path: fullPath, isDirectory: isDirectory, children: node[index].children)
                } else {
                    var children = node[index].children
                    insert(&children, parts: tail, fullPath: fullPath, isDirectory: isDirectory)
                    node[index].children = children.sorted(by: sortNodes)
                }
            } else {
                var newNode = FileTreeNode(name: head, path: tail.isEmpty ? fullPath : parts.joined(separator: "/"), isDirectory: tail.isEmpty ? isDirectory : true)
                if tail.isEmpty == false {
                    var children: [FileTreeNode] = []
                    insert(&children, parts: tail, fullPath: fullPath, isDirectory: isDirectory)
                    newNode.children = children
                }
                node.append(newNode)
                node.sort(by: sortNodes)
            }
        }

        var nodes: [FileTreeNode] = []
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            insert(&nodes, parts: ArraySlice(entry.path.split(separator: "/").map(String.init)), fullPath: entry.path, isDirectory: entry.isDirectory)
        }
        return nodes
    }

    private func sortNodes(_ lhs: FileTreeNode, _ rhs: FileTreeNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func icon(for path: String) -> String {
        if path.hasSuffix(".swift") { return "swift" }
        if path.hasSuffix(".json") { return "curlybraces" }
        if path.hasSuffix(".md") { return "doc.richtext" }
        if path.hasSuffix(".yml") || path.hasSuffix(".yaml") { return "gearshape.2" }
        return "doc.text"
    }
}

private struct ProviderProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProviderDraft
    @State private var apiKey: String
    let onSave: (ProviderProfile, String?) -> Void
    let onTest: (ProviderProfile, String?) -> Void

    init(profile: ProviderProfile, apiKey: String, onSave: @escaping (ProviderProfile, String?) -> Void, onTest: @escaping (ProviderProfile, String?) -> Void) {
        _draft = State(initialValue: ProviderDraft(profile: profile))
        _apiKey = State(initialValue: apiKey)
        self.onSave = onSave
        self.onTest = onTest
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    TextField("Name", text: $draft.name)
                    Picker("API Style", selection: $draft.apiStyle) {
                        ForEach(APIStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Base URL", text: $draft.baseURL)
                        .textInputAutocapitalization(.never)
                    TextField("Endpoint", text: $draft.endpoint)
                        .textInputAutocapitalization(.never)
                    Picker("Auth Type", selection: $draft.authType) {
                        ForEach(AuthType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Auth key name", text: $draft.authKeyName)
                    SecureField("API Key", text: $apiKey)
                    Toggle("Supports streaming", isOn: $draft.supportsStreaming)
                    Toggle("Supports tool calling", isOn: $draft.supportsToolCalling)
                    Toggle("Supports JSON mode", isOn: $draft.supportsJSONMode)
                    Toggle("Supports vision", isOn: $draft.supportsVision)
                    Toggle("Supports reasoning", isOn: $draft.supportsReasoning)
                    Toggle("Supports prompt cache", isOn: $draft.supportsPromptCache)
                    Toggle("Supports explicit cache control", isOn: $draft.supportsExplicitCacheControl)
                    Toggle("Supports web search", isOn: $draft.supportsWebSearch)
                }
                Section("Request Mapping") {
                    mappingFields(prefix: $draft.requestFieldMapping)
                }
                Section("Response Mapping") {
                    mappingFields(prefix: $draft.responseFieldMapping)
                }
                Section("Usage Mapping") {
                    mappingFields(prefix: $draft.usageFieldMapping)
                }
                Section("Extra Headers") {
                    KeyValueListEditor(rows: $draft.extraHeaders)
                }
                Section("Extra Body Parameters") {
                    KeyValueListEditor(rows: $draft.extraBodyParameters)
                }
                Section("Models") {
                    ForEach($draft.models) { $model in
                        ModelDraftEditor(model: $model)
                    }
                    Button("Add Model") { draft.models.append(ModelDraft()) }
                }
            }
            .navigationTitle("Provider Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Test") { if let profile = draft.makeProfile() { onTest(profile, apiKey.isEmpty ? nil : apiKey) } }
                    Button("Save") {
                        if let profile = draft.makeProfile() {
                            onSave(profile, apiKey.isEmpty ? nil : apiKey)
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func mappingFields(prefix: Binding<[EditablePair]>) -> some View {
        KeyValueListEditor(rows: prefix)
    }
}

private struct ModelDraftEditor: View {
    @Binding var model: ModelDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Model ID", text: $model.id)
            TextField("Display Name", text: $model.displayName)
            TextField("Max Context Tokens", value: $model.maxContextTokens, format: .number)
            TextField("Max Output Tokens", value: $model.maxOutputTokens, format: .number)
            Toggle("Supports reasoning", isOn: $model.supportsReasoning)
            TextField("Reasoning enabled field", text: $model.reasoningEnabledField)
            TextField("Reasoning depth field", text: $model.reasoningDepthField)
            KeyValueListEditor(rows: $model.reasoningLevels)
            Toggle("Supports cache", isOn: $model.supportsCache)
            Picker("Cache Strategy", selection: $model.cacheStrategy) {
                ForEach(CacheStrategy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("Supports tools", isOn: $model.supportsTools)
            Toggle("Supports streaming", isOn: $model.supportsStreaming)
            KeyValueListEditor(rows: $model.extraParameters)
        }
    }
}

private struct EditablePair: Identifiable, Hashable {
    let id = UUID()
    var key: String = ""
    var value: String = ""
}

private struct ModelDraft: Identifiable {
    var id = ""
    var displayName = ""
    var maxContextTokens = 128_000
    var maxOutputTokens = 4_096
    var supportsReasoning = false
    var reasoningEnabledField = ""
    var reasoningDepthField = ""
    var reasoningLevels: [EditablePair] = []
    var supportsCache = false
    var cacheStrategy: CacheStrategy = .noProviderCacheInfo
    var supportsTools = true
    var supportsStreaming = true
    var extraParameters: [EditablePair] = []

    init() {}

    init(model: ModelProfile) {
        id = model.id
        displayName = model.displayName
        maxContextTokens = model.maxContextTokens
        maxOutputTokens = model.maxOutputTokens
        supportsReasoning = model.supportsReasoning
        reasoningEnabledField = model.reasoningMapping?.enabledField ?? ""
        reasoningDepthField = model.reasoningMapping?.depthField ?? ""
        reasoningLevels = model.reasoningMapping?.levels.map { EditablePair(key: $0.label, value: $0.value) } ?? []
        supportsCache = model.supportsCache
        cacheStrategy = model.cacheStrategy
        supportsTools = model.supportsTools
        supportsStreaming = model.supportsStreaming
        extraParameters = model.extraParameters.map { EditablePair(key: $0.key, value: jsonString($0.value)) }.sorted(by: { $0.key < $1.key })
    }

    func makeModel() -> ModelProfile {
        let reasoning: ReasoningMapping? = supportsReasoning && reasoningEnabledField.isEmpty == false && reasoningDepthField.isEmpty == false ? ReasoningMapping(enabledField: reasoningEnabledField, depthField: reasoningDepthField, levels: reasoningLevels.compactMap { pair in
            guard pair.key.isEmpty == false, pair.value.isEmpty == false else { return nil }
            return ReasoningLevel(label: pair.key, value: pair.value)
        }) : nil
        return ModelProfile(
            id: id,
            displayName: displayName,
            supportsReasoning: supportsReasoning,
            reasoningMapping: reasoning,
            supportsCache: supportsCache,
            cacheStrategy: cacheStrategy,
            supportsTools: supportsTools,
            supportsStreaming: supportsStreaming,
            maxContextTokens: maxContextTokens,
            maxOutputTokens: maxOutputTokens,
            extraParameters: dictionary(from: extraParameters)
        )
    }
}

private struct ProviderDraft {
    var id: String
    var name: String
    var apiStyle: APIStyle
    var baseURL: String
    var endpoint: String
    var authType: AuthType
    var authKeyName: String
    var supportsStreaming: Bool
    var supportsToolCalling: Bool
    var supportsJSONMode: Bool
    var supportsVision: Bool
    var supportsReasoning: Bool
    var supportsPromptCache: Bool
    var supportsExplicitCacheControl: Bool
    var supportsWebSearch: Bool
    var requestFieldMapping: [EditablePair]
    var responseFieldMapping: [EditablePair]
    var usageFieldMapping: [EditablePair]
    var extraHeaders: [EditablePair]
    var extraBodyParameters: [EditablePair]
    var models: [ModelDraft]

    init(profile: ProviderProfile) {
        id = profile.id
        name = profile.name
        apiStyle = profile.apiStyle
        baseURL = profile.baseURL
        endpoint = profile.endpoint
        authType = profile.auth.type
        authKeyName = profile.auth.keyName ?? ""
        supportsStreaming = profile.supportsStreaming
        supportsToolCalling = profile.supportsToolCalling
        supportsJSONMode = profile.supportsJSONMode
        supportsVision = profile.supportsVision
        supportsReasoning = profile.supportsReasoning
        supportsPromptCache = profile.supportsPromptCache
        supportsExplicitCacheControl = profile.supportsExplicitCacheControl
        supportsWebSearch = profile.supportsWebSearch
        requestFieldMapping = profile.requestFieldMapping.map { EditablePair(key: $0.key, value: $0.value) }.sorted(by: { $0.key < $1.key })
        responseFieldMapping = profile.responseFieldMapping.map { EditablePair(key: $0.key, value: $0.value) }.sorted(by: { $0.key < $1.key })
        usageFieldMapping = profile.usageFieldMapping.map { EditablePair(key: $0.key, value: $0.value) }.sorted(by: { $0.key < $1.key })
        extraHeaders = profile.extraHeaders.map { EditablePair(key: $0.key, value: $0.value) }.sorted(by: { $0.key < $1.key })
        extraBodyParameters = profile.extraBodyParameters.map { EditablePair(key: $0.key, value: jsonString($0.value)) }.sorted(by: { $0.key < $1.key })
        models = profile.modelProfiles.map(ModelDraft.init(model:))
    }

    func makeProfile() -> ProviderProfile? {
        ProviderProfile(
            id: id.isEmpty ? UUID().uuidString : id,
            name: name,
            apiStyle: apiStyle,
            baseURL: baseURL,
            endpoint: endpoint,
            auth: AuthConfiguration(type: authType, keyName: authKeyName.isEmpty ? nil : authKeyName),
            supportsStreaming: supportsStreaming,
            supportsToolCalling: supportsToolCalling,
            supportsJSONMode: supportsJSONMode,
            supportsVision: supportsVision,
            supportsReasoning: supportsReasoning,
            supportsPromptCache: supportsPromptCache,
            supportsExplicitCacheControl: supportsExplicitCacheControl,
            supportsWebSearch: supportsWebSearch,
            requestFieldMapping: stringDictionary(from: requestFieldMapping),
            responseFieldMapping: stringDictionary(from: responseFieldMapping),
            usageFieldMapping: stringDictionary(from: usageFieldMapping),
            extraHeaders: stringDictionary(from: extraHeaders),
            extraBodyParameters: dictionary(from: extraBodyParameters),
            modelProfiles: models.map { $0.makeModel() }
        )
    }
}

private struct KeyValueListEditor: View {
    @Binding var rows: [EditablePair]

    var body: some View {
        ForEach($rows) { $row in
            HStack {
                TextField("key", text: $row.key)
                TextField("value", text: $row.value)
            }
        }
        HStack {
            Button("Add Row") { rows.append(EditablePair()) }
            if rows.isEmpty == false {
                Button("Remove Last", role: .destructive) { rows.removeLast() }
            }
        }
    }
}

private struct DiffViewer: View {
    let diff: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(background(for: item.element))
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

private func stringDictionary(from rows: [EditablePair]) -> [String: String] {
    rows.reduce(into: [:]) { partial, row in
        guard row.key.isEmpty == false else { return }
        partial[row.key] = row.value
    }
}

private func dictionary(from rows: [EditablePair]) -> [String: JSONValue] {
    rows.reduce(into: [:]) { partial, row in
        guard row.key.isEmpty == false else { return }
        partial[row.key] = parseJSONValue(row.value)
    }
}

private func parseJSONValue(_ text: String) -> JSONValue {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) else {
        return .string(text)
    }
    return convertJSONAny(object)
}

private func convertJSONAny(_ object: Any) -> JSONValue {
    switch object {
    case let value as String:
        return .string(value)
    case let value as Int:
        return .integer(value)
    case let value as Double:
        return .number(value)
    case let value as Bool:
        return .bool(value)
    case let value as [String: Any]:
        return .object(value.mapValues(convertJSONAny))
    case let value as [Any]:
        return .array(value.map(convertJSONAny))
    default:
        return .null
    }
}

private func jsonString(_ value: JSONValue) -> String {
    switch value {
    case let .string(string): return string
    case let .number(number): return String(number)
    case let .integer(integer): return String(integer)
    case let .bool(bool): return String(bool)
    case let .object(object): return (try? String(decoding: JSONEncoder.pretty.encode(object), as: UTF8.self)) ?? "{}"
    case let .array(array): return (try? String(decoding: JSONEncoder.pretty.encode(array), as: UTF8.self)) ?? "[]"
    case .null: return "null"
    }
}
