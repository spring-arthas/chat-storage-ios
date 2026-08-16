# 对话、网盘与动态增强 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增完整动态时间线，并把聊天和网盘内容接入发布动态与智能整理能力。

**Architecture:** iOS 使用独立 `Dynamics` 模块和主界面共享发布路由，复用现有附件上传/预览；net-server 在保留 `0x60/0x61` 的基础上补齐 `0x62-0x69`，互动数据使用独立表。

**Tech Stack:** Swift 6、SwiftUI、Observation、Network.framework、Java 8、Spring XML、MyBatis、MySQL 8、JUnit 5。

---

### Task 1: 锁定动态协议和客户端模型

**Files:**
- Create: `ChatStorage/Features/Dynamics/DynamicModels.swift`
- Create: `ChatStorage/Features/Dynamics/RemoteDynamicRepository.swift`
- Test: `ChatStorageTests/Dynamics/RemoteDynamicRepositoryTests.swift`
- Modify: `ChatStorage/Core/Protocol/FrameType.swift`

- [ ] 先写发布、时间线、互动、详情和删除的编码/解码失败测试。
- [ ] 运行动态仓库专项，确认因类型和帧缺失而失败。
- [ ] 实现 `DynamicRepository` 和 `RemoteDynamicRepository`，统一解析服务端 envelope。
- [ ] 重跑专项测试，要求 0 失败。

### Task 2: 动态状态与发布规则

**Files:**
- Create: `ChatStorage/Features/Dynamics/DynamicTimelineViewModel.swift`
- Create: `ChatStorage/Features/Dynamics/DynamicComposerViewModel.swift`
- Create: `ChatStorage/Features/Dynamics/DynamicComposerRouteStore.swift`
- Test: `ChatStorageTests/Dynamics/DynamicTimelineViewModelTests.swift`
- Test: `ChatStorageTests/Dynamics/DynamicComposerViewModelTests.swift`

- [ ] 写分页去重、刷新替换、乐观点赞失败回滚、500 字和媒体互斥测试。
- [ ] 运行测试并确认失败原因是行为尚未实现。
- [ ] 实现最小状态机和一次性发布草稿路由。
- [ ] 重跑专项测试，要求 0 失败。

### Task 3: Twitter 风格动态 UI

**Files:**
- Create: `ChatStorage/Features/Dynamics/DynamicTimelineView.swift`
- Create: `ChatStorage/Features/Dynamics/DynamicComposerView.swift`
- Create: `ChatStorage/Features/Dynamics/DynamicDetailView.swift`
- Modify: `ChatStorage/Features/Shell/MainShellView.swift`
- Modify: `ChatStorage/App/AppContainer.swift`
- Modify: `ChatStorage.xcodeproj/project.pbxproj`
- Test: `ChatStorageUITests/AppLaunchUITests.swift`

- [ ] 增加动态 Tab、时间线卡片、媒体网格、发布器、回复页和稳定无障碍标识。
- [ ] 用 UI 结构测试锁定 Tab、发布按钮和互动按钮存在。
- [ ] 运行通用 iPhone 架构构建，要求 `BUILD SUCCEEDED`。

### Task 4: 聊天内容搜索与分享到动态

**Files:**
- Modify: `ChatStorage/Features/Messages/RemoteChatRepository.swift`
- Modify: `ChatStorage/Features/Messages/ChatConversationViewModel.swift`
- Modify: `ChatStorage/Features/Chat/ChatConversationView.swift`
- Modify: `ChatStorage/Features/Messages/MessagesPlaceholderView.swift`
- Test: `ChatStorageTests/Messages/RemoteChatRepositoryTests.swift`
- Test: `ChatStorageTests/Chat/ChatConversationViewModelTests.swift`

- [ ] 先写 `0x5E/0x5F` 搜索编码、类型筛选和动态草稿映射测试。
- [ ] 实现聊天搜索页、稍后处理命名和“分享到动态”长按入口。
- [ ] 重跑聊天专项，要求 0 失败。

### Task 5: 网盘智能集合与分享到动态

**Files:**
- Modify: `ChatStorage/Features/Drive/DriveModels.swift`
- Modify: `ChatStorage/Features/Drive/DriveViewModel.swift`
- Modify: `ChatStorage/Features/Drive/DrivePlaceholderView.swift`
- Test: `ChatStorageTests/Drive/DriveViewModelTests.swift`

- [ ] 写全部、最近、图片、视频和大文件筛选测试。
- [ ] 实现固定智能集合栏和文件“发布到动态”菜单。
- [ ] 重跑网盘专项，要求 0 失败。

### Task 6: net-server 完整动态协议

**Files:**
- Modify: `src/main/java/com/alibaba/server/nio/model/file/FileUploadFrame.java`
- Modify: `src/main/java/com/alibaba/server/nio/service/file/handler/TextTransmissionHandler.java`
- Modify: `src/main/java/com/alibaba/server/nio/repository/dynamic/**`
- Create: `sql/user_dynamic_social_migration_20260812.sql`
- Test: `src/test/java/com/alibaba/server/nio/repository/dynamic/**`
- Test: `src/test/java/com/alibaba/server/nio/service/file/handler/TextTransmissionHandlerDynamicContractTest.java`

- [ ] 写帧、权限、可见性、分页和幂等互动测试并确认先失败。
- [ ] 实现查询 DTO、Mapper、Service 和 handler 分派。
- [ ] 生成只增不删的迁移脚本，不自动执行数据库操作。
- [ ] 用 Zulu Java 8 跑专项、全量测试和 package。

### Task 7: 回归和兼容性

**Files:**
- Modify: `README.md`

- [ ] 跑 iOS 动态、聊天、网盘专项和可执行的全量 XCTest。
- [ ] 跑 generic iOS build 与两仓库 `git diff --check`。
- [ ] 确认现有帧编号不变，新帧只占 `0x62-0x69`。
- [ ] 记录未执行的数据库迁移、真机安装和人工 UI 验收。
