# macOS 与 iOS 用户功能对齐 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 补齐 iOS 的注册、完整消息操作、消息通知跳转和真实 TLS 连接检测，同时保持现有 Socket 协议和其他端行为兼容。

**Architecture:** 在现有仓库协议上增加向后兼容的可选方法和字段；本地删除、清空、通知和导航留在 iOS，撤回继续使用既有 `0x59/0x5A/0x5B`，引用继续使用 `0x50/0x51` JSON。所有新增网络探测都使用独立 TLS 控制连接。

**Tech Stack:** Swift 6、SwiftUI、Observation、Network.framework、UserNotifications、XCTest、Java 8、JUnit 5。

---

### Task 1: 注册链路

**Files:**
- Modify: `ChatStorage/Features/Authentication/AuthModels.swift`
- Modify: `ChatStorage/Features/Authentication/AuthRepository.swift`
- Modify: `ChatStorage/Features/Authentication/RemoteAuthRepository.swift`
- Modify: `ChatStorage/Features/Authentication/LoginViewModel.swift`
- Modify: `ChatStorage/Features/Authentication/LoginView.swift`
- Modify: `ChatStorage/App/AppContainer.swift`
- Test: `ChatStorageTests/Authentication/RemoteAuthRepositoryTests.swift`
- Test: `ChatStorageTests/Authentication/LoginViewModelTests.swift`

- [ ] 写 `RemoteAuthRepository.register` 的失败测试：断言发送 `0x30`、字段为 `userName/password/mail/avatarData/avatarName`，且成功响应不写 Keychain。
- [ ] 运行注册专项测试，确认因 `register` 不存在而失败。
- [ ] 增加 `RegisterRequest`、仓库方法、注册验证状态机和移动端注册表单；注册成功只回填账号，不调用 `AppSession.authenticate`。
- [ ] 重跑注册专项测试，确认通过。

### Task 2: 消息引用、复制、本地删除、撤回和清空

**Files:**
- Modify: `ChatStorage/Features/Messages/ChatModels.swift`
- Modify: `ChatStorage/Features/Messages/RemoteChatRepository.swift`
- Modify: `ChatStorage/Features/Messages/CachedChatRepository.swift`
- Modify: `ChatStorage/Features/Messages/ChatConversationViewModel.swift`
- Modify: `ChatStorage/Core/Persistence/ChatCacheStore.swift`
- Modify: `ChatStorage/Features/Chat/ChatConversationView.swift`
- Modify: `ChatStorage/Features/Messages/MessagesViewModel.swift`
- Test: `ChatStorageTests/Messages/RemoteChatRepositoryTests.swift`
- Test: `ChatStorageTests/Chat/ChatConversationViewModelTests.swift`
- Test: `ChatStorageTests/Persistence/ChatCacheStoreTests.swift`
- Test: `ChatStorageTests/Messages/MessagesViewModelTests.swift`

- [ ] 写引用编码、撤回请求/推送解码、缓存删除/清空/撤回、视图模型引用发送与失败恢复测试。
- [ ] 运行聊天专项测试，确认新增行为按预期失败。
- [ ] 增加 `ChatQuote`、`ChatMessageAction`、可选引用发送方法和动作广播；缓存层实现账号/好友隔离的删除、清空和撤回。
- [ ] 在聊天 UI 增加长按菜单、引用块、引用输入预览、撤回态和清空确认提示。
- [ ] 重跑聊天专项测试，确认通过。

### Task 3: net-server 引用字段兼容透传

**Files:**
- Modify: `/Users/hljy/IdeaProjects/code/net-server/src/main/java/com/alibaba/server/nio/service/file/handler/TextTransmissionHandler.java`
- Test: `/Users/hljy/IdeaProjects/code/net-server/src/test/java/com/alibaba/server/nio/service/file/handler/TextTransmissionHandlerHistoryContractTest.java`

- [ ] 写合同测试，要求 `0x50` 请求中的三个引用字段进入 `0x51` 推送构造逻辑。
- [ ] 用 Zulu Java 8 跑专项测试，确认测试先失败。
- [ ] 在现有发送处理里校验长度并透传可选引用字段，不改数据库和帧编号。
- [ ] 重跑专项测试和 net-server 全量测试。

### Task 4: 消息通知与点击跳转

**Files:**
- Modify: `ChatStorage/Features/Profile/NotificationPermission.swift`
- Modify: `ChatStorage/App/ChatStorageApp.swift`
- Modify: `ChatStorage/Features/Shell/MainShellView.swift`
- Modify: `ChatStorage/Features/Messages/MessagesPlaceholderView.swift`
- Test: `ChatStorageTests/Profile/ProfileSettingsViewModelTests.swift`
- Test: `ChatStorageTests/SmokeTests.swift`

- [ ] 写通知内容隐私、仅通知对方消息、路由保留/消费的失败测试。
- [ ] 运行通知专项测试，确认类型和行为尚不存在。
- [ ] 实现系统通知投递器、AppDelegate 点击回调、待处理好友路由、Tab 选择和 NavigationStack 跳转。
- [ ] 重跑通知专项测试，确认通过。

### Task 5: 服务器 TLS 连接检测

**Files:**
- Modify: `ChatStorage/Features/Settings/ServerSettingsView.swift`
- Test: `ChatStorageTests/Networking/ServerConfigurationTests.swift`

- [ ] 写独立连接成功会断开、连接失败也会清理、候选配置校验的失败测试。
- [ ] 运行网络专项测试，确认测试先失败。
- [ ] 实现 `TLSServerConnectionTester` 和页面状态；按钮只探测候选控制端口，不保存也不复用当前登录连接。
- [ ] 重跑网络专项测试，确认通过。

### Task 6: 全局回归与交接

**Files:**
- Modify: `ChatStorage.xcodeproj/project.pbxproj` only if existing target membership requires it
- Modify: `/Users/hljy/.Codex/session-data/<dated-session>.md`

- [ ] 检查 macOS/iOS 功能矩阵，逐项核对没有漏项。
- [ ] 跑 iOS 全量 XCTest，要求 0 失败。
- [ ] 跑普通 iOS Simulator build，要求 `BUILD SUCCEEDED`。
- [ ] 用 Zulu Java 8 跑 net-server 全量测试和 `package`，要求 0 失败且 fat JAR 可启动入口不变。
- [ ] 跑两仓库 `git diff --check` 和敏感信息扫描，记录未执行的真机/UI 人工验证。
- [ ] 写会话交接文件，列出完成项、文件、下一步和注意点；不提交、不暂存用户现有改动。
