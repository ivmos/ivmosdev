#!/usr/bin/env bash
# =============================================================================
# bashgent — A Claude-Code / OpenCode-style coding agent in Bash
#            backed by a local Ollama server (https://ollama.com)
#
# WHAT THIS TEACHES (read top-to-bottom):
#   1. The agent tool-calling loop:
#        user → POST /api/chat → model returns tool_calls → execute tools →
#        POST /api/chat again (with results) → model replies → repeat
#   2. Ollama /api/chat JSON wire format (tools, tool_calls, tool results)
#   3. Bash JSON manipulation with jq (no manual string escaping)
#   4. Human-in-the-loop safety: destructive tools ask before running
#
# REQUIREMENTS:
#   bash >= 3.2  (macOS default; brew install bash for 5+)
#   curl         (HTTP client)
#   jq           (JSON processor — https://jqlang.github.io/jq/)
#   ollama serve (running locally — https://ollama.com)
#   At least one model: e.g. ollama pull qwen2.5-coder:7b
#
# USAGE:
#   ./bashgent [--yes] [--model MODEL] [--help]
#
# ENVIRONMENT:
#   OLLAMA_HOST   Ollama base URL          (default: http://localhost:11434)
#   OLLAMA_MODEL  Model to use             (default: first from GET /api/tags)
#   BASHGENT_YES  Set to 1 to skip confirms (default: 0)
# =============================================================================

# ── §1  Strict mode ───────────────────────────────────────────────────────────
# -e  exit on any unhandled error
# -u  error on unset variables (catches typos like $OLLAM_HOST)
# -o pipefail  propagate pipe failures (cmd1 | cmd2 — fails if cmd1 fails)
# IFS=$'\n\t'  word-split on newlines/tabs only, not spaces (safe for filenames)
set -euo pipefail
IFS=$'\n\t'

# ── §2  Usage ─────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
bashgent — Ollama-backed coding agent (learning demo)

USAGE:
  ./bashgent [OPTIONS]

OPTIONS:
  --yes, -y       Auto-confirm destructive tool calls (yolo mode)
  --model NAME    Force a specific Ollama model name
  --help, -h      Show this help and exit

ENVIRONMENT:
  OLLAMA_HOST     Ollama server URL           (default: http://localhost:11434)
  OLLAMA_MODEL    Model override              (default: first from /api/tags)
  BASHGENT_YES    1 = skip all confirmations  (default: 0)

TOOLS AVAILABLE TO THE MODEL:
  read_file      Read a file's contents                        (safe)
  list_dir       List directory contents                       (safe)
  grep_files     Regex search across files                     (safe)
  write_file     Create or overwrite a file          [confirms]
  edit_file      String-replace text inside a file   [confirms]
  bash_exec      Run an arbitrary shell command       [confirms]

IN THE REPL:
  End a line with \   to continue input on the next line
  Ctrl-D              to quit
EOF
}

# ── §3  Dependency checks ─────────────────────────────────────────────────────
# Fail early with a clear message rather than a cryptic error deep in a subshell.
check_deps() {
  local missing=0
  for cmd in curl jq awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      printf 'ERROR: missing required command: %s\n' "$cmd" >&2
      missing=1
    fi
  done
  if [[ $missing -eq 1 ]]; then
    printf '\nInstall missing tools:\n'
    printf '  macOS:  brew install curl jq\n'
    printf '  Debian: sudo apt install curl jq\n'
    exit 1
  fi >&2

  # The script avoids bash 4+ features (no declare -A, no mapfile) so it runs
  # on macOS's built-in bash 3.2. Upgrade with: brew install bash
  if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    printf 'NOTICE: bash %s detected (< 4). Script is compatible, but bash 4+ is nicer.\n' \
      "$BASH_VERSION" >&2
  fi
}

# ── §4  Configuration ─────────────────────────────────────────────────────────
# All settings have environment-variable overrides so bashgent is composable.
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-}"   # empty = auto-detect in §6
BASHGENT_YES="${BASHGENT_YES:-0}"  # 1 = skip confirmation prompts

