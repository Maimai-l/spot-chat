# Working on Spot Chat

Spot Chat is a native macOS floating AI window in Swift, SwiftUI and AppKit, built the way a product team would
build it. Treat every request as a feature in that product: work out what doing it well means, include the parts a
careful engineer would obviously include, and ask only when a choice really belongs to the owner.

## Delivery

- Every build is an alpha for testing. Don't publish releases or tags.
- An alpha is the release app packaged by a full CI run, delivered with an acceptance checklist in Chinese.
- Before saying something is done, check it in the app's own screenshots, not only in code.
- When a design changes, mock it up first if asked, and review the result critically before sending it.
- Measure against the reference when matching another app: same scale, pixel measurements, side by side.

## Interface

- One accent color, the system accent color. Everything else is gray, as in Claude.
- No emoji or Unicode symbols in place of buttons or icons; use SF Symbols or drawn shapes.
- Copy is written as macOS System Settings writes it, in English and Simplified Chinese:
  - no explanatory captions, comments or parentheticals in the interface;
  - buttons are verbs, states are short and standard, one name per concept everywhere;
  - no 句号 on buttons, titles, hints or table cells, and a space between CJK and Latin text or numbers;
  - no " · " or similar separators joining items.
- The input bar matches Gemini: 54 tall, 28 buttons, corners circular arcs of radius 24, lines 20 apart.
  See `docs/design/composer-vs-gemini.png`.

## Privacy

- Telemetry and log uploads stay off, including in the bundled dsh runtime (`agent/profile/cordis.patch.yml`).
- Commands outside the chosen folder always ask first; nothing is approved automatically.

## Code

- Prefer maintained libraries and dsh's own code over writing equivalents.
- SpotKit holds the logic in packages (SpotCore, SpotData, SpotAI, SpotAgent); the app target holds the interface.
- Comments say what and why in plain words.

## CI

The commit message chooses what runs, so iterating stays fast:

| Tag | Runs |
|---|---|
| none | every UI test, and the release app packaged as an alpha, side by side |
| `[ui: testA testB]` | only those UI tests |
| `[ui: none] [release]` | only the alpha |
| `[ui: testA] [release]` | those tests and the alpha |

Core tests run when `Packages/`, `Web/`, `App/Reply/`, `scripts/` or `.github/` change. Screenshots are uploaded
as PNGs in the `Screenshots` artifact, and each run's summary lists what ran and what failed.

Pushing cancels the run in progress on the branch, so batch changes before pushing, and don't push over a run
whose results are still needed.

## Git

- Commit with clear messages that say what changed and why; never put model names in commits or code.
- Don't open pull requests unless asked.
