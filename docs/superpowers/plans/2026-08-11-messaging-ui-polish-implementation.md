# Messaging UI Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved option A for the Messages tab top area and the chat conversation screen, including fixed search, numeric friend-request badge, distinct actions, full-screen chat, improved composer, and reliable latest-message visibility.

**Architecture:** Keep the existing repositories and view models unchanged. Make the Messages changes inside `MessagesPlaceholderView`, make conversation layout and scroll changes inside `ChatConversationView`, and cover both with authenticated preview-mode UI tests. All verification targets the paired physical iPhone over Wi-Fi; no simulator command is allowed.

**Tech Stack:** Swift 6, SwiftUI, Observation, XCTest/XCUITest, Xcode 26, iOS 26 physical device

---

## File Map

- Modify `ChatStorage/Features/Messages/MessagesPlaceholderView.swift`: fixed search header, toolbar symbols, badge, and accessibility identifiers.
- Modify `ChatStorage/Features/Chat/ChatConversationView.swift`: hide root tab bar, focus coordination, composer styling, bottom anchor, and automatic scrolling.
- Modify `ChatStorage/App/AppContainer.swift`: authenticated UI-test preview friend-request fixtures only.
- Modify `ChatStorageUITests/AppLaunchUITests.swift`: regression tests for both approved layouts and the keyboard/send visibility bug.
- Do not change socket frames, repositories, view-model send behavior, Android code, macOS code, or server code.

The target files already contain uncommitted user work. Do not create implementation commits that would capture unrelated existing hunks. Stage and commit only the already isolated documentation files; leave code changes uncommitted for explicit user review.

### Task 1: Add Failing UI Regression Tests

**Files:**
- Modify: `ChatStorage/App/AppContainer.swift:138-170`
- Modify: `ChatStorageUITests/AppLaunchUITests.swift:1-150`

- [ ] **Step 1: Give authenticated UI tests deterministic pending requests**

Change only the preview repository implementation. Keep the production repositories untouched:

```swift
actor PreviewChatRepository: ChatRepository {
    // Existing properties and methods remain unchanged.

    private static let previewPendingRequests: [FriendRequestItem] = {
        let data = Data(#"""
        [
          {"id":201,"senderId":21,"receiverId":1,"requestMsg":"一起整理旅行相册","status":0,"createTime":1,"senderUserName":"lin-one","senderNickName":"林一"},
          {"id":202,"senderId":22,"receiverId":1,"requestMsg":"你好","status":0,"createTime":2,"senderUserName":"zhou-two","senderNickName":"周二"},
          {"id":203,"senderId":23,"receiverId":1,"requestMsg":"申请添加好友","status":0,"createTime":3,"senderUserName":"chen-three","senderNickName":"陈三"}
        ]
        """#.utf8)
        return try! ProtocolJSON.decoder().decode([FriendRequestItem].self, from: data)
    }()

    func pendingRequests() async throws -> [FriendRequestItem] {
        Self.previewPendingRequests
    }
}
```

- [ ] **Step 2: Add the Messages top regression test**

Add this test to `AppLaunchUITests`:

```swift
func testMessagesTopKeepsSearchVisibleAndSeparatesFriendActions() {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTestMode", "authenticated"]
    app.launch()

    let search = app.descendants(matching: .any)["friends.search"]
    XCTAssertTrue(search.waitForExistence(timeout: 3))

    let requests = app.descendants(matching: .any)["friends.requests"].firstMatch
    let addFriend = app.descendants(matching: .any)["friends.add"].firstMatch
    XCTAssertTrue(requests.exists)
    XCTAssertTrue(addFriend.exists)
    XCTAssertEqual(requests.value as? String, "3个待处理")

    app.collectionViews["friends.list"].swipeUp()
    XCTAssertTrue(search.exists)
    XCTAssertTrue(search.isHittable)

    requests.tap()
    XCTAssertTrue(app.navigationBars["待接受好友申请"].waitForExistence(timeout: 3))
    app.buttons["完成"].tap()

    addFriend.tap()
    XCTAssertTrue(app.navigationBars["添加好友"].waitForExistence(timeout: 3))
}
```

