# Cloud Drive Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the complete macOS cloud-drive behavior in the iOS Drive tab with recursive directories, protocol-correct operations, search, pagination, details, preview, batch actions, and a complete transfer center.

**Architecture:** Decode the server's recursive directory tree and keep it separate from paged file records, then merge them in `DriveViewModel`. Extend the existing repository, transfer store, and transfer manager instead of replacing the custom frame protocol. Present the behavior through a single iPhone navigation stack with list/grid modes and sheets for tree selection, details, preview, sharing, and transfer controls.

**Tech Stack:** Swift 6, SwiftUI, Observation, Network.framework, AVKit, AVFoundation, UniformTypeIdentifiers, XCTest

---

### Task 1: Correct Drive Models And Wire Protocol

**Files:**
- Modify: `ChatStorage/Features/Drive/DriveModels.swift`
- Modify: `ChatStorage/Features/Drive/RemoteDriveRepository.swift`
- Test: `ChatStorageTests/Drive/RemoteDriveRepositoryTests.swift`

- [ ] **Step 1: Write failing protocol tests**

Add tests for a single recursive root payload, create/rename object responses, delete `null` responses, file detail, search fields, pagination fields, and directory move fields.

```swift
XCTAssertEqual(root.children.first?.children.first?.name, "旅行")
XCTAssertEqual(request["fileName"] as? String, "报告")
XCTAssertEqual(move["dirId"] as? Int, 4)
XCTAssertEqual(move["targetParentId"] as? Int, 8)
```

- [ ] **Step 2: Run repository tests and verify failure**

```bash
xcodebuild test -project ChatStorage.xcodeproj -scheme ChatStorage -destination 'platform=iOS Simulator,id=6E9A3CEA-679C-4020-B1EA-716397C0389C' -only-testing:ChatStorageTests/RemoteDriveRepositoryTests
```

Expected: recursive children are missing and operation responses fail to decode.

- [ ] **Step 3: Implement protocol-correct models and methods**

Add `children`, path, parent directory name, creation time, modification time, and MD5 fields to `DriveFileEntry`. Change `listFiles` to accept `search`. Add `fileDetail` and `moveDirectory`. Decode mutation responses with a non-generic success envelope so object and `null` data both work.

- [ ] **Step 4: Run repository tests and verify pass**

Run the command from Step 2.

Expected: all drive repository tests pass.

- [ ] **Step 5: Commit protocol corrections**

```bash
git add ChatStorage/Features/Drive/DriveModels.swift ChatStorage/Features/Drive/RemoteDriveRepository.swift ChatStorageTests/Drive/RemoteDriveRepositoryTests.swift
git commit -m "fix: decode complete drive protocol responses"
```

### Task 2: Build Directory, Search, Pagination, And Batch State

**Files:**
- Modify: `ChatStorage/Features/Drive/DriveViewModel.swift`
- Modify: repository spies in `ChatStorageTests/Drive/DriveViewModelTests.swift`
- Test: `ChatStorageTests/Drive/DriveViewModelTests.swift`

- [ ] **Step 1: Write failing view-model tests**

Cover:

```swift
XCTAssertEqual(model.entries.map(\.name), ["照片", "报告.pdf"])
await model.selectDirectory(id: nested.id)
XCTAssertEqual(model.path.map(\.id), [root.id, parent.id, nested.id])
await model.loadNextPage()
XCTAssertEqual(model.files.map(\.id), [101, 102])
await model.performSearch()
XCTAssertEqual(await repository.lastSearch, "报告")
```

Add partial-failure batch-delete and collision-free download-name tests.

- [ ] **Step 2: Run view-model tests and verify failure**

```bash
xcodebuild test -project ChatStorage.xcodeproj -scheme ChatStorage -destination 'platform=iOS Simulator,id=6E9A3CEA-679C-4020-B1EA-716397C0389C' -only-testing:ChatStorageTests/DriveViewModelTests
```

Expected: tests fail because directories are not merged, search is local-only, and pagination/batch APIs are missing.

- [ ] **Step 3: Implement drive state transitions**

