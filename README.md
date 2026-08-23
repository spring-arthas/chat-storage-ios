# chat-storage-ios

Native SwiftUI client for `chat-storage` and `net-server`, targeting iPhone and iOS 26.

## Open in Xcode

```bash
open /Users/hljy/iosProjects/chat-storage-ios/ChatStorage.xcodeproj
```

Select the `ChatStorage` scheme and an iPhone 17 Pro Max simulator, then press Run. The service ports mirror the current Android client. The host is only a placeholder prefilled in **server settings** — the actual host used for login and video playback is whatever you configure there:

- Host: `server.example.com` (placeholder; set the server's address in settings — no IP is hardcoded)
- Control: `10086`
- Upload: `10087`
- Download: `10088`
- Media: `10188`

The simulator and a physical iPhone cannot use `localhost` to reach a server running on this Mac. Use the Mac's LAN IP, keep both devices on the same network, and allow macOS firewall/local-network access.

## Generate and test

```bash
ruby scripts/generate_xcodeproj.rb
xcodebuild -project ChatStorage.xcodeproj -scheme ChatStorage \
  -destination 'platform=iOS Simulator,id=6E9A3CEA-679C-4020-B1EA-716397C0389C' test
```

The project generator replaces only `ChatStorage.xcodeproj`; source files are preserved.

## Install on the owner's iPhone

See [Device installation](docs/development/device-installation.md) for signing, Developer Mode, USB trust, and wireless debugging.