# Temp file for JSON conversation history — set in main(), cleaned on exit.
HISTORY_FILE=""

# ── §5  Colors / display helpers ──────────────────────────────────────────────
# Emit ANSI color codes only when stdout is a real terminal (-t 1).
if [[ -t 1 ]]; then
  C_USER=$'\033[96m'   # bright cyan  — "You:" label
  C_ASST=$'\033[92m'   # bright green — "Assistant:" label and banner
  C_TOOL=$'\033[93m'   # yellow       — tool call / result lines
  C_WARN=$'\033[91m'   # red          — confirmations and warnings
  C_DIM=$'\033[2m'     # dim          — secondary info
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_USER='' C_ASST='' C_TOOL='' C_WARN='' C_DIM='' C_BOLD='' C_RESET=''
fi

print_banner() {
  printf '\n%s%s' "$C_BOLD" "$C_ASST"
  printf '╔══════════════════════════════════════════════╗\n'
  printf '║       bashgent — Ollama coding agent         ║\n'
  printf '╚══════════════════════════════════════════════╝\n'
  printf '%s' "$C_RESET"
  printf '  %smodel :%s %s\n'  "$C_DIM" "$C_RESET" "$OLLAMA_MODEL"
  printf '  %shost  :%s %s\n'  "$C_DIM" "$C_RESET" "$OLLAMA_HOST"
  printf '  %scwd   :%s %s\n'  "$C_DIM" "$C_RESET" "$PWD"
  printf '  %stips  :%s end line with \\ for multi-line  •  Ctrl-D to quit\n' \
    "$C_DIM" "$C_RESET"
  printf '\n'
}

# ── §6  Model auto-detection ──────────────────────────────────────────────────
# GET /api/tags  →  { "models": [ { "model": "qwen2.5-coder:7b", ... }, ... ] }
# We pick the first installed model. Override with --model or $OLLAMA_MODEL.
detect_model() {
  local tags_json
  if ! tags_json="$(curl -fsS --max-time 5 "${OLLAMA_HOST}/api/tags" 2>&1)"; then
    printf 'ERROR: Cannot reach Ollama at %s\n' "$OLLAMA_HOST" >&2
    printf '  Is the server running?  Try: ollama serve\n' >&2
    exit 1
  fi

  # jq's "// empty" returns nothing (not the string "null") when the path is
  # missing or the array is empty — avoids surprises with empty-string checks.
  local model
  model="$(printf '%s' "$tags_json" | jq -r '.models[0].model // empty')"

  if [[ -z "$model" ]]; then
    printf 'ERROR: Ollama has no models installed.\n' >&2
    printf '  Pull one first, e.g.: ollama pull qwen2.5-coder:7b\n' >&2
    exit 1
  fi

  printf '%s' "$model"
}

# ── §7  System prompt ─────────────────────────────────────────────────────────
# The system message is the FIRST message in every conversation. It defines:
#   - The agent's role and environment (who am I, where am I)
#   - What tools it has and when to use them
#   - Behavioral constraints (stay concise, stop calling tools when done)
#
# A well-crafted system prompt is often the single largest lever on agent quality.
build_system_prompt() {
  cat <<EOF
You are bashgent, an expert coding assistant running in an interactive Bash terminal.

Environment:
  Working directory: $PWD
  Operating system:  $(uname -s) $(uname -m)

You have six tools for filesystem and shell interaction:
  read_file(path)                                     — Read a file's contents.
  write_file(path, content)                           — Create/overwrite a file (user confirms).
  edit_file(path, old_string, new_string[,replace_all]) — Replace text in file (user confirms).
  list_dir(path?)                                     — List directory (default: cwd).
  grep_files(pattern, path?, glob?)                   — Regex file search.
  bash_exec(command, timeout?)                        — Run shell command (user confirms).

Guidelines:
  - Use tools for any file or shell task. Never guess at file contents.
  - For multi-step tasks: plan first, then execute step-by-step with tools.
  - After finishing a task, stop calling tools and write your final reply.
  - Keep prose replies concise — the user sees tool output directly.
  - If a tool returns an ERROR prefix, explain the issue and suggest a fix.
  - Prefer read_file then edit_file over write_file for editing existing files.
EOF
}