- [ ] **Step 3: Add the chat layout and latest-message regression test**

Add this test to `AppLaunchUITests`:

```swift
func testChatHidesRootTabsAndKeepsLatestSentMessageVisibleWithKeyboard() {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTestMode", "authenticated"]
    app.launch()

    let conversation = app.buttons["conversation.2"]
    XCTAssertTrue(conversation.waitForExistence(timeout: 3))
    conversation.tap()

    XCTAssertTrue(app.descendants(matching: .any)["chat.conversation.screen"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.tabBars.firstMatch.exists)

    let input = app.descendants(matching: .any)["chat.composer.input"]
    let send = app.descendants(matching: .any)["chat.composer.send"]
    XCTAssertTrue(input.waitForExistence(timeout: 2))
    XCTAssertTrue(send.exists)

    input.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))

    for index in 1...8 {
        let text = "滚动验证消息 \(index)"
        input.tap()
        input.typeText(text)
        send.tap()
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 2))
        waitForComposerToClear(input, sentText: text)
    }

    let finalText = "最后一条必须显示在键盘上方"
    input.tap()
    input.typeText(finalText)
    send.tap()

    let latest = app.staticTexts[finalText]
    XCTAssertTrue(latest.waitForExistence(timeout: 3))
    XCTAssertTrue(latest.isHittable)
}

private func waitForComposerToClear(
    _ input: XCUIElement,
    sentText: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let predicate = NSPredicate { object, _ in
        guard let element = object as? XCUIElement else { return false }
        return (element.value as? String) != sentText
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: input)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 2), .completed, file: file, line: line)
}
```

- [ ] **Step 4: Run the two tests on the paired Wi-Fi iPhone and verify they fail**

Run only on the physical device:

```bash
xcodebuild test \
  -project ChatStorage.xcodeproj \
  -scheme ChatStorage \
  -destination 'platform=iOS,id=00008150-00010CD002A1401C' \
  -only-testing:ChatStorageUITests/AppLaunchUITests/testMessagesTopKeepsSearchVisibleAndSeparatesFriendActions \
  -only-testing:ChatStorageUITests/AppLaunchUITests/testChatHidesRootTabsAndKeepsLatestSentMessageVisibleWithKeyboard
```

Expected before implementation:

- Messages test fails because `friends.search`, `friends.add`, and the numeric badge do not exist.
- Chat test fails because the root tab bar remains visible and the composer identifiers do not exist.
- If Xcode reports that the device is locked or unavailable, stop verification, report the exact message, and continue with static code work without starting a simulator.

### Task 2: Implement Messages Tab Option A

**Files:**
- Modify: `ChatStorage/Features/Messages/MessagesPlaceholderView.swift:1-145`
- Test: `ChatStorageUITests/AppLaunchUITests.swift`

- [ ] **Step 1: Import UIKit semantic colors**

Add the import used by the fixed search field background:

```swift
import SwiftUI
import UIKit
```

- [ ] **Step 2: Replace `.searchable` with a fixed search header**

Wrap the current list in a zero-spacing vertical stack and keep every existing list branch and modifier:

```swift
NavigationStack {
    VStack(spacing: 0) {
        fixedSearchBar
        List {
            // Existing empty, pinned, and recent content stays unchanged.
        }
        .accessibilityIdentifier("friends.list")
        // Existing overlay, refreshable, destination, task, event, alert, and sheets stay unchanged.
    }
    .navigationTitle("消息")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { messagesToolbar }
}
```

Delete only this modifier from the list/navigation chain:

```swift
.searchable(text: $model.searchText, prompt: "搜索好友或消息")
```

