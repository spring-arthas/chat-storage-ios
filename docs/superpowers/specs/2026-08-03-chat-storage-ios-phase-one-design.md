# Chat Storage iOS Phase One Design

Date: 2026-08-03

## 1. Objective

Build a native iPhone client named `chat-storage-ios` that provides full phase-one behavioral parity with the current local `chat-storage-android` application and communicates with the existing `net-server` backend.

The application is intended for personal use on an iPhone 17 Pro Max running iOS 26.2. It will be installed directly through Xcode and will not be submitted to the App Store.

The Android working tree, including its current uncommitted functionality, is the source of truth for phase-one user-visible behavior. The macOS `chat-storage` project remains a secondary reference for Swift protocol handling and business rules, but its desktop UI architecture will not be copied.

## 2. Repository And Workspace

- GitHub repository: `https://github.com/spring-arthas/chat-storage-ios`
- Local checkout: `/Users/hljy/iosProjects/chat-storage-ios`
- Backend repository: `/Users/hljy/IdeaProjects/code/net-server`
- Android reference: `/Users/hljy/androidProjects/chat-storage-android`
- macOS reference: `/Users/hljy/macProjects/chat-storage`
- Initial default branch: `master`
- Repository visibility: public

The iOS repository owns all iPhone application code, tests, assets, local persistence schemas, and project documentation. Backend protocol, APNs, and background-transfer changes remain in `net-server`.

## 3. Platform And Toolchain

- Xcode 26.3
- iOS SDK 26.2
- Swift 6
- SwiftUI application lifecycle
- iOS deployment target 26.0
- iPhone portrait layout as the primary form factor
- Automatic code signing with a user-selected Apple development team
- Bundle identifier: `com.alibaba.chatstorage.ios`

The project will be an ordinary `.xcodeproj` that opens directly in Xcode. The first scheme will be named `ChatStorage` and will support simulator, unit-test, UI-test, and physical-device execution.

## 4. Visual Direction

The approved visual baseline is inspired by the supplied Telegram chat screenshot without copying Telegram branding or proprietary assets.

### 4.1 Shared Language

- Soft green patterned background with yellow-green light variation.
- Floating translucent controls using iOS 26 glass materials.
- White incoming message bubbles and pale-green outgoing bubbles.
- Rounded date markers and unread separators on the chat background.
- Floating circular back, attachment, microphone, add, and action buttons.
- Translucent bottom navigation for Messages, Drive, and Profile.
- White content sheets for dense lists so the interface remains readable and does not become uniformly green.
- Restrained accent colors: green for primary actions, blue for documents, coral for video/upload status, and muted violet for archives.
- System typography, Dynamic Type support, safe-area compliance, and VoiceOver labels.

### 4.2 Core Screens

The phase-one visual system covers:

1. Login and server connection.
2. Message list and pinned contacts.
3. Friend chat, date separators, unread state, attachments, emoji, and composer.
4. Cloud-drive overview, folders, files, search, directory tree, and actions.
5. Transfer center with upload/download progress and recovery controls.
6. Profile, server settings, notifications, storage, appearance, privacy, and logout.
7. Friend search, friend requests, friend details, aliases, and pin controls.
8. File details, media preview, video playback, and contextual action sheets.

## 5. Application Architecture

The application uses feature-oriented modules with explicit interfaces between presentation, domain, persistence, and transport code.

```text
ChatStorage/
  App/
  DesignSystem/
  Core/
    Protocol/
    Networking/
    Security/
    Persistence/
    Background/
    Media/
  Features/
    Authentication/
    Friends/
    Messages/
    Chat/
    Drive/
    Transfers/
    Profile/
    Settings/
  Resources/
ChatStorageTests/
ChatStorageUITests/
```

### 5.1 Presentation

- SwiftUI views contain layout and transient presentation state only.
- Each feature has an `@MainActor` observable view model.
- Navigation uses typed routes rather than string identifiers.
- Shared visual primitives live in `DesignSystem`; feature-specific views remain inside their feature.
- Views do not access sockets, databases, Keychain, or file-system APIs directly.

### 5.2 Domain And Repositories

- Feature repositories expose async operations and `AsyncStream` updates.
- Transport DTOs are mapped to stable domain models at repository boundaries.
- Repositories coordinate remote state, local cache, optimistic updates, and rollback.
- Session, friend, chat, drive, and transfer state have separate repository interfaces.

### 5.3 Persistence

- SwiftData stores friends, conversations, messages, read cursors, transfer tasks, cached file metadata, media-cache metadata, and UI preferences.
- Keychain stores session and transfer credentials.
- Plaintext passwords are never persisted.
- Application Support stores resumable transfer data and media cache files.
- User-selected documents are copied or security-scoped according to their source and task lifetime.

