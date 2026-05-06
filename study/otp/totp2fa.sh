#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════╗
# ║    totp2fa.sh — RFC 6238 TOTP 2FA CLI Demo                  ║
# ║    Requires: python3 (stdlib), bash 4+                       ║
# ║    Optional: qrencode (apt install qrencode)                 ║
# ║                                                              ║
# ║    Usage:                                                    ║
# ║      ./totp2fa.sh enroll    — Generate secret & show QR      ║
# ║      ./totp2fa.sh generate  — Show current TOTP code         ║
# ║      ./totp2fa.sh verify    — Validate a user-entered code   ║
# ║      ./totp2fa.sh watch     — Live countdown display         ║
# ╚══════════════════════════════════════════════════════════════╝
#
# ── What is TOTP? ─────────────────────────────────────────────────
# TOTP = Time-based One-Time Password (RFC 6238).
# It is built on top of HOTP (RFC 4226), an HMAC-based one-time password.
# The trick: instead of using a counter that advances per-use (HOTP),
# TOTP uses the current Unix time divided into 30-second buckets as the
# counter. So every 30 seconds the code changes, and both server and
# client can compute the same code independently as long as:
#   1. they share the same secret key (the "seed"), and
#   2. their clocks are roughly in sync (NTP).
#
# The full pipeline is:
#   shared_secret + current_time_bucket
#       → HMAC-SHA1     (a 20-byte pseudo-random digest)
#       → "dynamic truncation"  (extract 4 bytes → 31-bit integer)
#       → modulo 10^6   (final 6-digit code shown to the user)
#
# The shared secret is typically conveyed to the authenticator app
# via a QR code containing an `otpauth://` URI (Google's de facto
# standard, now adopted by basically every authenticator app).
#
# ── Bash strict mode ──────────────────────────────────────────────
#   -e  : exit on any command's non-zero status
#   -u  : treat unset variables as errors
#   -o pipefail : a pipeline fails if ANY command in it fails
#                 (without it, only the last command's status counts)
set -euo pipefail

# ── Config ────────────────────────────────────────────────────
SECRET_FILE="${TOTP_SECRET_FILE:-$HOME/.totp_secret}"
DIGITS=6
PERIOD=30
ISSUER="${TOTP_ISSUER:-Demo2FA}"
ACCOUNT="${TOTP_ACCOUNT:-user@localhost}"

# ── ANSI colors ───────────────────────────────────────────────
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Helpers ───────────────────────────────────────────────────
log_info()  { echo -e "  ${CYAN}[>]${RESET} $*"; }
log_ok()    { echo -e "  ${GREEN}[✔]${RESET} $*"; }
log_err()   { echo -e "  ${RED}[✖]${RESET} $*"; }
log_warn()  { echo -e "  ${YELLOW}[!]${RESET} $*"; }

require_python() {
    if ! command -v python3 &>/dev/null; then
        log_err "python3 is required. Install with: apt install python3"
        exit 1
    fi
}

# ── Generate a cryptographically random Base32 secret ─────────
generate_secret() {
    python3 -c "
import secrets, base64
# 160 bits = 20 bytes (RFC 4226 recommendation)
raw = secrets.token_bytes(20)
b32 = base64.b32encode(raw).decode().rstrip('=')
# Format as groups of 4 for readability (optional)
print(b32)
"
}

# ── Core TOTP computation (RFC 6238) ──────────────────────────
# Arguments: secret_b32, time_step (optional, defaults to now)
compute_totp() {
    local secret="$1"
    local t_override="${2:-}"

    python3 - "$secret" "$t_override" "$DIGITS" "$PERIOD" <<'PYEOF'
import sys, hmac, hashlib, struct, base64, time

secret_b32 = sys.argv[1]
t_override = sys.argv[2]   # Empty string = use current time
digits     = int(sys.argv[3])
period     = int(sys.argv[4])

# Decode Base32 secret (pad to multiple of 8)
pad = (8 - len(secret_b32) % 8) % 8
key = base64.b32decode((secret_b32 + "=" * pad).upper())

# Compute time counter T (RFC 6238 §4)
if t_override:
    t = int(t_override)
else:
    t = int(time.time()) // period      # T = floor((t - T0) / X)

# HMAC-SHA1 with 8-byte big-endian counter
msg = struct.pack('>Q', t)              # 8-byte big-endian
hs  = hmac.new(key, msg, hashlib.sha1).digest()   # 20-byte digest

# Dynamic Truncation (RFC 4226 §5.4)
offset  = hs[-1] & 0x0F                # Last nibble as offset
p       = struct.unpack('>I', hs[offset:offset+4])[0]
code_int = p & 0x7FFFFFFF              # Clear MSB to avoid sign issues

# Final 6-digit code
print(str(code_int % (10 ** digits)).zfill(digits))
PYEOF
}

