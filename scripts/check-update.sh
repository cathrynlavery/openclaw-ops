#!/usr/bin/env bash
# check-update.sh — detect OpenClaw version changes and explain what broke
#
# Run this after an update, or let heal.sh trigger it automatically when a
# version change is detected.
#
# What it does:
#   1. Compares current version to last-seen version
#   2. Looks up known breaking changes for that version range
#   3. Snapshots your current config
#   4. Explains in plain English what changed, what your config looks like now,
#      and exactly what you need to fix — before things break
#
# Usage:
#   bash check-update.sh              # check and report
#   bash check-update.sh --fix        # check and auto-apply safe fixes

set -euo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" && source "$LIB_DIR/lib.sh"

require_tools python3 openclaw openssl || exit 1

FIX_MODE=false
[[ "${1:-}" == "--fix" ]] && FIX_MODE=true

STATE_FILE="$HOME/.openclaw/watchdog-state.json"
OPENCLAW_JSON="$HOME/.openclaw/openclaw.json"
APPROVALS_JSON="$HOME/.openclaw/exec-approvals.json"

warn()  { echo -e "${YLW}[!]${RST} $1"; }
good()  { echo -e "${GRN}[✓]${RST} $1"; }
bad()   { echo -e "${RED}[✗]${RST} $1"; }
info()  { echo -e "${CYN}[~]${RST} $1"; }
fixed() { echo -e "${GRN}[FIXED]${RST} $1"; }

echo ""
echo -e "${BLD}OpenClaw Update Check${RST}"
echo "────────────────────────────────"
[[ "$FIX_MODE" == "true" ]] && echo -e "Mode: ${GRN}auto-fix enabled${RST}" || echo -e "Mode: report only (run with --fix to apply fixes)"
echo ""

# ── Get current version ───────────────────────────────────────────────────────
CURRENT_VERSION="$(get_openclaw_version)"
info "Current version: $CURRENT_VERSION"

# ── Get version state from watchdog/update history ──────────────────────────
VERSION_STATE="$(
  python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except:
    d = {}
print(d.get('current_version') or d.get('last_version', ''))
print(d.get('previous_version') or d.get('version_changed_from', ''))
print('1' if d.get('version_change_pending') else '0')
" "$STATE_FILE" 2>/dev/null || printf '\n\n0\n'
)"

STATE_CURRENT_VERSION="$(printf '%s\n' "$VERSION_STATE" | sed -n '1p')"
PREVIOUS_VERSION="$(printf '%s\n' "$VERSION_STATE" | sed -n '2p')"
VERSION_CHANGE_PENDING="$(printf '%s\n' "$VERSION_STATE" | sed -n '3p')"
VERSION_CHANGE_PENDING="${VERSION_CHANGE_PENDING:-0}"

if [[ "$VERSION_CHANGE_PENDING" == "1" ]] && [[ -n "$PREVIOUS_VERSION" ]] && [[ -n "$STATE_CURRENT_VERSION" ]]; then
  warn "Version changed: ${BLD}$PREVIOUS_VERSION${RST} → ${BLD}$STATE_CURRENT_VERSION${RST}"
  echo ""
elif [[ -z "$STATE_CURRENT_VERSION" ]]; then
  info "No previous version recorded — this looks like a first run."
  info "Recording current version for future comparisons."
elif [[ "$STATE_CURRENT_VERSION" == "$CURRENT_VERSION" ]]; then
  good "No version change detected ($CURRENT_VERSION)"
  echo ""
  echo "No update-related config changes expected."
  echo "Run 'bash heal.sh' for a general health check."
  exit 0
else
  PREVIOUS_VERSION="$STATE_CURRENT_VERSION"
  warn "Version changed: ${BLD}$PREVIOUS_VERSION${RST} → ${BLD}$CURRENT_VERSION${RST}"
  echo ""
fi

# Record current version and clear pending state once reported
python3 -c "
import sys, json
from time import gmtime, strftime

try:
    d = json.load(open(sys.argv[1]))
except:
    d = {}
current_version = sys.argv[2]
previous_version = sys.argv[3]
d['current_version'] = current_version
d['last_version'] = current_version
if previous_version and previous_version != current_version:
    d['previous_version'] = previous_version
    d['version_changed_from'] = previous_version
    d.setdefault('version_changed_at', strftime('%Y-%m-%dT%H:%M:%SZ', gmtime()))
d['version_change_pending'] = False
d['last_update_check'] = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime())
with open(sys.argv[1], 'w') as out:
    json.dump(d, out)