# ── §8  Tool JSON schemas ─────────────────────────────────────────────────────
# Ollama's /api/chat accepts a "tools" array in OpenAI-function-calling format:
#
#   [{ "type": "function",
#      "function": { "name": "...", "description": "...",
#                    "parameters": { <JSON Schema> } } }, ...]
#
# We build this once at startup using `jq -n` (jq with no input file, evaluating
# a pure expression). Why jq? It handles all JSON escaping; a heredoc would
# require manual escaping of quotes, newlines, and backslashes.
TOOLS_JSON=""  # populated in main()

build_tools_json() {
  jq -n '
  [
    { "type": "function", "function": {
        "name": "read_file",
        "description": "Read the full text contents of a file from disk.",
        "parameters": {
          "type": "object",
          "properties": {
            "path": { "type": "string", "description": "Path to the file (absolute or relative to cwd)." }
          },
          "required": ["path"]
        }
    }},
    { "type": "function", "function": {
        "name": "write_file",
        "description": "Create or completely overwrite a file. The user must confirm before writing.",
        "parameters": {
          "type": "object",
          "properties": {
            "path":    { "type": "string", "description": "Destination file path." },
            "content": { "type": "string", "description": "Full content to write into the file." }
          },
          "required": ["path", "content"]
        }
    }},
    { "type": "function", "function": {
        "name": "edit_file",
        "description": "Replace a specific string in an existing file. Preferred over write_file for targeted edits. The user must confirm.",
        "parameters": {
          "type": "object",
          "properties": {
            "path":        { "type": "string",  "description": "Path to the file to edit." },
            "old_string":  { "type": "string",  "description": "Exact text to find and replace." },
            "new_string":  { "type": "string",  "description": "Replacement text." },
            "replace_all": { "type": "boolean", "description": "If true, replace every occurrence. Default false — errors if not exactly one match." }
          },
          "required": ["path", "old_string", "new_string"]
        }
    }},
    { "type": "function", "function": {
        "name": "list_dir",
        "description": "List the contents of a directory (equivalent to ls -la).",
        "parameters": {
          "type": "object",
          "properties": {
            "path": { "type": "string", "description": "Directory to list. Defaults to current working directory." }
          },
          "required": []
        }
    }},
    { "type": "function", "function": {
        "name": "grep_files",
        "description": "Search files recursively for a regex pattern. Returns file:line matches.",
        "parameters": {
          "type": "object",
          "properties": {
            "pattern": { "type": "string", "description": "Regex pattern to search for." },
            "path":    { "type": "string", "description": "File or directory to search (default: cwd)." },
            "glob":    { "type": "string", "description": "Optional filename filter, e.g. \"*.py\" or \"*.{js,ts}\"." }
          },
          "required": ["pattern"]
        }
    }},
    { "type": "function", "function": {
        "name": "bash_exec",
        "description": "Execute a shell command and return stdout+stderr. The user must confirm. Use for tests, builds, git, etc.",
        "parameters": {
          "type": "object",
          "properties": {
            "command": { "type": "string",  "description": "Shell command to run." },
            "timeout": { "type": "integer", "description": "Max seconds to wait (default 30)." }
          },
          "required": ["command"]
        }
    }}
  ]'
}

# ── §9  Message history helpers ───────────────────────────────────────────────
# The conversation is a JSON array in a temp file:
#
#   [
#     { "role": "system",    "content": "You are bashgent..." },
#     { "role": "user",      "content": "list the files here" },
#     { "role": "assistant", "content": "", "tool_calls": [
#         { "function": { "name": "list_dir", "arguments": { "path": "." } } }
#       ]},
#     { "role": "tool",      "content": "total 8\ndrwxr-xr-x...", "tool_name": "list_dir" },
#     { "role": "assistant", "content": "The directory contains..." }
#   ]
#
# We write atomically: jq → .tmp file → mv. This prevents a half-written file
# if the script is interrupted mid-update.

