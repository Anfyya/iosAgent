# LocalAIWorkspace

LocalAIWorkspace 是一个本地优先的 iOS SwiftUI AI 工程工作台。当前仓库包含：

- SwiftUI App 壳与集中封装的 `LiquidGlassUI.swift`
- 本地 workspace 文件边界与文本工具链
- OpenAI-compatible 请求/响应适配与真实 `AIClient`
- 持久化 patch queue / agent run 核心逻辑
- patch snapshot / restore
- context prefix / cache usage 记录
- GitHub Actions 的 Swift Package 测试、XcodeGen 校验、iOS Simulator 构建、可选签名归档

## 当前已实现的核心能力

### 本地优先架构

- `WorkspaceFS` 只允许访问当前 workspace 根目录
- 拒绝绝对路径、`..` 路径穿越、符号链接逃逸
- protected path 默认不可读写
- 二进制文件与超大文件不会被内联进工具结果

### AI Provider

- `ProviderProfile` 支持 OpenAI-compatible profile
- 请求支持：
  - `model`
  - `messages`
  - `temperature`
  - `max_tokens`
  - `stream`
  - `tools`
  - `tool_choice`
  - reasoning 字段映射
  - web search 字段映射
  - extra headers / extra body parameters
- 响应支持解析：
  - `choices[0].message.content`
  - `reasoning_content`
  - `tool_calls`
  - `usage.prompt_tokens`
  - `usage.completion_tokens`
  - `usage.total_tokens`
  - `usage.prompt_tokens_details.cached_tokens`
  - `usage.cached_tokens`
  - `usage.prompt_cache_hit_tokens`
  - `usage.prompt_cache_miss_tokens`

### Agent / Patch

- `AgentLoop` 支持多轮 tool loop
- `ask_question` 会阻塞 run，等待用户恢复
- `propose_patch` 会写入真实 `PatchStore`
- `PatchEngine` 应用 patch 前会自动创建 snapshot
- `PatchEngine.restore` 可用 snapshot 回滚
- protected path patch 需要显式确认

### Context / Cache

- `ContextEngine` 保持稳定前缀块顺序
- `CacheEngine` 接收真实 usage 数据
- prefix hash / repo snapshot hash / tool schema hash 会进入 cache record

## 仓库结构

- `App/`：SwiftUI App 壳与 Liquid Glass UI
- `Sources/LocalAIWorkspace/`：workspace、AI、agent、patch、context、cache 核心逻辑
- `Tests/LocalAIWorkspaceTests/`：Swift Package 单元测试
- `project.yml`：XcodeGen 配置
- `.github/workflows/build-ios.yml`：CI

## 本地开发

### 运行核心测试

```bash
swift test
```

### 生成 Xcode 工程

```bash
brew install xcodegen
xcodegen generate
open LocalAIWorkspace.xcodeproj
```

## CI

`build-ios` workflow 当前会执行：

1. `swift test`
2. `xcodegen generate`
3. iOS Simulator build
4. 上传 `xcresult` / DerivedData
5. 当签名 secrets 完整时再执行 archive / export IPA

Simulator 设备会在 runner 上动态选择常见可用机型，不再写死 `iPhone 17`。

## 安全边界

- AI 不应直接写文件；必须通过 patch proposal
- AI 不应访问 workspace 外路径
- `.mobiledev` / credentials / workflow 等 protected path 默认需要确认
- API Key 不应写入普通配置文件
- 删除、重命名、push、触发 workflow 都应经过显式确认

## 已知限制

- 当前 App UI 仍需继续把这些核心服务完整接到真实 iPhone 交互流程
- 目前只实现了 OpenAI-compatible `AIClient`
- GitHub sync / Actions viewer 的 App 内 UI 还没有完全接通
- Provider Profile 编辑器、Keychain UI、workspace 导入/管理 UI 仍需继续补齐

## Liquid Glass 约束

- 自定义 Liquid Glass API 继续集中在 `App/LiquidGlassUI.swift`
- 仅用于导航/操作层，不覆盖代码区主体
- 低版本或可访问性场景回退到系统 Material
