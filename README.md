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

Requires macOS 15, Xcode 16 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open SpotChat.xcodeproj
```

The logic, storage and API tests run without the Xcode project. The API tests talk to a local mock server:

```bash
python3 scripts/mock_openai_server.py 8765 &
MOCK_OPENAI_BASE_URL=http://127.0.0.1:8765/v1 swift test --package-path Packages/SpotKit
```

## Libraries

| Purpose | Library |
| --- | --- |
| Global shortcuts and shortcut recording | [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) |
| OpenAI-compatible API calls and streaming | [OpenAI](https://github.com/MacPaw/OpenAI) by MacPaw |
| Markdown rendering | [Textual](https://github.com/gonzalezreal/textual) |
| SQLite | [GRDB.swift](https://github.com/groue/GRDB.swift) |
| Xcode project generation | [XcodeGen](https://github.com/yonaskolb/XcodeGen) |
