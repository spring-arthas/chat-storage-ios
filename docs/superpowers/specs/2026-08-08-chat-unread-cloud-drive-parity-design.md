# Chat Unread And Cloud Drive Parity Design

Date: 2026-08-08

## 1. Objective

Complete the remaining iOS chat and cloud-drive gaps:

- Every pushed chat message must reach every active observer. The conversation and friend list must never compete for one stream item.
- The open conversation must append incoming messages immediately and report them read.
- The friend list must update the latest-message preview and unread badge immediately, then remain consistent with server refreshes.
- The iOS Drive tab must provide the macOS cloud-drive behavior with iPhone-native navigation and controls.

This work stays inside the iOS repository and uses the existing `net-server` frames and media endpoints. It does not change unrelated authentication, profile, friend-management, or chat-attachment behavior.

## 2. Approaches Considered

### 2.1 Selected: Repository Broadcast Plus Feature-Scoped State

- `ChatRepository` creates a fresh stream for every subscriber and broadcasts each event to every stream.
- Chat events include pushed messages and successful read-clear events.
- `ChatConversationViewModel` and `MessagesViewModel` consume independent subscriptions.
- Drive keeps protocol decoding in `RemoteDriveRepository`, state transitions in `DriveViewModel`, and iPhone presentation in `DrivePlaceholderView`.
- Transfer persistence remains in `FileTransferTaskStore`; task execution remains in `TransferManager`.

This is selected because it fixes the message-loss root cause without introducing a new application-wide coordinator and extends the existing feature boundaries instead of replacing them.

### 2.2 Rejected: Application-Wide Chat Coordinator

An app-level coordinator could own all conversations, unread state, cache writes, and navigation visibility. It is a larger architectural change and would overlap existing repository and cache responsibilities. It is not required to close items 6 and 7.

### 2.3 Rejected: Polling And Refresh-Only Updates

Refreshing the friend list after a timer or page transition would leave visible delays and would not stop two consumers from splitting the same `AsyncStream`. It does not solve the root cause.

## 3. Chat Event Architecture

### 3.1 Event Stream

`ChatRepository` exposes a subscription method that returns a new `AsyncStream<ChatEvent>` for each caller.

`ChatEvent` contains:

- `message(ChatMessage)` for a valid `chatPush` frame.
- `read(friendId)` after the server confirms `markRead`.

A lock-protected, sendable broadcaster owns subscriber continuations. Subscriber termination removes its continuation so stale views do not leak.

### 3.2 Incoming Message Flow

1. `RemoteChatRepository` decodes one `chatPush` frame.
2. The broadcaster sends the same message event to every active subscriber.
3. `CachedChatRepository` stores the message once and rebroadcasts it to its own subscribers.
4. The open conversation appends the message if it belongs to the current friend and is not a duplicate.
5. For an incoming message, the conversation calls `markRead(friendId:)` immediately.
6. Successful read reporting emits a read event.
7. The message list updates the matching friend's preview and unread count for the message event, then clears the unread count for the read event.

Server refresh remains authoritative. Local event application exists to remove visible delay between the push and the next refresh.

### 3.3 Unread Rules

- Incoming message for a closed conversation: increment that friend's unread count.
- Incoming message for an open conversation: it can increment briefly in event order, then the following read event clears it immediately.
- Outgoing echo or delivery push: update the latest preview without increasing unread count.
- Opening a conversation: load history and report read; the read event clears the list badge.
- Duplicate pushes with the same client/server identity do not append twice.

## 4. Drive Data And Protocol Design

### 4.1 Directory Tree

`DriveFileEntry` decodes the complete recursive `childFileList` tree and the existing metadata fields, including parent directory name, path, creation time, modification time, and checksum where supplied.

The directory-list response is one root object. The view model stores:

- The complete directory tree.
- The current path from root to selected directory.
- The current directory's direct child directories from the tree.
- The current directory's paged files from the file-list endpoint.

Directories and files are merged for display. This is required because `net-server` intentionally filters the file-list endpoint to `isFile=Y`.

### 4.2 Correct Response Decoding

- Directory create and rename accept a single object response.
- Directory delete accepts a successful response with `data: null`.
- File rename accepts a single object response.
- File delete accepts a successful response with `data: null`.
- Operation responses decode only the success envelope and do not impose an incorrect data shape.

### 4.3 File Queries

- File search sends `fileName` to the server and remains scoped to the current directory.
- Pages use a fixed page size and append without duplicates.
- Pull-to-refresh reloads the directory tree and the first file page.
- Reaching the final visible item loads the next page while `records.count < totalCount`.
- File detail uses the existing `0x42` request and `0x43` response.

### 4.4 Directory Operations

