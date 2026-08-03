# iOS Foundation And Authentication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create an Xcode-openable native SwiftUI application with the approved visual shell, compatible frame protocol, server configuration, secure session storage, TCP authentication, and session restoration.

**Architecture:** A generated `.xcodeproj` contains one iOS app target plus unit and UI test targets. Protocol, networking, security, persistence-facing configuration, authentication, and presentation code are separated behind small interfaces so later friend, chat, drive, transfer, and notification features can reuse them without coupling to views.

**Tech Stack:** Xcode 26.3, Swift 6, SwiftUI, Observation, Network.framework, Security/Keychain, XCTest, Ruby `xcodeproj` 1.27.0.

---

## File Map

```text
project.yml                                      Human-readable project settings source
scripts/generate_xcodeproj.rb                    Deterministic Xcode project generator
ChatStorage.xcodeproj/                           Generated Xcode project
ChatStorage/App/ChatStorageApp.swift             Application entry point
ChatStorage/App/AppContainer.swift               Dependency composition root
ChatStorage/App/AppSession.swift                 Authenticated/unauthenticated navigation state
ChatStorage/DesignSystem/AppTheme.swift           Approved green/glass design tokens
ChatStorage/DesignSystem/PatternBackground.swift  Reusable chat-style patterned background
ChatStorage/Core/Protocol/Frame.swift             Frame value and protocol errors
ChatStorage/Core/Protocol/FrameType.swift         Complete frame-type mapping
ChatStorage/Core/Protocol/FrameCodec.swift        Binary encoding and strict decoding
ChatStorage/Core/Protocol/FrameStreamDecoder.swift Fragmented/coalesced stream parsing
ChatStorage/Core/Protocol/ProtocolJSON.swift      Shared JSON encoder/decoder settings
ChatStorage/Core/Networking/ServerConfiguration.swift Host and port configuration
ChatStorage/Core/Networking/ControlConnection.swift Connection interface
ChatStorage/Core/Networking/NWControlConnection.swift Network.framework implementation
ChatStorage/Core/Networking/RequestResponseClient.swift Correlated request/response actor
ChatStorage/Core/Security/SecureStore.swift        Credential storage interface
ChatStorage/Core/Security/KeychainSecureStore.swift Keychain implementation
ChatStorage/Features/Authentication/AuthModels.swift Wire/domain authentication models
ChatStorage/Features/Authentication/AuthRepository.swift Login/session lifecycle interface
ChatStorage/Features/Authentication/RemoteAuthRepository.swift Remote implementation
ChatStorage/Features/Authentication/LoginViewModel.swift Login presentation state
ChatStorage/Features/Authentication/LoginView.swift Approved login screen
ChatStorage/Features/Settings/ServerSettingsView.swift Server configuration editor
ChatStorage/Features/Shell/MainShellView.swift Three-tab authenticated shell
ChatStorage/Features/Messages/MessagesPlaceholderView.swift Approved message-list visual shell
ChatStorage/Features/Drive/DrivePlaceholderView.swift Approved drive visual shell
ChatStorage/Features/Profile/ProfilePlaceholderView.swift Approved profile visual shell
ChatStorage/Resources/Info.plist                Local-network purpose and app metadata
ChatStorageTests/Protocol/FrameCodecTests.swift  Binary compatibility tests
ChatStorageTests/Protocol/FrameStreamDecoderTests.swift Stream tests
ChatStorageTests/Security/KeychainSecureStoreTests.swift Secure-store contract tests
ChatStorageTests/Authentication/LoginViewModelTests.swift Authentication state tests
ChatStorageUITests/AppLaunchUITests.swift        Launch and tab smoke tests
```

### Task 1: Generate The Xcode Project

**Files:**
- Create: `project.yml`
- Create: `scripts/generate_xcodeproj.rb`
- Create: `ChatStorage/Resources/Info.plist`
- Create: `ChatStorage/App/ChatStorageApp.swift`
- Create: `ChatStorageTests/SmokeTests.swift`
- Create: `ChatStorageUITests/AppLaunchUITests.swift`
- Generate: `ChatStorage.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add the project manifest**

Create `project.yml` with the canonical settings used by the Ruby generator:

```yaml
name: ChatStorage
bundleIdentifier: com.alibaba.chatstorage.ios
deploymentTarget: "26.0"
swiftVersion: "6.0"
developmentTeam: ""
targets:
  app: ChatStorage
  unitTests: ChatStorageTests
  uiTests: ChatStorageUITests