# ── Enrollment: generate secret, save it, show QR ─────────────
enroll() {
    require_python
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║  TOTP 2FA Enrollment                 ║${RESET}"
    echo -e "${BOLD}║  RFC 6238 — 160-bit HMAC-SHA1        ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${RESET}"
    echo ""

    # Check if secret already exists
    if [[ -f "$SECRET_FILE" ]]; then
        log_warn "Secret file already exists: $SECRET_FILE"
        read -r -p "  Overwrite? [y/N]: " confirm
        if [[ "${confirm,,}" != "y" ]]; then
            log_info "Enrollment cancelled."
            exit 0
        fi
    fi

    log_info "Generating 160-bit secret (CSPRNG)..."
    local secret
    secret=$(generate_secret)

    # Save with restrictive permissions (owner read-only)
    echo "$secret" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"

    echo ""
    echo -e "  ${BOLD}Secret (Base32):${RESET}"
    echo -e "  ${GREEN}${BOLD}$secret${RESET}"
    echo ""
    echo -e "  ${DIM}⚠  Store this in a password manager — losing it means losing 2FA access${RESET}"
    echo ""

    # Build otpauth:// URI for QR code
    local uri="otpauth://totp/${ISSUER}:${ACCOUNT}?secret=${secret}&issuer=${ISSUER}&algorithm=SHA1&digits=${DIGITS}&period=${PERIOD}"
    echo -e "  ${BOLD}otpauth:// URI:${RESET}"
    echo -e "  ${DIM}$uri${RESET}"
    echo ""

    # Try to display QR code
    if command -v qrencode &>/dev/null; then
        echo -e "  ${BOLD}QR Code${RESET} ${DIM}(scan with Proton Authenticator / Aegis / Google Auth)${RESET}:"
        echo ""
        qrencode -t ANSIUTF8 "$uri"
        echo ""
    else
        log_warn "qrencode not found. Install it to display QR code:"
        echo -e "    ${DIM}sudo apt install qrencode${RESET}"
        echo ""
        echo -e "  ${BOLD}Manual entry:${RESET} Open your authenticator app → Add manually → enter:"
        echo -e "    Account: ${ACCOUNT}"
        echo -e "    Issuer:  ${ISSUER}"
        echo -e "    Secret:  ${GREEN}${secret}${RESET}"
        echo -e "    Type:    TOTP  |  SHA1  |  6 digits  |  30 seconds"
        echo ""
    fi

    log_ok "Secret saved to $SECRET_FILE"
    log_info "Now scan the QR code with your authenticator app."
    log_info "Then run: $0 verify — to confirm setup works."
    echo ""
}

# ── Generate: show current TOTP code ──────────────────────────
generate() {
    require_python

    if [[ ! -f "$SECRET_FILE" ]]; then
        log_err "No secret found. Run: $0 enroll"
        exit 1
    fi

    local secret
    secret=$(cat "$SECRET_FILE")

    local now
    now=$(date +%s)
    local remaining=$(( PERIOD - now % PERIOD ))
    local elapsed=$(( PERIOD - remaining ))

    local code
    code=$(compute_totp "$secret" "")

    # Progress bar
    local bar_len=20
    local filled=$(( elapsed * bar_len / PERIOD ))
    local empty=$(( bar_len - filled ))
    local bar=""
    for (( i=0; i<filled; i++ ));  do bar+="█"; done
    for (( i=0; i<empty; i++ ));   do bar+="░"; done

    # Color based on time left
    local color="${GREEN}"
    [[ $remaining -le 10 ]] && color="${YELLOW}"
    [[ $remaining -le 5 ]]  && color="${RED}"

    echo ""
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  ${BOLD}Current TOTP Code${RESET}  ${DIM}(${ISSUER} / ${ACCOUNT})${RESET}"
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    echo -e "  ${BOLD}${color}${code}${RESET}"
    echo ""
    echo -e "  ${DIM}[${color}${bar}${DIM}]  ${remaining}s remaining${RESET}"
    echo ""
    echo -e "  ${DIM}Algo: HMAC-SHA1  |  Period: ${PERIOD}s  |  Digits: ${DIGITS}  |  RFC 6238${RESET}"
    echo ""
}