- Create, rename, and delete refresh the complete tree and current listing.
- Directory move uses the existing `0x13` frame with `dirId` and `targetParentId`.
- The root cannot be renamed, deleted, or moved.
- A directory cannot be moved into itself or one of its descendants.

## 5. iPhone Drive Experience

The Drive tab uses one navigation stack rather than the macOS split layout.

### 5.1 Navigation

- The navigation title shows the current directory.
- A breadcrumb menu permits jumping to any ancestor.
- A directory-tree sheet permits jumping to any directory in the recursive tree.
- Entering a folder pushes state inside the same screen; back-to-parent remains available.

### 5.2 Display Modes

- List mode shows name, type, size, date, and operation affordances.
- Grid mode shows a thumbnail or type icon with name and size.
- The selected mode persists with `AppStorage`.

### 5.3 File And Directory Actions

- Create folder.
- Import and upload one or multiple files.
- Rename and delete a file or directory with destructive confirmation.
- Move a directory through the directory picker.
- Open file details.
- Preview images after cached download.
- Play supported video through the existing media HTTP Range URL.
- Download other files to the app download cache and expose the system share sheet so the user can save them to Files or another destination.

### 5.4 Selection And Batch Actions

- Selection mode supports item toggle and select all.
- Batch delete executes every selected item and reports partial failures without hiding successful operations.
- Batch download operates on selected files, creates collision-free local names, and leaves resulting files available for sharing.
- Directories are excluded from batch download.

### 5.5 Thumbnails

- Already downloaded images use their cached local files.
- Remote images are downloaded once into the preview cache and reused.
- Video thumbnails are generated with `AVAssetImageGenerator` from the existing HTTP Range playback URL.
- Unsupported or failed thumbnail types display deterministic file-type icons.

## 6. Transfer Center

The transfer center remains inside the Drive tab.

### 6.1 Task Controls

- Pause an active task.
- Continue a paused task.
- Retry a failed task.
- Cancel one task.
- Cancel all active tasks.
- Clear completed and cancelled records.

### 6.2 Presentation

- Filter by all, upload, or download.
- Filter by active, completed, or failed state.
- Show transferred bytes, total bytes, percentage, and current bytes per second.
- Show a useful error message for failed tasks.

### 6.3 Persistence And Recovery

- Upload sources are copied into Application Support before transfer.
- Upload MD5, transfer offsets, destination paths, and task states remain persisted.
- Tasks left queued, hashing, running, or waiting for authentication are automatically rescheduled after authenticated app launch.
- Downloads continue from the existing `.part` file and uploads continue from the server-confirmed offset.
- If iOS force-quits the process, arbitrary custom TCP sockets stop. The task is not lost and resumes on the next authenticated launch. Continuous execution while the process is killed requires the separate background HTTP protocol already identified in the phase-one architecture and is outside this iOS-only change.

### 6.4 Collision-Free Downloads

Before creating a download destination, the app checks both the completed file and its `.part` file. If either exists, it generates `name (1).ext`, `name (2).ext`, and so on.

## 7. Error Handling

- Empty folder names and unchanged rename values do not send requests.
- Repository decoding failures become stable drive errors instead of crashes.
- Loading a later page keeps already loaded records visible.
- Batch operations collect item-level failures and refresh once after the batch.
- Thumbnail failures never fail the main file list.
- Cancellation is persisted as `cancelled`, while pause is persisted as `paused`.
- A failed read report does not remove the visible chat message; the next server refresh restores authoritative unread state.

## 8. Testing

### 8.1 Chat Tests

- Two simultaneous subscribers receive the same push.
- Cancelling one subscriber does not stop the other.
- An open conversation appends a push and reports it read.
- The message list increments unread for an incoming message and clears it for a read event.
- Outgoing pushes do not increment unread.

### 8.2 Drive Repository Tests

- Decode a real single-root recursive `childFileList` response.
- Decode create and rename object responses.
- Decode delete responses with `data: null`.
- Send search, page, detail, and directory-move request fields correctly.

### 8.3 Drive View Model Tests

- Merge direct child directories with paged files.
- Navigate through the tree and jump through a directory picker.
- Search the current directory and append pages without duplicates.
- Refresh after create, rename, delete, move, and upload.
- Batch delete reports partial failures.
- Collision-free download naming is deterministic.

### 8.4 Transfer Tests

- Cancel one and cancel all update persisted state.
- Speed is calculated from progress deltas and published without writing the task file on every byte update.
- Filtering returns the correct task subsets.
- Relaunch recovery reschedules nonterminal recoverable tasks.

### 8.5 Verification

- Run the focused XCTest suites first.
- Run the complete `ChatStorage` unit-test and UI-test scheme on the known simulator.
- Run a normal simulator build.
- Review `git diff --check` and the final scoped diff.
