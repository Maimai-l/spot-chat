# Lessons

Problems this project hit and what fixed them, so they aren't solved twice.

## Models

- **deepseek-flash breaks off short replies under a system message.** Greetings came back as "帮S助",
  "<eos>" or code fragments, with thinking on or off, through both the OpenAI and the Anthropic formats. The
  system prompt now opens the first question for DeepSeek, and prompts carry no persona. Tests and sources are
  in `docs/prompts.md`.
- **A lower temperature didn't help.** Without thinking deepseek-flash holds top_p at 1.0, and its model card
  recommends temperature 1.0; the change was reverted.
- **`deepseek-flash` changes under the same name.** It became V4.1-Flash-1017 on 2026-10-17; check DeepSeek's
  change log when replies change.

## Commands

- **A level dsh refused counted as set.** `CommandAgent` dropped the error from `session/set_config_option`
  and marked the level applied, so it was never tried again. A refused or unoffered option is now logged
  and tried again next turn.

## Interface

- **A step's output spilled over the steps below.** SwiftUI's `Text` with `.lineLimit(n)` and
  `.truncationMode(.head)` reserved room for n lines and drew them all. The step now shows the end of the output
  cut in code (`CommandOutput.tail`), one row per line as a terminal shows it, so the text is exactly as tall as
  what it shows and a long line doesn't wrap into many.
- **A reopened conversation sat mid-way with no button back to the end.** It followed the end once on
  appearing, before the card had grown and the replies had rendered, and the button showed only after the
  reader scrolled up. `MessageList` now keeps following the end while the conversation's size settles, and
  shows the button whenever the view is away from the end.
- **Opening an edit scrolled the question away.** Following the end while the conversation's size settles
  also followed the edit box growing it. Editing now stops following the end, and saving brings the new reply
  into view.
- **The question being edited didn't scroll with the wheel and sometimes stuck.** SwiftUI's vertical
  `TextField` past its line limit ignores the wheel on macOS. The edit box now uses the input's own text view,
  `ComposerField`, whose scroll view hands the wheel on while the text fits.
- **Typed text sat a point below the +.** Fixing lines at 20 points put the extra height above the glyphs;
  `ComposerTextMetrics.baselineOffset` raises them. Measure glyphs, not the caret.
- **Menu check marks didn't line up.** Tab stops and image-less attachments don't place them reliably;
  `ModeMenuItem` spaces them with a blank image of measured width.
- **The model menu scrolled near the bottom of the screen.** `NSMenu.popUp(beside:)` opens upward when there's
  no room below.
- **The first reply showed a second late.** `ReplyPageWarmup` loads the reply page at launch.
- **Steps showed after the whole reply.** Each step records `textOffset`, and `ReplyPiece.layout` puts it where
  it began.
- **The window looked heavy next to Gemini's.** It was 480 wide with a grayer, more see-through bar, no rim and
  white blocks inside the card; it now follows Gemini's measurements (`docs/design/composer-vs-gemini.png`).

## Build and CI

- **The core tests couldn't start.** Resolving packages with a newer local Swift pinned swift-collections 1.7.5,
  which needs Swift 6.4; CI has 6.1. Dependencies are held at versions CI can read (see CLAUDE.md).
- **Logging libraries:** Puppy pins swift-log 1.6; CocoaLumberjack after 3.9.0 needs a newer Swift than CI.
- **Screenshots failed to upload** when a test failure attached a text file with quotes in its name; the export
  keeps only images and sanitizes names.
- **testCardExpandsToTheFullWindowAndCollapsesBack failed once** waiting for the card after collapsing, and
  passed on a rerun; it now waits longer, and every failure attaches a screenshot.
- **A UI test passed while the reply was blank**: it reads accessibility text, so the loading test also checks
  the reply's rendered height.
- **The screenshot comparison flagged two Chinese input screens** at 0.07%: macOS showed its input source
  bubble under the caret after Chinese text was typed. CI turns the indicator off, and those screens ignore
  the spot under the caret.
- **A dsh release added a tool, `working_directory`, that moves the model's folder.** The sandbox's writable
  folder stays the one the session started in (`sandbox-policy`: `session.header.cwd`), so commands outside
  it still ask; the smoke test's tool list shows new tools, worth a look on each release.
- **dsh's bugs are in its Discussions.** Its issues are closed; about a thousand bug reports sit in the
  Discussions, most about its desktop app. The few on Spot Chat's path are worked around in the client or the
  profile (`docs/maintenance.md`), and each has a mock scenario and a UI test.
- **A failed dsh resume was dropped with `try?`**, so a lost session showed up nowhere; it is logged now.
- **A command turn stopped halfway, and the next question lost its context.** Commands ran on a dsh that
  belonged to the window: a new conversation stopped the turn, and the full window started a second dsh that
  couldn't resume the session the first still held ("already owned by an active write handle"), so it began
  an empty one. The same window also reused its dsh for another conversation in the same folder, carrying the
  first conversation's session over. Each conversation now has one dsh, wherever it is shown, and its turn
  goes on when the window shows something else. A long command also looked stuck, since dsh shows output only
  at the end; a running step shows how long it has run.
- **"New Chat" stopped the reply under way, chat replies included, after replies were meant to outlive the
  window.** The rule was the mini window's from the first stage; when the reply writer made replies go on,
  only switching conversations was changed. When a rule like this changes, search every place that stops a
  reply (`stopGeneration`, `stop()`, `load`), not only the one at hand.
