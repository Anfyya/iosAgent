# LocalAIWorkspace

LocalAIWorkspace 是一个 **本地优先的 iOS 26.4 SwiftUI AI 工程工作台** MVP 骨架。

## 当前交付内容

- SwiftUI App Shell：Projects / Workspace / Chat / Patch Review / Context / Cache / Settings
- `LiquidGlassUI.swift`：集中封装 Liquid Glass，自定义玻璃仅用于导航/操作层
- `WorkspaceFS`：限制访问当前 workspace、阻止路径穿越、保护敏感路径
- Provider Profile 系统：支持 OpenAI-compatible profile + schema-driven model metadata
- Tool Call 基础设施：`list_files` / `read_file` / `search_in_files` / `ask_question` / `propose_patch` / `get_context_status`
- `PermissionManager`：工具级权限 + 危险路径硬规则
- `PatchEngine`：基于 `baseHash` 的 patch proposal 应用、snapshot 备份、创建/删除/重命名支持
- `ContextEngine`：固定前缀块顺序、稳定哈希、repo/file summary 构建
- `CacheEngine`：缓存命中统计与 miss reason 追踪
- GitHub Actions：`macos-26` + `Xcode_26.4` + XcodeGen 生成工程 + simulator build + signed archive/export 条件流程

## 目录结构

- `App/`：SwiftUI App 壳层与 Liquid Glass UI 封装
- `Sources/LocalAIWorkspace/`：MVP 核心模型与服务
- `Tests/LocalAIWorkspaceTests/`：Linux 环境可运行的核心单元测试
- `project.yml`：XcodeGen 配置，CI 上生成 iOS App 工程
- `.github/workflows/build-ios.yml`：iOS 26.4 CI 构建工作流

## Liquid Glass 说明

本仓库将所有自定义 Liquid Glass 代码集中在 `App/LiquidGlassUI.swift`：

- 优先使用系统 `TabView` / `NavigationStack`
- 自定义浮层在 `if #available(iOS 26.0, *)` 下使用 `GlassEffectContainer` 与 `glassEffect(_:in:)`
- 当开启 Reduce Transparency 或运行在更低版本时，回退到系统 Material

> 当前开发环境无法直接运行 Xcode 26.4 SDK 校验，因此将官方 Liquid Glass 调用集中封装在单文件中，方便在 macOS + Xcode 26.4 上验证后微调签名或参数，而不污染业务层。

## 本地开发

### 运行核心测试

```bash
swift test
```

### 生成 Xcode 工程

需要在 macOS + Xcode 26.4 环境：

```bash
brew install xcodegen
xcodegen generate
open LocalAIWorkspace.xcodeproj
```

## Provider Profile 设计

Provider Profile / Model Profile 采用 schema-driven 方式，不把某一家 API 的字段名写死在 UI：

- `apiStyle`
- `auth`
- `requestFieldMapping`
- `responseFieldMapping`
- `usageFieldMapping`
- `ReasoningMapping`
- `CacheStrategy`
- `extraHeaders`
- `extraBodyParameters`

## 签名与 IPA 构建

工作流包含两个阶段：

1. **Simulator Build**：始终执行，验证工程至少可以在无签名环境完成 iOS Simulator 编译。
2. **Signed Archive / Export IPA**：仅当以下 Secrets 全部存在时执行：
   - `IOS_CERTIFICATE_P12_BASE64`
   - `IOS_CERTIFICATE_PASSWORD`
   - `IOS_PROVISIONING_PROFILE_BASE64`
   - `IOS_KEYCHAIN_PASSWORD`
   - `IOS_TEAM_ID`

如未提供签名 Secrets，CI 会明确只产出 simulator build artifact，不假装导出可安装 IPA。

## 后续优先级

1. 真实本地 workspace 管理与导入 zip
2. Chat -> tool loop -> patch queue 的状态持久化
3. Provider Profile 编辑器 UI
4. GitHub link / branch / PR / Actions logs / artifact viewer
5. SwiftData 持久化 context/cache/patch history