```

- [ ] **Step 2: Add the deterministic generator**

Create `scripts/generate_xcodeproj.rb` using `Xcodeproj::Project.new`, add app/unit/UI targets, add every Swift file under the matching source directory, add `Info.plist`, and set:

```ruby
settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.alibaba.chatstorage.ios'
settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
settings['SWIFT_VERSION'] = '6.0'
settings['CODE_SIGN_STYLE'] = 'Automatic'
settings['GENERATE_INFOPLIST_FILE'] = 'NO'
settings['INFOPLIST_FILE'] = 'ChatStorage/Resources/Info.plist'
settings['TARGETED_DEVICE_FAMILY'] = '1'
```

The script must delete and regenerate only `ChatStorage.xcodeproj`, never source files.

- [ ] **Step 3: Add a failing smoke test target source**

```swift
import XCTest
@testable import ChatStorage

final class SmokeTests: XCTestCase {
    func testApplicationModuleLoads() {
        XCTAssertEqual(AppIdentity.displayName, "Chat Storage")
    }
}
```

Run:

```bash
ruby scripts/generate_xcodeproj.rb
xcodebuild -project ChatStorage.xcodeproj -scheme ChatStorage \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
```

Expected: FAIL because `AppIdentity` does not exist.

- [ ] **Step 4: Add the minimal app entry point**

```swift
import SwiftUI

enum AppIdentity {
    static let displayName = "Chat Storage"
}

@main
struct ChatStorageApp: App {
    var body: some Scene {
        WindowGroup { Text(AppIdentity.displayName) }
    }
}
```

- [ ] **Step 5: Generate, build, and test**

Run:

```bash
ruby scripts/generate_xcodeproj.rb
xcodebuild -project ChatStorage.xcodeproj -scheme ChatStorage \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add project.yml scripts ChatStorage.xcodeproj ChatStorage ChatStorageTests ChatStorageUITests
git commit -m "build: scaffold chat storage ios project"
```

### Task 2: Implement The Binary Frame Protocol

**Files:**
- Create: `ChatStorage/Core/Protocol/Frame.swift`
- Create: `ChatStorage/Core/Protocol/FrameType.swift`
- Create: `ChatStorage/Core/Protocol/FrameCodec.swift`
- Create: `ChatStorage/Core/Protocol/FrameStreamDecoder.swift`
- Create: `ChatStorage/Core/Protocol/ProtocolJSON.swift`
- Create: `ChatStorageTests/Protocol/FrameCodecTests.swift`
- Create: `ChatStorageTests/Protocol/FrameStreamDecoderTests.swift`

- [ ] **Step 1: Write strict codec tests**

Cover the exact Android frame contract:

```swift
func testEncodeUsesFaceMagicAndBigEndianLength() throws {
    let frame = Frame(type: .userLoginRequest, flags: 0x01, payload: Data([0x41, 0x42]))
    XCTAssertEqual(try FrameCodec.encode(frame), Data([0xFA, 0xCE, 0x31, 0x01, 0, 0, 0, 2, 0x41, 0x42]))
}

func testDecodeRejectsInvalidMagic() {
    XCTAssertThrowsError(try FrameCodec.decode(Data([0, 0, 0x31, 0, 0, 0, 0, 0])))
}

func testDecodeRejectsPayloadOverOneHundredMiB() {
    let header = Data([0xFA, 0xCE, 0x31, 0, 0x06, 0x40, 0, 0x01])
    XCTAssertThrowsError(try FrameCodec.decode(header))
}
```

Run:

```bash
xcodebuild -project ChatStorage.xcodeproj -scheme ChatStorage \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:ChatStorageTests/FrameCodecTests test
```

Expected: FAIL because protocol types do not exist.

- [ ] **Step 2: Implement frame values and complete type mapping**

`FrameType` must map all codes currently present in Android and `net-server`, including session resume, heartbeat, friend alias/pinning, message actions, and push frames. Unknown codes must throw rather than silently map.

```swift
struct Frame: Equatable, Sendable {
    let type: FrameType
    let flags: UInt8
    let payload: Data
}

