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

The interface follows the system language, Simplified Chinese or English. Settings › General › Language sets it for Spot Chat alone.

## Running commands

With a DeepSeek API key, a conversation can run commands in a folder: choose **Run Commands** in the + menu. Files you add go in by their path. Commands run in a sandbox that keeps them inside the folder; when one needs to go outside it, Spot Chat asks first.

## Build from source

Requires macOS 15, Xcode 16 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open SpotChat.xcodeproj
```

Running commands uses a bundled copy of dsh. Build it once with Node 24 before building the app; without it the app builds but can't run commands:

```bash
python3 scripts/build_agent_runtime.py --node "$(dirname "$(dirname "$(which node)")")" --out build/AgentRuntime
```

Replies are rendered by a small web page in `App/Reply`, built from `Web/`. After changing anything in `Web/src`, rebuild it and run its tests:

```bash
cd Web && npm ci && npm run build && npm test
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
| Markdown in replies, shown in a web view | [markdown-it](https://github.com/markdown-it/markdown-it), with [markdown-it-cjk-friendly](https://github.com/tats-u/markdown-cjk-friendly) |
| Math in replies | [KaTeX](https://github.com/KaTeX/KaTeX) through [@vscode/markdown-it-katex](https://github.com/microsoft/vscode-markdown-it-katex) |
| Code highlighting in replies | [highlight.js](https://github.com/highlightjs/highlight.js) |
| Updating a streaming reply in place | [morphdom](https://github.com/patrick-steele-idem/morphdom) |
| Diagrams in replies | [Mermaid](https://github.com/mermaid-js/mermaid) |
| SQLite | [GRDB.swift](https://github.com/groue/GRDB.swift) |
| Running commands: the agent, its sandbox and approvals | [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh), bundled with [Node.js](https://nodejs.org) |
| Talking to dsh over the Agent Client Protocol | [ACP Swift SDK](https://github.com/aptove/swift-sdk) |
| Xcode project generation | [XcodeGen](https://github.com/yonaskolb/XcodeGen) |
