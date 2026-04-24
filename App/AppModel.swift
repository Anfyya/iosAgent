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
    @Published var editorText = ""
    @Published var hasUnsavedChanges = false
    @Published var contentSearchResults: [SearchMatch] = []
    @Published var patchQueue: [PatchProposal] = []
    @Published var currentRun: AgentRun?
    @Published var currentContextSnapshot: ContextSnapshot?
    @Published var cacheRecord: CacheRecord?
    @Published var lastConnectionStatus: String?
    @Published var lastErrorMessage: String?
    @Published var chatInput = ""
    @Published var questionAnswer = ""
    @Published var fileSearchQuery = ""
    @Published var contentSearchQuery = ""
    @Published var pendingDeletePath: String?
    @Published var pendingRenamePath: String?

    private let workspaceManager: WorkspaceManager
    private let secretStore: any SecretStore
    private let aiClient: DefaultAIClient
    private let contextEngine = ContextEngine()
    private let cacheEngine = CacheEngine()
    private let permissionManager = PermissionManager(globalMode: .semiAuto)
    private let profilesURL: URL

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    init() {
        do {
            workspaceManager = try WorkspaceManager()
            profilesURL = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("ProviderProfiles/profiles.json") ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("profiles.json")
        } catch {
            fatalError("Failed to initialize WorkspaceManager: \(error.localizedDescription)")
        }
        secretStore = KeychainSecretStore()
        aiClient = DefaultAIClient()
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
        do {
            let workspace = try workspaceManager.createWorkspace(name: name)
            reloadWorkspaces(select: workspace.id)
        } catch {
            present(error)
        }
    }

    func renameWorkspace(_ workspace: Workspace, to name: String) {
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
            currentContextSnapshot = nil
            cacheRecord = nil
            return
        }
        do {
            let current = try workspaceManager.openWorkspace(id: workspace.id)
            if let index = workspaces.firstIndex(where: { $0.id == current.id }) {
                workspaces[index] = current
            }
            let fs = try workspaceManager.workspaceFS(for: current)
            workspaceFiles = try fs.listFiles()
            patchQueue = try FilePatchStore(storageURL: workspaceManager.mobiledevURL(for: current.id).appendingPathComponent("patches.json")).list(workspaceID: current.id)
            cacheRecord = try FileCacheRecordStore(storageURL: workspaceManager.mobiledevURL(for: current.id).appendingPathComponent("cache_records.json")).list(workspaceID: nil).first
            currentContextSnapshot = try contextEngine.buildContext(using: makeContextRequest(), workspaceFS: fs)
            if let path = selectedFilePath {
                try openFile(path)
            }
        } catch {
            present(error)
        }
    }

    func createFile(at path: String, contents: String = "") {
        updateFileSystem { fs in
            try fs.writeTextFile(path: path, content: contents)
        }
    }

    func createFolder(at path: String) {
        updateFileSystem { fs in
            let url = try fs.safeURL(for: path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
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
    }

    func renameSelectedPath(to destination: String) {
        guard let source = pendingRenamePath else { return }
        updateFileSystem { fs in
            try fs.moveItem(from: source, to: destination)
        }
        pendingRenamePath = nil
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
            if let apiKey, !apiKey.isEmpty {
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
            _ = try await aiClient.complete(profile: profile, apiKey: key, request: request)
            lastConnectionStatus = "Connection succeeded"
        } catch {
            present(error)
            lastConnectionStatus = "Connection failed: \(error.localizedDescription)"
        }
    }

    func startChat() async {
        guard let workspace = selectedWorkspace else {
            lastErrorMessage = "Select a workspace first."
            return
        }
        guard let profile = activeProvider else {
            lastErrorMessage = "Select a provider profile first."
            return
        }
        do {
            let fs = try workspaceManager.workspaceFS(for: workspace)
            let context = try contextEngine.buildContext(using: makeContextRequest(), workspaceFS: fs)
            currentContextSnapshot = context
            let loop = try makeAgentLoop(for: workspace)
            let run = try await loop.start(
                workspaceID: workspace.id,
                profile: profile,
                apiKey: try apiKeyForProfile(profile),
                modelID: profile.modelProfiles.first?.id ?? "",
                systemPrompt: "You are helping edit the current workspace safely via tools and patch review.",
                userTask: chatInput,
                contextRequest: makeContextRequest()
            )
            handle(run: run, profile: profile, snapshot: context)
        } catch {
            present(error)
        }
    }

    func answerQuestion() async {
        guard let run = currentRun, let profile = activeProvider, let workspace = selectedWorkspace else { return }
        do {
            let fs = try workspaceManager.workspaceFS(for: workspace)
            let snapshot = try contextEngine.buildContext(using: makeContextRequest(), workspaceFS: fs)
            let loop = try makeAgentLoop(for: workspace)
            let updated = try await loop.resume(runID: run.id, answer: questionAnswer, profile: profile, apiKey: try apiKeyForProfile(profile), contextRequest: makeContextRequest())
            questionAnswer = ""
            handle(run: updated, profile: profile, snapshot: snapshot)
        } catch {
            present(error)
        }
    }

    func resumePermission(approved: Bool) async {
        guard let run = currentRun, let profile = activeProvider, let workspace = selectedWorkspace else { return }
        do {
            let fs = try workspaceManager.workspaceFS(for: workspace)
            let snapshot = try contextEngine.buildContext(using: makeContextRequest(), workspaceFS: fs)
            let loop = try makeAgentLoop(for: workspace)
            let updated = try await loop.resumePermission(runID: run.id, approved: approved, profile: profile, apiKey: try apiKeyForProfile(profile), contextRequest: makeContextRequest())
            handle(run: updated, profile: profile, snapshot: snapshot)
        } catch {
            present(error)
        }
    }

    func applyPatch(_ proposal: PatchProposal, confirmedByUser: Bool = true) {
        guard let workspace = selectedWorkspace else { return }
        do {
            let service = PatchReviewService(
                patchStore: FilePatchStore(storageURL: workspaceManager.mobiledevURL(for: workspace.id).appendingPathComponent("patches.json")),
                workspaceManager: workspaceManager,
                permissionManager: permissionManager
            )
            _ = try service.apply(proposalID: proposal.id, confirmedByUser: confirmedByUser)
            refreshWorkspaceState()
        } catch {
            present(error)
        }
    }

    func rejectPatch(_ proposal: PatchProposal) {
        guard let workspace = selectedWorkspace else { return }
        do {
            let service = PatchReviewService(
                patchStore: FilePatchStore(storageURL: workspaceManager.mobiledevURL(for: workspace.id).appendingPathComponent("patches.json")),
                workspaceManager: workspaceManager,
                permissionManager: permissionManager
            )
            _ = try service.reject(proposalID: proposal.id)
            refreshWorkspaceState()
        } catch {
            present(error)
        }
    }

    var activeProvider: ProviderProfile? {
        guard let id = selectedWorkspace?.activeProviderProfileID else { return providerProfiles.first }
        return providerProfiles.first { $0.id == id } ?? providerProfiles.first
    }

    var filteredWorkspaceFiles: [WorkspaceFileEntry] {
        guard !fileSearchQuery.isEmpty else { return workspaceFiles }
        return workspaceFiles.filter { $0.path.localizedCaseInsensitiveContains(fileSearchQuery) }
    }

    private func handle(run: AgentRun, profile: ProviderProfile, snapshot: ContextSnapshot) {
        currentRun = run
        do {
            if let usage = run.usageHistory.last, let model = profile.modelProfiles.first(where: { $0.id == run.modelID }) {
                let store = FileCacheRecordStore(storageURL: workspaceManager.mobiledevURL(for: run.workspaceID).appendingPathComponent("cache_records.json"))
                let record = cacheEngine.makeRecord(provider: profile, model: model, snapshot: snapshot, usage: usage, previous: try store.list(workspaceID: nil).first)
                try store.save(record)
                cacheRecord = record
            }
            refreshWorkspaceState()
        } catch {
            present(error)
        }
    }

    private func makeAgentLoop(for workspace: Workspace) throws -> AgentLoop {
        let patchStore = FilePatchStore(storageURL: workspaceManager.mobiledevURL(for: workspace.id).appendingPathComponent("patches.json"))
        let runStore = FileAgentRunStore(storageURL: workspaceManager.mobiledevURL(for: workspace.id).appendingPathComponent("agent_runs.json"))
        let fs = try workspaceManager.workspaceFS(for: workspace)
        let executor = ToolExecutor(workspaceFS: fs, contextEngine: contextEngine, patchStore: patchStore)
        return AgentLoop(client: aiClient, patchStore: patchStore, runStore: runStore, toolExecutor: executor, permissionManager: permissionManager)
    }

    private func makeContextRequest() -> ContextBuildRequest {
        ContextBuildRequest(
            systemPrompt: "Safe local-first iOS workspace assistant.",
            toolSchemaText: SupportedTools.schemas.map(\.name).joined(separator: "\n"),
            permissionRules: "Read-only tools are automatic. Mutations require review or explicit permission.",
            projectRules: "Only edit files inside workspace/files. Never access Keychain or .mobiledev.",
            dependencySummary: "SwiftUI app shell + LocalAIWorkspace core services.",
            aiMemory: "Prefer patch proposals over direct mutation.",
            currentTask: chatInput,
            openedFiles: [],
            relatedSnippets: contentSearchResults,
            currentDiff: patchQueue.first?.changes.first?.diff ?? "",
            ciLogs: "",
            userRequirements: chatInput
        )
    }

    private func apiKeyForProfile(_ profile: ProviderProfile, override: String? = nil) throws -> String? {
        if let override, !override.isEmpty { return override }
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
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projects: "Projects"
        case .workspace: "Workspace"
        case .chat: "Chat"
        case .patches: "Patch Review"
        case .context: "Context"
        case .cache: "Cache"
        case .settings: "Settings"
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
        case .settings: "gearshape"
        }
    }
}