enum ProtocolError: Error, Equatable {
    case incompleteHeader
    case invalidMagic
    case unknownFrameType(UInt8)
    case invalidPayloadLength(Int)
    case incompleteBody(expected: Int, actual: Int)
    case trailingBytes(expected: Int, actual: Int)
}
```

- [ ] **Step 3: Implement strict encoding and decoding**

Use an eight-byte header: `FA CE`, type, flags, signed-positive UInt32 big-endian payload length. Enforce `100 * 1024 * 1024` maximum payload size and exact total length.

- [ ] **Step 4: Write fragmented/coalesced stream tests**

```swift
func testDecoderWaitsForFragmentedFrame() throws {
    var decoder = FrameStreamDecoder()
    let bytes = try FrameCodec.encode(Frame(type: .userResponse, flags: 0, payload: Data("{}".utf8)))
    XCTAssertTrue(try decoder.append(bytes.prefix(5)).isEmpty)
    XCTAssertEqual(try decoder.append(bytes.dropFirst(5)).count, 1)
}

func testDecoderExtractsTwoCoalescedFrames() throws {
    var decoder = FrameStreamDecoder()
    let first = try FrameCodec.encode(Frame(type: .heartbeatResponse, flags: 0, payload: Data()))
    let second = try FrameCodec.encode(Frame(type: .friendEventPush, flags: 0, payload: Data("{}".utf8)))
    XCTAssertEqual(try decoder.append(first + second).map(\.type), [.heartbeatResponse, .friendEventPush])
}
```

- [ ] **Step 5: Implement stream resynchronization**

The decoder buffers partial data, extracts all complete frames, and discards bytes before the next `FA CE` magic after malformed input. It must never loop without consuming data.

- [ ] **Step 6: Run protocol tests and commit**

```bash
xcodebuild -project ChatStorage.xcodeproj -scheme ChatStorage \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:ChatStorageTests/FrameCodecTests \
  -only-testing:ChatStorageTests/FrameStreamDecoderTests test
git add ChatStorage/Core/Protocol ChatStorageTests/Protocol ChatStorage.xcodeproj
git commit -m "feat: add compatible frame protocol"
```

Expected: all protocol tests pass.

### Task 3: Add Server Configuration And Secure Session Storage

**Files:**
- Create: `ChatStorage/Core/Networking/ServerConfiguration.swift`
- Create: `ChatStorage/Core/Security/SecureStore.swift`
- Create: `ChatStorage/Core/Security/KeychainSecureStore.swift`
- Create: `ChatStorageTests/Security/KeychainSecureStoreTests.swift`
- Modify: `ChatStorage/Resources/Info.plist`

- [ ] **Step 1: Write configuration validation tests**

```swift
func testConfigurationRejectsEmptyHost() {
    XCTAssertThrowsError(try ServerConfiguration(host: "", controlPort: 10086))
}

func testConfigurationProvidesServicePorts() throws {
    let config = try ServerConfiguration(host: "192.168.1.8", controlPort: 10086)
    XCTAssertEqual(config.uploadPort, 10087)
    XCTAssertEqual(config.downloadPort, 10088)
    XCTAssertEqual(config.mediaPort, 10188)
}
```

- [ ] **Step 2: Implement configuration**

Use a `Codable`, `Equatable`, `Sendable` struct. Validate non-empty trimmed host and ports in `1...65535`. Store the selected configuration in `UserDefaults` through a small `ServerConfigurationStore` interface.

- [ ] **Step 3: Write secure-store contract tests**

Use a unique Keychain service per test and verify set/read/delete for session and transfer tokens. Tests must remove their service in `tearDown`.

- [ ] **Step 4: Implement Keychain storage**

```swift
protocol SecureStore: Sendable {
    func data(for key: SecureStoreKey) throws -> Data?
    func set(_ data: Data, for key: SecureStoreKey) throws
    func remove(_ key: SecureStoreKey) throws
}

enum SecureStoreKey: String, Sendable {
    case sessionToken
    case transferToken
    case currentUser
}
```

Use `kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and update-before-add semantics. Never use `UserDefaults` for tokens.

- [ ] **Step 5: Add local-network metadata**

`Info.plist` must contain:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>用于连接你的 Chat Storage 私人服务器并同步消息与文件。</string>
```

- [ ] **Step 6: Run tests and commit**

```bash
xcodebuild -project ChatStorage.xcodeproj -scheme ChatStorage \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:ChatStorageTests/ServerConfigurationTests \
  -only-testing:ChatStorageTests/KeychainSecureStoreTests test