" "$STATE_FILE" "$CURRENT_VERSION" "$PREVIOUS_VERSION" 2>/dev/null || true

# ── Known breaking changes table ─────────────────────────────────────────────
# Each entry: version introduced, what changed, how to detect, how to fix
echo -e "${BLD}Checking known breaking changes for your version range...${RST}"
echo ""

ISSUES_FOUND=0
FIXES_APPLIED=0
FIXES_FAILED=0

# Run a fix command, capturing stderr. Increment FIXES_APPLIED only on real
# success (zero exit). On failure, print the captured error and increment
# FIXES_FAILED. This replaces the prior `cmd 2>/dev/null && fixed || bad`
# pattern that swallowed errors and lied in the summary (issue #3).
try_fix() {
  local description="$1"
  shift
  local stderr_file
  stderr_file="$(mktemp)"
  if "$@" 2>"$stderr_file"; then
    fixed "$description"
    FIXES_APPLIED=$((FIXES_APPLIED + 1))
    rm -f "$stderr_file"
    return 0
  else
    local rc=$?
    bad "Failed to $description (exit $rc)"
    if [[ -s "$stderr_file" ]]; then
      sed 's/^/       /' "$stderr_file"
    fi
    FIXES_FAILED=$((FIXES_FAILED + 1))
    rm -f "$stderr_file"
    return $rc
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BREAKING CHANGE: v2026.2.24 — Exec policy Layer 2
# New security and ask fields in exec-approvals.json defaults + openclaw.json
# This is the change that broke everyone after the update (April 2026)
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BLD}[1] Exec approval policy layer (introduced v2026.2.24)${RST}"

if [[ -f "$APPROVALS_JSON" ]]; then
  LAYER2_STATUS=$(python3 -c "
import sys, json
data = json.load(open(sys.argv[1]))
defaults = data.get('defaults', {})
security = defaults.get('security', 'NOT SET')
ask = defaults.get('ask', 'NOT SET')
ask_fallback = defaults.get('askFallback', 'NOT SET')
ok = security == 'full' and ask == 'off' and ask_fallback == 'full'
print(f'ok={ok} security={security!r} ask={ask!r} askFallback={ask_fallback!r}')
" "$APPROVALS_JSON" 2>/dev/null || echo "ok=False security=ERROR ask=ERROR askFallback=ERROR")

  if echo "$LAYER2_STATUS" | grep -q "ok=True"; then
    good "exec-approvals.json defaults: security=full, ask=off, askFallback=full"
  else
    bad "exec-approvals.json defaults are wrong or missing"
    echo "     Current: $LAYER2_STATUS"
    echo "     Expected: security='full', ask='off', askFallback='full'"
    echo ""
    echo "     What this means: Even with correct agent allowlists, a second"
    echo "     policy layer gates complex commands independently. Without these"
    echo "     settings, agents hit approval walls on any multi-step command."
    ISSUES_FOUND=$((ISSUES_FOUND + 1))

    if [[ "$FIX_MODE" == "true" ]]; then
      try_fix "patch exec-approvals.json defaults" python3 -c "
import sys, json
data = json.load(open(sys.argv[1]))
if 'defaults' not in data:
    data['defaults'] = {}
data['defaults']['security'] = 'full'
data['defaults']['ask'] = 'off'
data['defaults']['askFallback'] = 'full'
with open(sys.argv[1], 'w') as f:
    json.dump(data, f, indent=2)
" "$APPROVALS_JSON"
    else
      warn "To fix: run this script with --fix, or manually set:"
      echo "     openclaw approvals set-default security full"
      echo "     (or edit ~/.openclaw/exec-approvals.json directly)"
    fi
  fi
else
  info "exec-approvals.json not found — skipping"
fi

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# BREAKING CHANGE: v2026.2.24 — tools.exec.security + strictInlineEval
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BLD}[2] openclaw.json exec tool settings (introduced v2026.2.24)${RST}"

EXEC_SECURITY=$(openclaw config get tools.exec.security 2>/dev/null | tr -d '[:space:]' || echo "")
EXEC_STRICT=$(openclaw config get tools.exec.strictInlineEval 2>/dev/null | tr -d '[:space:]' || echo "")

EXEC_OK=true
if [[ "$EXEC_SECURITY" != "full" ]]; then
  bad "tools.exec.security = '${EXEC_SECURITY:-NOT SET}' (expected: full)"
  echo "     What this means: Without security=full, the gateway rejects inline"
  echo "     eval and certain shell expansions agents rely on."
  EXEC_OK=false
  ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi
