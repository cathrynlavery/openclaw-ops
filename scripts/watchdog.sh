#!/usr/bin/env bash
set -euo pipefail
# openclaw watchdog.sh — runs every 5 minutes via LaunchAgent
# Monitors gateway health and auto-heals common issues
# Install with: bash watchdog-install.sh

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" && source "$LIB_DIR/lib.sh"
require_tools python3 openclaw

LOG_DIR="${OPENCLAW_LOG_DIR:-$HOME/.openclaw/logs}"
LOG_FILE="$LOG_DIR/watchdog.log"
HEAL_SCRIPT="$(cd "$(dirname "$0")" && pwd)/heal.sh"
SESSION_MONITOR_SCRIPT="${OPENCLAW_SESSION_MONITOR_SCRIPT:-$(cd "$(dirname "$0")" && pwd)/session-monitor.sh}"
SESSION_MONITOR_STAMP="${OPENCLAW_SESSION_MONITOR_STAMP:-$HOME/.openclaw/session-monitor/watchdog.stamp}"
SESSION_MONITOR_THROTTLE=600
MAX_RESTART_ATTEMPTS=3
RESTART_ATTEMPT_WINDOW=900  # 15 minutes
STATE_FILE="$HOME/.openclaw/watchdog-state.json"

mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$STATE_FILE")"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $1" | tee -a "$LOG_FILE"; }

# Trim log to last 500 lines
if [[ -f "$LOG_FILE" ]]; then
  tail -500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

log "── Watchdog tick ────────────────────"

# Track version changes — write current version to state so heal.sh and check-update.sh
# can detect when an update occurred
CURRENT_VERSION="$(get_openclaw_version)"
if [[ -n "$CURRENT_VERSION" ]]; then
  python3 -c "
import sys, json
from time import gmtime, strftime

state_file = sys.argv[1]
current_version = sys.argv[2]
try:
    d = json.load(open(state_file))
except:
    d = {}
prev = d.get('current_version') or d.get('last_version', '')
d['current_version'] = current_version
d['last_version'] = current_version
if prev and prev != current_version:
    d['previous_version'] = prev
    d['version_changed_at'] = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime())
    d['version_changed_from'] = prev
    d['version_change_pending'] = True
with open(state_file, 'w') as out:
    json.dump(d, out)
" "$STATE_FILE" "$CURRENT_VERSION" 2>/dev/null || true
fi

# ── Track restart attempts in state file ─────────────────────────────────────
get_restart_count() {
  python3 -c "
import sys, json, time
state_file = sys.argv[1]
window = int(sys.argv[2])
try:
    d = json.load(open(state_file))
    attempts = [a for a in d.get('restarts', []) if time.time() - a < window]
    print(len(attempts))
except: print(0)
" "$STATE_FILE" "$RESTART_ATTEMPT_WINDOW" 2>/dev/null || echo 0
}

record_restart() {
  python3 -c "
import sys, json, time
state_file = sys.argv[1]
window = int(sys.argv[2])
try:
    d = json.load(open(state_file))
except:
    d = {}
attempts = [a for a in d.get('restarts', []) if time.time() - a < window]
attempts.append(time.time())
d['restarts'] = attempts
d['last_restart'] = time.time()
import tempfile, os
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(state_file), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(d, f)
os.replace(tmp, state_file)
" "$STATE_FILE" "$RESTART_ATTEMPT_WINDOW" 2>/dev/null || true
}

clear_restarts() {
  python3 -c "
import sys, json
state_file = sys.argv[1]
try:
    d = json.load(open(state_file))
except:
    d = {}
d['restarts'] = []
d['last_ok'] = __import__('time').time()
import tempfile, os
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(state_file), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(d, f)
os.replace(tmp, state_file)
" "$STATE_FILE" 2>/dev/null || true
}