history_init() {
  local sys_prompt
  sys_prompt="$(build_system_prompt)"
  # --arg injects a shell variable as a properly escaped JSON string.
  jq -n --arg content "$sys_prompt" \
    '[{"role":"system","content":$content}]' > "$HISTORY_FILE"
}

history_append_json() {
  # $1 = JSON string for a single message object to append.
  #
  # --argjson (vs --arg) parses the value as JSON rather than a string.
  # This is critical: without it, a message containing "tool_calls":[...]
  # would be double-encoded as a string, breaking the API request.
  jq --argjson m "$1" '. + [$m]' "$HISTORY_FILE" \
    > "${HISTORY_FILE}.tmp" \
    && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
}

history_append_user() {
  local msg_json
  msg_json="$(jq -n --arg c "$1" '{"role":"user","content":$c}')"
  history_append_json "$msg_json"
}

history_append_assistant() {
  # $1 = the full message JSON object from Ollama (may include tool_calls).
  # We save the WHOLE object, not just .content, because Ollama needs to see
  # prior tool_calls in history to maintain its reasoning context.
  history_append_json "$1"
}

history_append_tool() {
  # $1 = tool name, $2 = tool output text
  local msg_json
  msg_json="$(jq -n --arg name "$1" --arg c "$2" \
    '{"role":"tool","content":$c,"tool_name":$name}')"
  history_append_json "$msg_json"
}

# ── §10  Ollama HTTP client ────────────────────────────────────────────────────
# POST to /api/chat with the full conversation history and tool schemas.
#
# KEY DESIGN: stream:false
#   Ollama streams by default (one JSON line per token). Streaming requires
#   accumulating partial tool_calls across dozens of lines — fiddly in Bash.
#   Setting stream:false returns ONE complete JSON object. Much simpler to parse.
#   Trade-off: no output until the model finishes generating.
#   Exercise: implement streaming with `curl ... | while IFS= read -r line`.
ollama_chat() {
  local history_json body response

  history_json="$(cat "$HISTORY_FILE")"

  # Compose the request body via jq. All values are properly JSON-encoded.
  body="$(jq -n \
    --arg     model    "$OLLAMA_MODEL" \
    --argjson messages "$history_json" \
    --argjson tools    "$TOOLS_JSON" \
    '{"model":$model,"messages":$messages,"tools":$tools,"stream":false}')"

  # curl flags:
  #   -f  fail (non-zero exit) on HTTP 4xx/5xx
  #   -s  silent (no progress bar)
  #   -S  show errors even in silent mode
  #   --max-time  abort after N seconds total (prevent hanging forever)
  if ! response="$(curl -fsS --max-time 120 \
      -X POST \
      -H 'Content-Type: application/json' \
      -d "$body" \
      "${OLLAMA_HOST}/api/chat" 2>&1)"; then
    printf '\n%sOllama request failed:\n%s%s\n' "$C_WARN" "$response" "$C_RESET" >&2
    return 1
  fi

  printf '%s' "$response"
}

# ── §11  Confirmation helper ───────────────────────────────────────────────────
# Gate destructive operations (write_file, edit_file, bash_exec) behind an
# explicit y/n prompt. Reading from /dev/tty (not stdin) lets us still prompt
# the human even if stdin has been piped: echo "do X" | ./bashgent
confirm() {
  # $1 = human-readable description of the action
  if [[ "$BASHGENT_YES" == "1" ]]; then
    return 0  # --yes flag or BASHGENT_YES=1 bypasses all prompts
  fi

  printf '\n%s⚠  Confirm: %s%s\n' "$C_WARN" "$1" "$C_RESET"
  printf '%s   Proceed? [y/N]: %s' "$C_WARN" "$C_RESET"

  local answer
  read -r answer < /dev/tty || answer='n'
  printf '\n'

  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *)            return 1 ;;
  esac
}

