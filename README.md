# bashgent

A Claude-Code / OpenCode-style coding agent in a single Bash script, backed by a local [Ollama](https://ollama.com) server. Built as a **learning project** — the source code is heavily commented to explain how agentic AI tool-calling really works under the hood.

## Quick start

```bash
# 1. Install dependencies
brew install jq                        # macOS
# sudo apt install jq                  # Debian/Ubuntu

# 2. Install and start Ollama
# Download from https://ollama.com, then:
ollama serve &
ollama pull qwen2.5-coder:7b           # or any model that supports tool-calling

# 3. Run bashgent
chmod +x bashgent
./bashgent
```

## Options

```
./bashgent [--yes] [--model MODEL] [--help]
```

| Flag / Env var   | Default                      | Description                               |
|------------------|------------------------------|-------------------------------------------|
| `--yes` / `-y`   | off                          | Skip all confirmation prompts (yolo mode) |
| `--model NAME`   | first model from `/api/tags` | Override which Ollama model to use        |
| `OLLAMA_HOST`    | `http://localhost:11434`     | Ollama server URL                         |
| `OLLAMA_MODEL`   | auto-detected                | Same as `--model`                         |
| `BASHGENT_YES`   | `0`                          | Same as `--yes`                           |

## Example session

```
╔══════════════════════════════════════════════╗
║       bashgent — Ollama coding agent         ║
╚══════════════════════════════════════════════╝
  model : qwen2.5-coder:7b
  host  : http://localhost:11434
  cwd   : /Users/you/project

You: list the files here, then read the main script and summarise it

Thinking…
⚙  list_dir ({"path":"."})
   ↳ total 16 drwxr-xr-x ...
⚙  read_file ({"path":"app.py"})
   ↳ #!/usr/bin/env python3 ...

Assistant: This is a Flask web server with two endpoints: GET /health and POST /process.
```

## Tools

| Tool | Safe? | What it does |
|------|-------|--------------|
| `read_file` | yes | Read a file and return its text |
| `list_dir` | yes | `ls -la` a directory |
| `grep_files` | yes | Recursive regex search |
| `write_file` | confirms | Create or overwrite a file |
| `edit_file` | confirms | Replace a string inside a file |
| `bash_exec` | confirms | Run a shell command |

## Safety

Destructive tools (`write_file`, `edit_file`, `bash_exec`) always ask for confirmation before running. Decline with anything other than `y` or `yes`. To skip prompts in scripts: `BASHGENT_YES=1 ./bashgent`.

## How it works (study guide)

The script is organized into 16 sections, readable top-to-bottom:

| § | Name | What to learn |
|---|------|---------------|
| 1 | Strict mode | `set -euo pipefail` and why it matters |
| 2 | Usage | Writing self-documenting CLI tools |
| 3 | Dependency checks | Fail-fast with actionable messages |
| 4 | Configuration | Environment variables and defaults |
| 5 | Colors/UI | ANSI escapes, terminal detection |
| 6 | Model detection | `GET /api/tags` Ollama API call |
| 7 | System prompt | How to write agent instructions |
| 8 | Tool schemas | OpenAI-style function-calling JSON format |
| 9 | History helpers | Managing JSON arrays with jq |
| 10 | Ollama client | `POST /api/chat` with curl |
| 11 | Confirmation | Human-in-the-loop safety gate |
| 12 | Tool implementations | One function per tool, error-as-output pattern |
| 13 | Tool dispatcher | `case` routing by name |
| 14 | Input reader | Line continuation, EOF handling |
| 15 | Agent loop | **The core**: outer REPL + inner tool-call loop |
| 16 | Main | Flag parsing, startup, wiring it together |

The most important section is **§15**. It shows exactly why agents need two nested loops, and how tool results flow back into the conversation before the model produces its final reply.