- [ ] **Step 3: Add the fixed search field**

Add a private computed view to `MessagesPlaceholderView`:

```swift
private var fixedSearchBar: some View {
    HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
        TextField("搜索好友或消息", text: $model.searchText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("friends.search")
        if !model.searchText.isEmpty {
            Button {
                model.searchText = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("清除搜索")
        }
    }
    .padding(.horizontal, 12)
    .frame(minHeight: 38)
    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 11))
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(Color(uiColor: .systemGroupedBackground))
}
```

- [ ] **Step 4: Replace the two toolbar actions**

Keep them as two buttons and use the approved symbols and identifiers:

```swift
@ToolbarContentBuilder
private var messagesToolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
        Button {
            showsFriendRequests = true
        } label: {
            Image(systemName: "tray.full")
                .overlay(alignment: .topTrailing) {
                    if pendingRequestCount > 0 {
                        Text(pendingRequestBadgeText)
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, pendingRequestCount > 9 ? 5 : 4)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(.red, in: Capsule())
                            .offset(x: 8, y: -8)
                            .accessibilityIdentifier("friends.requests.badge")
                    }
                }
        }
        .accessibilityLabel("好友申请")
        .accessibilityValue(pendingRequestCount > 0 ? "\(pendingRequestCount)个待处理" : "无待处理")
        .accessibilityIdentifier("friends.requests")
    }

    ToolbarItem(placement: .topBarTrailing) {
        Button {
            showsFriendManagement = true
        } label: {
            Image(systemName: "person.badge.plus")
        }
        .accessibilityLabel("查找并添加好友")
        .accessibilityIdentifier("friends.add")
    }
}

private var pendingRequestBadgeText: String {
    pendingRequestCount > 99 ? "99+" : "\(pendingRequestCount)"
}

```

- [ ] **Step 5: Re-run the Messages UI test on the Wi-Fi device**

```bash
xcodebuild test \
  -project ChatStorage.xcodeproj \
  -scheme ChatStorage \
  -destination 'platform=iOS,id=00008150-00010CD002A1401C' \
  -only-testing:ChatStorageUITests/AppLaunchUITests/testMessagesTopKeepsSearchVisibleAndSeparatesFriendActions
```

Expected: PASS. No simulator process is launched.

### Task 3: Implement Chat Conversation Option A

**Files:**
- Modify: `ChatStorage/Features/Chat/ChatConversationView.swift:8-215`
- Test: `ChatStorageUITests/AppLaunchUITests.swift`

- [ ] **Step 1: Add focus and bottom-anchor state**

Add these properties near the existing state:

```swift
@FocusState private var isComposerFocused: Bool
private static let bottomAnchorID = "chat.conversation.bottom"
```

- [ ] **Step 2: Wrap the conversation in `ScrollViewReader` and add the anchor**

Change the top-level body shape without changing the existing toolbar, tasks, sheets, importer, or alerts:

```swift
var body: some View {
    ScrollViewReader { proxy in
        ZStack {
            ChatBackgroundView(imageData: backgroundData)
            ScrollView {
                LazyVStack(spacing: 10) {
                    // Existing day label, loading state, messages, and older-message button.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await model.load() }
        }
        .onChange(of: model.messages.last?.id) { _, latestID in
            guard latestID != nil else { return }
            scrollToBottom(using: proxy, animated: true)
        }
        .onChange(of: isComposerFocused) { _, focused in
            if focused {
                showsEmojiPicker = false
                scrollToBottom(using: proxy, animated: true)
            }
        }
        .onChange(of: showsEmojiPicker) { _, visible in
            if visible { scrollToBottom(using: proxy, animated: true) }
        }
        // Existing outer modifiers remain attached here.
    }
}
```

Add the helper inside `ChatConversationView`:

```swift
private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool) {
    DispatchQueue.main.async {
        let action = {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                action()
            }
        } else {
            action()
        }
    }
}
```

