# More ways to bring your own AI (2026-10-11)

The owner asked that people can use a wide range of providers and keys, and run OpenClicky off a
Claude Code or Codex subscription they already pay for. Scope chosen: OpenRouter, Claude Code plan,
Codex/ChatGPT plan, and Gemini, Groq, Mistral, xAI natively.

## What changes

- Questions (the ⌃⌥ ask lane, screen grounding, the tour's "watch this" demo) can be answered by
  any of: Anthropic key, OpenAI key, OpenRouter, Google Gemini, Groq, Mistral, xAI, the Claude Code
  CLI on a Claude plan, Codex on a ChatGPT plan, or OpenClicky's free credits.
- Every question still goes through `ClaudeAPI.analyzeImageStreaming`; `ProviderRouter` decides the
  source and ClaudeAPI hands the request to an `AnswerProvider` (AnswerProvider.swift) for any
  source other than Anthropic or the backend.
- Order when "automatic": an explicit `answerSource` in shell.json wins if usable; otherwise own keys
  (Anthropic, OpenRouter, OpenAI, Gemini, xAI, Mistral, Groq), then plans the person switched on
  (Claude Code, Codex), then the OpenClicky account, else unavailable.
- Quick actions (tool calls) work on the API providers through their function calling; the two CLI
  plans answer and point but do not run tools.
- Clean-up of dictation, spoken answers, transcription and realtime voice stay as they are
  (OpenAI key or account); this change is about who answers.

## Providers

| Source | How | Default model |
|---|---|---|
| OpenAI, OpenRouter, Groq, Mistral, xAI | `/chat/completions`, SSE, images as data URLs, tools as functions | gpt-4.1, anthropic/claude-sonnet-4.6, llama-4-scout, mistral-medium-latest, grok-4 |
| Gemini | `models/{m}:streamGenerateContent?alt=sse`, inlineData images, functionDeclarations | gemini-2.5-flash |
| Claude Code plan | `claude -p` with stream-json input (image blocks) and output, no tools, one turn | the CLI's |
| Codex plan | `codex exec -i <image>` read-only, `--output-last-message`, not streamed | the CLI's |

Models can be overridden per source in shell.json `answerModels`.

## Settings

- Account → Your keys: OpenAI, Anthropic, OpenRouter, Gemini, Groq, Mistral, xAI, Sarvam.
- Account → Subscriptions: Claude Code and Codex, each detected (installed, signed in) with a switch.
- Clicky → "Answers come from": Automatic or one source; shows which one is answering now.
