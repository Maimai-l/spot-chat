# Spot Chat bridge for DeepSeek Harness

Lets Spot Chat run its commands in the DeepSeek Harness you already use, so its conversations appear among
your sessions there and you can watch them. Approvals for commands outside the folder are still answered in
Spot Chat.

## Install

Quit DeepSeek Harness, then run the command Spot Chat copies from Settings > General > Run Commands:

```bash
dsh plugin --profile desktop add "file:/Applications/Spot Chat.app/Contents/Resources/dsh-bridge"
```

For `dsh web`, use `--profile web`. Then choose DeepSeek Harness under Run In.

## How it works

The plugin listens on a Unix socket in `~/Library/Application Support/Spot Chat/dsh-bridge`, a folder only
your account can open. A connection first sends Spot Chat's token; Spot Chat keeps the token in the Keychain
and writes only its SHA-256 beside the socket. A connection with the right token gets an ACP server of its
own, dsh's own `dsh-acp`, whose sessions use your default agent preset, models and settings.