Store the directory tree and paged files separately. Add tree path lookup, directory selection, first-page reload, next-page append with deduplication, server search, detail loading, move, selection, select-all, batch delete, batch download, and unique destination generation. Refresh the tree after every directory mutation and after upload.

- [ ] **Step 4: Run view-model tests and verify pass**

Run the command from Step 2.

Expected: all drive view-model tests pass.

- [ ] **Step 5: Commit drive state behavior**

```bash
git add ChatStorage/Features/Drive/DriveViewModel.swift ChatStorageTests/Drive/DriveViewModelTests.swift
git commit -m "feat: add complete drive navigation and batch state"
```

### Task 3: Add Transient Preview Downloads And Thumbnail Cache

**Files:**
- Modify: `ChatStorage/Features/Transfers/TransferManager.swift`
- Modify: `ChatStorage/Features/Drive/DriveViewModel.swift`
- Test: `ChatStorageTests/Transfers/TransferTaskStoreTests.swift`
- Test: `ChatStorageTests/Drive/DriveViewModelTests.swift`

- [ ] **Step 1: Write failing preview-cache tests**

Verify a preview download uses the transfer engine but does not create a transfer-center record, and a second request returns the existing cached file.

- [ ] **Step 2: Run focused tests and verify failure**

```bash
xcodebuild test -project ChatStorage.xcodeproj -scheme ChatStorage -destination 'platform=iOS Simulator,id=6E9A3CEA-679C-4020-B1EA-716397C0389C' -only-testing:ChatStorageTests/TransferTaskStoreTests -only-testing:ChatStorageTests/DriveViewModelTests
```

Expected: compile failure because transient preview download is missing.

- [ ] **Step 3: Implement transient preview download**

Add a `previewFile` method to `DriveTransferManaging` and `TransferManager`. It invokes `FileDownloadEngine` with a stable preview task ID, writes into `Caches/ChatStorage/DrivePreviews`, reuses complete files, resumes `.part` files, and does not insert a `TransferTaskRecord`.

- [ ] **Step 4: Run focused tests and verify pass**

Run the command from Step 2.

Expected: focused tests pass and transfer-center storage stays unchanged.

- [ ] **Step 5: Commit preview transport**

```bash
git add ChatStorage/Features/Transfers/TransferManager.swift ChatStorage/Features/Drive/DriveViewModel.swift ChatStorageTests/Transfers/TransferTaskStoreTests.swift ChatStorageTests/Drive/DriveViewModelTests.swift
git commit -m "feat: add cached drive previews"
```

### Task 4: Complete Transfer Controls, Speed, Filtering, And Recovery

**Files:**
- Modify: `ChatStorage/Features/Transfers/TransferTaskStore.swift`
- Modify: `ChatStorage/Features/Transfers/TransferManager.swift`
- Modify: `ChatStorage/Features/Transfers/TransferCenterViewModel.swift`
- Modify: `ChatStorage/Features/Transfers/TransferCenterView.swift`
- Test: `ChatStorageTests/Transfers/TransferTaskStoreTests.swift`
- Test: `ChatStorageTests/Transfers/TransferCenterViewModelTests.swift`

- [ ] **Step 1: Write failing transfer tests**

Add tests proving cancel persists `.cancelled`, cancel-all affects every active task, progress calculates bytes per second, direction/status filters return the expected rows, and recoverable persisted tasks are retried on launch.

- [ ] **Step 2: Run transfer tests and verify failure**

```bash
xcodebuild test -project ChatStorage.xcodeproj -scheme ChatStorage -destination 'platform=iOS Simulator,id=6E9A3CEA-679C-4020-B1EA-716397C0389C' -only-testing:ChatStorageTests/TransferTaskStoreTests -only-testing:ChatStorageTests/TransferCenterViewModelTests
```

Expected: missing cancel/filter/speed APIs cause failures.

- [ ] **Step 3: Implement transfer behavior**

