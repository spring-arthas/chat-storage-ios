# Messages Page Top Design

Date: 2026-08-11

## 1. Objective

Apply the approved option A to the iOS Messages tab:

- Keep the search field visible while the conversation list scrolls.
- Show the exact pending friend-request count on the friend-request action.
- Make friend requests and friend search/add visually and semantically distinct.
- Preserve the existing friend list, pull-to-refresh, navigation, sheets, unread totals, and repository event flow.

This change is limited to the Messages tab top area. It does not change the chat-conversation layout, socket protocol, repositories, server APIs, or the other two root tabs.

## 2. Approaches Considered

### 2.1 Selected: Fixed Search Header Plus Two Independent Actions

- Replace the navigation `.searchable` modifier with a custom search field placed above the `List` inside the `NavigationStack` content.
- Keep the search field outside the scrolling list so only the conversation rows move.
- Use an inbox-style SF Symbol for pending friend requests and `person.badge.plus` for user search/add.
- Keep both actions as separate buttons that open the existing `FriendRequestsView` and `FriendManagementView` sheets.
- Overlay a red numeric badge on the friend-request button.

This matches the approved option A, gives each action a different silhouette, and changes presentation without changing business behavior.

### 2.2 Rejected: Keep System `.searchable`

The system search field collapses with scrolling. It does not meet the fixed-search requirement.

### 2.3 Rejected: Merge Both Friend Actions Into One Menu

A menu reduces top-bar clutter but hides two high-frequency functions behind another tap and does not meet the requirement for two clearly separated actions.

## 3. View Structure

`MessagesPlaceholderView` keeps one `NavigationStack`. Its main content becomes a vertical layout:

1. A fixed search header directly below the navigation bar.
2. The existing `List` containing empty state, pinned conversations, and recent conversations.

The search header contains:

- A leading `magnifyingglass` symbol.
- A text field bound directly to `MessagesViewModel.searchText`.
- Placeholder text `搜索好友或消息`.
- Accessibility identifier `friends.search`.
- A trailing clear action only while the query is non-empty.
- A system-style rounded background and horizontal margins matching the existing Messages page.

The list retains its current accessibility identifier, refresh action, empty state, sections, swipe actions, and destination routing.

## 4. Toolbar Actions

### 4.1 Friend Requests

- Symbol: `tray.full`.
- Action: present the existing `FriendRequestsView`.
- Accessibility identifier: `friends.requests`.
- Badge rules:
  - `0`: no badge.
  - `1...99`: show the exact number.
  - More than `99`: show `99+`.
- Badge accessibility identifier: `friends.requests.badge`.
- Accessibility label includes the pending count when it is non-zero.

### 4.2 Find And Add Friend

- Symbol: `person.badge.plus`.
- Action: present the existing `FriendManagementView`.
- Accessibility identifier: `friends.add`.
- Accessibility label: `查找并添加好友`.

The two buttons remain independent click targets and are not combined into a menu.

## 5. State And Data Flow

No new repository method or server request is introduced.

The pending-request count continues to come from `chatRepository.pendingRequests()` and refreshes at the existing points:

- Initial Messages page load.
- Pull-to-refresh.
- Friend-relationship events.
- Dismissing or changing data inside the friend-request sheet.

Search continues to use `MessagesViewModel.searchText` and the existing `visibleFriends` filtering path. The custom field changes only where the query is displayed.

If the pending-request request fails, the current behavior remains: the badge is cleared to zero and the friend list stays usable.

## 6. Testing

Add focused UI coverage for:

- The search field remains present after scrolling the friend list.
- The friend-request and add-friend actions expose different accessibility identifiers and labels.
- A pending count renders as a numeric badge.
- The friend-request action still opens `FriendRequestsView`.
- The add-friend action still opens `FriendManagementView`.

The authenticated UI-test preview repository returns three pending requests so the numeric badge is testable without a live server. Production repository behavior is unchanged. Keep the existing Messages view-model and unread-count tests unchanged.

## 7. Acceptance Criteria

- Scrolling conversations never hides the search field.
- Pending friend requests show a red number rather than a dot.
- The two top-right actions are recognizable without opening them.
- Existing refresh, navigation, unread, friend-request, and add-friend behavior still works.
- The project builds and the targeted unit/UI tests pass on the configured iOS simulator.