# ── Verify: validate a user-entered TOTP code ─────────────────
verify() {
    require_python

    if [[ ! -f "$SECRET_FILE" ]]; then
        log_err "No secret found. Run: $0 enroll"
        exit 1
    fi

    local secret
    secret=$(cat "$SECRET_FILE")

    echo ""
    read -r -p "  $(echo -e "${BOLD}Enter 6-digit TOTP code:${RESET} ")" user_code

    # Validate format
    if [[ ! "$user_code" =~ ^[0-9]{6}$ ]]; then
        echo ""
        log_err "Invalid format — code must be exactly 6 digits."
        echo ""
        exit 1
    fi

    local now
    now=$(date +%s)

    # Check current window + ±1 adjacent windows (RFC 6238 clock drift tolerance)
    for delta in -1 0 1; do
        local t=$(( (now + delta * PERIOD) / PERIOD ))
        local expected
        expected=$(compute_totp "$secret" "$t")

        if [[ "$user_code" == "$expected" ]]; then
            echo ""
            if [[ $delta -eq 0 ]]; then
                log_ok "${GREEN}${BOLD}Authentication SUCCESSFUL${RESET}"
                log_info "Code matched current time window."
            else
                log_ok "${GREEN}${BOLD}Authentication SUCCESSFUL${RESET} (clock drift: ${delta} window)"
                log_warn "Minor clock drift detected (±${PERIOD}s). Check NTP sync."
            fi
            echo ""
            exit 0
        fi
    done

    echo ""
    log_err "${RED}${BOLD}Authentication FAILED${RESET}"
    log_warn "Code did not match any valid time window (checked ±${PERIOD}s)."
    log_info "Check your device clock is synchronized (NTP)."
    echo ""
    exit 1
}

# ── Watch: live countdown display ─────────────────────────────
watch_mode() {
    require_python

    if [[ ! -f "$SECRET_FILE" ]]; then
        log_err "No secret found. Run: $0 enroll"
        exit 1
    fi

    echo ""
    log_info "Live TOTP watch mode — Ctrl+C to exit"
    echo ""

    local last_code=""
    while true; do
        local code
        code=$(compute_totp "$(cat "$SECRET_FILE")" "")
        local remaining=$(( PERIOD - $(date +%s) % PERIOD ))

        if [[ "$code" != "$last_code" ]]; then
            echo -e "\r  ${BOLD}NEW CODE: ${GREEN}${code}${RESET}"
            last_code="$code"
        fi

        printf "\r  ${BOLD}Code: ${GREEN}%-6s${RESET}  |  ${DIM}%2ds remaining${RESET}   " "$code" "$remaining"
        sleep 1
    done
}

# ── Import: use an existing Base32 secret ─────────────────────
import_secret() {
    local secret="${2:-}"

    if [[ -z "$secret" ]]; then
        echo ""
        read -r -p "  $(echo -e "${BOLD}Paste your Base32 secret:${RESET} ")" secret
    fi

    # Strip spaces and uppercase
    secret=$(echo "$secret" | tr -d ' ' | tr '[:lower:]' '[:upper:]')

    # Validate Base32 (A-Z, 2-7, optional = padding)
    if [[ ! "$secret" =~ ^[A-Z2-7]+=*$ ]]; then
        echo ""
        log_err "Invalid Base32 secret. Only characters A-Z and 2-7 are valid."
        exit 1
    fi

    # Quick sanity check — try to compute a code
    local test_code
    if ! test_code=$(compute_totp "$secret" "" 2>/dev/null); then
        log_err "Failed to compute TOTP from that secret. Check it's valid Base32."
        exit 1
    fi

    if [[ -f "$SECRET_FILE" ]]; then
        log_warn "Secret file already exists: $SECRET_FILE"
        read -r -p "  Overwrite? [y/N]: " confirm
        [[ "${confirm,,}" != "y" ]] && { log_info "Import cancelled."; exit 0; }
    fi

    echo "$secret" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"

    echo ""
    log_ok "Secret imported and saved to $SECRET_FILE"
    log_info "Test code right now: ${GREEN}${BOLD}${test_code}${RESET}"
    echo ""
}

# ── Main ──────────────────────────────────────────────────────
case "${1:-}" in
    enroll)
        enroll
        ;;
    import)
        import_secret "$@"
        ;;
    generate | gen | code)
        generate
        ;;
    verify | check | validate)
        verify
        ;;
    watch | live)
        watch_mode
        ;;
    "")
        echo ""
        echo -e "  ${BOLD}totp2fa.sh${RESET} — RFC 6238 TOTP 2FA Demo"
        echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo -e "  ${CYAN}$0 enroll${RESET}    ${DIM}Generate 160-bit secret & QR code${RESET}"
        echo -e "  ${CYAN}$0 import${RESET}    ${DIM}Import an existing Base32 secret${RESET}"
        echo -e "  ${CYAN}$0 generate${RESET}  ${DIM}Show current TOTP code (with timer)${RESET}"
        echo -e "  ${CYAN}$0 verify${RESET}    ${DIM}Validate a user-entered TOTP code${RESET}"
        echo -e "  ${CYAN}$0 watch${RESET}     ${DIM}Live countdown display (refreshes every second)${RESET}"
        echo ""
        echo -e "  ${DIM}Env vars: TOTP_SECRET_FILE, TOTP_ISSUER, TOTP_ACCOUNT${RESET}"
        echo ""
        ;;
    *)
        log_err "Unknown command: $1"
        echo -e "  Usage: $0 {enroll|generate|verify|watch}"
        exit 1
        ;;
esac
