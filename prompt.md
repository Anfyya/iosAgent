# iOS Agent Project Prompt

```text
你现在是一个顶级 iOS 26.4 / SwiftUI / GitHub Actions / AI Coding Agent 架构师和工程实现者。请你不要想当然，不要用旧 iOS 毛玻璃写法糊弄，不要把 Liquid Glass 当成 .ultraThinMaterial + blur + opacity + shadow。这个项目要求非常明确：我要做一个 iOS 26.4 App，本地仓库是主状态，AI 可自定义 API 接入，重点是上下文管理、缓存命中、权限控制、patch 审核和可选 GitHub 同步。

如果你不确定某个 iOS 26.4 / Liquid Glass API 是否存在，必须先查官方 Apple Developer 文档或使用当前 Xcode 26.4 SDK 验证，不能编造 API。尤其是 Liquid Glass 相关代码，必须使用 iOS 26 官方 API 思路，比如 SwiftUI 的 glassEffect(_:in:) 和 GlassEffectContainer。UIKit 里如果要用 Liquid Glass，也必须查官方 UIKit 文档，不能自己写一个假的 UIGlassEffect 类。若 SDK 里没有对应 API，请明确说明并提供 fallback，而不是硬写不存在的代码。

项目目标：

开发一个 iOS 26.4 SwiftUI App，暂定名为 LocalAIWorkspace / ContextPilot / RepoGlass。这个 App 是一个“本地优先的 AI 工程工作台”，不是一个普通聊天 App，也不是一个完整 VSCode 复制品。它的核心价值是：

1. 在 iPhone 上管理本地工程 / 本地仓库。
2. 本地仓库是主状态，GitHub 只是可选 remote。
3. 用户可以配置自定义 AI API，例如 OpenAI-compatible、DeepSeek、OpenRouter、Qwen、GLM、Claude、Gemini、火山、百炼、中转站等。
4. AI 可以读取工程、搜索文件、理解上下文、提出 patch。
5. AI 默认不能直接乱改文件。它只能提出结构化 patch / 文件操作提案。
6. App 负责校验、展示 diff、创建 snapshot、应用 patch。
7. 用户可以选择只保存本地，也可以 commit / push 到 GitHub，也可以触发 GitHub Actions。
8. 这个 App 自己的 IPA 由 GitHub Actions 构建，使用 macos-26 runner + Xcode 26.4。
9. 重点不是“手机上编译所有工程”，而是“手机上管理工程上下文，让 AI 改代码，然后可选同步和远程构建”。
10. 最重要的系统是上下文管理和缓存命中，不是 UI 花活。

技术目标：

App：
- SwiftUI
- iOS 26.4 target
- Xcode 26.4
- 本地文件存储
- Keychain 存 API Key / GitHub Token
- SwiftData 或 SQLite 存 workspace metadata、context index、cache stats、patch history
- GitHub REST API / GraphQL API / Actions API
- 可选支持导入 zip / 从 GitHub 拉取文件 / 本地创建工程

GitHub Actions：
- 使用 macos-26 runner
- 显式选择 Xcode 26.4：
  sudo xcode-select -s /Applications/Xcode_26.4.app/Contents/Developer
- workflow 要能 build / archive / export IPA
- 签名信息通过 GitHub Secrets 注入，例如 p12 证书、provisioning profile、keychain password、team id 等
- 如果没有签名，至少能 build simulator 或 unsigned archive，但要明确区分

Liquid Glass UI 要求：

必须适配 iOS 26.4 的 Liquid Glass。注意：

1. Liquid Glass 不是普通毛玻璃。
   不要简单写：
   .background(.ultraThinMaterial)
   .blur(...)
   .opacity(...)
   .shadow(...)
   然后假装这是 Liquid Glass。

2. Apple 的 Liquid Glass 是系统级动态材料，会根据背景内容、光感、触控、滚动、交互状态变化。SwiftUI 自定义视图应使用官方 Liquid Glass API，例如：
   - glassEffect(_:in:)
   - GlassEffectContainer

3. 标准系统组件优先：
   - NavigationStack
   - TabView
   - Toolbar
   - Button
   - Sheet
   - NavigationSplitView
   - system toolbar / tab bar / popover
   不要为了“像玻璃”而重写所有系统控件。优先让 iOS 26 系统组件自动获得新设计语言。

4. 自定义 Liquid Glass 只用在适合的地方：
   - 顶部/底部浮动工具栏
   - 快捷操作按钮
   - AI 输入栏
   - Patch review 浮动操作区
   - 构建状态浮窗
   - Context / Cache 状态胶囊
   - 项目详情页的浮动 navigation controls

5. 不要把所有内容卡片、代码区域、文件列表 cell 都做成玻璃。代码阅读区域要清晰，Liquid Glass 应该服务于导航层和操作层，不要污染内容层。

6. 要做明暗模式、动态字体、Reduce Transparency / Increase Contrast / Reduce Motion 可访问性适配。
   如果用户开启降低透明度，应该退回更实心的系统背景或降低玻璃效果强度。
   如果用户开启减少动态效果，应该减少 morph / floating animation。

7. 示例 SwiftUI 结构应该类似：
   - RootView: TabView 或 NavigationSplitView
   - ProjectListView
   - WorkspaceView
   - FileExplorerView
   - CodeEditorView
   - AIChatView
   - PatchReviewView
   - ContextDashboardView
   - CacheDashboardView
   - ProviderProfileView
   - GitHubSyncView
   - SettingsView

8. 自定义玻璃按钮示例必须使用 iOS 26 availability guard：
   if #available(iOS 26.0, *) {
       GlassEffectContainer {
           HStack {
               Button { ... } label: { ... }
                   .glassEffect()
           }
       }
   } else {
       fallback UI
   }

9. 如果当前工程最低版本就是 iOS 26.4，可以少写 fallback，但公共组件最好仍然用 @available 包一下，防止编译配置变化。

产品定位：

这是一个本地优先的 AI 工程工作台。不要把它设计成“必须绑定 GitHub 才能用”。正确逻辑是：

本地 Workspace
  ↓
本地文件 / 本地仓库 / 本地上下文索引
  ↓
AI 读取、搜索、分析
  ↓
AI 生成 patch proposal
  ↓
用户审核 diff
  ↓
App 应用到本地
  ↓
自动 snapshot
  ↓
可选 commit
  ↓
可选 push GitHub
  ↓
可选触发 GitHub Actions
  ↓
可选查看 logs / 下载 artifacts

本地仓库是主状态，GitHub 是 remote，不是主数据库。

Workspace 目录建议：

Workspaces/
  MyProject/
    files/
      src/
      README.md
      package.json
      ...
    .mobiledev/
      workspace.json
      provider_profiles/
        openai.json
        deepseek.json
        custom-qwen.json
      context/
        file_tree.json
        repo_map.json
        symbol_index.json
        dependency_summary.json
        summaries/
        ai_memory.md
        rules.md
      cache/
        prefix_blocks.json
        prefix_hashes.json
        usage.sqlite
      patches/
        patch_0001.diff
        patch_0002.diff
      snapshots/
        snapshot_0001/
        snapshot_0002/
      github/
        remote.json
        workflow_cache.json
        artifact_cache.json
      logs/
        agent_runs.sqlite

AI Provider 设计：

不要把 OpenAI / DeepSeek / Claude / Qwen / GLM / Gemini 全写死在代码里。必须做成 Provider Profile / Model Profile / Schema-driven UI。

核心思想：

App 内部使用统一 AIRequest / AIResponse / ToolCall 格式。
不同服务商通过 ProviderAdapter 和 ProviderProfile 映射字段。

Provider Profile 应该描述：

- id
- name
- apiStyle:
  - openai-compatible
  - anthropic
  - gemini
  - custom-json
- baseURL
- endpoint
- auth type
  - bearer
  - header
  - query
  - none
- model list
- supportsStreaming
- supportsToolCalling
- supportsJSONMode
- supportsVision
- supportsReasoning
- supportsPromptCache
- supportsExplicitCacheControl
- supportsWebSearch
- request field mapping
- response field mapping
- usage field mapping
- cached token path
- reasoning content path
- tool call path
- error path
- extra headers
- extra body parameters

必须支持用户自己配置“思考模式”和“思考深度”的 UI 映射，因为不同 AI 的字段名不一样：

例子：

{
  "id": "custom-deepseek",
  "name": "Custom DeepSeek Gateway",
  "apiStyle": "openai-compatible",
  "baseURL": "https://example.com/v1",
  "endpoint": "/chat/completions",
  "auth": {
    "type": "bearer"
  },
  "models": [
    {
      "id": "deepseek-v4-pro",
      "displayName": "DeepSeek V4 Pro",
      "supportsReasoning": true,
      "reasoning": {
        "enabledField": "enable_thinking",
        "depthField": "thinking_level",
        "levels": [
          { "label": "低", "value": "low" },
          { "label": "高", "value": "high" },
          { "label": "Max", "value": "max" }
        ]
      },
      "cache": {
        "strategy": "automatic_prefix",
        "inputCachedTokensPath": "usage.prompt_cache_hit_tokens",
        "inputCacheMissTokensPath": "usage.prompt_cache_miss_tokens",
        "inputTokensPath": "usage.prompt_tokens",
        "outputTokensPath": "usage.completion_tokens"
      }
    }
  ]
}

另一个模型可能这样：

{
  "reasoning": {
    "enabledField": "thinking.enabled",
    "depthField": "reasoning_effort",
    "levels": [
      { "label": "自动", "value": "auto" },
      { "label": "中等", "value": "medium" },
      { "label": "深度", "value": "deep" }
    ]
  }
}

UI 要根据这个 Profile 自动生成参数页面，例如：

- 思考模式：开 / 关
- 思考强度：低 / 中 / 高 / Max
- 联网搜索：开 / 关
- Temperature
- Max Tokens
- Top P
- JSON Mode
- Tool Calling
- Cache Strategy
- Extra Params

不要把这些控件写死成某一家 API 的字段名。

AI 调用引擎：

内部统一结构类似：

struct AIRequest {
    var messages: [AIMessage]
    var model: String
    var temperature: Double?
    var maxTokens: Int?
    var stream: Bool
    var reasoning: ReasoningConfig?
    var tools: [AITool]?
    var cacheHint: CacheHint?
    var extraParams: [String: AnyCodable]
}

struct AIResponse {
    var text: String?
    var toolCalls: [ToolCall]
    var reasoningContent: String?
    var usage: AIUsage?
    var raw: Data
}

struct AIUsage {
    var inputTokens: Int?
    var outputTokens: Int?
    var cachedInputTokens: Int?
    var cacheMissInputTokens: Int?
    var totalTokens: Int?
    var latencyMs: Int?
    var timeToFirstTokenMs: Int?
}

ProviderAdapter 负责：

- buildRequestBody()
- parseResponse()
- parseStreamingChunk()
- extractToolCalls()
- extractUsage()
- extractCacheUsage()
- extractReasoningContent()
- normalizeError()

工具调用设计：

AI 不是直接写磁盘的东西。AI 只输出工具调用，App 解析后执行 Swift 本地函数。

基础工具：

1. list_files
   列出 workspace 内文件。
   默认 auto。

2. read_file
   读取 workspace 内文件。
   默认 auto，但必须经过安全路径校验。
   返回内容时带 file hash。

3. search_in_files
   搜索 workspace 文件内容。
   默认 auto。

4. get_file_hash
   获取文件 hash。
   默认 auto。

5. get_context_status
   获取 repo map、prefix hash、context budget、cache status。
   默认 auto。

6. ask_question
   AI 向用户提问。
   默认 auto，永远允许。
   如果 blocking=true，Agent Loop 必须暂停，等用户回答，不能继续猜。

7. propose_patch
   AI 提出修改 patch。
   默认 auto 或 review。
   注意：只是提案，不直接写文件。

8. propose_create_file
   AI 提议创建文件。
   默认 review。

9. propose_delete_file
   AI 提议删除文件。
   默认 ask 或 review。

10. propose_rename_file
   AI 提议重命名文件。
   默认 ask 或 review。

11. apply_patch
   不建议暴露给 AI。
   最好只由 App UI 在用户点击 Apply 后内部调用。
   如果未来支持 Auto 模式，也必须先 snapshot。

12. git_commit
   默认 ask。

13. git_push
   默认 ask。

14. trigger_github_action
   默认 ask。

15. create_pull_request
   默认 ask。

16. download_artifact
   默认 auto 或 ask。

必须有 WorkspaceFS 虚拟文件系统层：

- 只允许访问当前 workspace/files
- 禁止路径穿越，例如 ../
- 禁止访问 App Sandbox 之外路径
- 禁止 AI 读取 Keychain
- 禁止 AI 读取 API Key
- 禁止 AI 直接修改 .mobiledev/cache 原始数据
- 禁止 AI 修改 provider profile，除非用户确认

路径校验必须类似：

safeURL(for path):
  - path 不能包含 ..
  - 标准化后的 URL 必须仍然在 workspace root 内
  - protected paths 需要额外权限
  - binary / large file 需要特殊处理

工具调用循环：

Agent Loop 应该类似：

1. 用户输入需求。
2. App 构建上下文。
3. 发送消息 + 工具 schema 给模型。
4. 模型返回 tool_calls。
5. App 根据权限策略执行工具。
6. 工具结果作为 tool result 返回给模型。
7. 模型继续推理。
8. 如果模型调用 ask_question 且 blocking=true，暂停，等待用户。
9. 如果模型输出 propose_patch，进入 Patch Queue。
10. 如果模型输出最终回答，显示给用户。
11. loopCount 必须有限制，例如最多 8 或 12 轮，防止无限循环。

伪代码：

func runAgentLoop(userMessage: String) async throws {
    var messages = buildInitialMessages(userMessage)
    var loopCount = 0

    while loopCount < maxToolRounds {
        loopCount += 1

        let response = try await aiClient.send(messages)

        if let question = response.blockingQuestion {
            showQuestionToUser(question)
            pauseUntilUserAnswers()
            messages.append(userAnswer)
            continue
        }

        if !response.toolCalls.isEmpty {
            for call in response.toolCalls {
                let decision = permissionManager.decide(call)

                switch decision {
                case .deny:
                    messages.append(toolDeniedResult(call))
                case .auto:
                    let result = try await toolExecutor.execute(call)
                    messages.append(toolResult(call, result))
                case .ask:
                    let allowed = await askUserPermission(call)
                    if allowed {
                        let result = try await toolExecutor.execute(call)
                        messages.append(toolResult(call, result))
                    } else {
                        messages.append(toolDeniedResult(call))
                    }
                case .review:
                    let reviewId = try createReviewItem(call)
                    messages.append(reviewCreatedResult(reviewId))
                case .manualOnly:
                    messages.append(toolDeniedManualOnly(call))
                }
            }
            continue
        }

        showFinalAnswer(response.text)
        return
    }

    throw AgentError.tooManyToolCalls
}

权限系统：

权限不能粗暴只有“自动/手动”。必须做成工具级权限 + 操作级权限 + 风险级确认。

全局模式：

Manual：
AI 可以读、搜索、问问题、提出建议。所有修改必须用户确认。

Semi-Auto：
AI 可以自动读文件、搜索、生成 patch proposal。写入、删除、重命名、commit、push、build 必须确认。

Auto：
AI 可以自动执行用户允许的工具，但危险操作仍然强制确认。

每个工具权限值：

deny：
禁止，AI 不能调用。

auto：
自动执行。

ask：
每次执行前问用户。

review：
AI 可以生成提案，但必须进 Review 队列，用户点 Apply 才执行。

manual_only：
只能用户手动点按钮触发，AI 不能主动触发。

默认权限建议：

list_files: auto
read_file: auto
search_in_files: auto
get_file_hash: auto
get_context_status: auto
ask_question: auto

propose_patch: auto
propose_create_file: review
propose_delete_file: ask
propose_rename_file: ask

apply_patch: review 或 manual_only
write_file: 不暴露给 AI
delete_file: ask 或 manual_only
rename_file: ask
create_file: review

git_commit: ask
git_push: ask
create_branch: ask
create_pull_request: ask
trigger_github_action: ask
cancel_build: ask
download_artifact: auto

read_api_key: deny
read_keychain: deny
modify_provider_profile: ask
delete_workspace: manual_only
access_outside_workspace: deny

危险操作硬规则：

即使 Auto 模式开启，也必须确认：
- 删除文件
- 重命名大量文件
- 修改 .env / .key / .pem / .p12 / .mobileprovision / secrets
- 修改 GitHub Actions workflow
- 修改签名配置
- 修改 provider profile
- 修改 .mobiledev/cache
- 修改超过 N 个文件
- 改动超过 N 行
- push 到 main/master
- 删除 workspace
- 触发付费构建或大量 CI
- 任何超出用户明确需求范围的修改

ask_question 工具：

必须暴露 ask_question 工具。这个工具用于 AI 在不确定时询问用户。AI 不能自作主张扩大需求。

定义：

{
  "name": "ask_question",
  "description": "Ask the user a clarification question before taking action. Use this whenever the requirement is ambiguous, risky, or outside the user's explicit request.",
  "parameters": {
    "type": "object",
    "properties": {
      "question": { "type": "string" },
      "reason": { "type": "string" },
      "options": {
        "type": "array",
        "items": { "type": "string" }
      },
      "blocking": { "type": "boolean" }
    },
    "required": ["question", "reason", "blocking"]
  }
}

AI 必须遵守：

- 用户没让改的，一定不能改。
- 需求不明确，必须 ask_question。
- 不确定该改哪个文件，必须 ask_question。
- 发现可能需要改超出范围的文件，必须 ask_question。
- 不确定是否要同步 GitHub，必须 ask_question。
- 不确定是否要 commit / push / trigger build，必须 ask_question。
- 不能为了“顺手优化”擅自扩大修改范围。
- 不能删除、重命名、推送、构建，除非权限和用户确认允许。
- 不能读取密钥和 API Key。
- 不能访问 workspace 外路径。

系统提示词里必须包含：

“You must not modify files beyond the user's explicit request.
If the request is ambiguous, call ask_question before proposing or applying changes.
If a change may affect behavior outside the requested scope, call ask_question.
If you are unsure which file, framework, branch, build target, or style to use, call ask_question.
Never delete, rename, push, commit, or trigger builds without permission.
Never access files outside the current workspace.
Never read secrets, API keys, Keychain items, or provider credentials.”

Patch 修改机制：

AI 修改文件不能直接 write。必须走 patch proposal。

流程：

1. AI read_file，拿到内容和 baseHash。
2. AI search_in_files，定位相关位置。
3. AI propose_patch，带 path、baseHash、diff、reason。
4. App 校验 path。
5. App 校验 baseHash 是否等于当前文件 hash。
6. App 在临时副本尝试应用 diff。
7. 如果应用失败，返回 patch failure 给 AI，让 AI 重新生成。
8. 如果成功，进入 Patch Queue。
9. UI 展示 diff。
10. 用户选择 Apply / Reject / Edit / Apply Partially / Ask AI to revise。
11. 用户点 Apply 后，App 自动创建 snapshot。
12. App 写入本地文件。
13. App 更新 file hash、repo map、context index、cache prefix 状态。
14. 可选 commit / push / trigger build。

PatchProposal 结构：

{
  "type": "patch_proposal",
  "title": "修复登录按钮重复点击问题",
  "changes": [
    {
      "path": "Sources/App/LoginView.swift",
      "operation": "modify",
      "baseHash": "abc123",
      "diff": "@@ -18,7 +18,11 @@\n- Button(\"Login\") {\n-     login()\n- }\n+ Button(\"Login\") {\n+     guard !isLoading else { return }\n+     isLoading = true\n+     login()\n+ }\n"
    }
  ],
  "reason": "防止用户重复点击导致多次请求。"
}

支持三种修改格式：

1. Unified Diff
适合修改已有文件，默认优先。

2. File Operations JSON
适合新建、删除、重命名。

3. Whole File Replace
只允许小文件或用户明确同意时使用。大文件不能默认整文件覆盖。

Patch Engine 要支持：

- strict apply
- fuzzy apply
- patch conflict detection
- baseHash check
- protected path check
- binary file detection
- large file detection
- snapshot before apply
- rollback
- partial apply
- diff preview

上下文管理：

这是项目核心。不要每次随便把所有文件塞给模型。必须有 Context Engine。

Context Engine 负责：

- 扫描文件树
- 识别语言和项目类型
- 生成 repo map
- 生成 symbol index
- 生成 dependency summary
- 生成重要文件摘要
- 维护 ai_memory.md
- 维护 rules.md
- 根据当前任务选择相关文件
- 控制 token budget
- 生成稳定 prompt prefix
- 记录 prefix hash
- 分析缓存命中/失效原因

上下文分层：

Static Prefix Block：
稳定内容，放 prompt 最前面，尽量不变，用于缓存命中。
包括：
- system prompt
- tool schema
- provider constraints
- project rules
- dependency summary
- stable file tree
- repo map
- key file summaries
- coding style
- ai_memory

Dynamic Task Block：
变化内容，放后面。
包括：
- 用户当前问题
- 当前打开文件
- 相关代码片段
- 当前 diff
- CI 错误日志
- 最近失败 patch
- 用户临时指令

Prompt 拼接顺序必须是：

[固定系统提示词]
[固定工具 schema]
[权限规则]
[项目规则]
[稳定排序的文件树]
[稳定 repo map]
[关键文件摘要]
[依赖摘要]
[AI memory]
--------------------
[当前任务]
[当前打开文件]
[相关代码片段]
[当前 diff]
[CI 报错日志]
[用户要求]

原因：
很多模型和服务商的 prompt caching / context caching 依赖重复前缀。静态内容必须在前，动态内容必须在后。不要把用户当前问题放到最前面。不要每次随机排序文件树。不要每次插入时间戳。不要每次改变工具 schema 顺序。不要把临时日志放进 prefix 前面。

Context Budget Manager：

根据模型上下文和用户设置自动选择上下文规模：

Small：
- system prompt
- tools
- project rules
- repo map
- 当前文件
- 相关少量片段

Medium：
- Small
- 相关文件
- 最近 diff
- 编译错误

Large：
- Medium
- 关键文件摘要
- dependency summary
- 更完整 repo map

Huge：
- 不全塞
- 使用 search / symbol index / retrieval
- 只带相关片段
- 必须保护 prefix 稳定

Cache Engine：

必须做缓存观测，不只是发 API。

每次请求记录：

- provider
- model
- apiStyle
- promptTokens
- completionTokens
- cachedTokens
- cacheMissTokens
- cacheHitRate
- prefixHash
- repoSnapshotHash
- toolSchemaHash
- projectRulesHash
- fileTreeHash
- symbolIndexHash
- staticPrefixTokenCount
- dynamicTokenCount
- estimatedCost
- estimatedSavedCost
- latencyMs
- timeToFirstTokenMs
- cacheStrategy
- cacheMissReason

缓存策略：

1. automatic_prefix
适合 OpenAI-style / DeepSeek-style 重复前缀缓存。
要求：
- 静态内容放最前面
- prefix 稳定
- 工具 schema 稳定
- 文件树排序稳定
- 不要插入随机 ID / 时间戳

2. explicit_cache_control
适合 Claude-style cache_control。
要求：
- 对不同稳定块设置 cache breakpoint
- system / tools / project rules / repo map 可以作为 cacheable blocks
- 动态任务不要放进 cache block

3. no_provider_cache_info
服务商不返回 cached_tokens。
要求：
- 本地估算 prefixHash 是否复用
- 显示“预计命中”，但明确这是估算

4. disabled
用户关闭缓存优化。

Cache Dashboard UI：

显示：
- 本次 cached tokens
- cache hit rate
- prefix hash
- 哪些 block 变了
- 为什么没命中
- 预计省了多少钱
- 预计减少了多少延迟
- provider 是否返回真实缓存数据

示例：

Provider: DeepSeek
Model: deepseek-v4-pro
Prompt tokens: 82,000
Cached tokens: 71,000
Cache hit rate: 86.5%
Prefix hash: a8f3...
Repo snapshot: unchanged
Tool schema: unchanged
Dynamic tokens: 9,800
Estimated saved cost: ¥0.42
Latency saved: 6.8s

缓存未命中原因示例：

- system prompt changed
- tool schema changed
- provider profile changed
- model changed
- repo map order changed
- project rules changed
- dynamic content inserted before static prefix
- current timestamp inserted into prefix
- file tree changed
- key file summary regenerated with unstable wording

UI 页面：

1. Projects
本地工程列表。
显示：
- Local Only
- Linked to GitHub
- Ahead / Behind
- Context Ready
- Cache Prefix Stable
- Last AI Run
- Last Snapshot

2. Workspace
工程首页。
显示：
- 文件树
- 最近 patch
- GitHub 状态
- 构建状态
- 上下文状态

3. Files
文件浏览和轻编辑。
支持：
- 文件树
- 搜索
- 打开文件
- 基础代码高亮
- 大文件提示
- binary 文件提示

4. Chat
AI 对话。
支持：
- 当前 workspace 上下文
- 当前文件上下文
- 工具调用状态
- ask_question 弹窗
- reasoning content 可折叠显示
- token / cache 统计

5. Patch Review
Patch 队列。
支持：
- diff preview
- Apply
- Reject
- Edit
- Apply Partially
- Ask AI to revise
- Rollback snapshot

6. Context
上下文仪表盘。
显示：
- repo map
- symbol index
- included files
- ignored files
- static prefix blocks
- token budget
- context freshness
- rebuild context button

7. Cache
缓存仪表盘。
显示：
- cache hit rate
- prefix hash
- token usage
- provider cache usage
- cache miss reason

8. Provider Profiles
AI API 配置。
支持：
- Base URL
- API Key
- Model
- API style
- Thinking mode mapping
- Reasoning depth mapping
- Web search mapping
- Cache usage path mapping
- Tool call mapping
- Extra headers
- Extra body params
- Test request

9. Permissions
权限设置。
支持：
- 全局 Manual / Semi-Auto / Auto
- 每个工具 deny / auto / ask / review / manual_only
- protected paths
- dangerous operation policy
- per-task permissions

10. GitHub Sync
可选 GitHub 功能。
支持：
- Link repo
- branch
- commit
- push
- pull
- create PR
- trigger workflow_dispatch
- read Actions logs
- download artifacts

GitHub 设计：

GitHub 不是主状态。
本地 workspace 是主状态。

GitHub 功能：

- 读取 repo 文件
- 拉取到本地 workspace
- 本地修改
- 用户确认 commit
- 可选 push 到 branch
- 可选 create PR
- 可选 trigger workflow_dispatch
- 可选查看 logs / artifacts

不要让 AI 默认 push。
不要让 AI 默认触发 Actions。
不要让 AI 默认改 main/master。

用户工程的构建产物不固定：
- 可能是 exe
- 可能是 apk
- 可能是 ipa
- 可能是 dmg
- 可能是 docker image
- 可能是 zip
- 可能只是 test report

App 只负责触发和观察 CI，不要假装知道所有工程怎么构建。

建议支持仓库内配置：

.mobiledev/builds.json

{
  "name": "My Project",
  "builds": [
    {
      "name": "Windows EXE",
      "workflow": "build-windows.yml",
      "artifact": "*.exe"
    },
    {
      "name": "Linux Binary",
      "workflow": "build-linux.yml",
      "artifact": "*.tar.gz"
    }
  ]
}

这个 iOS App 自己的 GitHub Actions：

需要生成 workflow：
.github/workflows/build-ios.yml

要求：
- runs-on: macos-26
- xcode-select Xcode_26.4
- xcodebuild -version
- xcrun --sdk iphoneos --show-sdk-version
- build / archive
- export IPA
- upload artifact

注意签名：
- 如果有证书和 provisioning profile，用 secrets 导入 keychain 后 archive/export。
- 如果没有签名，只能 build simulator 或生成不可安装 artifact。必须明确说明。

安全设计：

- API Key 放 Keychain
- GitHub Token 放 Keychain
- 不允许 AI read_api_key
- 不允许 AI read_keychain
- 不允许 AI access_outside_workspace
- 所有文件操作经过 WorkspaceFS
- 所有 patch 应用前 snapshot
- 所有危险操作写审计日志
- 所有 AI tool call 记录到 agent run log
- 删除操作二次确认
- push main/master 二次确认
- 修改 workflow / signing / secrets 二次确认

数据模型建议：

Workspace:
- id
- name
- rootURL
- mode: localOnly / linkedToGitHub / githubMirror
- createdAt
- updatedAt
- activeProviderProfileId
- githubRemote
- currentBranch
- contextStatus
- cacheStatus

ProviderProfile:
- id
- name
- apiStyle
- baseURL
- endpoint
- authConfig
- modelProfiles
- requestMapping
- responseMapping
- usageMapping
- extraHeaders
- extraBody

ModelProfile:
- id
- displayName
- supportsReasoning
- reasoningMapping
- supportsCache
- cacheStrategy
- supportsTools
- supportsStreaming
- maxContextTokens
- maxOutputTokens

ToolPolicy:
- toolName
- permission
- protectedPaths
- maxFilesWithoutConfirmation
- maxChangedLinesWithoutConfirmation
- requireConfirmationOnMainBranch

Patch:
- id
- workspaceId
- title
- reason
- status: pending / applied / rejected / failed
- changes
- createdAt
- appliedAt
- sourceConversationId

Snapshot:
- id
- workspaceId
- createdAt
- reason
- fileHashes
- changedFiles
- patchId
- conversationId

ContextBlock:
- id
- type
- stable
- contentHash
- tokenCount
- order
- lastUpdated

CacheRecord:
- id
- provider
- model
- prefixHash
- promptTokens
- cachedTokens
- cacheMissTokens
- outputTokens
- latencyMs
- estimatedCost
- createdAt
- missReason

MVP 范围：

第一版不要做太大。先实现：

1. 本地 workspace 创建。
2. 导入 zip 或创建空工程。
3. 文件树 + read file。
4. Provider Profile 配置 OpenAI-compatible。
5. Chat 页面。
6. 工具调用：
   - list_files
   - read_file
   - search_in_files
   - ask_question
   - propose_patch
7. Patch Review。
8. Apply patch with snapshot。
9. Context prefix builder。
10. Cache stats 记录。
11. GitHub link / push 可以先做最小版。
12. GitHub Actions 构建这个 App 的 IPA。

第二版：

- GitHub pull / branch / PR / Actions logs / artifacts
- Claude explicit cache_control
- 更完整 Provider Profile Editor
- Tree-sitter / symbol index
- Fuzzy patch apply
- Local git support
- CI error auto-fix loop
- More Liquid Glass polish

第三版：

- 多模型对比
- local embeddings
- repo semantic search
- task scope lock
- per-file permissions
- build artifact manager
- plugin system

特别注意：

不要因为用户说“AI 可自定义调用代码”就让 AI 直接执行任意脚本。本项目里所谓“工具调用”是受控的 App 内部 Swift 工具，例如 read_file、search、propose_patch，而不是 shell。iOS 上不要开放任意 shell。对于远程 CI，也必须用户确认。

不要因为用户说“本地仓库”就强行实现完整 Git。第一版可以是本地 Workspace + snapshot + diff。Git 支持可以逐步加。GitHub 同步第一版可以走 GitHub API，不一定内置 libgit2。

不要因为用户说“缓存命中”就做 HTTP 缓存。这里重点是 LLM prompt/context caching。要通过稳定 prompt prefix、固定工具 schema、稳定 repo map、静态内容前置、动态内容后置来提高服务商的 KV/prompt cache 命中率。

最终你要交付：

1. 清晰的项目架构。
2. SwiftUI iOS 26.4 工程骨架。
3. 正确使用 Liquid Glass 的 UI 组件，不要假玻璃。
4. WorkspaceFS。
5. Provider Profile 系统。
6. AI Tool Call 解析和执行器。
7. Permission Manager。
8. ask_question 工具。
9. Patch Engine。
10. Context Engine。
11. Cache Engine。
12. GitHub Actions build-ios.yml。
13. README，说明如何配置 API、如何配置签名、如何构建 IPA。
14. 不确定的 API 必须标注并要求查官方文档，不允许编造。

直接开始写代码并使用githubaction构建。写代码时优先保证能编译，不要堆不存在的 API。Liquid Glass 相关代码必须使用 iOS 26 官方 SwiftUI API；如果当前环境无法确认 API，可先写带 @available(iOS 26.0, *) 的封装，并把具体实现集中在一个 LiquidGlassUI.swift 文件里，方便替换和修正。
```
