# Maintenance

How Spot Chat is kept working between features: reporting and fixing bugs, shipping alphas, and keeping the
build and its dependencies healthy. The rules themselves are in `CLAUDE.md`; this is the routine.

## Reporting a bug

Tell Claude in a session, or open an issue on the repository, with:

- **What you did, what you expected, what happened.** One line each is enough.
- **A screenshot or screen recording** when something looks or moves wrong.
- **The log.** Settings > General > Export Logs… saves it as one file. Its first lines name the build, such as
  `Spot Chat 0.1.0 (134)`, and every line carries a time, so say roughly when it happened.

A request for something new says what problem it solves and where it shows: the mini window, the full window,
Settings or the menu bar.

## Triage

| Priority | What it covers | When it's fixed |
| --- | --- | --- |
| P0 | Data lost, an API key exposed, a command run outside the folder without asking, a crash at launch | Now, with a new alpha the same day |
| P1 | A main flow broken: sending, streaming, history, attachments, commands, web search; a wrong reply shown | In the next alpha |
| P2 | Something looks or reads wrong: alignment, copy, animation | Batched into an alpha |
| Request | Something new | Into the backlog below; mocked up first when it changes the interface |

## Fixing a bug

1. **Read the log before the code.** For a reply, compare the request, every streamed line, the reply as saved
   and as shown: the first that differs is the culprit. For the interface, compare the report's screenshot with
   the CI screenshots of the same screen.
2. **Reproduce it in a test first.** Logic goes in a SpotKit test, behavior against an API in a scenario of
   `scripts/mock_openai_server.py`, and the interface in a UI test that attaches a screenshot.
3. **If the log didn't show what was needed,** add that logging as part of the fix.
4. **Fix it and run only its tests,** with `[ui: testName]` in the commit message, and check the screenshots.
5. **Write it down** in `docs/lessons.md` when it teaches something.
6. **Batch the fixes,** then push without a tag: every UI test runs and the alpha is packaged.

## Alpha builds

- A full CI run (no tag) packages `SpotChat-0.1.0-alpha.<run>`. The run number is the app's build number, so a
  log names the alpha it came from.
- Each alpha goes out with a checklist in Chinese: what changed, and how to check each change in the app.
- The app isn't notarized; the README gives the command that lets it open.
- There are no releases or tags.

## Keeping it building

CI builds with Xcode 16.4 (Swift 6.1) on GitHub's macos-15 image. A newer local toolchain resolves packages to
versions CI can't build, so after updating any package, check `Package.resolved` and let CI build it before
building on it.

| What | Held at | Why, and how to update |
| --- | --- | --- |
| CocoaLumberjack | 3.9.0, exact | 3.9.1 and later need a newer Swift than CI's |
| swift-collections | 1.2.1 | A local resolve picked 1.7.5, which needs Swift 6.4 |
| GRDB.swift, MacPaw OpenAI, ACP swift-sdk, swift-log | as resolved: 7.11.1, 0.5.3, 0.2.2, 1.9.1 | Update one at a time and run the core tests |
| KeyboardShortcuts | from 2.0.0 | Check the recording field in Settings after an update |
| dsh | 0.2.2-alpha.2 in `agent/package.json`, on Node 24.22.2 | Rebuild the runtime, run `scripts/agent_smoke_test.sh`, update `agent/runtime-packages.txt`, and check telemetry is still off in `agent/profile/cordis.patch.yml` |
| Reply page | exact versions in `Web/package.json` | `npm run build` and commit `App/Reply`; CI fails if the build isn't committed |
| GitHub Actions | checkout, cache, setup-node, upload-artifact at v4 | GitHub now runs them on Node 24 with a deprecation warning; move to their next major versions |

The app icon is drawn by `node scripts/make_app_icon.mjs`; see `docs/design/pinhole.md`.

## Watching the model providers

- **Models change under the same name.** deepseek-flash became V4.1-Flash-1017 on 2026-10-17 and began breaking
  off short replies. When replies change, check the provider's change log first.
- **DeepSeek gets the system prompt at the start of the first question** (`OpenAICompatibleClient`). When a new
  model version lands, rerun the test matrix in `docs/prompts.md`, and drop the workaround if system messages
  behave again.
- **Prompts change together with `docs/prompts.md`.**

## Backlog

| Item | Kind | Status |
| --- | --- | --- |
| Bugs and requests from using alpha 134 | Bugs, requests | Owner is using it |
| The question being edited doesn't scroll with the wheel, and sometimes sticks | Bug, P1 | Fixed, in testing |
| A conversation opened with the shortcut has no button back to the end until scrolled | Bug, P2 | Fixed, in testing |
| Changing effort while a reply or command is under way | Edge case | Tested: the reply under way keeps its level, the next one uses the new level |
| A reply keeps being written after Spot Chat quits: 1. reply logic out of the interface, 2. confirm quitting and keep the Mac awake while replying, 3. a background process prototype | Feature | 1 and 2 done; 3 in testing (`docs/design/reply-writer.md`) |
| Chat through the user's own Claude Code or Codex sign-in, no API key: as Easydict runs `claude -p` and `codex exec`, or over ACP through Zed's claude-code-acp and codex-acp, as dsh runs now. Check the adapters and each vendor's terms first | Idea | Later |
| The app feels slow at times | Bug | Needs a log of it: the log now records freezes and slow reply renders |
| swift-format lint in CI | Tooling | Proposed |
| One command that builds and runs the app | Tooling | Proposed |
| Why "You are a helpful assistant." breaks deepseek-flash: other personas, a paraphrase, neutral text of the same length, 30 replies each | Research | Needs a temporary API key |
| Each vendor's end-of-turn and end-of-text tokens, checked against their tokenizer configs | Research | Later |
| The menu bar dot sits close to its ring at 1×; check on a 2× display | Interface | To check |
| GitHub Actions on Node 24 | CI | To do |
