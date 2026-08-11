# Chat Conversation Layout Design

Date: 2026-08-11

## 1. Objective

Apply the approved option A to the iOS chat conversation screen:

- Present a conversation as a full-screen detail view without the three root tabs.
- Give the composer a clear, stable visual boundary above the bottom safe area or keyboard.
- Keep the newest message visible when history first loads, the keyboard opens, a message is sent, or a new message arrives.
- Preserve attachment import, emoji input, message retry, chat background, friend details, pinning, pull-to-refresh, and native back navigation.

This change is limited to the iOS conversation presentation and scroll behavior. It does not change message protocol frames, repository send semantics, server APIs, Android, or macOS clients.

## 2. Approaches Considered

### 2.1 Selected: Full-Screen Conversation With Bottom Anchor

- Hide the root `TabView` tab bar while `ChatConversationView` is visible.
- Keep the composer in a bottom safe-area inset so the system keyboard moves it without manual keyboard-height calculations.
- Give the composer an opaque system material surface and give the text field its own rounded background.
- Wrap the message scroll view in `ScrollViewReader` and add one stable bottom anchor after the last message.
- Scroll to that anchor after initial load, when the latest message identity changes, and when the composer gains focus.

This follows standard iPhone chat behavior, preserves the existing `NavigationStack`, and fixes the visibility problem at its source.

### 2.2 Rejected: Keep The Root Tabs Visible

Keeping the root tabs forces the composer into a second bottom layer and wastes vertical space. It is the current layout problem.

### 2.3 Rejected: Present Every Conversation As A Full-Screen Sheet

A sheet would hide the root tabs but replace the current navigation route and native left-edge back gesture. That is unnecessary for this fix.

## 3. Conversation Structure

`ChatConversationView` retains the existing background and navigation toolbar. The content stack is:

1. Chat background filling the available conversation area.
2. A `ScrollViewReader` containing the existing message `ScrollView` and `LazyVStack`.
3. A stable bottom anchor after the final message.
4. The composer in `.safeAreaInset(edge: .bottom)`.

The conversation applies `.toolbar(.hidden, for: .tabBar)` so the root Messages, Drive, and Profile tabs are not visible on the detail screen.

## 4. Composer Design

The composer remains one horizontal row in its default state:

- Attachment button.
- Multi-line text field limited to four lines.
- Emoji/keyboard toggle.
- Circular send or microphone button.

The text field receives a rounded system background, internal horizontal padding, and accessibility identifier `chat.composer.input`. The send button receives accessibility identifier `chat.composer.send`.

The composer surface uses a system material with an explicit top separator. It stays visually separate from custom chat backgrounds and does not overlap a root tab bar.

Keyboard and emoji behavior:

- Focusing the text field closes the custom emoji strip.
- Opening the emoji strip dismisses the system keyboard.
- Opening either input mode scrolls the latest message above the composer.

## 5. Scroll Rules

The view owns one bottom-anchor identifier. Scrolling occurs after layout has updated, using animation only for user-visible message and focus changes.

- Initial history load: scroll to the bottom without a long animation.
- Local send: the optimistic local message changes the latest message identity and scrolls into view before the server receipt returns.
- Send receipt replacement: the existing message remains in place because its client message identity is stable.
- Incoming message: append and scroll to the bottom.
- Loading older history: do not jump to the bottom because the latest message identity does not change.
- Keyboard focus or emoji strip opening: scroll to the bottom after the available message area changes.

The existing `ChatConversationViewModel.send()` behavior remains unchanged: it appends an optimistic message, sends through `ChatRepository`, replaces the local state with the receipt, and preserves failed messages for retry.

## 6. Error Handling

- Send failures keep the failed message and retry action already provided by the view model.
- Scroll requests are best-effort UI actions and never affect message persistence or sending.
- Keyboard and emoji focus changes do not clear the draft.
- Attachment and background errors keep their existing alerts and sheets.

## 7. Testing

Add focused UI coverage for:

- Opening a conversation hides the root tab bar.
- The composer input and send controls are addressable through stable accessibility identifiers.
- With the keyboard visible and enough outgoing messages to overflow the viewport, the newest sent message is visible and hittable.
- Native left-edge back navigation still returns to the Messages list.

Keep the existing conversation view-model tests for optimistic send, failure, retry, history merging, incoming pushes, and attachment deduplication.

## 8. Acceptance Criteria

- No root tab bar is visible inside a conversation.
- The default composer is visually distinct from the chat background.
- The composer stays immediately above the system keyboard.
- The latest message remains visible after send and incoming events.
- Loading older messages does not force the user back to the newest message.
- The project builds for the paired physical iPhone without starting a simulator.