if [[ "$EXEC_STRICT" == "true" ]]; then
  bad "tools.exec.strictInlineEval = true (expected: false)"
  echo "     What this means: Strict inline eval blocks common shell patterns"
  echo "     used by agent skills, causing silent command failures."
  EXEC_OK=false
  ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

if [[ "$EXEC_OK" == "true" ]]; then
  good "tools.exec.security=full, strictInlineEval=false"
elif [[ "$FIX_MODE" == "true" ]]; then
  try_fix "set tools.exec.security=full" openclaw config set tools.exec.security full
  try_fix "set tools.exec.strictInlineEval=false" openclaw config set tools.exec.strictInlineEval false
else
  warn "To fix:"
  echo "     openclaw config set tools.exec.security full"
  echo "     openclaw config set tools.exec.strictInlineEval false"
fi

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# BREAKING CHANGE: v2026.1.29 — auth.mode "none" removed
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BLD}[3] Gateway auth mode (breaking change in v2026.1.29)${RST}"

AUTH_MODE=$(openclaw config get gateway.auth.mode 2>/dev/null | tr -d '[:space:]' || echo "unknown")
if [[ "$AUTH_MODE" == "none" ]]; then
  bad "gateway.auth.mode = 'none' — this was permanently removed in v2026.1.29"
  echo "     What this means: Your gateway will refuse to start after an upgrade."
  ISSUES_FOUND=$((ISSUES_FOUND + 1))
  if [[ "$FIX_MODE" == "true" ]]; then
    NEW_TOKEN=$(openssl rand -hex 32)
    if try_fix "set gateway.auth.mode=token" openclaw config set gateway.auth.mode token; then
      try_fix "set gateway.auth.token to a new random token" openclaw config set gateway.auth.token "$NEW_TOKEN"
    fi
  else
    warn "To fix:"
    echo "     openclaw config set gateway.auth.mode token"
    echo "     openclaw config set gateway.auth.token \"\$(openssl rand -hex 32)\""
  fi
else
  good "gateway.auth.mode = '$AUTH_MODE'"
fi

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# BREAKING CHANGE: v2026.2.12 — POST /hooks/agent rejects sessionKey overrides
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BLD}[4] Webhook sessionKey behavior (v2026.2.12)${RST}"
info "If you use POST /hooks/agent webhooks: sessionKey overrides are rejected by"
info "default since v2026.2.12. If your webhook integrations stopped routing"
info "sessions correctly, this is why. See docs.openclaw.ai/changelog"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Config snapshot — show key settings at a glance
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BLD}Config snapshot${RST}"
echo "────────────────────────────────"

SNAPSHOT_FIELDS=(
  "gateway.auth.mode"
  "tools.exec.security"
  "tools.exec.strictInlineEval"
  "agents.defaults.model"
  "agents.defaults.sandbox.mode"
  "agents.defaults.subagents.maxSpawnDepth"
)

for field in "${SNAPSHOT_FIELDS[@]}"; do
  val=$(openclaw config get "$field" 2>/dev/null | tr -d '[:space:]' || echo "(not set)")
  printf "  %-45s %s\n" "$field" "$val"
done

echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "════════════════════════════════"
if [[ "$ISSUES_FOUND" -eq 0 ]]; then
  good "No update-related config issues found. You're good."
elif [[ "$FIX_MODE" == "true" ]]; then
  if (( FIXES_FAILED > 0 )); then
    bad "Applied $FIXES_APPLIED fix(es), but $FIXES_FAILED fix(es) FAILED — see errors above."
    echo ""
    echo -e "Run ${BLD}bash heal.sh${RST} to retry, or apply the fixes manually using the commands shown."
    echo "Then restart the gateway: openclaw gateway restart"
    exit 1
  elif (( FIXES_APPLIED == 0 )); then
    warn "$ISSUES_FOUND issue(s) found, but no fixes were applied (check that --fix code paths covered them)."
    exit 1
  else
    echo -e "${GRN}Applied $FIXES_APPLIED fix(es). Restart the gateway to apply:${RST}"
    echo "  openclaw gateway restart"
  fi
else
  warn "$ISSUES_FOUND issue(s) found from this version's breaking changes."
  echo ""
  echo -e "Run with ${BLD}--fix${RST} to auto-apply safe fixes:"
  echo "  bash $(basename "$0") --fix"
  echo "  openclaw gateway restart"
fi
echo ""