## 6. Networking And Protocol

### 6.1 Foreground Control Channel

- `Network.framework` provides the control TCP connection.
- The iOS frame codec must remain byte-compatible with `net-server` and Android.
- A single actor owns each connection, parser buffer, request correlation map, and write queue.
- Control operations that share response frame types are serialized or correlated so responses cannot cross-deliver.
- Session restoration uses the existing session token flow.
- Connection recovery uses bounded exponential backoff with foreground and network-path awareness.

### 6.2 Existing Service Ports

- Control and metadata: `10086`
- Upload: `10087`
- Download: `10088`
- Media thumbnail and range playback: `10188`

The server address is user-configurable. A physical iPhone must use a LAN or externally reachable server address, never `localhost`.

### 6.3 iOS Background Transfer Extension

iOS cannot keep arbitrary TCP sockets alive indefinitely in the background. To preserve phase-one transfer behavior, `net-server` will gain authenticated HTTP endpoints compatible with background `URLSession`.

The background-transfer contract will provide:

- Creation and resumption of upload sessions.
- Fixed-size idempotent upload chunks from temporary local files.
- Server-side received-range tracking and offset reconciliation.
- HTTP Range downloads with stable validators.
- Pause, resume, retry, cancellation, and duplicate-request protection.
- Short-lived transfer credentials derived from the authenticated session.
- Task status lookup after application relaunch.
- Final MD5 or equivalent integrity verification matching existing server semantics.

Foreground transfers may continue to use the existing TCP protocol where it provides better progress behavior. Background-capable jobs use the HTTP transport while sharing the same domain task model and server-side file records.

### 6.4 Local Network And Cleartext Media

- The app declares local-network usage with user-facing purpose text.
- Cleartext HTTP exceptions are narrowly scoped to the configured personal server where required by media playback and background transfer.
- A future TLS endpoint can replace the exception without changing feature code.
- The app surfaces permission denial, unreachable-host, and firewall guidance in server settings.

## 7. Authentication And Session Lifecycle

- Login accepts server, account, and password.
- Password exists only for the active login request.
- Keychain persists session and transfer tokens.
- App launch attempts session restoration before showing authenticated content.
- Manual logout closes connections, cancels authenticated background work as appropriate, clears credentials, and preserves only non-sensitive preferences.
- Changing the server closes old connections and rebinds subsequent operations to the new endpoint.
- Face ID protects reuse of stored credentials or entry into the authenticated app; it does not replace server authentication.

## 8. Friend And Messaging Scope

Phase one includes the complete Android friend and chat behavior:

- Friend list and current online state where the server provides it.
- Friend search.
- Send friend request.
- Friend-request inbox.
- Accept and reject actions.
- Friend event push handling.
- Friend aliases.
- Account-synchronized friend pinning.
- Conversation ordering and unread counts.
- Text message sending and receiving.
- Delivery acknowledgement and explicit failure state.
- Chat history pagination and incremental synchronization.
- Read reporting and read-cursor persistence.
- Persistent local chat cache.
- Emoji selection and text insertion behavior.
- Per-friend chat backgrounds.
- Chat attachment upload, send, download, recovery, and batch behavior.
- Foreground socket restoration after interruption or app activation.

Voice and video calling are not phase-one features because they are not part of the Android source-of-truth functionality.

## 9. Drive, Transfer, And Media Scope

- Drive overview and current-directory browsing on one screen.
- Breadcrumb navigation.
- Directory tree sheet.
- Directory create, rename, delete, and move where supported by the protocol.
- File list, details, search, rename, delete, and download.
- File import with target-directory selection.
- Persistent upload and download tasks.
- Pause, resume, retry, cancellation, app-relaunch recovery, and integrity checks.
- First-pass MD5 persistence so large uploads are not rescanned unnecessarily.
- Transfer center with active, completed, paused, waiting-for-login, and failed states.
- Video thumbnails.
- HTTP Range video playback.
- Progressive local cache and preference for a complete local file.
- Export to Files or Photos when supported by media type and user choice.
- Cache cleanup and local-storage reporting.

## 10. Background Messages And APNs

`net-server` will add APNs device registration and provider delivery so a suspended iPhone can receive timely message notifications.

### 10.1 Client Responsibilities

- Request notification authorization at an appropriate authenticated point.
- Register the APNs device token with the server.
- Associate tokens with account, installation identifier, environment, and app bundle.
- Refresh registration when the token changes.
- Handle notification taps and navigate to the correct conversation.
- Reconnect and incrementally synchronize before displaying authoritative conversation state.
- Unregister the installation during logout when possible.

### 10.2 Server Responsibilities

