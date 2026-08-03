# Install Chat Storage On A Personal iPhone

The application does not need App Store or TestFlight distribution. Xcode can sign and install a development build directly on the owner's iPhone 17 Pro Max.

## One-time setup

1. Connect the iPhone to the Mac using a data-capable USB cable.
2. Unlock the phone, tap **Trust This Computer**, and enter the device passcode.
3. On the iPhone, enable **Settings > Privacy & Security > Developer Mode**, then restart and confirm when prompted.
4. In Xcode, open **Xcode > Settings > Accounts**, add the Apple Account used for development, and wait for the personal or paid development team to appear.
5. Open `/Users/hljy/iosProjects/chat-storage-ios/ChatStorage.xcodeproj` after the development branch is integrated into the main checkout.
6. Select the `ChatStorage` target, open **Signing & Capabilities**, enable **Automatically manage signing**, and select the development team.
7. If Xcode reports that `com.alibaba.chatstorage.ios` is unavailable to the selected team, change it to a unique reverse-domain identifier such as `com.springarthas.chatstorage.personal` in both `project.yml` and `scripts/generate_xcodeproj.rb`, then regenerate the project.

## Install and run

1. Select the connected iPhone 17 Pro Max from Xcode's run-destination menu.
2. Press Run (`⌘R`). Xcode builds, signs, installs, and launches the app.
3. On first launch, allow local-network access so the app can reach `net-server`.
4. Open the server settings in the app and enter the Mac/server's LAN address. Do not use `127.0.0.1` or `localhost` unless `net-server` runs on the iPhone itself.
5. Confirm the server ports and macOS firewall rules allow the iPhone to connect.

With a free Apple Account, development provisioning may expire after a short period and require another Xcode run. A paid Apple Developer Program membership is needed for reliable APNs testing and longer-lived provisioning, but is not required for ordinary direct installation.

## Optional wireless debugging

After one successful USB installation, open **Window > Devices and Simulators**, select the iPhone, and enable **Connect via network**. Keep the Mac and iPhone on the same trusted network. Xcode can then install later debug builds without the cable when the device is reachable.

## Verification commands

Simulator regression:

```bash
xcodebuild -project ChatStorage.xcodeproj -scheme ChatStorage \
  -destination 'platform=iOS Simulator,id=6E9A3CEA-679C-4020-B1EA-716397C0389C' test
```

Unsigned physical-device compilation:

```bash
xcodebuild -project ChatStorage.xcodeproj -scheme ChatStorage \
  -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build
```
