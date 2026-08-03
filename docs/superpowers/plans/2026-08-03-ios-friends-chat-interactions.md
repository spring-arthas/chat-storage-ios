# iOS Friends And Chat Interactions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the message placeholder with server-backed friend conversations and implement friend details, account-synchronized pinning, full-bleed chat backgrounds, native edge-swipe navigation, and pull-to-refresh.

**Architecture:** `FriendRepository` owns the existing friend-list and `0x5C/0x5D` pin wire contracts. A main-actor observable model maps repository state into pinned-first rows. SwiftUI uses `NavigationStack` for list -> chat -> friend details; the chat background is a clipped aspect-fill layer behind the full safe-area conversation canvas.

**Tech Stack:** Swift 6, SwiftUI, Observation, PhotosUI, XCTest, Network.framework through the existing `FrameRequesting` boundary.

---

### Task 1: Connect Before Authentication

- [ ] Add a failing test proving `connect()` occurs before login credentials are sent.
- [ ] Add `connect()` to `FrameRequesting` and call it for login and resume.
- [ ] Run authentication/network tests and commit.

### Task 2: Friend Wire Models And Repository

- [ ] Add failing tests for Android-compatible friend decoding and exact pin JSON.
- [ ] Implement list refresh with `0x35/0x3F` and pin update with `0x5C/0x5D`.
- [ ] Verify business failures do not leave local state pinned; run tests and commit.

### Task 3: Conversation State And Pull Refresh

- [ ] Add failing tests for pinned-first ordering, refresh state, and pin rollback.
- [ ] Replace the placeholder with a searchable `.refreshable` friend list and no refresh toolbar button.
- [ ] Add overflow pin/unpin and run tests.

### Task 4: Native Chat Navigation And Friend Details

- [ ] Add failing UI tests for chat opening, avatar details, pin menu, and back navigation.
- [ ] Use `NavigationStack`/`NavigationLink` without a full-width drag gesture.
- [ ] Make the chat avatar open a read-only friend profile; run tests.

### Task 5: Full-Bleed Chat Backgrounds

- [ ] Add a failing layout contract test for aspect-fill/full-bleed.
- [ ] Render selected images with `scaledToFill`, geometry sizing, clipping, and safe-area coverage.
- [ ] Verify large and small iPhone simulators.

### Task 6: Regression And Compatibility

- [ ] Run all iOS unit/UI tests and unsigned device build.
- [ ] Confirm `net-server` is unchanged and only existing frame codes are used.
- [ ] Commit and push the development branch.