Add optional `bytesPerSecond` to persisted tasks. Calculate speed from byte/time deltas and publish progress in memory while throttling disk writes. Extend `TransferManaging` with `cancel` and `cancelAll`. Preserve `.cancelled` when a cancelled job observes `CancellationError`. Add view-model direction and status filters, cancel actions, and aggregate active/completed counts.

- [ ] **Step 4: Update transfer-center UI**

Add filter menus, speed text, continue/retry labels, per-task cancel, cancel-all, and clear-completed controls. Keep all controls inside the Drive transfer center.

- [ ] **Step 5: Run transfer tests and verify pass**

Run the command from Step 2.

Expected: all transfer tests pass.

- [ ] **Step 6: Commit transfer-center completion**

```bash
git add ChatStorage/Features/Transfers ChatStorageTests/Transfers
git commit -m "feat: complete transfer center controls"
```

### Task 5: Replace The Drive Placeholder With The Complete iPhone UI

**Files:**
- Modify: `ChatStorage/Features/Drive/DrivePlaceholderView.swift`
- Modify: `ChatStorage/Features/Shell/MainShellView.swift` only if dependency wiring changes
- Test: `ChatStorageUITests/AppLaunchUITests.swift`

- [ ] **Step 1: Add failing UI assertions**

In authenticated UI-test mode, assert the Drive tab exposes the transfer-center entry, display-mode control, directory-tree control, and add menu. Add accessibility identifiers:

```swift
drive.tree
drive.display-mode
drive.selection
drive.transfer-center
```

- [ ] **Step 2: Run the focused UI test and verify failure**

```bash
xcodebuild test -project ChatStorage.xcodeproj -scheme ChatStorage -destination 'platform=iOS Simulator,id=6E9A3CEA-679C-4020-B1EA-716397C0389C' -only-testing:ChatStorageUITests/AppLaunchUITests
```

Expected: new drive controls are not found.

- [ ] **Step 3: Implement the complete Drive screen**

Build list/grid modes, breadcrumb navigation, recursive tree sheet, multi-file importer, row/grid context actions, selection mode, select-all, batch delete/download, file detail sheet, rename/create alerts, move picker, destructive confirmations, preview sheet, video playback, image preview, and system sharing. Use `task(id: searchText)` with a cancellation-aware debounce before server search and trigger `loadNextPage()` from the final visible item.

- [ ] **Step 4: Implement thumbnails**

For image files, load the cached transient preview and render `UIImage`. For video files, obtain the existing media playback URL and extract a frame with `AVAssetImageGenerator`. Cache generated images by file ID. Fall back to deterministic type icons without failing the list.

- [ ] **Step 5: Run the focused UI test and verify pass**

Run the command from Step 2.

Expected: authenticated UI tests find every Drive control.

- [ ] **Step 6: Commit the iPhone Drive UI**

```bash
git add ChatStorage/Features/Drive/DrivePlaceholderView.swift ChatStorage/Features/Shell/MainShellView.swift ChatStorageUITests/AppLaunchUITests.swift
git commit -m "feat: complete iPhone cloud drive experience"
```

### Task 6: Full Verification And Scope Review

**Files:**
- Review: all files changed by Tasks 1-5

- [ ] **Step 1: Run all unit and UI tests**

```bash
xcodebuild test -project ChatStorage.xcodeproj -scheme ChatStorage -destination 'platform=iOS Simulator,id=6E9A3CEA-679C-4020-B1EA-716397C0389C'
```

Expected: all unit tests and UI tests pass.

- [ ] **Step 2: Run a clean simulator build**

```bash
xcodebuild build -project ChatStorage.xcodeproj -scheme ChatStorage -destination 'platform=iOS Simulator,id=6E9A3CEA-679C-4020-B1EA-716397C0389C'
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Review formatting and scope**

```bash
git diff --check
git status --short
git diff --stat
```

Expected: no whitespace errors; only item 6, item 7, tests, and their design/plan documents are newly changed by this work.

- [ ] **Step 4: Record final verification evidence**

Report exact test counts, build result, changed files, remaining platform boundary for force-killed custom-socket transfers, and any runtime checks that were not performed against a live server.

