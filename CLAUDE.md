# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository shape

Personal experiments sandbox. Each experiment is a self-contained artifact under `experiments/` — no shared build system, no cross-experiment imports. Add new experiments as a new subdirectory in `experiments/`. Keep root clean: only top-level project config (`.gitignore`, `README.md`, `CLAUDE.md`).

Current layout:

- `experiments/bashgent/bashgent.sh` — Ollama-backed coding agent (see below).
- `experiments/traceroute/traceroute.py` — toy traceroute in Python (UDP probes + ICMP receive), based on alexanderell.is/posts/toy-traceroute.
- `study/otp/totp2fa.sh` — RFC 6238 TOTP 2FA CLI demo (enroll / generate / verify / watch).
- `study/prompt_injection/` — slide-deck PDFs from a prompt-injection talk; reference material, no code.

## Current experiment: `experiments/bashgent/bashgent.sh`

A Claude-Code-style coding agent in a single Bash script, backed by a local Ollama server. Built for **learning**; every section has explanatory comments. Keep that property when editing — prefer clarifying comments over terseness.

### Running

```bash
# Prerequisites (once): ollama serve, plus at least one tool-calling model pulled:
#   ollama pull qwen2.5-coder:7b

./experiments/bashgent/bashgent.sh                       # auto-detect model
./experiments/bashgent/bashgent.sh --debug               # full request/response traces in gray
./experiments/bashgent/bashgent.sh --yes                 # auto-confirm destructive tools
./experiments/bashgent/bashgent.sh --model llama3.1:8b   # override auto-detection
BASHGENT_DEBUG=1 ./experiments/bashgent/bashgent.sh      # env-var equivalents exist for all flags
```

Syntax-only check (no Ollama needed): `bash -n experiments/bashgent/bashgent.sh`.

### Script architecture — read the sections in order

The script is ordered as a linear narrative in 16 numbered sections (`# ── §N  Name ──`). The **agent loop is §15** — everything else is supporting infrastructure. If you're confused about the overall flow, start there.

The loop is two nested `while`s:
- **Outer** — one iteration per user message (REPL turn).
- **Inner** — keep POSTing to `/api/chat` until the model stops returning `tool_calls`. This is what makes it an agent rather than a chatbot.

### Non-obvious invariants — violating these will cause silent hangs or corrupt history

1. **Tool functions run inside `$(dispatch_tool_call ...)`** in §15. Their stdout is captured as the tool-result string. Anything the human should see — confirmation prompts, progress lines — MUST go to stderr (`>&2`) or it vanishes into the capture and the script appears to hang. See `confirm()` in §11 and the `$ cmd` progress line in `tool_bash_exec`.

2. **Tool functions never exit non-zero.** Errors are returned as output prefixed with `ERROR:` so the model sees them and can recover. Never `return 1` from a tool — the `$(...)` capture plus `set -e` would abort the agent loop.

3. **History append uses `jq --argjson m`** (not `--arg`). Assistant messages contain a nested `tool_calls` array; `--arg` would stringify it and corrupt subsequent requests. See `history_append_json()` in §9.

4. **`local var="$(cmd)"` masks `cmd`'s exit code** because `local` itself always returns 0 — a classic `set -e` gotcha. Declare `local var` on one line, then assign `var="$(cmd)"` on the next. See the pattern in `run_agent_loop`.

5. **Don't use `read -e`.** Readline mode hijacks echo in some terminals (IDE-embedded shells, minimal emulators, readline-less bash builds) and the user sees nothing as they type. Plain `read -r` relies on the terminal's native cooked-mode echo and works everywhere.

6. **Target bash 3.2+.** macOS ships bash 3.2 — the script avoids bash 4 features (`declare -A`, `mapfile`, namerefs). Stick to that baseline when adding code.

### External contract: Ollama `/api/chat` wire format

Tool calls come back as `response.message.tool_calls[i].function.{name, arguments}` where `arguments` is already a **JSON object** (Ollama is not OpenAI-compatible on this point — OpenAI returns `arguments` as an encoded string). Tool results go back as messages with `{"role": "tool", "content": "...", "tool_name": "..."}`. The whole flow runs with `"stream": false` to keep Bash parsing simple — streaming would require accumulating partial `tool_calls` across many NDJSON lines.

## Commit style

Conventional-Commits prefix (`feat:`, `fix:`, `refactor:`, …), imperative subject under ~70 chars, blank line, then a body explaining the *why* — including a short user quote when the change came from a specific user report ("Per user: ..."). See `git log` for examples. Use HEREDOC for the commit message to preserve formatting, and include the `Co-Authored-By` trailer.
