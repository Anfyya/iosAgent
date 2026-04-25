import LocalAIWorkspace
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var providerProfiles: [ProviderProfile] = []
    @Published var appPreferences = AppPreferences()
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
    @Published var selectedReasoningEffort: ReasoningEffortPreset = .high
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
    @Published var commitMessage = "通过本地工程助手更新"
    @Published var pullRequestTitle = ""
    @Published var pullRequestBody = ""
    @Published var pullRequestHeadBranch = ""
    @Published var pullRequestBaseBranch = ""
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
    private let promptBuilder = PromptBuilder()
    private let profilesURL: URL
    private let preferencesURL: URL
    private let workspaceImportService: WorkspaceImportService
    private let buildConfigLoader: BuildConfigLoader
    private let githubSyncService: GitHubSyncService
    private let gitHubProjectImportService: GitHubProjectImportService
    private var lastLoadedWorkspaceID: UUID?

    private var permissionManager: PermissionManager {
        PermissionManager(
            globalMode: appPreferences.permissionMode.globalPermissionMode,
            toolPolicies: appPreferences.permissionMode.toolPolicies
        )
    }

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    var activeProvider: ProviderProfile? {
        guard let id = appPreferences.selectedProviderID else { return providerProfiles.first }
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
        let startupErrorMessage: String?
        do {
            self.workspaceManager = try workspaceManager ?? WorkspaceManager()
            startupErrorMessage = nil
            let documentsURL = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("LocalAIWorkspace", isDirectory: true) ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LocalAIWorkspace", isDirectory: true)
            profilesURL = documentsURL.appendingPathComponent("ProviderProfiles/profiles.json")
            preferencesURL = documentsURL.appendingPathComponent("Preferences/app_preferences.json")
        } catch {
            startupErrorMessage = "初始化项目目录失败，已切换到临时目录：\(error.localizedDescription)"
            let fallbackWorkspaceManager = try? WorkspaceManager(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent("LocalAIWorkspaceFallback", isDirectory: true))
            guard let fallbackWorkspaceManager else {
                fatalError("初始化项目目录失败：\(error.localizedDescription)")
            }
            self.workspaceManager = fallbackWorkspaceManager
            let documentsURL = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAIWorkspace", isDirectory: true)
            profilesURL = documentsURL.appendingPathComponent("ProviderProfiles/profiles.json")
            preferencesURL = documentsURL.appendingPathComponent("Preferences/app_preferences.json")
        }
        self.secretStore = secretStore
        self.aiClient = aiClient
        workspaceImportService = WorkspaceImportService(workspaceManager: self.workspaceManager)
        buildConfigLoader = BuildConfigLoader(workspaceManager: self.workspaceManager)
        githubSyncService = GitHubSyncService(workspaceManager: self.workspaceManager, secretStore: secretStore)
        gitHubProjectImportService = GitHubProjectImportService(
            workspaceManager: self.workspaceManager,
            workspaceImportService: workspaceImportService
        )
        loadPreferences()
        loadProfiles()
        normalizeSelectedProvider()
        selectedReasoningEffort = appPreferences.defaultReasoningEffort
        reloadWorkspaces()
        if let startupErrorMessage {
            lastErrorMessage = startupErrorMessage
        }
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
            lastErrorMessage = "项目名称不能为空。"
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
            lastErrorMessage = "项目名称不能为空。"
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
            githubRepository = nil
            githubWorkflows = []
            workflowRuns = []
            workflowJobs = []
            workflowArtifacts = []
            commitSummary = nil
            currentRun = nil
            auditEntries = []
            buildConfiguration = nil
            lastLoadedWorkspaceID = nil
            resetTransientProjectState()
            return
        }
        do {
            let current = try workspaceManager.openWorkspace(id: workspace.id)
            let switchedWorkspace = lastLoadedWorkspaceID != current.id
            lastLoadedWorkspaceID = current.id
            if switchedWorkspace {
                resetTransientProjectState()
            }
            githubRepository = nil
            githubWorkflows = []
            workflowRuns = []
            workflowJobs = []
            workflowArtifacts = []
            commitSummary = nil
            if currentRun?.workspaceID != current.id {
                currentRun = nil
            }
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
                pullRequestHeadBranch = remote.branch
                selectedWorkflowRef = remote.branch
            } else {
                remoteOwner = ""
                remoteRepo = ""
                remoteBranch = "main"
                pullRequestHeadBranch = ""
                pullRequestBaseBranch = ""
                selectedWorkflowRef = ""
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
            importStatusMessage = "已导入 \(result.importedCount) 个文件。\(result.warnings.joined(separator: " "))"
            refreshWorkspaceState()
            try log(action: isZip ? "zip_imported" : "files_imported", workspaceID: workspace.id, metadata: ["count": .integer(result.importedCount)])
        } catch {
            present(error)
        }
    }

    func importProjectFromGitHub(_ repositoryURLString: String) async {
        do {
            let workspace = try await gitHubProjectImportService.importProject(from: repositoryURLString)
            reloadWorkspaces(select: workspace.id)
            try log(action: "github_project_imported", workspaceID: workspace.id, metadata: ["url": .string(repositoryURLString)])
        } catch {
            present(error)
        }
    }

    func createFile(at path: String, contents: String = "") {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            lastErrorMessage = "新文件路径不能为空。"
            return
        }
        if updateFileSystem({ fs in
            try fs.writeTextFile(path: trimmed, content: contents)
        }) {
            try? log(action: "file_created", workspaceID: selectedWorkspace?.id, metadata: ["path": .string(trimmed)])
        }
    }

    func createFolder(at path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            lastErrorMessage = "新文件夹路径不能为空。"
            return
        }
        if updateFileSystem({ fs in
            let url = try fs.safeURL(for: trimmed)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }) {
            try? log(action: "folder_created", workspaceID: selectedWorkspace?.id, metadata: ["path": .string(trimmed)])
        }
    }

    func requestOpenFile(_ path: String) {
        guard hasUnsavedChanges, selectedFilePath != path else {
            do {
                try openFile(path)
            } catch {
                present(error)
            }
            return
        }
        pendingOpenFilePath = path
    }

    func resolvePendingFileOpen(saveChanges: Bool) {
        if saveChanges, saveSelectedFile() == false {
            return
        }
        if let path = pendingOpenFilePath {
            do {
                try openFile(path)
            } catch {
                present(error)
                return
            }
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

    @discardableResult
    func saveSelectedFile() -> Bool {
        guard let path = selectedFilePath else { return false }
        let didSave = updateFileSystem { fs in
            try fs.writeTextFile(path: path, content: editorText)
        }
        if didSave {
            hasUnsavedChanges = false
            try? log(action: "file_saved", workspaceID: selectedWorkspace?.id, metadata: ["path": .string(path)])
        }
        return didSave
    }

    func renameSelectedPath(to destination: String) {
        guard let source = pendingRenamePath else { return }
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            lastErrorMessage = "重命名路径不能为空。"
            return
        }
        if updateFileSystem({ fs in
            try fs.moveItem(from: source, to: trimmed)
        }) {
            pendingRenamePath = nil
            try? log(action: "file_renamed", workspaceID: selectedWorkspace?.id, metadata: ["from": .string(source), "to": .string(trimmed)])
        }
    }

    func deletePendingPath() {
        guard let path = pendingDeletePath else { return }
        if updateFileSystem({ fs in
            try fs.deleteItem(path: path)
        }) {
            if selectedFilePath == path {
                selectedFilePath = nil
                editorText = ""
                hasUnsavedChanges = false
            }
            pendingDeletePath = nil
            try? log(action: "file_deleted", workspaceID: selectedWorkspace?.id, metadata: ["path": .string(path)])
        }
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
            if appPreferences.selectedProviderID == nil || appPreferences.selectedProviderID == mutable.id {
                appPreferences.selectedProviderID = mutable.id
                try persistPreferences()
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
            if providerProfiles.isEmpty {
                providerProfiles = BuiltInModelProfiles.deepSeekDefaults()
            }
            try persistProfiles()
            if appPreferences.selectedProviderID == profile.id {
                appPreferences.selectedProviderID = providerProfiles.first?.id
                try persistPreferences()
                lastConnectionStatus = providerProfiles.first.map { "当前模型已删除，已切换到 \($0.name)。" }
            }
        } catch {
            present(error)
        }
    }

    func assignProvider(_ profileID: String?) {
        do {
            appPreferences.selectedProviderID = profileID
            try persistPreferences()
            objectWillChange.send()
        } catch {
            present(error)
        }
    }

    func setPermissionMode(_ mode: ModelPermissionMode) {
        do {
            appPreferences.permissionMode = mode
            try persistPreferences()
            objectWillChange.send()
        } catch {
            present(error)
        }
    }

    func setReasoningEffort(_ effort: ReasoningEffortPreset) {
        do {
            selectedReasoningEffort = effort
            appPreferences.defaultReasoningEffort = effort
            try persistPreferences()
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
            lastConnectionStatus = "连接成功 · 模型=\(modelID) · 用量/延迟=\(usageSummary.isEmpty ? "无" : usageSummary)"
            try log(action: "provider_tested", workspaceID: selectedWorkspace?.id, metadata: ["provider": .string(profile.name), "success": .bool(true)])
        } catch {
            present(error)
            lastConnectionStatus = "连接失败：\(error.localizedDescription)"
            try? log(action: "provider_tested", workspaceID: selectedWorkspace?.id, metadata: ["provider": .string(profile.name), "success": .bool(false)])
        }
    }

    func startChat() async {
        guard let workspace = selectedWorkspace else {
            lastErrorMessage = "请先选择项目。"
            return
        }
        guard let profile = activeProvider, let model = activeModel else {
            lastErrorMessage = "请先选择模型服务配置。"
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
                contextRequest: makeContextRequest(for: workspace),
                requestOptions: agentRequestOptions(for: model)
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
            let updated = try await loop.resume(
                runID: run.id,
                answer: questionAnswer,
                profile: profile,
                apiKey: try apiKeyForProfile(profile),
                contextRequest: makeContextRequest(for: workspace),
                requestOptions: activeModel.map(agentRequestOptions(for:)) ?? AgentRequestOptions()
            )
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
            let updated = try await loop.resumePermission(
                runID: run.id,
                approved: approved,
                profile: profile,
                apiKey: try apiKeyForProfile(profile),
                contextRequest: makeContextRequest(for: workspace),
                requestOptions: activeModel.map(agentRequestOptions(for:)) ?? AgentRequestOptions()
            )
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
        chatInput = "修改补丁 \(proposal.title)。要求：\(instruction)\n\n当前补丁 diff：\n\(diff)"
        selectedTab = .chat
        try? log(action: "patch_revise_requested", workspaceID: selectedWorkspace?.id, metadata: ["patch": .string(proposal.id.uuidString)])
    }

    func linkGitHubRepository() async {
        guard let workspace = selectedWorkspace else { return }
        do {
            let remote = try await githubSyncService.linkRepository(workspaceID: workspace.id, owner: remoteOwner, repo: remoteRepo, branch: remoteBranch, token: remoteToken)
            githubRemoteConfig = remote
            pullRequestHeadBranch = remote.branch
            githubStatusMessage = "已关联 \(remote.owner)/\(remote.repo)@\(remote.branch)"
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
            if pullRequestBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pullRequestBaseBranch = githubRepository?.defaultBranch ?? "main"
            }
            if selectedWorkflowIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selectedWorkflowIdentifier = githubWorkflows.first?.path ?? ""
            }
            workflowRuns = try await githubSyncService.listWorkflowRuns(workspaceID: workspace.id)
            if let run = workflowRuns.first {
                workflowJobs = try await githubSyncService.listJobsForRun(workspaceID: workspace.id, runID: run.id)
                workflowArtifacts = try await githubSyncService.listArtifactsForRun(workspaceID: workspace.id, runID: run.id)
            } else {
                workflowJobs = []
                workflowArtifacts = []
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
            githubStatusMessage = "已推送提交 \(commitSummary?.headSHA ?? "")"
            try log(action: "github_push", workspaceID: workspace.id, metadata: ["sha": .string(commitSummary?.headSHA ?? "")])
            refreshWorkspaceState()
        } catch {
            present(error)
        }
    }

    func previewCommit() async {
        guard let workspace = selectedWorkspace else { return }
        do {
            commitSummary = try await githubSyncService.previewWorkspaceChanges(workspaceID: workspace.id)
            githubStatusMessage = "预览完成：\(commitSummary?.changedFiles.count ?? 0) 个文件可提交，\(commitSummary?.skippedFiles.count ?? 0) 个文件会跳过。不会创建 GitHub 提交。"
        } catch {
            present(error)
        }
    }

    func createPullRequest() async {
        guard let workspace = selectedWorkspace, let remote = githubRemoteConfig else { return }
        let normalizedTitle = pullRequestTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTitle.isEmpty == false else {
            lastErrorMessage = "拉取请求标题不能为空。"
            return
        }
        do {
            let headBranch = pullRequestHeadBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? remote.branch : pullRequestHeadBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseBranch = pullRequestBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (githubRepository?.defaultBranch ?? "main") : pullRequestBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = try await githubSyncService.createPullRequest(workspaceID: workspace.id, title: normalizedTitle, body: pullRequestBody, head: headBranch, base: baseBranch)
            githubStatusMessage = "拉取请求已创建：\(url)"
            try log(action: "pull_request_created", workspaceID: workspace.id, metadata: ["url": .string(url)])
        } catch {
            present(error)
        }
    }

    func dispatchWorkflow(build: BuildDefinition? = nil) async {
        guard let workspace = selectedWorkspace else { return }
        let workflow = build?.workflow ?? selectedWorkflowIdentifier
        guard workflow.isEmpty == false else {
            lastErrorMessage = "请先选择工作流。"
            return
        }
        do {
            let inputs = try parseInputs(workflowInputsText)
            let ref = build?.ref ?? (selectedWorkflowRef.isEmpty ? (githubRemoteConfig?.branch ?? "main") : selectedWorkflowRef)
            let dispatchInputs = (build?.inputs.isEmpty == false) ? (build?.inputs ?? [:]) : inputs
            try await githubSyncService.dispatchWorkflow(workspaceID: workspace.id, workflowIDOrFileName: workflow, ref: ref, inputs: dispatchInputs)
            githubStatusMessage = "工作流已触发：\(workflow)"
            try log(action: "workflow_dispatched", workspaceID: workspace.id, metadata: ["workflow": .string(workflow), "ref": .string(ref)])
            await refreshGitHubData()
        } catch {
            present(error)
        }
    }

    func downloadArtifact(_ artifact: GitHubArtifact) async {
        guard let workspace = selectedWorkspace else { return }
        do {
            let fileURL = try await githubSyncService.downloadArtifact(workspaceID: workspace.id, artifactID: artifact.id)
            githubStatusMessage = "产物已下载到 \(fileURL.path)"
            try log(action: "artifact_downloaded", workspaceID: workspace.id, metadata: ["artifact": .string(artifact.name), "path": .string(fileURL.path)])
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
            try autoApplyPendingPatches(for: run)
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
            systemPrompt: "安全的本地优先 iOS 项目助手。遵循稳定前缀块，并且只允许修改当前项目内的文件。",
            toolSchemaText: SupportedTools.schemas.sorted(by: { $0.name < $1.name }).map { "\($0.name): \($0.description)" }.joined(separator: "\n"),
            permissionRules: makePermissionRules(),
            projectRules: "只允许编辑当前项目目录内的文件。不要访问 Keychain、API Key 或项目外部路径。项目外文件永远不能修改。",
            dependencySummary: "SwiftUI App 壳 + LocalAIWorkspace 核心服务 + GitHub 同步/Actions + 自动补丁应用权限流。",
            aiMemory: "需求不明确时使用 ask_question；任何修改都必须使用 propose_patch，并且只能修改当前项目内文件。",
            currentTask: chatInput,
            openedFiles: currentOpenedFiles(),
            relatedSnippets: contentSearchResults,
            currentDiff: patchQueue.first?.changes.map { $0.diff ?? $0.newContent ?? "" }.joined(separator: "\n\n") ?? "",
            ciLogs: githubStatusMessage ?? "",
            userRequirements: chatInput
        )
    }

    private func makePermissionRules() -> String {
        permissionManager.toolPolicies.values
            .sorted(by: { $0.toolName < $1.toolName })
            .map { "\($0.toolName): \($0.permission.rawValue)" }
            .joined(separator: "\n")
    }

    private func agentRequestOptions(for model: ModelProfile) -> AgentRequestOptions {
        AgentRequestOptions(
            toolChoice: "auto",
            reasoning: model.supportsReasoning ? ReasoningConfiguration(enabled: true, level: selectedReasoningEffort.rawValue) : nil,
            maxTokens: nil,
            extraParameters: model.extraParameters
        )
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

    @discardableResult
    private func updateFileSystem(_ operation: (WorkspaceFS) throws -> Void) -> Bool {
        guard let workspace = selectedWorkspace else { return false }
        do {
            let fs = try workspaceManager.workspaceFS(for: workspace)
            try operation(fs)
            refreshWorkspaceState()
            return true
        } catch {
            present(error)
            return false
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

    private func parseInputs(_ raw: String) throws -> [String: String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [:] }
        guard let data = trimmed.data(using: .utf8) else {
            throw WorkflowInputParseError.invalidJSON
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw WorkflowInputParseError.topLevelMustBeObject
        }
        return try dictionary.reduce(into: [:]) { partial, item in
            switch item.value {
            case let value as String:
                partial[item.key] = value
            case let value as Bool:
                partial[item.key] = value ? "true" : "false"
            case let value as NSNumber:
                partial[item.key] = value.stringValue
            case _ as NSNull:
                partial[item.key] = ""
            default:
                throw WorkflowInputParseError.unsupportedValue(item.key)
            }
        }
    }

    private func resetTransientProjectState() {
        importStatusMessage = nil
        githubStatusMessage = nil
        commitSummary = nil
        pullRequestTitle = ""
        pullRequestBody = ""
        pullRequestHeadBranch = ""
        pullRequestBaseBranch = ""
        selectedWorkflowIdentifier = ""
        selectedWorkflowRef = ""
        workflowInputsText = "{}"
        questionAnswer = ""
    }

    private func loadProfiles() {
        do {
            guard FileManager.default.fileExists(atPath: profilesURL.path) else {
                providerProfiles = BuiltInModelProfiles.deepSeekDefaults()
                try persistProfiles()
                return
            }
            providerProfiles = try JSONDecoder().decode([ProviderProfile].self, from: Data(contentsOf: profilesURL))
        } catch {
            present(error)
        }
    }

    private func loadPreferences() {
        do {
            guard FileManager.default.fileExists(atPath: preferencesURL.path) else {
                appPreferences = AppPreferences()
                return
            }
            appPreferences = try JSONDecoder().decode(AppPreferences.self, from: Data(contentsOf: preferencesURL))
        } catch {
            present(error)
        }
    }

    private func persistProfiles() throws {
        try FileManager.default.createDirectory(at: profilesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(providerProfiles)
        try data.write(to: profilesURL, options: .atomic)
    }

    private func persistPreferences() throws {
        try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(appPreferences)
        try data.write(to: preferencesURL, options: .atomic)
    }

    private func normalizeSelectedProvider() {
        guard providerProfiles.isEmpty == false else {
            appPreferences.selectedProviderID = nil
            return
        }
        if let selectedProviderID = appPreferences.selectedProviderID,
           providerProfiles.contains(where: { $0.id == selectedProviderID }) {
            return
        }
        appPreferences.selectedProviderID = providerProfiles.first?.id
        try? persistPreferences()
    }

    private func autoApplyPendingPatches(for run: AgentRun) throws {
        let proposals = try patchStore(for: run.workspaceID)
            .list(workspaceID: run.workspaceID)
            .filter {
                $0.agentRunID == run.id && $0.status == .pendingReview
            }
        guard proposals.isEmpty == false else { return }
        for proposal in proposals {
            applyPatch(
                proposal,
                confirmedByUser: appPreferences.permissionMode == .readOnly
            )
        }
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

private enum WorkflowInputParseError: LocalizedError {
    case invalidJSON
    case topLevelMustBeObject
    case unsupportedValue(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "工作流输入必须是合法 JSON。"
        case .topLevelMustBeObject:
            return "工作流输入必须是 JSON 对象，例如 {\"platform\":\"ios\"}。"
        case let .unsupportedValue(key):
            return "工作流输入字段 \(key) 只支持字符串、数字、布尔值或 null。"
        }
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
        case .projects: "项目"
        case .workspace: "项目"
        case .chat: "对话"
        case .patches: "补丁审核"
        case .context: "上下文"
        case .cache: "缓存"
        case .github: "GitHub"
        case .settings: "设置"
        case .logs: "日志"
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