- [ ] **Step 3: Hide the root tab bar on the conversation destination**

Attach this modifier to the conversation container:

```swift
.toolbar(.hidden, for: .tabBar)
```

Do not hide the navigation bar and do not replace `NavigationLink` with a sheet.

- [ ] **Step 4: Restyle and coordinate the composer**

Update the existing text field and emoji button while preserving attachment and send actions:

```swift
TextField("消息", text: $model.draft, axis: .vertical)
    .lineLimit(1...4)
    .focused($isComposerFocused)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    .accessibilityIdentifier("chat.composer.input")

Button("表情", systemImage: showsEmojiPicker ? "keyboard" : "face.smiling") {
    if showsEmojiPicker {
        showsEmojiPicker = false
        isComposerFocused = true
    } else {
        isComposerFocused = false
        showsEmojiPicker = true
    }
}
.labelStyle(.iconOnly)

Button("发送", systemImage: model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "mic.fill" : "arrow.up") {
    Task { await model.send() }
}
.labelStyle(.iconOnly)
.frame(width: 34, height: 34)
.background(AppTheme.primaryGreen, in: Circle())
.foregroundStyle(.white)
.disabled(model.isSending)
.accessibilityIdentifier("chat.composer.send")
```

Give the composer surface a clear separator and stable material:

```swift
.background(.regularMaterial)
.overlay(alignment: .top) { Divider() }
```

Keep the existing `.safeAreaInset(edge: .bottom) { composer }`; do not calculate keyboard height manually.

- [ ] **Step 5: Re-run the chat UI test on the Wi-Fi device**

```bash
xcodebuild test \
  -project ChatStorage.xcodeproj \
  -scheme ChatStorage \
  -destination 'platform=iOS,id=00008150-00010CD002A1401C' \
  -only-testing:ChatStorageUITests/AppLaunchUITests/testChatHidesRootTabsAndKeepsLatestSentMessageVisibleWithKeyboard
```

Expected: PASS. The root tab bar is absent, the system keyboard is present, and the final sent message is hittable.

### Task 4: Physical-Device Regression Verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Run the existing conversation model tests on the Wi-Fi device**

```bash
xcodebuild test \
  -project ChatStorage.xcodeproj \
  -scheme ChatStorage \
  -destination 'platform=iOS,id=00008150-00010CD002A1401C' \
  -only-testing:ChatStorageTests/ChatConversationViewModelTests \
  -only-testing:ChatStorageTests/MessagesViewModelTests
```

Expected: PASS.

- [ ] **Step 2: Run the complete app build for the physical device**

```bash
xcodebuild build \
  -project ChatStorage.xcodeproj \
  -scheme ChatStorage \
  -destination 'platform=iOS,id=00008150-00010CD002A1401C'
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run both new UI tests together**

```bash
xcodebuild test \
  -project ChatStorage.xcodeproj \
  -scheme ChatStorage \
  -destination 'platform=iOS,id=00008150-00010CD002A1401C' \
  -only-testing:ChatStorageUITests/AppLaunchUITests/testMessagesTopKeepsSearchVisibleAndSeparatesFriendActions \
  -only-testing:ChatStorageUITests/AppLaunchUITests/testChatHidesRootTabsAndKeepsLatestSentMessageVisibleWithKeyboard
```

Expected: PASS.

- [ ] **Step 4: Review the final diff without touching unrelated WIP**

```bash
git diff --check
git diff -- ChatStorage/Features/Messages/MessagesPlaceholderView.swift
git diff -- ChatStorage/Features/Chat/ChatConversationView.swift
git diff -- ChatStorage/App/AppContainer.swift
git diff -- ChatStorageUITests/AppLaunchUITests.swift
```

Confirm that the diff contains only the approved Messages and conversation UI changes plus their preview fixtures and tests. Do not stage or commit existing unrelated modifications.