- Persist device registrations without logging full tokens.
- Send minimal notification payloads that do not expose message bodies unless explicitly enabled by the user.
- Use APNs HTTP/2 through a Java 8-compatible provider client.
- Remove invalid or expired device tokens from active delivery.
- Keep APNs credentials outside source control and inject them through local configuration.
- Treat push delivery as a wake-up hint; chat history remains the source of truth.

If APNs credentials are not configured in a development environment, foreground messaging and activation-time synchronization remain functional, while the app clearly reports that background notifications are unavailable.

## 11. Error Handling And Recovery

- User-facing errors use stable domain error categories rather than raw socket or JSON messages.
- Retryable operations expose retry controls and retain task context.
- Authentication expiry pauses protected work and requests login without discarding transfer metadata.
- Network changes trigger path-aware reconnect or rescheduling.
- Duplicate chat sends and transfer chunks use stable client-generated identifiers for idempotency.
- Database writes and remote acknowledgements are ordered to avoid false-success UI.
- Failed optimistic updates roll back or display a pending-sync state.
- Corrupt local cache entries are isolated and rebuilt from the server rather than crashing startup.
- All logs redact passwords, session tokens, transfer tokens, APNs tokens, and private file paths where possible.

## 12. Testing Strategy

### 12.1 iOS Unit Tests

- Frame encoding, fragmented parsing, oversized frame handling, and invalid input.
- Request correlation and serialization.
- Session restoration and logout cleanup.
- Repository cache/remote merge behavior.
- Friend events, aliases, pinning, and unread calculations.
- Chat history pagination, read cursors, attachment state transitions, and retry behavior.
- Directory and file operations.
- Transfer state machine, range reconciliation, integrity validation, and relaunch recovery.
- View-model state and error mapping.

### 12.2 iOS UI Tests

- Login and server configuration.
- Three-tab navigation.
- Friend request workflow.
- Send and receive chat messages.
- Attachment selection and progress states.
- Drive navigation and file actions.
- Transfer pause/resume and failure recovery.
- Dynamic Type, keyboard, safe-area, and long-text layout checks.

### 12.3 Backend Tests

- APNs device-registration lifecycle.
- Push-trigger decisions and invalid-token cleanup.
- Background upload session creation, range validation, duplicate chunks, and finalization.
- Range download authorization and validators.
- Token expiry and authorization boundaries.
- Compatibility tests proving existing Android and macOS clients remain unaffected.

### 12.4 Device Verification

- iPhone 17 Pro Max on iOS 26.2.
- USB installation through Xcode followed by wireless debugging.
- Local-network permission and LAN server connectivity.
- Foreground/background transitions.
- Force quit and relaunch recovery.
- Wi-Fi loss, server restart, and token expiry.
- Large-file transfer interruption and continuation.
- Notification delivery and conversation synchronization.

## 13. Signing And Personal Distribution

- Development builds install directly from Xcode.
- The user signs in under Xcode Settings > Accounts.
- Automatic signing selects the user's development team.
- Developer Mode must be enabled on the iPhone.
- A paid Apple Developer Program membership is recommended for APNs and longer-lived provisioning.
- No App Store, TestFlight, analytics SDK, advertising SDK, or public distribution workflow is required in phase one.

## 14. Delivery Increments

Implementation will proceed in dependency order while preserving one coherent phase-one release:

1. Xcode project, design system, protocol codec, connection foundation, and authentication.
2. Local persistence, session restoration, app shell, and settings.
3. Friend workflows, message list, chat, history, read state, emoji, and backgrounds.
4. Drive metadata operations, file actions, and media browsing.
5. Persistent transfer engine, attachments, video playback, and cache management.
6. Backend HTTP background-transfer contract and iOS background `URLSession` integration.
7. APNs registration, backend delivery, notification routing, and activation synchronization.
8. Full regression, physical-device verification, signing documentation, and final debug build.

Each increment must keep existing Android, macOS, and server behavior compatible.

## 15. Phase-One Acceptance Criteria

Phase one is complete only when:

- The repository opens and builds with Xcode 26.3.
- The app installs and launches on the user's iPhone 17 Pro Max running iOS 26.2.
- The approved green-pattern and floating-glass visual system is applied consistently.
- All current Android authentication, friend, chat, drive, transfer, media, and settings behaviors have an iOS equivalent.
- Foreground custom-protocol behavior remains compatible with `net-server`.
- Uploads and downloads can recover across interruption and app relaunch.
- Suspended-device message notifications work when APNs credentials and a paid developer team are configured.
- Foreground activation always reconciles missed messages with server history.
- Automated unit, UI, and backend compatibility tests pass.
- No secrets or signing material are committed.
- Existing Android and macOS clients continue to function.

