import LocalAIWorkspace
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            ProjectListView(model: model)
                .tabItem { Label(AppTab.projects.title, systemImage: AppTab.projects.systemImage) }
                .tag(AppTab.projects)

            WorkspaceOverviewView(model: model)
                .tabItem { Label(AppTab.workspace.title, systemImage: AppTab.workspace.systemImage) }
                .tag(AppTab.workspace)

            ChatWorkspaceView(model: model)
                .tabItem { Label(AppTab.chat.title, systemImage: AppTab.chat.systemImage) }
                .tag(AppTab.chat)

            PatchQueueView(model: model)
                .tabItem { Label(AppTab.patches.title, systemImage: AppTab.patches.systemImage) }
                .tag(AppTab.patches)

            ContextDashboardView(model: model)
                .tabItem { Label(AppTab.context.title, systemImage: AppTab.context.systemImage) }
                .tag(AppTab.context)

            CacheDashboardView(model: model)
                .tabItem { Label(AppTab.cache.title, systemImage: AppTab.cache.systemImage) }
                .tag(AppTab.cache)

            SettingsView(model: model)
                .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage) }
                .tag(AppTab.settings)
        }
    }
}

private struct ProjectListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.workspaces) { workspace in
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(workspace.name)
                                            .font(.title3.bold())
                                        Text(workspace.mode == .localOnly ? "Local Only" : "Linked to GitHub")
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: workspace.status.cachePrefixStable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(workspace.status.cachePrefixStable ? .green : .orange)
                                }

                                HStack(spacing: 12) {
                                    statusLabel("Branch", workspace.currentBranch ?? "Not linked")
                                    statusLabel("Context", workspace.status.contextReady ? "Ready" : "Pending")
                                    statusLabel("Prefix", workspace.status.cachePrefixStable ? "Stable" : "Changed")
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Projects")
        }
    }

    private func statusLabel(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkspaceOverviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    GlassPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(model.selectedWorkspace?.name ?? "Workspace")
                                .font(.title2.bold())
                            Text("Local-first workspace state stays authoritative. GitHub remains optional remote sync.")
                                .foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                GlassCapsuleBadge(title: "Recent Patch", value: "\(model.patchQueue.count) pending")
                                GlassCapsuleBadge(title: "Provider", value: model.providerProfiles.first?.name ?? "None")
                            }
                        }
                    }

                    GlassPanel {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("WorkspaceFS boundary", systemImage: "externaldrive.badge.checkmark")
                                .font(.headline)
                            Text("Only files inside `workspace/files` are readable. Protected paths, workflows, credentials, and cache internals require confirmation.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    GlassPanel {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("MVP focus", systemImage: "scope")
                                .font(.headline)
                            bullet("Workspace creation and local storage")
                            bullet("Provider profile editor for OpenAI-compatible APIs")
                            bullet("Chat + ask_question + patch review loop")
                            bullet("Context prefix builder and cache telemetry")
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Workspace")
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .padding(.top, 6)
            Text(text)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct ChatWorkspaceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    GlassPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Current clarification", systemImage: "questionmark.circle")
                                .font(.headline)
                            Text(string(from: model.currentQuestion.arguments["question"]))
                            Text(string(from: model.currentQuestion.arguments["reason"]))
                                .foregroundStyle(.secondary)
                        }
                    }

                    GlassPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Recent tool calls", systemImage: "hammer")
                                .font(.headline)
                            ForEach(model.recentToolCalls) { call in
                                HStack(alignment: .top) {
                                    Text(call.name)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(call.arguments.isEmpty ? "auto" : "payload")
                                        .foregroundStyle(.secondary)
                                }
                                if call.id != model.recentToolCalls.last?.id {
                                    Divider()
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

    private func string(from value: JSONValue?) -> String {
        if case let .string(text)? = value { return text }
        return ""
    }
}

private struct PatchQueueView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            List(model.patchQueue) { patch in
                Section(patch.title) {
                    Text(patch.reason)
                    ForEach(patch.changes, id: \.path) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(change.path)
                                .font(.subheadline.weight(.semibold))
                            Text(change.operation.rawValue.capitalized)
                                .foregroundStyle(.secondary)
                            if let diff = change.diff {
                                Text(diff)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(6)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Patch Review")
        }
    }
}

private struct ContextDashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    GlassPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Static prefix order", systemImage: "text.justify.left")
                                .font(.headline)
                            ForEach([
                                "System prompt",
                                "Tool schema",
                                "Permission rules",
                                "Project rules",
                                "File tree",
                                "Repo map",
                                "Key file summaries",
                                "Dependency summary",
                                "AI memory"
                            ], id: \.self) { item in
                                Text("• \(item)")
                            }
                        }
                    }

                    GlassPanel {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Dynamic task block")
                                .font(.headline)
                            Text("Current task, opened files, snippets, diff, CI logs, and user request stay after the stable prefix so provider prompt caches can reuse the prefix.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Context")
        }
    }
}

private struct CacheDashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    GlassPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("\(Int(model.cacheRecord.cacheHitRate * 100))% cache hit rate")
                                .font(.largeTitle.bold())
                            Text("Prefix hash: \(model.cacheRecord.prefixHash)")
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                metric("Prompt", "\(model.cacheRecord.promptTokens)")
                                metric("Cached", "\(model.cacheRecord.cachedTokens)")
                                metric("Saved", String(format: "¥%.2f", model.cacheRecord.estimatedSavedCost))
                            }
                        }
                    }

                    if !model.cacheRecord.missReasons.isEmpty {
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Miss reasons")
                                    .font(.headline)
                                ForEach(model.cacheRecord.missReasons, id: \.self) { reason in
                                    Text("• \(reason.rawValue)")
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Cache")
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Provider Profiles") {
                    ForEach(model.providerProfiles) { provider in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(provider.name)
                            Text(provider.baseURL)
                                .foregroundStyle(.secondary)
                            Text(provider.modelProfiles.map(\.displayName).joined(separator: ", "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Permissions") {
                    Label("Manual / Semi-Auto / Auto", systemImage: "lock.shield")
                    Label("Protected paths and dangerous operation policy", systemImage: "exclamationmark.shield")
                }

                Section("GitHub Sync") {
                    Label("Optional branch / PR / workflow dispatch", systemImage: "point.3.connected.trianglepath.dotted")
                    Label("No automatic push or workflow trigger", systemImage: "hand.raised")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
