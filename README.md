# LocalAIWorkspace

LocalAIWorkspace 是一个面向 iOS 26.4 的本地优先 AI 工程工作台：它可以管理本地 workspace、导入 ZIP / Files App 文件、配置自定义 OpenAI-compatible Provider、让 AI 用受控工具读取上下文并产出 patch proposal、让用户审核应用 patch、记录 Context / Cache 命中，并可选连接 GitHub 完成 commit / push / PR / Actions / artifacts 流程。

## 产品定位

- **本地优先**：工程文件始终位于本地 `workspace/files`
- **安全边界明确**：AI 不直接写文件，只能 `propose_patch`
- **人工确认**：高风险操作必须 ask / review / 二次确认
- **可审计**：导入、Provider、Patch、GitHub、权限操作都会写审计日志
- **可缓存**：稳定 prefix、repo snapshot、tool schema、project rules 会进入 cache record

## 架构概览

### 本地数据布局

每个 workspace 都会创建：

- `workspace/files/`：项目文件
- `workspace/.mobiledev/workspace.json`：workspace 元数据
- `workspace/.mobiledev/context/latest_snapshot.json`：最近一次 ContextSnapshot
- `workspace/.mobiledev/cache_records.json`：真实 cache 记录历史
- `workspace/.mobiledev/patches.json`：patch proposal 队列
- `workspace/.mobiledev/snapshots.json`：patch apply 生成的 snapshot 索引
- `workspace/.mobiledev/github/remote.json`：GitHub remote 配置（**不含 token**）
- `workspace/.mobiledev/logs/audit.jsonl`：审计日志

### 安全模型

- `WorkspaceFS` 拒绝绝对路径、`..`、符号链接逃逸
- `.github/workflows`、敏感路径、受保护路径默认需要确认
- API Key / GitHub Token 使用 Keychain，不写普通 JSON 文件
- AI 不可读取 Keychain / Token / workspace 外路径
- 删除、重命名、commit/push/PR/Actions 走人工确认路径

## Liquid Glass 说明

- `App/LiquidGlassUI.swift` 继续作为唯一的 Liquid Glass 封装入口
- iOS 26 使用 `GlassEffectContainer` / `glassEffect`
- Reduce Transparency 或降级场景自动 fallback 到系统 Material
- 玻璃效果只用于导航层、状态卡片、操作面板
- 不对代码编辑主体做整屏玻璃覆盖

## 用户主流程

### 1. 创建 Workspace

1. 打开 **Projects**
2. 输入名称并点击 **Create**
3. App 会创建本地 workspace 目录与 `.mobiledev` 元数据

### 2. 导入 ZIP / Files App 文件

在 **Workspace** 页：

- 点击 **Import Files**：从 Files App 多选文件或文件夹复制到 `workspace/files`
- 点击 **Import ZIP**：导入 zip 并解压到 `workspace/files`

导入特性：

- 默认冲突策略为 **keep both**
- 自动忽略 `__MACOSX` 与 `.DS_Store`
- ZIP 导入会在解压前检查路径，拒绝 `../`、绝对路径等 zip slip
- 导入完成后自动刷新文件树、ContextSnapshot、搜索结果

### 3. 浏览 / 编辑工程

在 **Workspace** 页：

- 文件树按目录缩进展示，支持展开折叠
- 顶部可按路径搜索
- 内容搜索结果支持点击打开文件
- 选中文本文件后可直接编辑并保存
- 切换文件时如果有未保存内容，会提示保存或丢弃
- 新建文件 / 文件夹时空路径会被拒绝
- 删除操作会确认
- 二进制文件或超大文件不会进入文本编辑主流程

### 4. 配置自定义 AI Provider

在 **Settings** → **Provider Profiles**：

可完整配置：

- Provider 基础字段：
  - name
  - apiStyle
  - baseURL
  - endpoint
  - auth type
  - auth key name
  - API Key
  - supportsStreaming
  - supportsToolCalling
  - supportsJSONMode
  - supportsVision
  - supportsReasoning
  - supportsPromptCache
  - supportsExplicitCacheControl
  - supportsWebSearch
- Request / Response / Usage 字段映射
- Extra Headers（可增删 key/value）
- Extra Body Parameters（dotted path + JSON value）
- 多个模型配置：
  - model id / displayName
  - maxContextTokens / maxOutputTokens
  - reasoning 开关字段 / 深度字段 / levels
  - cache strategy
  - tool / streaming 支持
  - model extraParameters