git add ChatStorage/Core/Networking ChatStorage/Core/Security ChatStorage/Resources ChatStorageTests ChatStorage.xcodeproj
git commit -m "feat: add secure server session storage"
```

### Task 4: Implement The Control Connection And Request Client

**Files:**
- Create: `ChatStorage/Core/Networking/ControlConnection.swift`
- Create: `ChatStorage/Core/Networking/NWControlConnection.swift`
- Create: `ChatStorage/Core/Networking/RequestResponseClient.swift`
- Create: `ChatStorageTests/Networking/RequestResponseClientTests.swift`

- [ ] **Step 1: Define a mockable connection contract**

```swift
protocol ControlConnection: Sendable {
    var frames: AsyncThrowingStream<Frame, Error> { get }
    func connect() async throws
    func send(_ frame: Frame) async throws
    func disconnect() async
}
```

- [ ] **Step 2: Write request routing tests**

Test that a request waiting for `.userResponse` receives only that frame, unsolicited `.friendEventPush` appears on the push stream, timeout removes pending state, and cancellation does not leak a continuation.

- [ ] **Step 3: Implement `NWControlConnection` as an actor**

Use `NWConnection(host:port:using:.tcp)`, one receive loop, `FrameStreamDecoder`, and checked continuations for connection readiness. Map state failures to stable `ConnectionError` values. Sending must preserve frame order.

- [ ] **Step 4: Implement correlated request handling**

Because the wire protocol does not carry a universal correlation identifier, `RequestResponseClient` serializes operations sharing the same response type while allowing independent response types concurrently. Push frame types are never consumed by request waiters.

- [ ] **Step 5: Run tests and commit**

```bash
xcodebuild -project ChatStorage.xcodeproj -scheme ChatStorage \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:ChatStorageTests/RequestResponseClientTests test
git add ChatStorage/Core/Networking ChatStorageTests/Networking ChatStorage.xcodeproj
git commit -m "feat: add control connection client"
```

### Task 5: Implement Authentication And Session Restoration

**Files:**
- Create: `ChatStorage/Features/Authentication/AuthModels.swift`
- Create: `ChatStorage/Features/Authentication/AuthRepository.swift`
- Create: `ChatStorage/Features/Authentication/RemoteAuthRepository.swift`
- Create: `ChatStorage/Features/Authentication/LoginViewModel.swift`
- Create: `ChatStorage/App/AppSession.swift`
- Create: `ChatStorageTests/Authentication/LoginViewModelTests.swift`

- [ ] **Step 1: Port the exact Android auth JSON models**

Inspect `AuthModels.kt` and use explicit `CodingKeys` for server field names. Define login request, user response envelope, authenticated user, session resume request, and logout request. Do not rename wire keys to guessed alternatives.

- [ ] **Step 2: Write repository tests with a fake request client**

Cover successful login, server rejection, malformed payload, token persistence, session resume, expired session cleanup, and logout cleanup.

- [ ] **Step 3: Implement `RemoteAuthRepository`**

Login sends `.userLoginRequest` and waits for `.userResponse`. Resume sends `.userSessionResumeRequest`. Successful responses persist tokens and current-user data in Keychain. Password data is released after frame encoding and is never written to logs or storage.

- [ ] **Step 4: Write view-model tests**

```swift
@MainActor
func testLoginSuccessTransitionsToAuthenticated() async {
    let repository = FakeAuthRepository(result: .success(.fixture))
    let model = LoginViewModel(repository: repository)
    model.account = "veneno@example.com"
    model.password = "secret"
    await model.login()
    XCTAssertEqual(model.state, .authenticated(.fixture))
}
```

Also test empty account, empty password, loading state, double-submit prevention, server error text, and password clearing after success.

- [ ] **Step 5: Implement app-session restoration**

`AppSession` starts as `.restoring`, calls repository resume once, then becomes `.authenticated(user)` or `.unauthenticated`. It owns logout and publishes only main-actor state.

- [ ] **Step 6: Run tests and commit**

```bash
xcodebuild -project ChatStorage.xcodeproj -scheme ChatStorage \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:ChatStorageTests/LoginViewModelTests \
  -only-testing:ChatStorageTests/RemoteAuthRepositoryTests test
