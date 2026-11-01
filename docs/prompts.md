# Prompts

What Spot Chat tells the model, and why.

## Chats

The default system prompt, which the user can change in Settings > General:

```
Current date: {{date}}

Answer in the language the user writes in, as briefly or as fully as the question needs. Use Markdown where it helps reading, with $…$ and $$…$$ for math. In Chinese, use full-width punctuation.
```

- **No persona.** DeepSeek's own chat sends only the date and the user's location. Given a "You are …"
  system message, deepseek-flash (V4.1-Flash-1017) often broke off a short reply mid-word with a stray
  token, such as "帮S助" or "<eos>". Tested against the API with greetings:

  | System prompt | Broken replies |
  | --- | --- |
  | none, or an empty one | 0 of 10 |
  | the date only | 1 of 10 |
  | "你是一个乐于助人的助手。" | 4 of 10 |
  | "You are a helpful assistant." | 8 of 10 |
  | "You are a helpful assistant.", at the start of the first question instead | 1 of 30 |

  So for DeepSeek the system prompt also goes at the start of the first question rather than in a system
  message (`OpenAICompatibleClient.makeStreamRequest`).
- **The date**, as every vendor's chat prompt gives it, so the model knows what "today" and "latest" mean.
- **Language and length**, after Kimi's "Match the user. Follow their lead on language, depth, and
  formality."
- **Math delimiters** the reply page renders with KaTeX, as Gemini's prompt names them.
- **Full-width punctuation in Chinese**, after Kimi's prompt.

Earlier defaults saved unchanged count as the default, so they move to this one.

With web search on, dsh's web_search and web_fetch guidance follows (`DeepSeekWebTools.guidance`).

## Running commands

dsh writes the system prompt from its own tool guidance. Spot Chat's profile
(`agent/profile/cordis.patch.yml`) replaces only its first line:

```
You run commands on the user's Mac to get their task done, working in the folder they chose. Answer in the language the user writes in.
```

It says what the agent is doing rather than giving it a persona, for the same reason as above: dsh sends
it as a system message, which Spot Chat can't move.

## Sources

- DeepSeek's chat: [asgeirtj/system_prompts_leaks, DeepSeek/deepseek-chat.md](https://github.com/asgeirtj/system_prompts_leaks/blob/main/DeepSeek/deepseek-chat.md)
- dsh with deepseek-flash: [jujumilk3/leaked-system-prompts, deepseek-dsh_20260917.md](https://github.com/jujumilk3/leaked-system-prompts/blob/main/deepseek-dsh_20260917.md)
- Kimi K3, Qwen 3.8 and Gemini 3 Flash: the `Kimi`, `Qwen` and `Google` folders of asgeirtj/system_prompts_leaks