### 5. API Key 与 Token 存储

- Provider API Key 存 Keychain：`service=LocalAIWorkspace.provider`
- GitHub Token 存 Keychain：`service=LocalAIWorkspace.github`
- `remote.json` 只保存 `tokenReference`，不保存 token 明文
- 导出 ProviderProfile JSON 时不会包含 API Key 明文
- 导入 ProviderProfile JSON 后要求重新输入 API Key

### 6. Test Connection

Provider 编辑器右上角可点击 **Test**：

- 使用当前 provider + model 发送最小请求
- 成功时显示模型名、usage / latency 摘要
- 失败时展示 provider 返回的 error message
- UI 不会回显 API Key

## Chat / Agent / Patch 流程

### 支持的工具

当前工具链会把以下 schema 真实传给模型：

- `list_files`
- `read_file`
- `search_in_files`
- `get_context_status`
- `ask_question`
- `propose_patch`

### Prompt / Context 如何构建

每次开始聊天前，App 会：

1. 重新构建 `ContextSnapshot`
2. 生成稳定顺序的 static prefix
3. 用 `PromptBuilder` 拼接：

```
[STATIC PREFIX START]
system rules
tool schema text
permission rules
project rules
stable file tree
repo map
key file summaries
dependency summary
ai memory
workspace metadata
[STATIC PREFIX END]

[DYNAMIC TASK START]
current task
opened files
related snippets
current diff
ci logs
user requirements
[DYNAMIC TASK END]
```

关键保证：

- static prefix 永远排在 dynamic task 前
- 当前任务变化不会污染 `prefixHash`
- 不会把当前时间戳塞进 static prefix
- 不会把 API Key / GitHub Token 拼进 messages
- `ContextEngine` 与 `CacheEngine` 使用同一份 `ContextSnapshot`

### ask_question 如何工作

- 当需求不明确、范围不清、目标文件不确定时，模型应调用 `ask_question`
- `ask_question` 会阻塞当前 run
- 用户在 Chat 页回答后，AgentLoop 才会继续

### 权限确认如何工作

默认策略：

- `git_commit`: ask
- `git_push`: ask
- `create_pull_request`: ask
- `trigger_github_action`: ask
- `download_artifact`: auto

此外：

- destructive patch / 受保护路径 / workflow 修改 / push main/master 都会升级确认级别
- ask 权限不会先执行再询问

## Patch Review

在 **Patch Review** 页会分区显示：

- Pending
- Applied
- Rejected
- Failed

每个 patch 会显示：

- title
- reason
- status
- changedFiles
- changedLines
- agentRunID
- snapshotID
- errorMessage
- 真实 diff / newContent / rename 说明

可执行操作：

- **Apply**：应用 patch，并创建 snapshot
- **Reject**：标记为 rejected
- **Ask AI to Revise**：把当前 proposal diff 带回 Chat 输入框继续修订
- **Restore Snapshot**：对已应用 patch 执行回滚

Apply 之后：

- `PatchEngine` 会先创建 snapshot
- 文件会真实写入本地 workspace
- proposal 状态会更新为 `applied`
- Context / Cache / 文件树会刷新

Reject 之后：

- proposal 状态会更新为 `rejected`

Rollback 之后：

- snapshot 对应的文件会恢复到 apply 前状态

## Context 页面

**Context** 页展示真实 ContextSnapshot：

- prefixHash
- repoSnapshotHash
- fileTreeHash
- toolSchemaHash
- projectRulesHash
- staticTokenCount
- dynamicTokenCount
- includedFiles
- ignoredFiles
- blocks 列表：
  - type
  - stable / dynamic
  - tokenCount
  - contentHash
  - 展开后可预览 content

## Cache 页面

每次 AI 返回 usage 后，App 会用：

- active ProviderProfile
- active ModelProfile
- 当前 ContextSnapshot
- previous CacheRecord

调用 `CacheEngine.makeRecord` 并写入 `FileCacheRecordStore`。

Cache 页展示：

- provider / model
- promptTokens / completionTokens / totalTokens
- cachedTokens / cacheMissTokens
- hitRate
- prefixHash
- repoSnapshotHash
- fileTreeHash
- toolSchemaHash
- projectRulesHash
- staticTokenCount / dynamicTokenCount
- latency
- missReasons
- history 列表

如果 provider 不声明 prompt cache，UI 会明确提示；如果 provider 支持但没有返回 cached token 字段，也只会显示 prefix hash 估算，不会使用假数据。

