# Chat Unread Broadcast Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Broadcast every chat event to every active observer and keep conversation messages, read reporting, latest previews, and unread badges synchronized.

**Architecture:** Replace the shared single-consumer message stream with a lock-protected broadcaster that returns one stream per subscriber. Repositories emit `message` and `read` events; the conversation and message-list view models apply those events independently.

**Tech Stack:** Swift 6, Swift Concurrency, AsyncStream, Observation, XCTest

---

### Task 1: Define Chat Events And Prove Broadcast Delivery

**Files:**
- Modify: `ChatStorage/Features/Messages/ChatModels.swift`
- Modify: `ChatStorage/Features/Messages/RemoteChatRepository.swift`
- Test: `ChatStorageTests/Messages/RemoteChatRepositoryTests.swift`

- [ ] **Step 1: Write the failing two-subscriber test**

Add a test that creates two independent `repository.eventStream()` subscriptions, emits one `chatPush`, and asserts both tasks receive `.message` with message ID `91`.

```swift
func testPushIsBroadcastToEverySubscriber() async throws {
    let repository = RemoteChatRepository(client: client)
    let first = Task { try await firstEvent(from: repository.eventStream()) }
    let second = Task { try await firstEvent(from: repository.eventStream()) }
    await client.emit(pushFrame)
    XCTAssertEqual(try await first.value, .message(.fixture(id: 91)))
    XCTAssertEqual(try await second.value, .message(.fixture(id: 91)))
}
```

- [ ] **Step 2: Run the focused test and verify failure**

Run:

```bash
xcodebuild test -project ChatStorage.xcodeproj -scheme ChatStorage -destination 'platform=iOS Simulator,id=6E9A3CEA-679C-4020-B1EA-716397C0389C' -only-testing:ChatStorageTests/RemoteChatRepositoryTests
```

Expected: compile failure because `ChatEvent` and `eventStream()` do not exist.

- [ ] **Step 3: Add the event model and broadcaster**

Add:

```swift
enum ChatEvent: Equatable, Sendable {
    case message(ChatMessage)
    case read(friendId: Int64)
}

final class ChatEventBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<ChatEvent>.Continuation] = [:]

    func stream() -> AsyncStream<ChatEvent> { /* register one continuation */ }
    func yield(_ event: ChatEvent) { /* snapshot and yield to all */ }
}
```

Change `ChatRepository` to:

```swift
func eventStream() -> AsyncStream<ChatEvent>
```

Make `RemoteChatRepository` return `broadcaster.stream()`, emit `.message` for valid pushes, and emit `.read(friendId:)` after a successful read response.

- [ ] **Step 4: Run the focused test and verify pass**

Run the command from Step 2.

Expected: all `RemoteChatRepositoryTests` pass.

- [ ] **Step 5: Commit the repository broadcast change**

```bash
git add ChatStorage/Features/Messages/ChatModels.swift ChatStorage/Features/Messages/RemoteChatRepository.swift ChatStorageTests/Messages/RemoteChatRepositoryTests.swift
git commit -m "fix: broadcast chat events to every subscriber"
```

### Task 2: Preserve Broadcast Semantics Through The Cache

**Files:**
- Modify: `ChatStorage/Features/Messages/CachedChatRepository.swift`
- Modify: `ChatStorage/App/AppContainer.swift`
- Modify: test repository implementations under `ChatStorageTests/`
- Test: `ChatStorageTests/Persistence/CachedRepositoriesTests.swift`

- [ ] **Step 1: Write the failing cached-repository subscription test**

Create two `CachedChatRepository.eventStream()` subscribers, emit one event from the remote spy, and assert both receive the same event while the cache stores the message once.

- [ ] **Step 2: Run the focused persistence test and verify failure**

```bash
xcodebuild test -project ChatStorage.xcodeproj -scheme ChatStorage -destination 'platform=iOS Simulator,id=6E9A3CEA-679C-4020-B1EA-716397C0389C' -only-testing:ChatStorageTests/CachedRepositoriesTests
```

Expected: compile failures from the removed `messages` property.

- [ ] **Step 3: Rebroadcast cached events**

Give `CachedChatRepository` its own `ChatEventBroadcaster`. Consume one remote subscription, merge `.message` events into `ChatCacheStore`, and rebroadcast both `.message` and `.read` events. Update preview and test repositories to expose independent streams.

- [ ] **Step 4: Run the focused persistence test and verify pass**

Run the command from Step 2.

Expected: all persistence repository tests pass.

- [ ] **Step 5: Commit cached broadcast wiring**

```bash
git add ChatStorage/Features/Messages/CachedChatRepository.swift ChatStorage/App/AppContainer.swift ChatStorageTests
git commit -m "fix: preserve chat broadcasts through cache"
```

### Task 3: Apply Message And Read Events In Both View Models

**Files:**
- Modify: `ChatStorage/Features/Messages/ChatConversationViewModel.swift`
- Modify: `ChatStorage/Features/Messages/MessagesViewModel.swift`
- Modify: `ChatStorage/Features/Messages/MessagesPlaceholderView.swift`
- Test: `ChatStorageTests/Chat/ChatConversationViewModelTests.swift`
- Test: `ChatStorageTests/Messages/MessagesViewModelTests.swift`

- [ ] **Step 1: Write failing behavior tests**

Add tests proving:

```swift
// Open conversation appends an incoming message and calls markRead again.
XCTAssertEqual(model.messages.last?.messageId, 91)
XCTAssertEqual(await repository.readFriendIds, [9])

// Closed conversation increments unread and updates preview.
model.apply(.message(incoming), currentUserId: 7)
XCTAssertEqual(model.friends[0].unreadCount, 3)
XCTAssertEqual(model.friends[0].latestMessage, "push")

// Read event clears unread.
model.apply(.read(friendId: 9), currentUserId: 7)
XCTAssertEqual(model.friends[0].unreadCount, 0)

// Outgoing echo does not increment unread.
```

- [ ] **Step 2: Run the two focused suites and verify failure**

```bash
xcodebuild test -project ChatStorage.xcodeproj -scheme ChatStorage -destination 'platform=iOS Simulator,id=6E9A3CEA-679C-4020-B1EA-716397C0389C' -only-testing:ChatStorageTests/ChatConversationViewModelTests -only-testing:ChatStorageTests/MessagesViewModelTests
```

Expected: tests fail because the view models do not apply `ChatEvent`.

- [ ] **Step 3: Implement event application**

Change `observeIncoming()` to consume `eventStream()`. Append relevant message events and call `markRead` for incoming messages from the current friend. Add `MessagesViewModel.apply(_:currentUserId:)` to rebuild only the matching `ChatFriend` with updated preview and unread count. Change `MessagesPlaceholderView` to consume events instead of refreshing the entire friend list after every push.

- [ ] **Step 4: Run focused chat suites and verify pass**

Run the command from Step 2.

Expected: both suites pass.

- [ ] **Step 5: Run all message, chat, and persistence tests**

```bash
xcodebuild test -project ChatStorage.xcodeproj -scheme ChatStorage -destination 'platform=iOS Simulator,id=6E9A3CEA-679C-4020-B1EA-716397C0389C' -only-testing:ChatStorageTests/RemoteChatRepositoryTests -only-testing:ChatStorageTests/MessagesViewModelTests -only-testing:ChatStorageTests/ChatConversationViewModelTests -only-testing:ChatStorageTests/CachedRepositoriesTests
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit the unread behavior**

```bash
git add ChatStorage/Features/Messages ChatStorageTests/Chat ChatStorageTests/Messages ChatStorageTests/Persistence
git commit -m "fix: synchronize chat unread state in real time"
```

