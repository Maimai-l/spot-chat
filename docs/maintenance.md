# Maintenance

How Spot Chat is kept working between features: reporting and fixing bugs, shipping alphas, and keeping the
build and its dependencies healthy. The rules themselves are in `CLAUDE.md`; this is the routine.

## Reporting a bug

Tell Claude in a session, or open an issue on the repository, with:

- **What you did, what you expected, what happened.** One line each is enough.
- **A screenshot or screen recording** when something looks or moves wrong.
- **The log.** Settings > General > Export Logs… saves it as one file. Its first line names the build, such as
  `Spot Chat 0.1.0 alpha 134`, as Settings > General > Version does, and every line carries a time, so say
  roughly when it happened. It ends with the
  crash reports macOS kept for Spot Chat's processes in the last 30 days.

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
   The screenshot comparison fails on a screen that changed; accept the new baselines only for a change that
   was meant.
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
| dsh | Followed, not pinned: `agent/package.json` names the `next` channel, its release candidates, on Node 24.22.2 | Each CI run builds the newest release whole, records what loads in the smoke test (which also changes the effort, stops a turn and resumes a session), trims to that and tests again. The run's summary names the dsh version and any package not yet in `agent/runtime-packages.txt`: add those. When the smoke or command tests fail on a new release, adapt to it; check telemetry is still off in `agent/profile/cordis.patch.yml` |
| Reply page | exact versions in `Web/package.json` | `npm run build` and commit `App/Reply`; CI fails if the build isn't committed |
| GitHub Actions | checkout v7, cache v6, setup-node v7, upload-artifact v7, download-artifact v8 | Read each major version's breaking changes before moving |

The app icon is drawn by `node scripts/make_app_icon.mjs`; see `docs/design/pinhole.md`.

## Watching the model providers

- **Models change under the same name.** deepseek-flash became V4.1-Flash-1017 on 2026-10-17 and began breaking
  off short replies. When replies change, check the provider's change log first.
- **DeepSeek gets the system prompt at the start of the first question** (`OpenAICompatibleClient`). When a new
  model version lands, rerun the test matrix in `docs/prompts.md`, and drop the workaround if system messages
  behave again.
- **Prompts change together with `docs/prompts.md`.**

## Watching dsh

- dsh takes bug reports in its GitHub Discussions, not issues. On a new release, search the Discussions for
  `acp`, `llm-deepseek`, `sandbox` and `macOS`.
- Its CVEs are filed by others (VulnCheck, VulDB, MITRE), not on the repository's advisories page. Search NVD
  for "DeepSeek Harness", "deepseek-harness" and "DeepSeek dsh" (each finds records the others miss), OSV by
  the repository (`ecosystem: GIT`), and GitHub's advisory database for "deepseek".
- Bugs on Spot Chat's path, checked against 0.2.2-rc.1 on 2026-11-04, and what Spot Chat does about them:

| Discussion | Bug | Spot Chat |
| --- | --- | --- |
| 7050, 11029 | A tool call saved without its thinking makes DeepSeek reject every later turn of the session | Leaves the session; a turn that failed before doing anything runs again in a new one |
| 11577 | A tool call with broken JSON ends the turn | The profile retries it (`retryPolicy` in `cordis.patch.yml`) |
| 9980 | A turn where the model only thinks ends with no reply | Shows "The reply was empty." with Retry |
| 12133 | Renaming the folder fails every later turn | Checks the folder before each turn and says it can't be found |
| 12136 | A session log dsh can't read is skipped without a word | The failed resume is logged |
| 10553 | Changing the tools mid-session can break it with a 400; the web switch does this | To test against the real API |
| 11511 | A tall image through `read_image` can break later turns | To test |
| 10363 | Sandboxed commands can't reach the local network on macOS | To test |

CVEs naming dsh, checked against 0.2.2-rc.1 as Spot Chat runs it:

| CVE | What | Spot Chat |
| --- | --- | --- |
| 2026-82533 | Local HTTP control API accepts a spoofed Host header | Not affected: fixed in 0.1.2-alpha.1 |
| 2026-82033 | Web profile's RPC control plane has no authentication | Not affected: fixed in 0.1.2-alpha.2 |
| 2026-101078 | bwrap sandbox run as root can remount the filesystem | Not affected: Linux only |
| 2026-101102 | Code Mode `run_code` sandbox | Not affected: the tool isn't in the profile |
| 2026-101131 | E2B sandbox trusts `E2B_API_KEY` | Not affected: E2B isn't in the runtime |
| 2026-101132 | Path traversal through a profile's `dsh.bundle.patch` | Not affected: the only profile is the app's own, replaced on every start |
| 2026-108789 | Workflow tool escapes its vm | Not affected: workflows are off and not in the runtime |
| 2026-116367 | `cordis-host-runner` sandbox | Not affected: not in the runtime |
| 2026-116368 | Browser authentication of the web client | Not affected: not in the runtime |
| 2026-95182 | MCP servers and sandbox runners started by bare name through PATH | MCP: not affected, no servers are configured anywhere. Sandbox: `sandbox-exec` is found through PATH, where `/opt/homebrew/bin` comes first; open |
| 2026-95183 | Instructions injected into fetched pages survive context compaction | Applies: web tools and compaction are on, and the sandbox leaves the network open; open |
| 2026-108788 | Sandbox `spawn` with a crafted profile | Undetermined: the details are only in a Feishu document behind a login |

Not a CVE, but on the same path: the macOS sandbox profile has no network rule, so commands can reach local
services such as Docker Desktop's socket and ssh-agent (Discussion 4503); open.

## Backlog

| Item | Kind | Status |
| --- | --- | --- |
| Bugs and requests from using alpha 134 | Bugs, requests | Owner is using it |
| A command turn stops when a new conversation starts, and reopening it in the full window loses its context | Bug, P1 | Fixed, in testing |
| The question being edited doesn't scroll with the wheel, and sometimes sticks | Bug, P1 | Fixed, in testing |
| A conversation opened with the shortcut has no button back to the end until scrolled | Bug, P2 | Fixed, in testing |
| Changing effort while a reply or command is under way | Edge case | Tested: the reply under way keeps its level, the next one uses the new level |
| A reply keeps being written after Spot Chat quits: 1. reply logic out of the interface, 2. confirm quitting and keep the Mac awake while replying, 3. a background process prototype | Feature | 1 and 2 done; 3 in testing (`docs/design/reply-writer.md`) |
| The app feels slow at times | Bug | Needs a log of it: the log now records freezes and slow reply renders |
| swift-format lint in CI | Tooling | Proposed |
| One command that builds and runs the app | Tooling | Proposed |
| Why "You are a helpful assistant." breaks deepseek-flash: other personas, a paraphrase, neutral text of the same length, 30 replies each | Research | Needs a temporary API key |
| Each vendor's end-of-turn and end-of-text tokens, checked against their tokenizer configs | Research | Later |
| The menu bar dot sits close to its ring at 1×; check on a 2× display | Interface | To check |
| dsh bugs still to test: the web switch mid-session, tall images, the local network (above) | Research | Needs a temporary API key |
