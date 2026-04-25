import LocalAIWorkspace
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ChatBubbleItem: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id: String
    let role: Role
    let text: String
    let secondaryText: String?
    var isThinking: Bool = false
}

struct ChatBubble: View {
    let item: ChatBubbleItem
    @State private var thinkingExpanded: Bool

    init(item: ChatBubbleItem) {
        self.item = item
        _thinkingExpanded = State(initialValue: item.isThinking)
    }

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
        .onChange(of: item.isThinking) { newValue in
            withAnimation(.easeInOut(duration: 0.2)) {
                thinkingExpanded = newValue
            }
        }
    }

    private func bubble(
        alignment: HorizontalAlignment,
        foregroundStyle: Color,
        background: AnyShapeStyle,
        borderColor: Color? = nil
    ) -> some View {
        let hasReasoning = item.secondaryText?.isEmpty == false
        return VStack(alignment: alignment, spacing: 6) {
            if hasReasoning {
                DisclosureGroup(isExpanded: $thinkingExpanded) {
                    ReasoningText(content: item.secondaryText ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: thinkingExpanded ? "brain.head.profile.fill" : "brain.head.profile")
                            .font(.caption)
                        Text(thinkingExpanded ? "正在思考…" : "思考过程")
                            .font(.caption.weight(.medium))
                        if !thinkingExpanded {
                            Text("(\(item.secondaryText?.count ?? 0) 字)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            if item.text.isEmpty == false || !hasReasoning {
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

#if canImport(UIKit)
private struct ReasoningText: UIViewRepresentable {
    let content: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.font = .preferredFont(forTextStyle: .caption1)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .secondaryLabel
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != content {
            uiView.text = content
        }
        uiView.font = .preferredFont(forTextStyle: .caption1)
        uiView.textColor = .secondaryLabel
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let targetSize = CGSize(width: max(width, 0), height: .greatestFiniteMagnitude)
        let fittingSize = uiView.sizeThatFits(targetSize)
        return CGSize(width: width, height: fittingSize.height)
    }
}
#else
private struct ReasoningText: View {
    let content: String

    var body: some View {
        Text(content)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
#endif

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