# ── §12  Tool implementations ──────────────────────────────────────────────────
# One function per tool. Input: a JSON string (the arguments object from the API).
# Output: printed to stdout and captured by the agent loop.
#
# PATTERN: errors are returned as output text (prefixed "ERROR:"), never as
# shell failures. The model sees "ERROR: ..." and can react, explain, or retry.
# This prevents one bad tool call from crashing the entire agent session.

MAX_TOOL_OUTPUT=65536  # 64 KiB cap to avoid blowing up the context window

_truncate() {
  # Print $1 capped at MAX_TOOL_OUTPUT bytes with a notice if truncated.
  local text="$1"
  if [[ "${#text}" -gt $MAX_TOOL_OUTPUT ]]; then
    printf '%s' "${text:0:$MAX_TOOL_OUTPUT}"
    printf '\n... [output truncated: %d bytes omitted] ...' \
      "$(( ${#text} - MAX_TOOL_OUTPUT ))"
  else
    printf '%s' "$text"
  fi
}

tool_read_file() {
  # Args JSON: { "path": "..." }
  local path
  path="$(printf '%s' "$1" | jq -r '.path')"

  [[ -e "$path" ]] || { printf 'ERROR: File not found: %s' "$path"; return; }
  [[ -f "$path" ]] || { printf 'ERROR: Not a regular file (use list_dir for dirs): %s' "$path"; return; }

  local content
  content="$(cat "$path" 2>&1)" || { printf 'ERROR: Cannot read: %s' "$path"; return; }
  _truncate "$content"
}

tool_write_file() {
  # Args JSON: { "path": "...", "content": "..." }
  local path content
  path="$(printf '%s' "$1" | jq -r '.path')"
  content="$(printf '%s' "$1" | jq -r '.content')"

  confirm "Write ${#content} bytes to: $path" \
    || { printf 'ERROR: user declined — file not written.'; return; }

  # Create parent directories if they don't exist (-p = no error if already there)
  mkdir -p "$(dirname "$path")"

  # printf '%s' avoids interpreting escape sequences in $content (e.g. \n, \t)
  printf '%s' "$content" > "$path" 2>&1 \
    || { printf 'ERROR: Failed to write: %s' "$path"; return; }

  printf 'OK: wrote %d bytes to %s' "${#content}" "$path"
}

tool_edit_file() {
  # Args JSON: { "path": "...", "old_string": "...", "new_string": "...", "replace_all"?: bool }
  local path old_string new_string replace_all
  path="$(printf '%s' "$1"        | jq -r '.path')"
  old_string="$(printf '%s' "$1"  | jq -r '.old_string')"
  new_string="$(printf '%s' "$1"  | jq -r '.new_string')"
  replace_all="$(printf '%s' "$1" | jq -r '.replace_all // false')"

  [[ -f "$path" ]] || { printf 'ERROR: File not found: %s' "$path"; return; }

  local current
  current="$(cat "$path")"

  # Count occurrences. grep -cF = count, fixed-string (not regex).
  # || true: grep returns exit 1 for "no matches" which would trigger set -e.
  local count=0
  count="$(printf '%s' "$current" | grep -cF -- "$old_string" 2>/dev/null || true)"

  if [[ "$replace_all" == "false" ]]; then
    [[ "$count" -gt 0 ]] \
      || { printf 'ERROR: old_string not found in %s' "$path"; return; }
    [[ "$count" -eq 1 ]] \
      || { printf 'ERROR: old_string found %d times in %s — use replace_all:true or be more specific' \
           "$count" "$path"; return; }
  fi

  confirm "Edit $path — replace $count occurrence(s)" \
    || { printf 'ERROR: user declined — file not edited.'; return; }

  # Bash ${var/pattern/replace} substitutes one occurrence.
  # ${var//pattern/replace} substitutes all. The pattern is a glob (not regex),
  # which is correct here since old_string is a literal string from the file.
  local new_content
  if [[ "$replace_all" == "true" ]]; then
    new_content="${current//"$old_string"/"$new_string"}"
  else
    new_content="${current/"$old_string"/"$new_string"}"
  fi

  printf '%s' "$new_content" > "$path" 2>&1 \
    || { printf 'ERROR: Failed to write edited file: %s' "$path"; return; }

  printf 'OK: edited %s (%d replacement(s))' "$path" "$count"
}

