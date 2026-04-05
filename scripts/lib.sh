#!/usr/bin/env bash
# lib.sh — shared functions for openclaw-ops scripts
# Source this from other scripts:
#   LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$LIB_DIR/lib.sh"

# ── Color output (disabled when not a TTY) ─────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GRN='\033[0;32m'
  YLW='\033[0;33m'
  CYN='\033[0;36m'
  BLD='\033[1m'
  RST='\033[0m'
else
  RED='' GRN='' YLW='' CYN='' BLD='' RST=''
fi

# ── Logging helpers ─────────────────────────────────────────────────────────
log_fixed()  { echo -e "${GRN}[FIXED]${RST}  $1"; }
log_broken() { echo -e "${RED}[BROKEN]${RST} $1"; }
log_manual() { echo -e "${YLW}[MANUAL]${RST} $1"; }
log_info()   { echo -e "        $1"; }
log_ok()     { echo -e "${GRN}[✓]${RST} $1"; }
log_warn()   { echo -e "${YLW}[!]${RST} $1"; }
log_error()  { echo -e "${RED}[✗]${RST} $1"; }

# ── Preflight checks ───────────────────────────────────────────────────────
require_tools() {
  local missing=()
  for tool in "$@"; do
    command -v "$tool" &>/dev/null || missing+=("$tool")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing required tools: ${missing[*]}"
    echo "Install openclaw: curl -fsSL https://openclaw.ai/install.sh | bash"
    return 1
  fi
}

# ── Version parsing ─────────────────────────────────────────────────────────
# Usage: get_openclaw_version → "v2026.2.12" or "unknown"
get_openclaw_version() {
  local version
  version="$(
    openclaw --version 2>/dev/null | grep -oE 'v?[0-9]{4}\.[0-9]+\.[0-9]+' | head -1
  )"

  if [[ -z "$version" ]]; then
    echo "unknown"
    return 0
  fi

  [[ "$version" == v* ]] || version="v$version"
  printf '%s\n' "$version"
}

# Usage: version_below "v2026.2.12" "v2026.2.12" → false (not below)
#        version_below "v2026.2.11" "v2026.2.12" → true
version_below() {
  local current="$1" minimum="$2"
  python3 -c "
import sys
a = tuple(int(x) for x in sys.argv[1].lstrip('v').split('.'))
b = tuple(int(x) for x in sys.argv[2].lstrip('v').split('.'))
sys.exit(0 if a < b else 1)
" "$current" "$minimum" 2>/dev/null
}

# ── State file helpers (safe — no shell interpolation in Python) ────────────
# Usage: state_get "$STATE_FILE" "key" → value or empty string
state_get() {
  local state_file="$1" key="$2"
  python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get(sys.argv[2], ''))
except: print('')
" "$state_file" "$key" 2>/dev/null || echo ""
}

# Usage: state_set "$STATE_FILE" "key" "value"
state_set() {
  local state_file="$1" key="$2" value="$3"
  python3 -c "
import json, sys
f = sys.argv[1]
try:
    d = json.load(open(f))
except:
    d = {}
d[sys.argv[2]] = sys.argv[3]
with open(f, 'w') as out:
    json.dump(d, out)
" "$state_file" "$key" "$value" 2>/dev/null || true
}

# ── Platform helpers ────────────────────────────────────────────────────────
# Current time in epoch seconds
epoch_now() {
  python3 -c "import time; print(int(time.time()))" 2>/dev/null
}

# Current UTC timestamp in ISO-8601 form
iso_now() {
  python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null
}

# Redact common credential patterns from stdin
sanitize_sensitive() {
  python3 -c '
import re
import sys

text = sys.stdin.read()
patterns = [
    (re.compile(r"sk-[A-Za-z0-9-]{20,}"), "[REDACTED_API_KEY]"),
    (re.compile(r"xoxb-[0-9A-Za-z-]+"), "[REDACTED_SLACK_TOKEN]"),
    (re.compile(r"ghp_[A-Za-z0-9]{36,}"), "[REDACTED_GH_TOKEN]"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "[REDACTED_AWS_KEY]"),
    (re.compile(r"Bearer\s+[A-Za-z0-9._-]{20,}", re.IGNORECASE), "Bearer [REDACTED]"),
    (
        re.compile(
            r"(\"(?:password|secret|token|api_key|apiKey|auth_token)\"\s*:\s*\")([^\"]+)(\")",
            re.IGNORECASE,
        ),
        r"\1[REDACTED]\3",
    ),
]

for pattern, replacement in patterns:
    text = pattern.sub(replacement, text)

sys.stdout.write(text)
' 2>/dev/null
}

# Run inline Python and surface the first error line through the standard logger
run_python() {
  local script="$1"
  shift || true

  local output
  if ! output=$(python3 -c "$script" "$@" 2>&1); then
    log_error "Python script failed: ${output%%$'\n'*}"
    return 1
  fi

  printf '%s\n' "$output"
}

# File modification time in epoch seconds (cross-platform)
file_mtime() {
  local file="$1"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    stat -f%m "$file" 2>/dev/null
  else
    stat -c%Y "$file" 2>/dev/null
  fi
}

# File permissions as octal (cross-platform)
file_perms() {
  local file="$1"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    stat -f "%OLp" "$file" 2>/dev/null
  else
    stat -c "%a" "$file" 2>/dev/null
  fi
}

# Portable date N days ago (YYYY-MM-DD)
date_days_ago() {
  local days="$1"
  python3 -c "
from datetime import datetime, timedelta
import sys
print((datetime.now() - timedelta(days=int(sys.argv[1]))).strftime('%Y-%m-%d'))
" "$days" 2>/dev/null
}

# ── Gateway port resolution ────────────────────────────────────────────────
# Reads the gateway port from ~/.openclaw/openclaw.json.
# Precedence: OPENCLAW_GATEWAY_PORT env var → config file → 18789 fallback.
# Usage: GATEWAY_PORT=$(get_gateway_port)
get_gateway_port() {
  if [[ -n "${OPENCLAW_GATEWAY_PORT:-}" ]]; then
    echo "$OPENCLAW_GATEWAY_PORT"
    return
  fi
  python3 -c "
import json, sys, os
try:
    cfg = os.path.expanduser('~/.openclaw/openclaw.json')
    d = json.load(open(cfg))
    print(d.get('gateway', {}).get('port', 18789))
except:
    print(18789)
" 2>/dev/null || echo 18789
}

# ── SHA-256 hash (cross-platform) ──────────────────────────────────────────
file_sha256() {
  local file="$1"
  shasum -a 256 "$file" 2>/dev/null | awk '{print $1}' || \
  openssl dgst -sha256 "$file" 2>/dev/null | awk '{print $NF}' || \
  echo "error"
}
