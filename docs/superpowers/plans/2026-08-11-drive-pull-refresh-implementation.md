# 网盘下拉刷新 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 网盘下拉时只刷新当前目录，并把刷新动画移动到当前目录名称右侧。

**Architecture:** `DriveViewModel` 新增独立的当前目录刷新入口，原子更新子目录和文件第一页；`DrivePlaceholderView` 删除系统 `.refreshable`，使用 iOS 18+ 滚动几何与滚动阶段 API 触发刷新，并把固定头部移出内容滚动区。

**Tech Stack:** Swift 6、SwiftUI、Observation、XCTest、iOS 26

---

### Task 1: 锁定刷新状态行为

**Files:**
- Modify: `ChatStorageTests/Drive/DriveViewModelTests.swift`
- Modify: `ChatStorage/Features/Drive/DriveViewModel.swift`

- [ ] **Step 1: 写失败测试**

增加测试，断言首次 `load()` 后调用 `refreshCurrentDirectory()` 不增加 `rootCalls`，仍停留在原目录，并用刷新后的子目录和文件第一页替换旧内容。

- [ ] **Step 2: 确认测试失败**

Run:

```bash
xcodebuild test -project ChatStorage.xcodeproj -scheme ChatStorage -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ChatStorageTests/DriveViewModelTests
```

Expected: FAIL，原因是 `DriveViewModel` 尚无 `refreshCurrentDirectory()` 或 `isRefreshing`。

- [ ] **Step 3: 最小实现**

在 `DriveViewModel` 增加 `private(set) var isRefreshing` 和 `refreshCurrentDirectory()`。捕获当前目录、搜索条件和内容版本，并行请求 `directoryChildren(id:)` 与 `listFiles(... page: 1 ...)`；两个请求成功且上下文未变化后再统一替换目录树、路径、文件和分页。

- [ ] **Step 4: 验证通过**

重新运行同一测试命令，预期 `DriveViewModelTests` 全部通过。

### Task 2: 锁定刷新失败与进行中状态

**Files:**
- Modify: `ChatStorageTests/Drive/DriveViewModelTests.swift`
- Modify: `ChatStorage/Features/Drive/DriveViewModel.swift`

- [ ] **Step 1: 写失败测试**

给仓库测试桩增加可控的目录、分页错误和延迟，分别断言刷新失败不清空旧列表，以及延迟请求期间 `isRefreshing == true`、结束后为 `false`。

- [ ] **Step 2: 确认测试失败**

运行 DriveViewModel 定向测试，预期新断言失败。

- [ ] **Step 3: 最小实现**

刷新开始时清空旧错误并设置 `isRefreshing`，使用 `defer` 恢复；失败只设置“网盘刷新失败”或仓库错误文本，不修改原内容。重复刷新和首次加载期间直接返回。

- [ ] **Step 4: 验证通过**

重新运行 DriveViewModel 定向测试，预期全部通过。

### Task 3: 移动动画并固定头部

**Files:**
- Modify: `ChatStorage/Features/Drive/DrivePlaceholderView.swift`

- [ ] **Step 1: 调整页面层级**

外层改为 `VStack`：目录栏和传输中心位于固定区域，内部 `ScrollView` 只渲染 `driveContent`。

- [ ] **Step 2: 替换系统刷新控件**

删除 `.refreshable`。使用 `onScrollGeometryChange` 计算顶部过度滚动距离，达到 72pt 后置为待触发；使用 `onScrollPhaseChange` 在用户松手时调用 `refreshCurrentDirectory()`。

- [ ] **Step 3: 放置刷新指示器**

在目录菜单右侧显示小型 `ProgressView`，增加 `drive.refresh-indicator` 标识；给列表滚动区设置始终允许回弹。

- [ ] **Step 4: 编译验证**

Run:

```bash
xcodebuild build -project ChatStorage.xcodeproj -scheme ChatStorage -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

Expected: BUILD SUCCEEDED。

### Task 4: 回归与界面验证

**Files:**
- Verify only

- [ ] **Step 1: 运行定向单测**

运行 `DriveViewModelTests`，预期 0 failures。

- [ ] **Step 2: 检查差异**

运行 `git diff --check`，并只审查本任务涉及的网盘文件和测试。

- [ ] **Step 3: 模拟器验证**

启动现有模拟器应用，进入网盘并下拉。确认目录名右侧出现动画，搜索栏、目录栏和传输中心不滚动，下拉结束后列表保留在当前目录。