tool_list_dir() {
  # Args JSON: { "path"?: "..." }
  local path
  path="$(printf '%s' "$1" | jq -r '.path // "."')"

  [[ -d "$path" ]] || { printf 'ERROR: Not a directory: %s' "$path"; return; }

  local output
  output="$(ls -la "$path" 2>&1)" || { printf 'ERROR: Cannot list: %s' "$path"; return; }
  _truncate "$output"
}

tool_grep_files() {
  # Args JSON: { "pattern": "...", "path"?: "...", "glob"?: "..." }
  local pattern path glob
  pattern="$(printf '%s' "$1" | jq -r '.pattern')"
  path="$(printf '%s' "$1"    | jq -r '.path // "."')"
  glob="$(printf '%s' "$1"    | jq -r '.glob // ""')"

  # grep flags: -r recursive, -I ignore binary, -n line numbers, -E extended regex
  # || true: grep exits 1 for "no matches" — we handle that case explicitly below
  local output
  if [[ -n "$glob" ]]; then
    output="$(grep -rInE --include="$glob" -- "$pattern" "$path" 2>&1 || true)"
  else
    output="$(grep -rInE -- "$pattern" "$path" 2>&1 || true)"
  fi

  if [[ -z "$output" ]]; then
    printf 'No matches found for: %s' "$pattern"
    return
  fi
  _truncate "$output"
}

tool_bash_exec() {
  # Args JSON: { "command": "...", "timeout"?: N }
  local cmd timeout_secs
  cmd="$(printf '%s' "$1"          | jq -r '.command')"
  timeout_secs="$(printf '%s' "$1" | jq -r '.timeout // 30')"

  confirm "Run command: $cmd" \
    || { printf 'ERROR: user declined — command not run.'; return; }

  printf '%s  $ %s%s\n' "$C_DIM" "$cmd" "$C_RESET" >&2

  # `timeout` is GNU coreutils — not available by default on macOS.
  # On macOS after `brew install coreutils` it's available as `gtimeout`.
  # If neither is found we run without a time limit and warn the user.
  local output exit_code
  if command -v gtimeout >/dev/null 2>&1; then
    output="$(gtimeout "$timeout_secs" bash -c "$cmd" 2>&1)" && exit_code=0 || exit_code=$?
  elif command -v timeout >/dev/null 2>&1; then
    output="$(timeout  "$timeout_secs" bash -c "$cmd" 2>&1)" && exit_code=0 || exit_code=$?
  else
    printf '%s(no timeout command — running without time limit)%s\n' "$C_DIM" "$C_RESET" >&2
    output="$(bash -c "$cmd" 2>&1)" && exit_code=0 || exit_code=$?
  fi

  local result
  result="$(_truncate "$output")"
  # Append exit code so the model knows whether the command succeeded.
  printf '%s\n[exit=%d]' "$result" "$exit_code"
}

# ── §13  Tool dispatcher ───────────────────────────────────────────────────────
# Routes a named tool call to its implementation. Called by the agent loop.
dispatch_tool_call() {
  # $1 = tool name (from the model's tool_calls[i].function.name)
  # $2 = arguments JSON object string (from tool_calls[i].function.arguments)
  case "$1" in
    read_file)   tool_read_file   "$2" ;;
    write_file)  tool_write_file  "$2" ;;
    edit_file)   tool_edit_file   "$2" ;;
    list_dir)    tool_list_dir    "$2" ;;
    grep_files)  tool_grep_files  "$2" ;;
    bash_exec)   tool_bash_exec   "$2" ;;
    *) printf 'ERROR: Unknown tool "%s". Available: read_file, write_file, edit_file, list_dir, grep_files, bash_exec.' "$1" ;;
  esac
}

