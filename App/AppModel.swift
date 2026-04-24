import LocalAIWorkspace
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var providerProfiles: [ProviderProfile] = []
    @Published var selectedWorkspaceID: Workspace.ID?
    @Published var selectedTab: AppTab = .projects
    @Published var workspaceFiles: [WorkspaceFileEntry] = []
    @Published var selectedFilePath: String?
    @Published var pendingOpenFilePath: String?
    @Published var editorText = ""
    @Published var hasUnsavedChanges = false
    @Published var contentSearchResults: [SearchMatch] = []
    @Published var patchQueue: [PatchProposal] = []
    @Published var snapshots: [SnapshotRecord] = []
    @Published var currentRun: AgentRun?
    @Published var currentContextSnapshot: ContextSnapshot?
    @Published var cacheRecord: CacheRecord?
    @Published var cacheHistory: [CacheRecord] = []
    @Published var lastConnectionStatus: String?
    @Published var lastErrorMessage: String?
    @Published var chatInput = ""
    @Published var questionAnswer = ""
    @Published var fileSearchQuery = ""
    @Published var contentSearchQuery = ""
    @Published var pendingDeletePath: String?
    @Published var pendingRenamePath: String?
    @Published var importStatusMessage: String?
    @Published var auditEntries: [AuditLogEntry] = []
    @Published var githubRemoteConfig: GitHubRemoteConfig?
    @Published var githubRepository: GitHubRepository?
    @Published var githubWorkflows: [GitHubWorkflow] = []
    @Published var workflowRuns: [GitHubWorkflowRun] = []
    @Published var workflowJobs: [GitHubWorkflowJob] = []
    @Published var workflowArtifacts: [GitHubArtifact] = []
    @Published var buildConfiguration: BuildConfiguration?
    @Published var githubStatusMessage: String?
    @Published var commitSummary: GitHubCommitSummary?
    @Published var remoteOwner = ""
    @Published var remoteRepo = ""
    @Published var remoteBranch = "main"
    @Published var remoteToken = ""
    @Published var commitMessage = "Update from LocalAIWorkspace"
    @Published var pullRequestTitle = ""
    @Published var pullRequestBody = ""
    @Published var selectedWorkflowIdentifier = ""
    @Published var selectedWorkflowRef = ""
    @Published var workflowInputsText = "{}"
    @Published var patchRevisionInstruction = ""
    @Published var providerExportJSON = ""
    @Published var providerImportJSON = ""

    private let workspaceManager: WorkspaceManager
    private let secretStore: any SecretStore
    private let aiClient: DefaultAIClient
    private let contextEngine = ContextEngine()
    private let cacheEngine = CacheEngine()
    private let permissionManager = PermissionManager(globalMode: .semiAuto)
    private let promptBuilder = PromptBuilder()
    private let profilesURL: URL
    private let workspaceImportService: WorkspaceImportService
    private let buildConfigLoader: BuildConfigLoader
    private let githubSyncService: GitHubSyncService

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    var activeProvider: ProviderProfile? {
        guard let id = selectedWorkspace?.activeProviderProfileID else { return providerProfiles.first }
        return providerProfiles.first { $0.id == id } ?? providerProfiles.first
    }

    var activeModel: ModelProfile? {
        activeProvider?.modelProfiles.first
    }

    var filteredWorkspaceFiles: [WorkspaceFileEntry] {
        guard fileSearchQuery.isEmpty == false else { return workspaceFiles }
        return workspaceFiles.filter { $0.path.localizedCaseInsensitiveContains(fileSearchQuery) }
    }

    init(
        workspaceManager: WorkspaceManager? = nil,
        secretStore: any SecretStore = KeychainSecretStore(),
        aiClient: DefaultAIClient = DefaultAIClient()
    ) {
        do {
            self.workspaceManager = try workspaceManager ?? WorkspaceManager()
            profilesURL = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("ProviderProfiles/profiles.json") ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("profiles.json")
        } catch {
            fatalError("Failed to initialize WorkspaceManager: \(error.localizedDescription)")
        }
        self.secretStore = secretStore
        self.aiClient = aiClient
        workspaceImportService = WorkspaceImportService(workspaceManager: self.workspaceManager)
        buildConfigLoader = BuildConfigLoader(workspaceManager: self.workspaceManager)
        githubSyncService = GitHubSyncService(workspaceManager: self.workspaceManager, secretStore: secretStore)
        loadProfiles()
        reloadWorkspaces()
    }

    func reloadWorkspaces(select workspaceID: UUID? = nil) {
        do {
            workspaces = try workspaceManager.listWorkspaces()
            if let workspaceID {
                selectedWorkspaceID = workspaceID
            } else if selectedWorkspaceID == nil {
                selectedWorkspaceID = workspaces.first?.id
            }
            refreshWorkspaceState()
        } catch {
            present(error)
        }
    }

    func createWorkspace(named name: String) {
        guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            lastErrorMessage = "Workspace name cannot be empty."
            return
        }
        do {
            let workspace = try workspaceManager.createWorkspace(name: name)
            reloadWorkspaces(select: workspace.id)
            try log(action: "workspace_created", workspaceID: workspace.id, metadata: ["name": .string(name)])
        } catch {
            present(error)
        }
    }

    func renameWorkspace(_ workspace: Workspace, to name: String) {
        guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            lastErrorMessage = "Workspace name cannot be empty."
            return
        }
        do {
            _ = try workspaceManager.renameWorkspace(id: workspace.id, to: name)
            reloadWorkspaces(select: workspace.id)
        } catch {
            present(error)
        }
    }

    func deleteWorkspace(_ workspace: Workspace) {
        do {
            try workspaceManager.deleteWorkspace(id: workspace.id)
            reloadWorkspaces(select: workspaces.first(where: { $0.id != workspace.id })?.id)
        } catch {
            present(error)
        }
    }

    func refreshWorkspaceState() {
        guard let workspace = selectedWorkspace else {
            workspaceFiles = []
            patchQueue = []
            snapshots = []
            currentContextSnapshot = nil
            cacheHistory = []
            cacheRecord = nil
            githubRemoteConfig = nil
            auditEntries = []
            buildConfiguration = nil
            return
        }
        do {
            let current = try workspaceManager.openWorkspace(id: workspace.id)
            if let index = workspaces.firstIndex(where: { $0.id == current.id }) {
                workspaces[index] = current
            }
            let fs = try workspaceManager.workspaceFS(for: current)
            workspaceFiles = try fs.listFiles()
            patchQueue = try patchStore(for: current.id).list(workspaceID: current.id)
            snapshots = try snapshotStore(for: current.id).list(workspaceID: current.id)
            cacheHistory = try cacheStore(for: current.id).list(workspaceID: nil)
            cacheRecord = cacheHistory.first
            currentContextSnapshot = try buildAndPersistContextSnapshot(for: current)
            buildConfiguration = try buildConfigLoader.load(workspaceID: current.id)
            githubRemoteConfig = try? githubSyncService.loadRemoteConfig(workspaceID: current.id)
            if let remote = githubRemoteConfig {
                remoteOwner = remote.owner
                remoteRepo = remote.repo
                remoteBranch = remote.branch
                selectedWorkflowRef = remote.branch
            }
            auditEntries = try auditStore(for: current.id).recent(limit: 100)
            if let path = selectedFilePath, workspaceFiles.contains(where: { $0.path == path }) {
                try openFile(path)
            } else if selectedFilePath != nil {
                selectedFilePath = nil
                editorText = ""
                hasUnsavedChanges = false
            }
        } catch {
            present(error)
        }
    }

    func importFiles(from urls: [URL], isZip: Bool) {
        guard let workspace = selectedWorkspace else { return }
        do {
            let result = if isZip {
                try workspaceImportService.importZip(sourceURL: urls[0], workspaceID: workspace.id)
            } else {
                try workspaceImportService.importDirectory(sourceURLs: urls, workspaceID: workspace.id)
            }
            importStatusMessage = "Imported \(result.importedCount) item(s). \(result.warnings.joined(separator: " "))"
            refreshWorkspaceState()
            try log(action: isZip ? "zip_imported" : "files_imported", workspaceID: workspace.id, metadata: ["count": .integer(result.importedCount)])
        } catch {
            present(error)
        }
    }

    func createFile(at path: String, contents: String = "") {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            lastErrorMessage = "New file path cannot be empty."
            return
        }
        updateFileSystem { fs in
            try fs.writeTextFile(path: trimmed, content: contents)
        }
        try? log(action: "file_created", workspaceID: selectedWorkspace?.id, metadata: ["path": .string(trimmed)])
    }

    func createFolder(at path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            lastErrorMessage = "New folder path cannot be empty."
            return
        }
        updateFileSystem { fs in
            let url = try fs.safeURL(for: trimmed)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try? log(action: "folder_created", workspaceID: selectedWorkspace?.id, metadata: ["path": .string(trimmed)])
    }

    func requestOpenFile(_ path: String) {
        guard hasUnsavedChanges, selectedFilePath != path else {
            try? openFile(path)
            return
        }
        pendingOpenFilePath = path
    }

    func resolvePendingFileOpen(saveChanges: Bool) {
        if saveChanges {
            saveSelectedFile()
        }
        if let path = pendingOpenFilePath {
            try? openFile(path)
        }
        pendingOpenFilePath = nil
    }

    func openFile(_ path: String) throws {
        guard let workspace = selectedWorkspace else { return }
        let fs = try workspaceManager.workspaceFS(for: workspace)
        let file = try fs.readTextFile(path: path)
        selectedFilePath = path
        editorText = file.content
        hasUnsavedChanges = false
    }

    func saveSelectedFile() {
        guard let path = selectedFilePath else { return }
        updateFileSystem { fs in
            try fs.writeTextFile(path: path, content: editorText)
        }
        hasUnsavedChanges = false
        try? log(action: "file_saved", workspaceID: selectedWorkspace?.id, metadata: ["path": .string(path)])
    }

    func renameSelectedPath(to destination: String) {
        guard let source = pendingRenamePath else { return }
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            lastErrorMessage = "Rename path cannot be empty."
            return
        }
        updateFileSystem { fs in
            try fs.moveItem(from: source, to: trimmed)
        }
        pendingRenamePath = nil
        try? log(action: "file_renamed", workspaceID: selectedWorkspace?.id, metadata: ["from": .string(source), "to": .string(trimmed)])
    }

    func deletePendingPath() {
        guard let path = pendingDeletePath else { return }
        updateFileSystem { fs in
            try fs.deleteItem(path: path)
        }
        if selectedFilePath == path {
            selectedFilePath = nil
            editorText = ""
            hasUnsavedChanges = false
        }
        pendingDeletePath = nil
        try? log(action: "file_deleted", workspaceID: selectedWorkspace?.id, metadata: ["path": .string(path)])
    }

    func searchContent() {
        guard let workspace = selectedWorkspace else { return }
        do {
            let fs = try workspaceManager.workspaceFS(for: workspace)
            contentSearchResults = contentSearchQuery.isEmpty ? [] : try fs.search(query: contentSearchQuery)
        } catch {
            present(error)
        }
    }

    func saveProvider(_ profile: ProviderProfile, apiKey: String?) {
        do {
            var mutable = profile
            if let apiKey, apiKey.isEmpty == false {
                let reference = mutable.apiKeyReference ?? "provider.\(mutable.id)"
                try secretStore.save(service: "LocalAIWorkspace.provider", account: reference, value: apiKey)
                mutable.apiKeyReference = reference
            }
            providerProfiles.removeAll { $0.id == mutable.id }
            providerProfiles.append(mutable)
            providerProfiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            try persistProfiles()
            if var workspace = selectedWorkspace, workspace.activeProviderProfileID == nil {
                workspace.activeProviderProfileID = mutable.id
                try workspaceManager.updateWorkspace(workspace)
                reloadWorkspaces(select: workspace.id)
            }
            try log(action: "provider_saved", workspaceID: selectedWorkspace?.id, metadata: ["provider": .string(mutable.name)])
        } catch {
            present(error)
        }
    }

    func importProviderProfileJSON() {
        guard providerImportJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        do {
            let profile = try ProviderProfile.imported(from: Data(providerImportJSON.utf8))
            providerProfiles.removeAll { $0.id == profile.id }
            providerProfiles.append(profile)
            try persistProfiles()
            providerImportJSON = ""
        } catch {
            present(error)
        }
    }

    func exportProvider(_ profile: ProviderProfile) {
        do {
            providerExportJSON = String(decoding: try profile.exportedData(), as: UTF8.self)
        } catch {
            present(error)
        }
    }

    func deleteProvider(_ profile: ProviderProfile, deleteSecret: Bool) {
        do {
            if deleteSecret, let reference = profile.apiKeyReference {
                try secretStore.delete(service: "LocalAIWorkspace.provider", account: reference)
            }
            providerProfiles.removeAll { $0.id == profile.id }
            try persistProfiles()
        } catch {
            present(error)
        }
    }

    func assignProvider(_ profileID: String?) {
        guard var workspace = selectedWorkspace else { return }
        workspace.activeProviderProfileID = profileID
        do {
            try workspaceManager.updateWorkspace(workspace)
            reloadWorkspaces(select: workspace.id)
        } catch {
            present(error)
        }
    }

    func testConnection(profile: ProviderProfile, apiKey: String?) async {
        do {
            let key = try apiKeyForProfile(profile, override: apiKey)
            let modelID = profile.modelProfiles.first?.id ?? ""
            let request = AIRequest(messages: [AIMessage(role: "user", content: "ping")], model: modelID, maxTokens: 8, stream: false)
            let response = try await aiClient.complete(profile: profile, apiKey: key, request: request)
            let usage = response.usage
            let usageSummary = [usage?.inputTokens, usage?.outputTokens, usage?.latencyMs].compactMap { $0 }.map(String.init).joined(separator: "/")
            lastConnectionStatus = "Connection succeeded · model=\(modelID) · usage/latency=\(usageSummary.isEmpty ? "n/a" : usageSummary)"
            try log(action: "provider_tested", workspaceID: selectedWorkspace?.id, metadata: ["provider": .string(profile.name), "success": .bool(true)])
        } catch {
            present(error)
            lastConnectionStatus = "Connection failed: \(error.localizedDescription)"
            try? log(action: "provider_tested", workspaceID: selectedWorkspace?.id, metadata: ["provider": .string(profile.name), "success": .bool(false)])
        }
    }

    func startChat() async {
        guard let workspace = selectedWorkspace else {
            lastErrorMessage = "Select a workspace first."
            return
        }
        guard let profile = activeProvider, let model = activeModel else {
            lastErrorMessage = "Select a provider profile first."
            return
        }
        do {
            let snapshot = try buildAndPersistContextSnapshot(for: workspace)
            currentContextSnapshot = snapshot
            let prompt = promptBuilder.build(
                snapshot: snapshot,
                userTask: chatInput,
                toolSchemas: SupportedTools.schemas,
                permissionRules: makePermissionRules(),
                activeProvider: profile,
                activeModel: model,
                workspace: workspace,
                additionalUserRequirements: chatInput
            )
            let loop = try makeAgentLoop(for: workspace)
            let run = try await loop.start(
                workspaceID: workspace.id,
                profile: profile,
                apiKey: try apiKeyForProfile(profile),
                modelID: model.id,
                systemPrompt: prompt.systemMessage,
                userTask: chatInput,
                initialMessages: prompt.messages,
                contextRequest: makeContextRequest(for: workspace)
            )
            try log(action: "chat_started", workspaceID: workspace.id, metadata: ["task": .string(chatInput)])
            handle(run: run, profile: profile, model: model, snapshot: snapshot)
        } catch {
            present(error)
        }
    }

    func answerQuestion() async {
        guard let run = currentRun, let profile = activeProvider, let workspace = selectedWorkspace else { return }
        do {
            let snapshot = try buildAndPersistContextSnapshot(for: workspace)
            let loop = try makeAgentLoop(for: workspace)
            let updated = try await loop.resume(runID: run.id, answer: questionAnswer, profile: profile, apiKey: try apiKeyForProfile(profile), contextRequest: makeContextRequest(for: workspace))
            questionAnswer = ""
            if let model = activeModel {
                handle(run: updated, profile: profile, model: model, snapshot: snapshot)
            }
        } catch {
            present(error)
        }
    }

    func resumePermission(approved: Bool) async {
        guard let run = currentRun, let profile = activeProvider, let workspace = selectedWorkspace else { return }
        do {
            let snapshot = try buildAndPersistContextSnapshot(for: workspace)
            let loop = try makeAgentLoop(for: workspace)
            let updated = try await loop.resumePermission(runID: run.id, approved: approved, profile: profile, apiKey: try apiKeyForProfile(profile), contextRequest: makeContextRequest(for: workspace))
            try log(action: approved ? "permission_approved" : "permission_denied", workspaceID: workspace.id, metadata: ["tool": .string(run.pendingPermissionRequest?.name ?? "unknown")])
            if let model = activeModel {
                handle(run: updated, profile: profile, model: model, snapshot: snapshot)
            }
        } catch {
            present(error)
        }
    }

    func applyPatch(_ proposal: PatchProposal, confirmedByUser: Bool = true) {
        guard let workspace = selectedWorkspace else { return }
        do {
            let service = makePatchReviewService(for: workspace.id)
            _ = try service.apply(proposalID: proposal.id, confirmedByUser: confirmedByUser)
            try log(action: "patch_applied", workspaceID: workspace.id, metadata: ["patch": .string(proposal.id.uuidString)])
            refreshWorkspaceState()
        } catch {
            present(error)
        }
    }

    func rejectPatch(_ proposal: PatchProposal) {
        guard let workspace = selectedWorkspace else { return }
        do {
            let service = makePatchReviewService(for: workspace.id)
            _ = try service.reject(proposalID: proposal.id)
            try log(action: "patch_rejected", workspaceID: workspace.id, metadata: ["patch": .string(proposal.id.uuidString)])
            refreshWorkspaceState()
        } catch {
            present(error)
        }
    }

    func restoreSnapshot(for proposal: PatchProposal) {
        guard let workspace = selectedWorkspace, let snapshotID = proposal.snapshotID else { return }
        do {
            let service = makePatchReviewService(for: workspace.id)
            _ = try service.restoreSnapshot(snapshotID: snapshotID, workspaceID: workspace.id, confirmedByUser: true)
            try log(action: "snapshot_restored", workspaceID: workspace.id, metadata: ["snapshot": .string(snapshotID.uuidString)])
            refreshWorkspaceState()
        } catch {
            present(error)
        }
    }

    func revisePatch(_ proposal: PatchProposal, instruction: String) {
        patchRevisionInstruction = instruction
        let diff = proposal.changes.map { $0.diff ?? $0.newContent ?? "\($0.operation.rawValue) \($0.path)" }.joined(separator: "\n\n")
        chatInput = "Revise patch \(proposal.title). Instruction: \(instruction)\n\nCurrent proposal diff:\n\(diff)"
        selectedTab = .chat
        try? log(action: "patch_revise_requested", workspaceID: selectedWorkspace?.id, metadata: ["patch": .string(proposal.id.uuidString)])
    }

    func linkGitHubRepository() async {
        guard let workspace = selectedWorkspace else { return }
        do {
            let remote = try await githubSyncService.linkRepository(workspaceID: workspace.id, owner: remoteOwner, repo: remoteRepo, branch: remoteBranch, token: remoteToken)
            githubRemoteConfig = remote
            githubStatusMessage = "Linked \(remote.owner)/\(remote.repo)@\(remote.branch)"
            try log(action: "github_linked", workspaceID: workspace.id, metadata: ["repo": .string(remote.remoteURL)])
            remoteToken = ""
        } catch {
            present(error)
        }
    }

    func refreshGitHubData() async {
        guard let workspace = selectedWorkspace else { return }
        do {
            githubRepository = try await githubSyncService.getRepository(workspaceID: workspace.id)
            githubWorkflows = try await githubSyncService.listWorkflows(workspaceID: workspace.id)
            workflowRuns = try await githubSyncService.listWorkflowRuns(workspaceID: workspace.id)
            if let run = workflowRuns.first {
                workflowJobs = try await githubSyncService.listJobsForRun(workspaceID: workspace.id, runID: run.id)
                workflowArtifacts = try await githubSyncService.listArtifactsForRun(workspaceID: workspace.id, runID: run.id)
            }
            buildConfiguration = try buildConfigLoader.load(workspaceID: workspace.id)
        } catch {
            present(error)
        }
    }

    func commitAndPush(confirmed: Bool, secondProtectedBranchConfirmation: Bool) async {
        guard let workspace = selectedWorkspace else { return }
        do {
            commitSummary = try await githubSyncService.pushWorkspaceToBranch(workspaceID: workspace.id, message: commitMessage, confirmed: confirmed, secondProtectedBranchConfirmation: secondProtectedBranchConfirmation)
            githubStatusMessage = "Pushed commit \(commitSummary?.headSHA ?? "")"
            try log(action: "github_push", workspaceID: workspace.id, metadata: ["sha": .string(commitSummary?.headSHA ?? "")])
            refreshWorkspaceState()
        } catch {
            present(error)
        }
    }

    func previewCommit() async {
        guard let workspace = selectedWorkspace else { return }
        do {
            commitSummary = try await githubSyncService.commitWorkspaceChanges(workspaceID: workspace.id, message: commitMessage)
            githubStatusMessage = "Prepared commit \(commitSummary?.headSHA ?? "") with \(commitSummary?.changedFiles.count ?? 0) files."
        } catch {
            present(error)
        }
    }

    func createPullRequest() async {
        guard let workspace = selectedWorkspace, let remote = githubRemoteConfig else { return }
        do {
            let url = try await githubSyncService.createPullRequest(workspaceID: workspace.id, title: pullRequestTitle, body: pullRequestBody, head: remote.branch, base: remote.branch)
            githubStatusMessage = "Pull Request created: \(url)"
            try log(action: "pull_request_created", workspaceID: workspace.id, metadata: ["url": .string(url)])
        } catch {
            present(error)
        }
    }

    func dispatchWorkflow(build: BuildDefinition? = nil) async {
        guard let workspace = selectedWorkspace else { return }
        let workflow = build?.workflow ?? selectedWorkflowIdentifier
        guard workflow.isEmpty == false else {
            lastErrorMessage = "Choose a workflow first."
            return
        }
        do {
            let inputs = parseInputs(workflowInputsText)
            let ref = build?.ref ?? (selectedWorkflowRef.isEmpty ? (githubRemoteConfig?.branch ?? "main") : selectedWorkflowRef)
            try await githubSyncService.dispatchWorkflow(workspaceID: workspace.id, workflowIDOrFileName: workflow, ref: ref, inputs: build?.inputs.isEmpty == false ? build!.inputs : inputs)
            githubStatusMessage = "Workflow dispatched: \(workflow)"
            try log(action: "workflow_dispatched", workspaceID: workspace.id, metadata: ["workflow": .string(workflow), "ref": .string(ref)])
            await refreshGitHubData()
        } catch {
            present(error)
        }
    }

    private func handle(run: AgentRun, profile: ProviderProfile, model: ModelProfile, snapshot: ContextSnapshot) {
        currentRun = run
        do {
            if let usage = run.usageHistory.last {
                let store = cacheStore(for: run.workspaceID)
                let record = cacheEngine.makeRecord(provider: profile, model: model, snapshot: snapshot, usage: usage, previous: try store.list(workspaceID: nil).first)
                try store.save(record)
                cacheHistory = try store.list(workspaceID: nil)
                cacheRecord = cacheHistory.first
            }
            refreshWorkspaceState()
        } catch {
            present(error)
        }
    }

    private func makeAgentLoop(for workspace: Workspace) throws -> AgentLoop {
        let patchStore = patchStore(for: workspace.id)
        let runStore = FileAgentRunStore(storageURL: workspaceManager.mobiledevURL(for: workspace.id).appendingPathComponent("agent_runs.json"))
        let fs = try workspaceManager.workspaceFS(for: workspace)
        let executor = ToolExecutor(workspaceFS: fs, contextEngine: contextEngine, patchStore: patchStore)
        return AgentLoop(client: aiClient, patchStore: patchStore, runStore: runStore, toolExecutor: executor, permissionManager: permissionManager)
    }

    private func makePatchReviewService(for workspaceID: UUID) -> PatchReviewService {
        PatchReviewService(
            patchStore: patchStore(for: workspaceID),
            workspaceManager: workspaceManager,
            permissionManager: permissionManager,
            snapshotStore: snapshotStore(for: workspaceID)
        )
    }

    private func makeContextRequest(for workspace: Workspace) -> ContextBuildRequest {
        ContextBuildRequest(
            systemPrompt: "Safe local-first iOS workspace assistant. Follow the stable prefix blocks and always use patch review.",
            toolSchemaText: SupportedTools.schemas.sorted(by: { $0.name < $1.name }).map { "\($0.name): \($0.description)" }.joined(separator: "\n"),
            permissionRules: makePermissionRules(),
            projectRules: "Only edit files inside workspace/files. Never access Keychain, API keys, or workspace-external paths. Protected paths and GitHub operations require confirmation.",
            dependencySummary: "SwiftUI App shell + LocalAIWorkspace core services + GitHub sync/actions + context/cache + patch review.",
            aiMemory: "Use ask_question for ambiguity and propose_patch for every mutation.",
            currentTask: chatInput,
            openedFiles: currentOpenedFiles(),
            relatedSnippets: contentSearchResults,
            currentDiff: patchQueue.first?.changes.map { $0.diff ?? $0.newContent ?? "" }.joined(separator: "\n\n") ?? "",
            ciLogs: githubStatusMessage ?? "",
            userRequirements: chatInput
        )
    }

    private func makePermissionRules() -> String {
        PermissionManager.defaultPolicies.values.sorted(by: { $0.toolName < $1.toolName }).map { "\($0.toolName): \($0.permission.rawValue)" }.joined(separator: "\n")
    }

    private func buildAndPersistContextSnapshot(for workspace: Workspace) throws -> ContextSnapshot {
        let fs = try workspaceManager.workspaceFS(for: workspace)
        let request = makeContextRequest(for: workspace)
        let snapshot = try contextEngine.buildContext(using: request, workspaceFS: fs)
        let url = workspaceManager.mobiledevURL(for: workspace.id).appendingPathComponent("context/latest_snapshot.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(snapshot).write(to: url, options: .atomic)
        return snapshot
    }

    private func currentOpenedFiles() -> [ReadFileResult] {
        guard let path = selectedFilePath else { return [] }
        return [ReadFileResult(path: path, content: editorText, hash: StableHasher.fnv1a64(string: editorText))]
    }

    private func apiKeyForProfile(_ profile: ProviderProfile, override: String? = nil) throws -> String? {
        if let override, override.isEmpty == false { return override }
        guard let reference = profile.apiKeyReference else { return nil }
        return try secretStore.read(service: "LocalAIWorkspace.provider", account: reference)
    }

    private func updateFileSystem(_ operation: (WorkspaceFS) throws -> Void) {
        guard let workspace = selectedWorkspace else { return }
        do {
            let fs = try workspaceManager.workspaceFS(for: workspace)
            try operation(fs)
            refreshWorkspaceState()
        } catch {
            present(error)
        }
    }

    private func patchStore(for workspaceID: UUID) -> FilePatchStore {
        FilePatchStore(storageURL: workspaceManager.mobiledevURL(for: workspaceID).appendingPathComponent("patches.json"))
    }

    private func cacheStore(for workspaceID: UUID) -> FileCacheRecordStore {
        FileCacheRecordStore(storageURL: workspaceManager.mobiledevURL(for: workspaceID).appendingPathComponent("cache_records.json"))
    }

    private func snapshotStore(for workspaceID: UUID) -> FileSnapshotStore {
        FileSnapshotStore(storageURL: workspaceManager.mobiledevURL(for: workspaceID).appendingPathComponent("snapshots.json"))
    }

    private func auditStore(for workspaceID: UUID) -> FileAuditLogStore {
        FileAuditLogStore(storageURL: workspaceManager.mobiledevURL(for: workspaceID).appendingPathComponent("logs/audit.jsonl"))
    }

    private func parseInputs(_ raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object.reduce(into: [:]) { partial, item in
            partial[item.key] = String(describing: item.value)
        }
    }

    private func loadProfiles() {
        do {
            guard FileManager.default.fileExists(atPath: profilesURL.path) else {
                providerProfiles = []
                return
            }
            providerProfiles = try JSONDecoder().decode([ProviderProfile].self, from: Data(contentsOf: profilesURL))
        } catch {
            present(error)
        }
    }

    private func persistProfiles() throws {
        try FileManager.default.createDirectory(at: profilesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(providerProfiles)
        try data.write(to: profilesURL, options: .atomic)
    }

    private func log(action: String, workspaceID: UUID?, metadata: [String: JSONValue]) throws {
        guard let workspaceID else { return }
        try auditStore(for: workspaceID).append(AuditLogEntry(action: action, metadata: metadata))
        auditEntries = try auditStore(for: workspaceID).recent(limit: 100)
    }

    private func present(_ error: Error) {
        lastErrorMessage = error.localizedDescription
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case projects
    case workspace
    case chat
    case patches
    case context
    case cache
    case github
    case settings
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projects: "Projects"
        case .workspace: "Workspace"
        case .chat: "Chat"
        case .patches: "Patch Review"
        case .context: "Context"
        case .cache: "Cache"
        case .github: "GitHub"
        case .settings: "Settings"
        case .logs: "Logs"
        }
    }

    var systemImage: String {
        switch self {
        case .projects: "folder"
        case .workspace: "doc.text"
        case .chat: "bubble.left.and.bubble.right"
        case .patches: "square.and.pencil"
        case .context: "text.redaction"
        case .cache: "speedometer"
        case .github: "arrow.triangle.branch"
        case .settings: "gearshape"
        case .logs: "list.bullet.rectangle"
        }
    }
}
