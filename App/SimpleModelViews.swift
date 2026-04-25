import LocalAIWorkspace
import SwiftUI

struct ChatBubbleItem: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let text: String
    let secondaryText: String?
}

struct ChatBubble: View {
    let item: ChatBubbleItem

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if item.role == .assistant {
                bubble(
                    alignment: .leading,
                    foregroundStyle: .primary,
                    background: AnyShapeStyle(.regularMaterial),
                    borderColor: Color.white.opacity(0.18)
                )
                Spacer(minLength: 56)
            } else {
                Spacer(minLength: 56)
                bubble(
                    alignment: .trailing,
                    foregroundStyle: .white,
                    background: AnyShapeStyle(.tint)
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func bubble(
        alignment: HorizontalAlignment,
        foregroundStyle: Color,
        background: AnyShapeStyle,
        borderColor: Color? = nil
    ) -> some View {
        let hasSecondaryText = item.secondaryText?.isEmpty == false
        VStack(alignment: alignment, spacing: 6) {
            if let secondaryText = item.secondaryText, hasSecondaryText {
                Text(secondaryText)
                    .font(.caption)
                    .foregroundStyle(
                        item.role == .assistant
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(Color.white.opacity(0.78))
                    )
                    .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
            }
            if item.text.isEmpty == false || hasSecondaryText == false {
                Text(item.text.isEmpty ? " " : item.text)
                    .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
            }
        }
        .padding(14)
        .background(background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            if let borderColor {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
        }
        .foregroundStyle(foregroundStyle)
    }
}

struct SimpleModelEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL: String
    @State private var apiKey: String
    @State private var modelID: String
    @State private var reasoningEffort: ReasoningEffortPreset

    private let editingProfile: ProviderProfile?
    let onSave: (ProviderProfile, String?, ReasoningEffortPreset) -> Void
    let onTest: (ProviderProfile, String?) -> Void

    init(
        profile: ProviderProfile?,
        apiKey: String,
        defaultReasoningEffort: ReasoningEffortPreset,
        onSave: @escaping (ProviderProfile, String?, ReasoningEffortPreset) -> Void,
        onTest: @escaping (ProviderProfile, String?) -> Void
    ) {
        editingProfile = profile
        _baseURL = State(initialValue: profile?.baseURL ?? "https://api.deepseek.com")
        _apiKey = State(initialValue: apiKey)
        _modelID = State(initialValue: profile?.modelProfiles.first?.id ?? "deepseek-v4-pro")
        _reasoningEffort = State(initialValue: defaultReasoningEffort)
        self.onSave = onSave
        self.onTest = onTest
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("模型参数") {
                    TextField("URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $apiKey)
                    TextField("Model ID", text: $modelID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("推理深度", selection: $reasoningEffort) {
                        ForEach(ReasoningEffortPreset.allCases) { effort in
                            Text(effort.title).tag(effort)
                        }
                    }
                }

                Section {
                    Text("优先按 DeepSeek V4 真实参数构建，请求地址默认使用 OpenAI 兼容格式的 https://api.deepseek.com/chat/completions。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(editingProfile == nil ? "添加模型" : "模型设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("测试") {
                        if let profile = makeProfile() {
                            onTest(profile, apiKey.isEmpty ? nil : apiKey)
                        }
                    }
                    Button("保存") {
                        if let profile = makeProfile() {
                            onSave(profile, apiKey.isEmpty ? nil : apiKey, reasoningEffort)
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func makeProfile() -> ProviderProfile? {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedURL.isEmpty == false, trimmedModelID.isEmpty == false else { return nil }

        let displayName: String
        switch trimmedModelID {
        case "deepseek-v4-pro":
            displayName = "DeepSeek V4 Pro"
        case "deepseek-v4-flash":
            displayName = "DeepSeek V4 Flash"
        default:
            displayName = trimmedModelID
        }

        return ProviderProfile(
            id: editingProfile?.id ?? UUID().uuidString,
            name: displayName,
            apiStyle: .openAICompatible,
            baseURL: trimmedURL,
            endpoint: "/chat/completions",
            auth: AuthConfiguration(type: .bearer),
            supportsStreaming: true,
            supportsToolCalling: true,
            supportsJSONMode: true,
            supportsVision: false,
            supportsReasoning: true,
            supportsPromptCache: true,
            supportsExplicitCacheControl: false,
            supportsWebSearch: false,
            modelProfiles: [
                ModelProfile(
                    id: trimmedModelID,
                    displayName: displayName,
                    supportsReasoning: true,
                    reasoningMapping: ReasoningMapping(
                        enabledField: "thinking.type",
                        depthField: "reasoning_effort",
                        levels: [
                            ReasoningLevel(label: "高", value: "high"),
                            ReasoningLevel(label: "极限", value: "max")
                        ]
                    ),
                    supportsCache: true,
                    cacheStrategy: .automaticPrefix,
                    supportsTools: true,
                    supportsStreaming: true,
                    maxContextTokens: 1_000_000,
                    maxOutputTokens: 384_000
                )
            ]
        )
    }
}