# ── §14  User input reader ────────────────────────────────────────────────────
# Reads one "logical" message from the user. Supports line continuation:
# a line ending with \ means the user wants to keep typing on the next line
# (the same convention bash itself uses for long commands).
#
# Result is stored in the global USER_INPUT variable.
# Returns 1 on EOF (Ctrl-D), which signals the outer loop to exit.
USER_INPUT=""

read_user_input() {
  USER_INPUT=""
  local line accumulated="" got_input=0 prompt

  # When using `read -e` (readline mode), the prompt MUST be passed via -p.
  # If you print it with printf first and then call `read -e`, readline doesn't
  # know the cursor has advanced and won't echo your typing correctly.
  prompt="$(printf '%sYou:%s ' "$C_USER" "$C_RESET")"

  # read -r: don't interpret backslash escapes in the input itself
  # read -e: use readline (arrow keys, history) — prompt via -p, not printf
  # 2>/dev/null: suppress "read: -e: invalid option" on minimal shells
  while IFS= read -r -e -p "$prompt" line 2>/dev/null; do
    got_input=1
    if [[ "$line" == *\\ ]]; then
      # Trailing backslash = line continuation: strip \ and keep reading
      accumulated+="${line%\\}"$'\n'
      prompt='  > '
    else
      accumulated+="$line"
      break
    fi
  done

  # If read returned non-zero on the very first call, stdin is at EOF (Ctrl-D).
  if [[ "$got_input" -eq 0 ]]; then
    return 1
  fi

  # Blank input: prompt again rather than sending an empty message.
  if [[ -z "$accumulated" ]]; then
    read_user_input
    return $?
  fi

  USER_INPUT="$accumulated"
}

# ── §15  The agent loop ────────────────────────────────────────────────────────
# THE HEART OF THE PROGRAM. Two nested loops implement the full agent lifecycle.
#
# OUTER LOOP — one iteration per user message (the REPL turn).
# INNER LOOP — one iteration per /api/chat call, until the model stops
#              requesting tool calls and produces a plain text reply.
#
# This inner loop is what distinguishes an "agent" from a plain chatbot:
# the model can call many tools, see each result, decide to call more tools,
# and only "surfaces" when it has everything it needs to answer.
#
# FLOW DIAGRAM (inner loop):
#
#   POST /api/chat (history + tools)
#        │
#        ▼
#   response.message.tool_calls  ──exists──▶  execute each tool
#        │                                         │
#        │ empty                            append tool results to history
#        │                                         │
#        ▼                                    loop back ──────────────────┐
#   print response.message.content  ◀── POST /api/chat again (with results)
#        │
#        ▼
#   wait for next user message  (outer loop)

