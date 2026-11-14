# Spot Chat bridge for DeepSeek Harness

Lets Spot Chat run its commands in the DeepSeek Harness you already use, so its conversations appear among
your sessions there and you can watch them. Approvals for commands outside the folder are still answered in
Spot Chat.

## Install

In Spot Chat, choose DeepSeek Harness under Settings > General > Run In, and follow the steps it shows: in
DeepSeek Harness, open Plugins > Add Plugin and paste the location Spot Chat copies, which is
`/Applications/SpotChat.app/Contents/Resources/dsh-bridge` for the app in Applications. Spot Chat connects
once DeepSeek Harness has loaded the plugin.

## How it works

The plugin listens on a Unix socket in `~/Library/Application Support/Spot Chat/dsh-bridge`, a folder only
your account can open. A connection first sends Spot Chat's token; Spot Chat keeps the token in the Keychain
and writes only its SHA-256 beside the socket. A connection with the right token gets an ACP server of its
own, dsh's own `dsh-acp`, whose sessions use your default agent preset, models and settings.

dsh adds each session's log to its requests to DeepSeek's official API unless you turn it off in its
settings. The plugin leaves it out for the sessions Spot Chat creates or joins, which it lists in
`sessions` in the same folder; your other sessions are as you set them.
