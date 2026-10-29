# Spot Chat

A native macOS floating chat window. Press a global shortcut, ask a question, and get answers from your own OpenAI-compatible API.

Spot Chat is in alpha. There are no releases yet; every build is an alpha build for testing.

## Install an alpha build

1. Open the latest successful [CI run](https://github.com/Maimai-l/spot-chat/actions/workflows/ci.yml) and download the `SpotChat-<version>-alpha.<build>` artifact.
2. Unzip it and move `SpotChat.app` to Applications.
3. The app is not notarized. Before opening it the first time, run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/SpotChat.app
   ```

4. Spot Chat lives in the menu bar. Press Option+Space to open the mini window.

The interface follows the system language: Simplified Chinese on a Chinese system, English otherwise.

## Build from source

Requires Xcode 16 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open SpotChat.xcodeproj
```

The core logic tests run without the Xcode project:

```bash
swift test --package-path Packages/SpotCore
```

## Libraries

| Purpose | Library |
| --- | --- |
| Global shortcuts and shortcut recording | [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) |
| Xcode project generation | [XcodeGen](https://github.com/yonaskolb/XcodeGen) |