## GitHub Sync / Actions / Artifacts

在 **GitHub** 页可以：

1. 输入 owner / repo / branch / token 并 **Link Repo**
2. 预览 commit summary
3. **Commit & Push** 当前 workspace/files 到目标 branch
4. 创建 Pull Request
5. 查看 workflows
6. 触发 `workflow_dispatch`
7. 查看 workflow runs / jobs / artifacts
8. 读取 build buttons（见 builds.json）

### GitHub Push 说明

- App 通过 GitHub REST API 创建 blob / tree / commit / update ref
- 不做完整 clone / rebase
- 上传的是当前 `workspace/files` 文件树
- 默认忽略 `.mobiledev`
- 默认跳过 binary / 超大文件，并在 summary 中显示 skipped reason
- push 需要显式确认
- push `main` / `master` 需要二次确认
- AI 不会自动 push，必须由用户点击或显式批准

### Pull Request

可直接在 GitHub 页填写：

- PR title
- PR body

然后点击 **Create PR**。

### Workflow Dispatch

支持：

- 直接输入 workflow id / 文件名
- 指定 ref
- 输入 JSON 形式的 dispatch inputs

### Artifacts

可查看：

- artifact name
- size
- archive download URL / browser URL 元信息

## `.mobiledev/builds.json`

App 会按以下优先级加载构建配置：

1. `workspace/files/.mobiledev/builds.json`
2. `workspace/files/mobiledev-builds.json`
3. `workspace/.mobiledev/github/builds.json`

示例：

```json
{
  "name": "My Project",
  "builds": [
    {
      "name": "iOS Build",
      "workflow": "build-ios.yml",
      "ref": "main",
      "artifact": "*.ipa",
      "inputs": {
        "configuration": "release"
      }
    }
  ]
}
```

加载后会在 **GitHub** 页显示对应的构建按钮，点击即触发 workflow_dispatch。

## 审计日志

所有重要操作会写入：

- `workspace/.mobiledev/logs/audit.jsonl`

当前已记录的典型事件：

- workspace created
- files / zip imported
- provider saved / tested
- permission approved / denied
- patch applied / rejected / restored
- github linked
- github push
- pull request created
- workflow dispatched

可在 **Logs** 页查看最近 100 条。

## 本地开发

### Swift Package 测试

```bash
swift test
```

### 生成 Xcode 工程

```bash
brew install xcodegen
xcodegen generate
open LocalAIWorkspace.xcodeproj
```

### iOS 构建

项目保留现有 `.github/workflows/build-ios.yml`，CI 继续执行：

1. `swift test`
2. `xcodegen generate`
3. iOS Simulator build
4. 上传 `xcresult` / DerivedData
5. 当签名 secrets 完整时执行 archive / export IPA

## GitHub Actions 构建 IPA

当前 workflow 支持：

- Swift Package tests
- XcodeGen 生成工程
- iOS Simulator build
- 条件式 signed archive / export

### 签名相关 secrets

signed archive 仅在 secrets 完整时运行；具体 secrets 以 workflow 文件为准，通常包括：

- 证书或 p12 数据
- 证书密码
- provisioning profile 数据
- 导出选项配置
- 团队 / 签名相关参数

## 当前限制

- ZIP 解压当前依赖系统 `unzip` 能力；仓库里的 Swift Package 测试在 Linux runner 上已覆盖 zip slip / 忽略规则，但实际 iOS 设备仍需按 Xcode 构建结果继续校正平台差异
- GitHub push 目前是“当前 workspace 文件树全量 tree commit”模型，不做复杂 diff/rebase
- UI 已接通真实状态，但仍建议继续根据真机 / Xcode 编译反馈微调交互与布局
- 当前 AIClient 仍以 OpenAI-compatible provider 为主
- SwiftUI App 侧需要继续根据 CI / Xcode 报错修正编译细节

## 不再是 Skeleton / MVP

这个仓库现在面向“可交付、可操作”的本地优先工作台流程：

- 本地 workspace 管理
- ZIP / Files 导入
- 文件树浏览与文本编辑
- 自定义 Provider + Keychain secret
- Context / Cache 可视化
- ask_question / permission / patch review 闭环
- GitHub remote / push / PR / Actions / artifacts
- 构建按钮读取
- 审计日志留痕

如果 CI 或 Xcode 后续报出编译问题，优先按报错修正即可；主流程能力已不再依赖假数据或骨架说明。
