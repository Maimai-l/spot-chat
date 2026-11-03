# The reply writer

A chat reply is written by SpotChatWriter, a small program inside the app (`Contents/MacOS`), so the reply is
finished and saved even when Spot Chat quits or crashes partway through, as it would be by a chat service's
server.

## How it works

1. The app saves the question and an empty, pending reply, then starts the writer with a `ReplyJob` as JSON
   on its input: the request, the reply's id, the provider and the app's data folder. The provider's address
   and key are read from the database, so they never pass through the job.
2. The writer runs `ChatReplyRunner`, the same code the app runs, and saves the reply into the database at
   most five times a second. While the app is there it also prints each update as a line of JSON, which the
   app shows at once.
3. While it writes, the writer keeps the Mac from sleeping on its own and leaves a mark in
   `Writers/<reply id>` holding its process id. When it is done it saves the final reply, removes the mark,
   logs how long it took and how much memory it used, and exits.
4. Stop sends it SIGTERM; it saves the reply as stopped, keeping what arrived.

When the app quits, the writer is not stopped: a process started this way outlives the app that started it.
Its pipe to the app closes, and it goes on saving to the database alone.

## After a relaunch, or in another window

A pending reply with a live writer, known from its mark, is shown as being written, and the app reads it from
the database four times a second until the writer is done. A pending reply without one was cut off by a
restart or a crash and is shown as stopped.

## What stays in the app

- Commands: dsh asks for approval through the window, so they run in the app, and quitting while one runs
  asks first (`WorkGuard`).
- Replies when the writer isn't in the build or won't start: the app writes them itself, as before.

## Why a child process rather than a launchd agent

A launchd agent registered with `SMAppService` would also outlive the app, but it needs a background item the
user approves in System Settings and a stable code signature, which alpha builds don't have. A child process
needs neither, starts only for a reply and exits after it, so it holds no memory when nothing is written.

## Logging

The writer logs to its own files, `Writer <date>.log`, in `~/Library/Logs/Spot Chat`, one per reply, so two
processes never share a file. Export Logs includes them after the app's own.