git add ChatStorage/Features/Authentication ChatStorage/App/AppSession.swift ChatStorageTests/Authentication ChatStorage.xcodeproj
git commit -m "feat: add login and session restoration"
```

### Task 6: Implement The Approved Visual Shell

**Files:**
- Create: `ChatStorage/DesignSystem/AppTheme.swift`
- Create: `ChatStorage/DesignSystem/PatternBackground.swift`
- Create: `ChatStorage/Features/Authentication/LoginView.swift`
- Create: `ChatStorage/Features/Settings/ServerSettingsView.swift`
- Create: `ChatStorage/Features/Shell/MainShellView.swift`
- Create: `ChatStorage/Features/Messages/MessagesPlaceholderView.swift`
- Create: `ChatStorage/Features/Drive/DrivePlaceholderView.swift`
- Create: `ChatStorage/Features/Profile/ProfilePlaceholderView.swift`
- Create: `ChatStorage/App/AppContainer.swift`
- Modify: `ChatStorage/App/ChatStorageApp.swift`
- Modify: `ChatStorageUITests/AppLaunchUITests.swift`

- [ ] **Step 1: Add UI launch tests**

Launch with `-uiTestMode unauthenticated` and assert the login title, account field, password field, server status, login button, and Face ID button exist. Launch with `-uiTestMode authenticated` and assert Messages, Drive, and Profile tabs can each be selected.

- [ ] **Step 2: Implement design tokens and patterned background**

Use semantic colors for primary green, outgoing bubble green, sheet surface, blue document, coral media, violet archive, and high-contrast text. `PatternBackground` uses a `Canvas` with a small set of abstract line motifs and honors Reduce Transparency and Increase Contrast.

- [ ] **Step 3: Implement the approved login screen**

Use the approved green patterned background, product statement, floating glass login sheet, server-status row, main login action, and Face ID action. Fields use native `TextField` and `SecureField`. The keyboard never covers the action row on iPhone 17 Pro Max or smaller supported simulator sizes.

- [ ] **Step 4: Implement server settings**

Provide host and four ports with validation, a connection test, save/cancel actions, and local-network guidance. Saving closes the old connection and updates the configuration store without deleting valid tokens.

- [ ] **Step 5: Implement the authenticated shell**

Use a native `TabView` with Messages, Drive, and Profile. Each first-pass screen renders the approved visual structure with realistic local sample state only when launched under UI-test mode; normal runtime shows repository-backed empty/loading states.

- [ ] **Step 6: Compose dependencies**

`AppContainer.live()` creates configuration store, Keychain store, connection factory, request client, auth repository, and app session. Preview/test factories inject fakes.

- [ ] **Step 7: Run unit and UI tests**

```bash
xcodebuild -project ChatStorage.xcodeproj -scheme ChatStorage \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
```

Expected: `** TEST SUCCEEDED **` with unit and UI targets passing.

- [ ] **Step 8: Build the physical-device configuration without signing**

```bash
xcodebuild -project ChatStorage.xcodeproj -scheme ChatStorage \
  -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit and push the foundation increment**

```bash
git add ChatStorage ChatStorageTests ChatStorageUITests ChatStorage.xcodeproj project.yml scripts docs
git commit -m "feat: add ios authentication foundation"
git push origin master
```

### Task 7: Document Xcode And Device Launch

**Files:**
- Modify: `README.md`
- Create: `docs/development/device-installation.md`

- [ ] **Step 1: Document Xcode opening and simulator use**

Document:

```bash
open /Users/hljy/iosProjects/chat-storage-ios/ChatStorage.xcodeproj
```

Include scheme selection, simulator selection, server-address rules, and test commands.

- [ ] **Step 2: Document iPhone installation**

Include USB trust, Developer Mode, Xcode Accounts, automatic signing, unique bundle identifier, physical-device selection, Run, local-network permission, and optional wireless debugging.

- [ ] **Step 3: Verify documentation commands and commit**

```bash
ruby scripts/generate_xcodeproj.rb
xcodebuild -project ChatStorage.xcodeproj -scheme ChatStorage \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build
git add README.md docs/development
git commit -m "docs: add ios development and device setup"
git push origin master
```

Expected: the generated project opens in Xcode and the simulator build succeeds.