maybe_run_session_monitor() {
  local now stamp_mtime

  [[ -x "$SESSION_MONITOR_SCRIPT" ]] || return 0
  mkdir -p "$(dirname "$SESSION_MONITOR_STAMP")"
  now="$(epoch_now)"
  stamp_mtime="$(file_mtime "$SESSION_MONITOR_STAMP" || true)"
  stamp_mtime="${stamp_mtime:-0}"

  if (( now - stamp_mtime < SESSION_MONITOR_THROTTLE )); then
    log "Session monitor throttled"
    return 0
  fi

  log "Running session monitor"
  if bash "$SESSION_MONITOR_SCRIPT" --no-alert >>"$LOG_FILE" 2>&1; then
    touch "$SESSION_MONITOR_STAMP"
  else
    log "Session monitor failed"
    touch "$SESSION_MONITOR_STAMP"
  fi
}

# ── Gateway health check ──────────────────────────────────────────────────────
GATEWAY_PORT="$(get_gateway_port)"
GATEWAY_URL="http://127.0.0.1:${GATEWAY_PORT}/health"

HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 "$GATEWAY_URL" 2>/dev/null || echo "000")

if [[ "$HTTP_STATUS" == "200" ]] || [[ "$HTTP_STATUS" == "401" ]]; then
  # 401 = gateway is up, auth token required (expected in normal operation)
  log "Gateway healthy (HTTP $HTTP_STATUS)"
  clear_restarts
  maybe_run_session_monitor
  exit 0
fi

# ── Gateway is down ───────────────────────────────────────────────────────────
log "Gateway unreachable (HTTP $HTTP_STATUS)"

RESTART_COUNT=$(get_restart_count)
log "Restart attempts in last ${RESTART_ATTEMPT_WINDOW}s: $RESTART_COUNT"

if [[ "$RESTART_COUNT" -ge "$MAX_RESTART_ATTEMPTS" ]]; then
  log "ERROR: Max restart attempts ($MAX_RESTART_ATTEMPTS) reached in window. Escalating."

  # macOS notification
  if command -v osascript &>/dev/null; then
    osascript -e 'display notification "OpenClaw gateway is down and not recovering. Manual intervention needed." with title "OpenClaw Watchdog" subtitle "Restart limit reached" sound name "Basso"' 2>/dev/null || true
  fi

  # Log escalation for potential alerting integrations
  log "ESCALATION: Gateway down, $RESTART_COUNT restarts attempted. Check: tail -50 ~/.openclaw/logs/gateway.err.log"
  exit 1
fi

# ── Attempt recovery ──────────────────────────────────────────────────────────
log "Attempting gateway restart (attempt $((RESTART_COUNT + 1)) of $MAX_RESTART_ATTEMPTS)"
record_restart

openclaw gateway restart 2>>"$LOG_FILE" &
RESTART_PID=$!
sleep 8

# Verify it came back up
HTTP_STATUS_AFTER=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 "$GATEWAY_URL" 2>/dev/null || echo "000")

if [[ "$HTTP_STATUS_AFTER" == "200" ]] || [[ "$HTTP_STATUS_AFTER" == "401" ]]; then
  log "Gateway recovered (HTTP $HTTP_STATUS_AFTER)"
  # macOS notification on recovery
  if command -v osascript &>/dev/null; then
    osascript -e 'display notification "OpenClaw gateway restarted successfully." with title "OpenClaw Watchdog" subtitle "Recovered"' 2>/dev/null || true
  fi
  maybe_run_session_monitor
  exit 0
fi

# ── Restart didn't help — run heal.sh ────────────────────────────────────────
if [[ -f "$HEAL_SCRIPT" ]]; then
  log "Simple restart failed — running heal.sh"
  bash "$HEAL_SCRIPT" 2>&1 | tee -a "$LOG_FILE" || log "heal.sh exited with errors"
else
  log "heal.sh not found at $HEAL_SCRIPT — skipping"
fi

# Final check
HTTP_FINAL=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 "$GATEWAY_URL" 2>/dev/null || echo "000")
if [[ "$HTTP_FINAL" == "200" ]] || [[ "$HTTP_FINAL" == "401" ]]; then
  log "Gateway recovered after heal.sh"
  clear_restarts
  maybe_run_session_monitor
  exit 0
else
  log "Gateway still down after heal.sh (HTTP $HTTP_FINAL)"
  exit 1
fi
