# Transfer Action Icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace transfer-row pause, resume, and cancel text actions with direction-compatible SF Symbol icon buttons while preserving accessibility labels and existing behavior.

**Architecture:** Keep `TransferCenterViewModel` and transfer state transitions unchanged. Update only `TransferCenterView.actionButtons(_:)`; upload/download direction remains represented by the leading cloud icon, while pause, resume, and cancel use universal action symbols with task-specific accessibility labels.

**Tech Stack:** Swift 6, SwiftUI, XCTest, Xcode command-line build, `devicectl` Wi-Fi installation.

---

### Task 1: Convert row actions to icon buttons

**Files:**
- Modify: `ChatStorage/Features/Transfers/TransferCenterView.swift:122-151`

- [ ] **Step 1: Replace visible labels with SF Symbols**

Use `pause.circle.fill` for active transfer pause, `play.circle.fill` for paused/paused-authentication resume, and `xmark.circle.fill` for preparing/failed cancel actions. Keep retry/open/share text actions unchanged.

- [ ] **Step 2: Add accessibility labels**

Set labels containing the operation and direction, for example `暂停上传任务`, `继续下载任务`, and `取消上传任务`, so icon-only buttons remain usable with VoiceOver.

- [ ] **Step 3: Verify the diff**

Run `git diff --check` and inspect that only the transfer row action UI changed.

### Task 2: Verify and install

**Files:**
- Test: Existing transfer center and transfer manager tests

- [ ] **Step 1: Run transfer center tests**

Run the `TransferCenterViewModelTests` suite and the existing artifact cleanup test; expect all tests to pass.

- [ ] **Step 2: Build the latest commit for iPhone**

Build the `ChatStorage` scheme for generic iOS device output, sign with the provisioning-profile-matched development identity, and verify the app bundle identifier and commit hash.

- [ ] **Step 3: Install and launch over Wi-Fi**

Use `xcrun devicectl` with the paired iPhone device identifier to install the newly built app and launch `com.alibaba.chatstorage.ios`.

- [ ] **Step 4: Commit the implementation**

Commit the UI change with message `feat: use icons for transfer actions` and merge the branch back into `master` after verification.
