import LocalAIWorkspace
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var newWorkspaceName = ""
    @State private var showCreateProjectSheet = false
    @State private var showGitHubProjectSheet = false
    @State private var gitHubProjectURL = ""
    @State private var showProviderEditor = false
    @State private var editingProvider: ProviderProfile?
    @State private var providerAPIKey = ""
    @State private var renameWorkspace: Workspace?
    @State private var renameWorkspaceName = ""
    @State private var pendingDeleteProject: Workspace?
    @State private var newItemPath = ""
    @State private var newFolderPath = ""
    @State private var showNewFileSheet = false
    @State private var showNewFolderSheet = false
    @State private var renamePathValue = ""
    @State private var showFileImporter = false
    @State private var showZipImporter = false
    @State private var showChatHistorySheet = false
    @State private var pushProtectedBranch = false
    @FocusState private var isChatComposerFocused: Bool

    var body: some View {
        TabView(selection: $model.selectedTab) {
            projectsView
                .tabItem { Label(AppTab.projects.title, systemImage: AppTab.projects.systemImage) }
                .tag(AppTab.projects)
            chatView
                .tabItem { Label(AppTab.chat.title, systemImage: AppTab.chat.systemImage) }
                .tag(AppTab.chat)
            githubView
                .tabItem { Label(AppTab.github.title, systemImage: AppTab.github.systemImage) }
                .tag(AppTab.github)
            settingsView
                .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage) }
                .tag(AppTab.settings)
        }
        .alert("错误", isPresented: .constant(model.lastErrorMessage != nil), actions: {
            Button("确定") { model.lastErrorMessage = nil }
        }, message: {
            Text(model.lastErrorMessage ?? "")
        })
        .sheet(isPresented: $showProviderEditor) {
            SimpleModelEditorSheet(
                profile: editingProvider,
                apiKey: providerAPIKey,
                defaultReasoningEffort: model.selectedReasoningEffort,
                onSave: { profile, apiKey, reasoningEffort in
                    model.setReasoningEffort(reasoningEffort)
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
                Form { TextField("名称", text: $renameWorkspaceName) }
                    .navigationTitle("重命名项目")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { renameWorkspace = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                model.renameWorkspace(workspace, to: renameWorkspaceName)
                                renameWorkspace = nil
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showCreateProjectSheet) {
            NavigationStack {
                Form { TextField("项目名称", text: $newWorkspaceName) }
                    .navigationTitle("添加空项目")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showCreateProjectSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("创建") {
                                model.createWorkspace(named: newWorkspaceName)
                                newWorkspaceName = ""
                                showCreateProjectSheet = false
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showGitHubProjectSheet) {
            NavigationStack {
                Form {
                    TextField("GitHub 仓库 URL", text: $gitHubProjectURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("输入 github.com 仓库地址后，应用会创建本地项目并导入仓库内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .navigationTitle("从 GitHub 添加项目")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showGitHubProjectSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("导入") {
                            let url = gitHubProjectURL
                            Task { await model.importProjectFromGitHub(url) }
                            gitHubProjectURL = ""
                            showGitHubProjectSheet = false
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showNewFileSheet) {
            NavigationStack {
                Form { TextField("文件路径", text: $newItemPath) }
                    .navigationTitle("新建文件")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showNewFileSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("创建") {
                                model.createFile(at: newItemPath)
                                newItemPath = ""
                                showNewFileSheet = false
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showNewFolderSheet) {
            NavigationStack {
                Form { TextField("文件夹路径", text: $newFolderPath) }
                    .navigationTitle("新建文件夹")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showNewFolderSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("创建") {
                                model.createFolder(at: newFolderPath)
                                newFolderPath = ""
                                showNewFolderSheet = false
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
        .confirmationDialog("打开其他文件？", isPresented: .constant(model.pendingOpenFilePath != nil), actions: {
            Button("保存并打开") { model.resolvePendingFileOpen(saveChanges: true) }
            Button("放弃更改") { model.resolvePendingFileOpen(saveChanges: false) }
            Button("取消", role: .cancel) { model.pendingOpenFilePath = nil }
        }, message: {
            Text("当前文件有未保存的更改。")
        })
        .confirmationDialog("删除文件？", isPresented: .constant(model.pendingDeletePath != nil), actions: {
            Button("删除", role: .destructive) { model.deletePendingPath() }
            Button("取消", role: .cancel) { model.pendingDeletePath = nil }
        }, message: {
            Text(model.pendingDeletePath ?? "")
        })
        .confirmationDialog("删除项目？", isPresented: .constant(pendingDeleteProject != nil), actions: {
            if let project = pendingDeleteProject {
                Button("删除", role: .destructive) {
                    model.deleteWorkspace(project)
                    pendingDeleteProject = nil
                }
            }
            Button("取消", role: .cancel) { pendingDeleteProject = nil }
        }, message: {
            Text(pendingDeleteProject?.name ?? "")
        })
        .sheet(isPresented: .constant(model.pendingRenamePath != nil), onDismiss: { model.pendingRenamePath = nil }) {
            NavigationStack {
                Form { TextField("新路径", text: $renamePathValue) }
                    .navigationTitle("重命名文件")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { model.pendingRenamePath = nil } }
                        ToolbarItem(placement: .confirmationAction) { Button("保存") { model.renameSelectedPath(to: renamePathValue) } }
                    }
            }
        }
    }

    private var projectsView: some View {
        NavigationStack {
            List {
                Section("项目") {
                    if model.workspaces.isEmpty {
                        ContentUnavailableView("还没有项目", systemImage: "folder")
                    }
                    ForEach(model.workspaces) { workspace in
                        NavigationLink {
                            projectDetailView(projectID: workspace.id)
                        } label: {
                            projectRow(for: workspace)
                        }
                        .contextMenu {
                            Button("重命名项目") {
                                renameWorkspace = workspace
                                renameWorkspaceName = workspace.name
                            }
                            Button("删除项目", role: .destructive) {
                                pendingDeleteProject = workspace
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("项目")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("添加空项目") { showCreateProjectSheet = true }
                        Button("从 GitHub 添加项目") { showGitHubProjectSheet = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    private func projectRow(for workspace: Workspace) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(workspace.rootPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if model.selectedWorkspaceID == workspace.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func projectDetailView(projectID: UUID) -> some View {
        Group {
            if let project = model.workspaces.first(where: { $0.id == projectID }) {
                List {
                    Section {
                        projectOverviewRow(project)
                    }

                    if let importStatusMessage = model.importStatusMessage {
                        Section {
                            Text(importStatusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("文件") {
                        let roots = buildFileTree(from: model.workspaceFiles)
                        if roots.isEmpty {
                            ContentUnavailableView("没有文件", systemImage: "doc")
                        } else {
                            fileRows(roots)
                        }
                    }

                    Section("工作区") {
                        Button {
                            model.selectedTab = .chat
                        } label: {
                            Label("打开对话", systemImage: "bubble.left.and.bubble.right")
                        }
                        Button {
                            model.selectedTab = .github
                            Task { await model.refreshGitHubData() }
                        } label: {
                            Label("GitHub 与构建", systemImage: "arrow.triangle.branch")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle(project.name)
                .navigationBarTitleDisplayMode(.inline)
                .task(id: projectID) {
                    if model.selectedWorkspaceID != projectID {
                        model.selectedWorkspaceID = projectID
                    }
                    model.refreshWorkspaceState()
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Menu {
                            Button("新建文件") {
                                newItemPath = ""
                                showNewFileSheet = true
                            }
                            Button("新建文件夹") {
                                newFolderPath = ""
                                showNewFolderSheet = true
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        Menu {
                            Button("刷新") { model.refreshWorkspaceState() }
                            Button("导入文件") { showFileImporter = true }
                            Button("导入 ZIP") { showZipImporter = true }
                            Button("重命名项目") {
                                renameWorkspace = project
                                renameWorkspaceName = project.name
                            }
                            Button("删除项目", role: .destructive) {
                                pendingDeleteProject = project
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            } else {
                ContentUnavailableView("项目不存在", systemImage: "folder.badge.questionmark")
            }
        }
    }

    private func projectOverviewRow(_ project: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.blue)
                Text(project.name)
                    .font(.headline)
                Spacer()
            }
            Text(project.rootPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if let provider = model.activeProvider {
                    labelCapsule(title: provider.name)
                }
                if let remote = model.githubRemoteConfig {
                    labelCapsule(title: "\(remote.owner)/\(remote.repo)@\(remote.branch)")
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func fileRows(_ nodes: [FileTreeNode]) -> some View {
        ForEach(nodes) { node in
            repositoryNodeRow(node)
        }
    }

    @ViewBuilder
    private func repositoryNodeRow(_ node: FileTreeNode) -> some View {
        if node.isDirectory {
            NavigationLink {
                directoryView(node)
            } label: {
                repositoryRowContent(node)
            }
            .contextMenu {
                fileContextMenu(for: node)
            }
        } else {
            NavigationLink {
                fileEditorView(path: node.path)
            } label: {
                repositoryRowContent(node)
            }
            .contextMenu {
                Button("打开") { model.requestOpenFile(node.path) }
                fileContextMenu(for: node)
            }
        }
    }

    private func directoryView(_ node: FileTreeNode) -> some View {
        List {
            Section(node.path) {
                if node.children.isEmpty {
                    ContentUnavailableView("空文件夹", systemImage: "folder")
                } else {
                    fileRows(node.children)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(node.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("新建文件") {
                        newItemPath = node.path + "/"
                        showNewFileSheet = true
                    }
                    Button("新建文件夹") {
                        newFolderPath = node.path + "/"
                        showNewFolderSheet = true
                    }
                    Button("重命名文件夹") {
                        model.pendingRenamePath = node.path
                        renamePathValue = node.path
                    }
                    Button("删除文件夹", role: .destructive) {
                        model.pendingDeletePath = node.path
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private func repositoryRowContent(_ node: FileTreeNode) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: node.path, isDirectory: node.isDirectory))
                .font(.title3)
                .foregroundStyle(node.isDirectory ? .blue : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if node.isDirectory {
                    Text("\(node.children.count) 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if node.size > 0 {
                    Text(byteCount(node.size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func fileContextMenu(for node: FileTreeNode) -> some View {
        Button("重命名") {
            model.pendingRenamePath = node.path
            renamePathValue = node.path
        }
        Button("删除", role: .destructive) {
            model.pendingDeletePath = node.path
        }
    }

    private func fileEditorView(path: String) -> some View {
        VStack(spacing: 0) {
            if model.selectedFilePath == path {
                TextEditor(text: Binding(
                    get: { model.editorText },
                    set: {
                        model.editorText = $0
                        model.hasUnsavedChanges = true
                    }
                ))
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .systemBackground))
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("文件未打开", systemImage: "doc.text")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(lastPathComponent(path))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: path) {
            if model.selectedFilePath != path {
                model.requestOpenFile(path)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    model.saveSelectedFile()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(model.selectedFilePath != path || model.hasUnsavedChanges == false)

                Menu {
                    Button("重命名") {
                        model.pendingRenamePath = path
                        renamePathValue = path
                    }
                    Button("删除文件", role: .destructive) {
                        model.pendingDeletePath = path
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 10) {
                Text(path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.hasUnsavedChanges ? "未保存" : "已保存")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(model.hasUnsavedChanges ? .orange : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
    }

    private var chatView: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

                if model.selectedWorkspace == nil {
                    VStack {
                        Spacer()
                        ContentUnavailableView("请先选择项目", systemImage: "folder")
                        Spacer()
                    }
                } else {
                    GeometryReader { geometry in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                chatStatusStrip

                                if let run = model.currentRun {
                                    ForEach(chatBubbleItems(for: run)) { item in
                                        ChatBubble(item: item)
                                    }
                                } else {
                                    Spacer(minLength: max(40, geometry.size.height * 0.22))
                                    ContentUnavailableView("新对话", systemImage: "bubble.left.and.bubble.right")
                                        .frame(maxWidth: .infinity)
                                }

                                if let run = model.currentRun, run.status == .running {
                                    Text("模型正在处理…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)
                                }
                                if let run = model.currentRun,
                                   run.status == .waitingForUser,
                                   let question = run.pendingQuestion?.arguments["question"]?.stringDescription {
                                    GlassPanel {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("需要你补充信息")
                                                .font(.headline)
                                            Text(question)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                if let run = model.currentRun,
                                   run.status == .waitingForPermission,
                                   let request = run.pendingPermissionRequest {
                                    GlassPanel {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("操作确认")
                                                .font(.headline)
                                            Text(run.pendingPermissionDecision?.reason ?? "")
                                                .foregroundStyle(.secondary)
                                            Text(request.arguments.map { "\($0.key)=\($0.value.stringDescription)" }.sorted().joined(separator: "\n"))
                                                .font(.caption.monospaced())
                                            HStack {
                                                Button("允许一次") { Task { await model.resumePermission(approved: true) } }
                                                Button("拒绝", role: .destructive) { Task { await model.resumePermission(approved: false) } }
                                            }
                                        }
                                    }
                                }

                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                            .padding(.bottom, 124)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                dismissChatKeyboard()
                            }
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.selectedWorkspace != nil {
                    chatComposerBar
                }
            }
            .navigationTitle(model.selectedWorkspace?.name ?? "对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        model.startNewChat()
                        isChatComposerFocused = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    Button {
                        showChatHistorySheet = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
            }
            .sheet(isPresented: $showChatHistorySheet) {
                chatHistorySheet
            }
        }
    }

    private var chatStatusStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let project = model.selectedWorkspace {
                    labelCapsule(title: project.name)
                }
                labelCapsule(title: model.activeProvider?.name ?? "未选择模型")
                if let run = model.currentRun {
                    labelCapsule(title: agentRunStatusText(run.status))
                } else {
                    labelCapsule(title: "新对话")
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var chatComposerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let project = model.selectedWorkspace {
                        labelCapsule(title: project.name)
                    }

                    Menu {
                        ForEach(model.providerProfiles) { profile in
                            Button {
                                model.assignProvider(profile.id)
                            } label: {
                                if model.activeProvider?.id == profile.id {
                                    Label(profile.name, systemImage: "checkmark")
                                } else {
                                    Text(profile.name)
                                }
                            }
                        }
                    } label: {
                        labelCapsule(title: model.activeProvider?.name ?? "选择模型")
                    }

                    if model.activeModel?.supportsReasoning == true {
                        Menu {
                            ForEach(ReasoningEffortPreset.allCases) { effort in
                                Button {
                                    model.setReasoningEffort(effort)
                                } label: {
                                    if model.selectedReasoningEffort == effort {
                                        Label(effort.title, systemImage: "checkmark")
                                    } else {
                                        Text(effort.title)
                                    }
                                }
                            }
                        } label: {
                            labelCapsule(title: "思考 \(model.selectedReasoningEffort.title)")
                        }
                    }
                }
                .padding(.horizontal, 2)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("输入消息", text: $model.chatInput, axis: .vertical)
                    .focused($isChatComposerFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        Task { await sendChatInput() }
                    }
                    .lineLimit(1 ... 6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )

                Button {
                    Task { await sendChatInput() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.accentColor, in: Circle())
                }
                .disabled(chatSendDisabled)
                .opacity(chatSendDisabled ? 0.45 : 1)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .shadow(color: .black.opacity(0.08), radius: 14, y: -2)
    }

    private var chatHistorySheet: some View {
        NavigationStack {
            List {
                Section("历史记录") {
                    if model.chatHistory.isEmpty {
                        ContentUnavailableView("暂无历史记录", systemImage: "clock")
                    }
                    ForEach(model.chatHistory) { run in
                        Button {
                            model.selectChatRun(run)
                            showChatHistorySheet = false
                        } label: {
                            chatHistoryRow(run)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("对话历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showChatHistorySheet = false }
                }
            }
        }
    }

    private func chatHistoryRow(_ run: AgentRun) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(run.userTask.isEmpty ? "未命名对话" : run.userTask)
                .font(.body.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(agentRunStatusText(run.status))
                Text(run.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func sendChatInput() async {
        let draft = model.chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft.isEmpty == false else { return }
        if model.currentRun?.status == .waitingForUser {
            model.questionAnswer = draft
            await model.answerQuestion()
        } else {
            await model.startChat()
        }
        if model.lastErrorMessage == nil {
            model.chatInput = ""
        }
    }

    private var chatSendDisabled: Bool {
        model.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.selectedWorkspace == nil
            || model.currentRun?.status == .waitingForPermission
    }

    private func dismissChatKeyboard() {
        isChatComposerFocused = false
#if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
    }

    private func chatBubbleItems(for run: AgentRun) -> [ChatBubbleItem] {
        run.messages.compactMap { message in
            guard message.role == "user" || message.role == "assistant" else { return nil }
            if message.role == "assistant", message.content.isEmpty, let toolCalls = message.toolCalls, toolCalls.isEmpty == false {
                return ChatBubbleItem(
                    role: .assistant,
                    text: "调用工具：\(toolCalls.map(\.name).joined(separator: ", "))",
                    secondaryText: message.reasoningContent
                )
            }
            return ChatBubbleItem(
                role: message.role == "user" ? .user : .assistant,
                text: message.content,
                secondaryText: message.reasoningContent
            )
        }
    }

    private func labelCapsule(title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
    }

    private var patchesView: some View {
        NavigationStack {
            List {
                patchSection(title: "待审核", status: .pendingReview)
                patchSection(title: "已应用", status: .applied)
                patchSection(title: "已拒绝", status: .rejected)
                patchSection(title: "失败", status: .failed)
            }
            .navigationTitle("补丁审核")
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
                        Text(patchProposalStatusText(proposal.status))
                            .font(.caption)
                    }
                    Text("\(proposal.changedFiles) 个文件 · \(proposal.changedLines) 行 · agent=\(proposal.agentRunID?.uuidString ?? "无") · snapshot=\(proposal.snapshotID?.uuidString ?? "无")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let errorMessage = proposal.errorMessage, errorMessage.isEmpty == false {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    ForEach(proposal.changes, id: \.self) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(patchOperationText(change.operation))：\(change.path)")
                                .font(.caption.monospaced())
                            DiffViewer(diff: change.diff ?? change.newContent ?? (change.newPath.map { "重命名 -> \($0)" } ?? ""))
                                .frame(maxHeight: 180)
                        }
                    }
                    if proposal.status == .pendingReview {
                        HStack {
                            Button("应用") { model.applyPatch(proposal) }
                            Button("拒绝", role: .destructive) { model.rejectPatch(proposal) }
                            Button("让 AI 修改") { model.revisePatch(proposal, instruction: "请根据用户反馈修改这个补丁。") }
                        }
                    }
                    if proposal.snapshotID != nil {
                        Button("恢复快照") { model.restoreSnapshot(for: proposal) }
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
                            ("前缀哈希", snapshot.prefixHash),
                            ("仓库快照哈希", snapshot.repoSnapshotHash),
                            ("文件树哈希", snapshot.fileTreeHash),
                            ("工具协议哈希", snapshot.toolSchemaHash),
                            ("项目规则哈希", snapshot.projectRulesHash),
                            ("静态 Token", "\(snapshot.staticTokenCount)"),
                            ("动态 Token", "\(snapshot.dynamicTokenCount)")
                        ])
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("已包含文件（\(snapshot.includedFiles.count)）").font(.headline)
                                Text(snapshot.includedFiles.joined(separator: "\n")).font(.caption.monospaced())
                            }
                        }
                        if snapshot.ignoredFiles.isEmpty == false {
                            GlassPanel {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("已忽略文件（\(snapshot.ignoredFiles.count)）").font(.headline)
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
                                    Text("稳定=\(block.stable ? "是" : "否") · token=\(block.tokenCount) · hash=\(block.contentHash)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding()
                } else {
                    ContentUnavailableView("暂无上下文", systemImage: "text.redaction")
                }
            }
            .navigationTitle("上下文")
        }
    }

    private var cacheView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let record = model.cacheRecord {
                        metricsGrid([
                            ("服务", record.provider),
                            ("模型", record.model),
                            ("提示词 Token", "\(record.promptTokens)"),
                            ("输出 Token", "\(record.completionTokens)"),
                            ("总 Token", "\(record.promptTokens + record.completionTokens)"),
                            ("缓存 Token", "\(record.cachedTokens)"),
                            ("未命中 Token", "\(record.cacheMissTokens)"),
                            ("命中率", String(format: "%.1f%%", record.cacheHitRate * 100)),
                            ("前缀哈希", record.prefixHash),
                            ("仓库快照哈希", record.repoSnapshotHash),
                            ("文件树哈希", record.fileTreeHash),
                            ("工具协议哈希", record.toolSchemaHash),
                            ("项目规则哈希", record.projectRulesHash),
                            ("静态 Token", "\(record.staticPrefixTokenCount)"),
                            ("动态 Token", "\(record.dynamicTokenCount)"),
                            ("延迟", "\(record.latencyMs)ms")
                        ])
                        if record.cachedTokens == 0 {
                            Text(model.activeProvider?.supportsPromptCache == true ? "服务没有返回缓存 token 字段；这里只显示前缀 hash 估算。" : "当前服务没有声明支持提示词缓存。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if record.missReasons.isEmpty == false {
                            GlassPanel {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("未命中原因").font(.headline)
                                    Text(record.missReasons.map(\.rawValue).joined(separator: "\n"))
                                        .font(.caption.monospaced())
                                }
                            }
                        }
                    }
                    SectionHeader(title: "历史")
                    ForEach(model.cacheHistory) { record in
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(record.provider) / \(record.model)")
                                Text("缓存=\(record.cachedTokens) 提示词=\(record.promptTokens) 命中=\(String(format: "%.1f%%", record.cacheHitRate * 100))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("缓存")
        }
    }

    private var githubView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.selectedWorkspace != nil {
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("GitHub 远端").font(.headline)
                                TextField("所有者", text: $model.remoteOwner)
                                TextField("仓库", text: $model.remoteRepo)
                                TextField("分支", text: $model.remoteBranch)
                                SecureField("GitHub 令牌", text: $model.remoteToken)
                                HStack {
                                    Button("关联仓库") { Task { await model.linkGitHubRepository() } }
                                    Button("重新加载") { Task { await model.refreshGitHubData() } }
                                }
                                if let remote = model.githubRemoteConfig {
                                    Text("已关联：\(remote.owner)/\(remote.repo) @ \(remote.branch)")
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
                                Text("提交并推送").font(.headline)
                                TextField("提交信息", text: $model.commitMessage)
                                Button("预览提交摘要") { Task { await model.previewCommit() } }
                                Button("提交并推送") {
                                    Task {
                                        let isProtectedBranch = GitHubSyncService.protectedBranches.contains(model.remoteBranch)
                                        await model.commitAndPush(confirmed: true, secondProtectedBranchConfirmation: pushProtectedBranch || !isProtectedBranch)
                                    }
                                }
                                Toggle("确认推送到受保护分支", isOn: $pushProtectedBranch)
                                if let summary = model.commitSummary {
                                    Text("准备提交 SHA：\(summary.headSHA)").font(.caption)
                                    ForEach(summary.changedFiles, id: \.path) { file in
                                        Text("• \(file.path)")
                                            .font(.caption.monospaced())
                                    }
                                    if summary.skippedFiles.isEmpty == false {
                                        Text("已跳过：\(summary.skippedFiles.map { "\($0.path) (\($0.skippedReason ?? ""))" }.joined(separator: ", "))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        GlassPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("创建拉取请求").font(.headline)
                                TextField("标题", text: $model.pullRequestTitle)
                                TextField("Head 分支", text: $model.pullRequestHeadBranch)
                                TextField("Base 分支", text: $model.pullRequestBaseBranch)
                                TextField("正文", text: $model.pullRequestBody, axis: .vertical)
                                Button("创建拉取请求") { Task { await model.createPullRequest() } }
                            }
                        }

                        if let builds = model.buildConfiguration {
                            GlassPanel {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("构建按钮 · \(builds.name)").font(.headline)
                                    ForEach(builds.builds) { build in
                                        Button(build.name) { Task { await model.dispatchWorkflow(build: build) } }
                                    }
                                }
                            }
                        }

                        GlassPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("工作流").font(.headline)
                                TextField("工作流 ID 或文件名", text: $model.selectedWorkflowIdentifier)
                                TextField("引用分支或标签", text: $model.selectedWorkflowRef)
                                TextField("输入 JSON", text: $model.workflowInputsText, axis: .vertical)
                                Text("输入格式必须是 JSON 对象，例如 {\"scheme\":\"App\"}。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("触发工作流") { Task { await model.dispatchWorkflow() } }
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
                                Text("运行 / 任务 / 产物").font(.headline)
                                ForEach(model.workflowRuns) { run in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(run.name ?? "运行 \(run.id)")
                                        Text("状态=\(run.status ?? "无") 结论=\(run.conclusion ?? "无") 分支=\(run.headBranch ?? "无")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Divider()
                                ForEach(model.workflowJobs) { job in
                                    Text("任务：\(job.name) · \(job.status ?? "无") / \(job.conclusion ?? "无")")
                                        .font(.caption)
                                }
                                Divider()
                                ForEach(model.workflowArtifacts) { artifact in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(artifact.name)
                                        Text("大小=\(artifact.sizeInBytes) · \(artifact.archiveDownloadURL)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Button("下载到本地") {
                                            Task { await model.downloadArtifact(artifact) }
                                        }
                                        .disabled(artifact.expired)
                                        if let downloadURL = URL(string: artifact.browserDownloadURL ?? artifact.archiveDownloadURL) {
                                            Link("打开产物下载地址", destination: downloadURL)
                                                .font(.caption)
                                        }
                                        if artifact.expired {
                                            Text("该产物已过期，无法下载。")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView("请先选择项目", systemImage: "arrow.triangle.branch")
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
                Section("模型") {
                    ForEach(model.providerProfiles) { profile in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(profile.name)
                                Spacer()
                                if model.activeProvider?.id == profile.id {
                                    Text("当前使用")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(profile.baseURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(profile.modelProfiles.first?.id ?? "")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("编辑") {
                                    editingProvider = profile
                                    providerAPIKey = ""
                                    showProviderEditor = true
                                }
                                Button("使用") { model.assignProvider(profile.id) }
                                Button("测试") { Task { await model.testConnection(profile: profile, apiKey: nil) } }
                                Button("删除", role: .destructive) { model.deleteProvider(profile, deleteSecret: true) }
                            }
                            .font(.caption)
                        }
                    }
                    Button("添加模型") {
                        editingProvider = nil
                        providerAPIKey = ""
                        showProviderEditor = true
                    }
                }

                Section("模型权限") {
                    Picker(
                        "权限模式",
                        selection: Binding(
                            get: { model.appPreferences.permissionMode },
                            set: { model.setPermissionMode($0) }
                        )
                    ) {
                        ForEach(ModelPermissionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(model.appPreferences.permissionMode.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker(
                        "默认思考强度",
                        selection: Binding(
                            get: { model.selectedReasoningEffort },
                            set: { model.setReasoningEffort($0) }
                        )
                    ) {
                        ForEach(ReasoningEffortPreset.allCases) { effort in
                            Text(effort.title).tag(effort)
                        }
                    }
                }

                if let status = model.lastConnectionStatus {
                    Section("连接") { Text(status) }
                }
            }
            .navigationTitle("设置")
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
            .navigationTitle("审计日志")
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

    private func agentRunStatusText(_ status: AgentRunStatus) -> String {
        switch status {
        case .running: "运行中"
        case .waitingForUser: "等待用户回答"
        case .waitingForPermission: "等待权限确认"
        case .waitingForPatchReview: "等待补丁审核"
        case .completed: "已完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }

    private func patchProposalStatusText(_ status: PatchProposalStatus) -> String {
        switch status {
        case .pendingReview: "待审核"
        case .applied: "已应用"
        case .rejected: "已拒绝"
        case .failed: "失败"
        case .superseded: "已被替代"
        }
    }

    private func patchOperationText(_ operation: PatchOperation) -> String {
        switch operation {
        case .modify: "修改"
        case .create: "新建"
        case .delete: "删除"
        case .rename: "重命名"
        }
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View { Text(title).font(.headline) }
}

private struct FileTreeNode: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    var children: [FileTreeNode]

    init(name: String, path: String, isDirectory: Bool, size: Int64 = 0, children: [FileTreeNode] = []) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.children = children
    }
}

private func buildFileTree(from entries: [WorkspaceFileEntry]) -> [FileTreeNode] {
    func insert(
        _ nodes: inout [FileTreeNode],
        parts: [String],
        index: Int,
        currentPath: String,
        entry: WorkspaceFileEntry
    ) {
        guard index < parts.count else { return }
        let name = parts[index]
        let nodePath = currentPath.isEmpty ? name : "\(currentPath)/\(name)"
        let isLeaf = index == parts.count - 1
        let isDirectory = isLeaf ? entry.isDirectory : true

        if let existingIndex = nodes.firstIndex(where: { $0.path == nodePath }) {
            if isLeaf {
                nodes[existingIndex] = FileTreeNode(
                    name: name,
                    path: nodePath,
                    isDirectory: isDirectory,
                    size: entry.size,
                    children: nodes[existingIndex].children
                )
            } else {
                insert(
                    &nodes[existingIndex].children,
                    parts: parts,
                    index: index + 1,
                    currentPath: nodePath,
                    entry: entry
                )
                nodes[existingIndex].children.sort(by: sortFileNodes)
            }
        } else {
            var node = FileTreeNode(
                name: name,
                path: nodePath,
                isDirectory: isDirectory,
                size: isLeaf ? entry.size : 0
            )
            if isLeaf == false {
                insert(&node.children, parts: parts, index: index + 1, currentPath: nodePath, entry: entry)
            }
            nodes.append(node)
            nodes.sort(by: sortFileNodes)
        }
    }

    var roots: [FileTreeNode] = []
    for entry in entries.sorted(by: { $0.path < $1.path }) {
        let parts = entry.path.split(separator: "/").map(String.init)
        insert(&roots, parts: parts, index: 0, currentPath: "", entry: entry)
    }
    return roots
}

private func sortFileNodes(_ lhs: FileTreeNode, _ rhs: FileTreeNode) -> Bool {
    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
}

private func icon(for path: String, isDirectory: Bool) -> String {
    if isDirectory { return "folder.fill" }
    if path.hasSuffix(".swift") { return "swift" }
    if path.hasSuffix(".json") { return "curlybraces" }
    if path.hasSuffix(".md") { return "doc.richtext" }
    if path.hasSuffix(".yml") || path.hasSuffix(".yaml") { return "gearshape.2" }
    return "doc.text"
}

private func byteCount(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

private func lastPathComponent(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
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
                Section("服务") {
                    TextField("名称", text: $draft.name)
                    Picker("API 类型", selection: $draft.apiStyle) {
                        ForEach(APIStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TextField("基础 URL", text: $draft.baseURL)
                        .textInputAutocapitalization(.never)
                    TextField("接口路径", text: $draft.endpoint)
                        .textInputAutocapitalization(.never)
                    Picker("认证方式", selection: $draft.authType) {
                        ForEach(AuthType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TextField("认证字段名", text: $draft.authKeyName)
                    SecureField("API 密钥", text: $apiKey)
                    Toggle("支持流式输出", isOn: $draft.supportsStreaming)
                    Toggle("支持工具调用", isOn: $draft.supportsToolCalling)
                    Toggle("支持 JSON 模式", isOn: $draft.supportsJSONMode)
                    Toggle("支持视觉", isOn: $draft.supportsVision)
                    Toggle("支持推理", isOn: $draft.supportsReasoning)
                    Toggle("支持提示词缓存", isOn: $draft.supportsPromptCache)
                    Toggle("支持显式缓存控制", isOn: $draft.supportsExplicitCacheControl)
                    Toggle("支持联网搜索", isOn: $draft.supportsWebSearch)
                }
                Section("请求字段映射") {
                    mappingFields(prefix: $draft.requestFieldMapping)
                }
                Section("响应字段映射") {
                    mappingFields(prefix: $draft.responseFieldMapping)
                }
                Section("用量字段映射") {
                    mappingFields(prefix: $draft.usageFieldMapping)
                }
                Section("额外请求头") {
                    KeyValueListEditor(rows: $draft.extraHeaders)
                }
                Section("额外请求体参数") {
                    KeyValueListEditor(rows: $draft.extraBodyParameters)
                }
                Section("模型") {
                    ForEach($draft.models) { $model in
                        ModelDraftEditor(model: $model)
                    }
                    Button("添加模型") { draft.models.append(ModelDraft()) }
                }
            }
            .navigationTitle("服务配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("测试") { if let profile = draft.makeProfile() { onTest(profile, apiKey.isEmpty ? nil : apiKey) } }
                    Button("保存") {
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
            TextField("模型 ID", text: $model.id)
            TextField("显示名称", text: $model.displayName)
            TextField("最大上下文 Token", value: $model.maxContextTokens, format: .number)
            TextField("最大输出 Token", value: $model.maxOutputTokens, format: .number)
            Toggle("支持推理", isOn: $model.supportsReasoning)
            TextField("推理开关字段", text: $model.reasoningEnabledField)
            TextField("推理深度字段", text: $model.reasoningDepthField)
            KeyValueListEditor(rows: $model.reasoningLevels)
            Toggle("支持缓存", isOn: $model.supportsCache)
            Picker("缓存策略", selection: $model.cacheStrategy) {
                ForEach(CacheStrategy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("支持工具", isOn: $model.supportsTools)
            Toggle("支持流式输出", isOn: $model.supportsStreaming)
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
                TextField("键", text: $row.key)
                TextField("值", text: $row.value)
            }
        }
        HStack {
            Button("添加行") { rows.append(EditablePair()) }
            if rows.isEmpty == false {
                Button("删除最后一行", role: .destructive) { rows.removeLast() }
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
