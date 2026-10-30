# Running commands

A conversation can run commands in a folder through the bundled dsh. dsh's sandbox lets a command write only inside that folder; when one needs more, Spot Chat asks first.

The mini window and the full window use the same parts: the input, the list of commands in a reply, and the approval card. The full window adds what its room allows.

## Turning it on

- The + menu has **Run Commands**, with the line "Runs in a folder you choose and asks before going outside it". It is a menu item with a check mark, not a separate control.
- Turning it on uses the folder of the first file in the input, or asks for a folder.
- The input then shows a chip with the folder's name, **Run Commands Movies**, next to the +. Its menu: Choose Another Folder…, Show in Finder, Stop Running Commands.
- While commands run, files dropped or added go in **by path**. dsh reads them where they are, and only the path goes into the question. The + menu shows **Add File Path…** in place of the uploads.

## In the conversation

- A reply shows its text, then **Ran 2 commands**, folded under one line like Thinking. It is open while the reply is being written.
- Each command shows its summary from dsh, the command in a code box, and the end of its output. While it runs it has a Stop button; when it ends, how long it took.
- States: running, succeeded, failed with its exit code, stopped by the sandbox, denied, stopped, and ran outside the folder (in orange).

## Asking before going outside the folder

dsh first runs every command in its sandbox. When the sandbox stops one and dsh asks to run it without the sandbox, a card appears in the reply:

- Title: **Run this command outside Movies?**
- dsh's reason, the command, and the orange note **This one runs without the sandbox**.
- **Deny** (Esc) and **Allow Once** (⌘↩). There is no "always allow".
- Stopping the reply while the card is open answers no.

## Full window

![Full window](command-mode-full-window.png)

1. Conversations that run commands have a terminal icon in the sidebar.
2. The folder chip's menu has **Show in Finder**, since what the commands make is in that folder.
3. Files dropped anywhere on the window go in by path.

## Icons

Buttons and labels use SF Symbols, never emoji: `apple.terminal` for running commands, `paperclip` for adding paths, `checkmark.circle.fill`, `xmark.circle.fill`, `hand.raised.circle.fill` and `stop.circle.fill` for command states, `exclamationmark.triangle.fill` for the note on the approval card. Files show their Finder icon. The mockups draw these as plain shapes because a browser has no SF Symbols.