run_agent_loop() {
  history_init   # write the system message to the history file

  # ── OUTER LOOP: each user turn ─────────────────────────────────────────────
  while read_user_input; do
    printf '\n'
    history_append_user "$USER_INPUT"

    # ── INNER LOOP: call model, handle tool calls, repeat until done ────────
    while true; do

      printf '%sThinking…%s\n' "$C_DIM" "$C_RESET"

      # IMPORTANT: declare locals BEFORE assigning from subshells.
      # `local var="$(cmd)"` always returns 0 (the `local` builtin's exit
      # status), hiding cmd's failure. Separate declare + assign is safe.
      local response
      response="$(ollama_chat)" || { printf '%sSkipping turn due to API error.%s\n' "$C_WARN" "$C_RESET"; break; }

      # The full response shape is:
      #   { "model": "...", "message": { "role": "assistant",
      #     "content": "...", "tool_calls": [...] }, "done": true, ... }
      local msg_json
      msg_json="$(printf '%s' "$response" | jq '.message')"

      # Persist the assistant's message (with any tool_calls) in history.
      # We save the WHOLE object so Ollama sees its own prior tool_calls
      # on subsequent requests and can maintain reasoning continuity.
      history_append_assistant "$msg_json"

      # Check for tool calls. jq -c '.tool_calls // [] | .[]' emits one compact
      # JSON object per line. Empty output = no tool calls = model is done.
      local tool_calls_raw
      tool_calls_raw="$(printf '%s' "$msg_json" \
        | jq -c '.tool_calls // [] | .[]' 2>/dev/null || true)"

      if [[ -z "$tool_calls_raw" ]]; then
        # ── Model produced a final text reply — print it and exit inner loop ─
        local content
        content="$(printf '%s' "$msg_json" | jq -r '.content // ""')"
        printf '\n%sAssistant:%s %s\n\n' "$C_ASST" "$C_RESET" "$content"
        break
      fi

      # ── Model wants to call tools — process each one ──────────────────────
      # tool_calls_raw is one JSON object per line (from jq -c ... | .[]).
      while IFS= read -r call_json; do

        # Ollama tool call format:
        #   { "function": { "name": "tool_name", "arguments": { ... } } }
        # Note: .arguments is already a JSON object, not an encoded string.
        local tool_name tool_args
        tool_name="$(printf '%s' "$call_json" | jq -r '.function.name')"
        tool_args="$(printf '%s' "$call_json" | jq -c '.function.arguments')"

        # Show what the model is doing (transparency is important for trust)
        printf '%s⚙  %s%s %s(%s)%s\n' \
          "$C_TOOL" "$tool_name" "$C_RESET" "$C_DIM" "$tool_args" "$C_RESET"

        # Execute the tool. It always exits 0; errors appear in its output text.
        local tool_result
        tool_result="$(dispatch_tool_call "$tool_name" "$tool_args")"

        # Show a one-line preview of the result (newlines → spaces for display)
        local preview="${tool_result:0:200}"
        printf '%s   ↳ %s%s%s\n' \
          "$C_TOOL" "$C_DIM" "${preview//$'\n'/ }" "$C_RESET"
        if [[ "${#tool_result}" -gt 200 ]]; then
          printf '%s     … (%d bytes total)%s\n' "$C_DIM" "${#tool_result}" "$C_RESET"
        fi

        # Append the result to history. On the next POST the model will see it.
        history_append_tool "$tool_name" "$tool_result"

      done <<< "$tool_calls_raw"
      # After all tool calls are handled, the inner loop continues: we POST
      # again so the model can see the results and decide what to do next.

    done  # end inner loop
  done    # end outer loop

  printf '\nGoodbye!\n'
}

# ── §16  Main entrypoint ───────────────────────────────────────────────────────
main() {
  # ── Parse CLI flags ──────────────────────────────────────────────────────────
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y)
        BASHGENT_YES=1; shift ;;
      --model)
        [[ $# -ge 2 ]] || { printf 'ERROR: --model requires a model name\n' >&2; exit 1; }
        OLLAMA_MODEL="$2"; shift 2 ;;
      --help|-h)
        usage; exit 0 ;;
      *)
        printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
  done

  # ── Validate dependencies ────────────────────────────────────────────────────
  check_deps

  # ── Resolve model ────────────────────────────────────────────────────────────
  if [[ -z "$OLLAMA_MODEL" ]]; then
    OLLAMA_MODEL="$(detect_model)"
  fi

  # ── Build tool schemas (once, stored globally) ───────────────────────────────
  TOOLS_JSON="$(build_tools_json)"

  # ── Set up conversation history temp file ───────────────────────────────────
  # mktemp creates a uniquely named empty file. The trap removes it when the
  # script exits (whether normally, via Ctrl-C, or due to an error).
  HISTORY_FILE="$(mktemp -t bashgent.XXXXXX.json)"
  trap 'rm -f "$HISTORY_FILE" "${HISTORY_FILE}.tmp" 2>/dev/null' EXIT INT TERM

  # ── Launch the agent ─────────────────────────────────────────────────────────
  print_banner
  run_agent_loop
}

main "$@"
