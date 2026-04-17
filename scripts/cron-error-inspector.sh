#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

require_tools openclaw python3 || exit 1

AGENT_FILTER=""
CONSECUTIVE_FILTER=1

usage() {
  cat <<'USAGE'
Usage: scripts/cron-error-inspector.sh [--agent NAME] [--consecutive N]

Formats erroring cron jobs from `openclaw cron list --all --json`.
Only deterministic hint in v1: timeout errors mention `--light-context` when missing.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)
      AGENT_FILTER="${2:-}"
      shift 2
      ;;
    --consecutive)
      CONSECUTIVE_FILTER="${2:-1}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
    *)
      printf 'Unexpected argument: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$CONSECUTIVE_FILTER" in
  ''|*[!0-9]*)
    printf 'Invalid consecutive count: %s\n' "$CONSECUTIVE_FILTER" >&2
    usage >&2
    exit 1
    ;;
esac

inspect_tmp="$(mktemp)"
trap 'rm -f "$inspect_tmp"' EXIT

if ! openclaw cron list --all --json >"$inspect_tmp" 2>/dev/null; then
  log_error "Failed to load cron jobs from openclaw"
  exit 1
fi

python3 - "$inspect_tmp" "$AGENT_FILTER" "$CONSECUTIVE_FILTER" <<'PY'
import json
import sys
import time


def schedule_text(schedule):
    if not isinstance(schedule, dict):
        return "unknown"
    kind = schedule.get("kind")
    if kind == "cron":
        expr = schedule.get("expr", "?")
        tz = schedule.get("tz")
        return f"{expr} ({tz})" if tz else expr
    if kind == "every":
        every = schedule.get("every") or schedule.get("interval") or "unknown"
        return f"every {every}"
    if kind == "at":
        at = schedule.get("at") or schedule.get("when") or "unknown"
        tz = schedule.get("tz")
        return f"{at} ({tz})" if tz else str(at)
    return kind or "unknown"


def human_age(last_run_ms):
    if not last_run_ms:
        return "never"
    try:
        delta = max(0, int(time.time() - (float(last_run_ms) / 1000.0)))
    except Exception:
        return "unknown"
    if delta < 60:
        return f"{delta}s"
    if delta < 3600:
        return f"{delta // 60}m"
    if delta < 86400:
        return f"{delta // 3600}h"
    return f"{delta // 86400}d"


def payload_preview(payload):
    if not isinstance(payload, dict):
        return ""
    fields = []
    if payload.get("kind"):
        fields.append(f"kind={payload['kind']}")
    if payload.get("model"):
        fields.append(f"model={payload['model']}")
    if payload.get("thinking"):
        fields.append(f"thinking={payload['thinking']}")
    if "lightContext" in payload:
        fields.append(f"lightContext={payload['lightContext']}")
    message = payload.get("message")
    if message:
        message_text = str(message).replace("\n", " ").strip()
        if len(message_text) > 48:
            message_text = message_text[:48] + "..."
        fields.append(message_text)
    preview = " | ".join(fields).replace("\n", " ").strip()
    return preview[:500]


with open(sys.argv[1], "r", encoding="utf-8") as handle:
    raw = json.load(handle)

jobs = raw if isinstance(raw, list) else raw.get("jobs", raw.get("crons", []))
agent_filter = sys.argv[2]
consecutive_filter = int(sys.argv[3])

rows = []
for job in jobs:
    if not isinstance(job, dict):
        continue
    agent = job.get("agentId") or "unknown"
    if agent_filter and agent != agent_filter:
        continue

    state = job.get("state") or {}
    consecutive = int(state.get("consecutiveErrors") or 0)
    last_status = state.get("lastStatus") or state.get("lastRunStatus") or ""
    if consecutive_filter > 1:
        if consecutive < consecutive_filter:
            continue
    else:
        if consecutive <= 0 and last_status != "error":
            continue

    payload = job.get("payload") or {}
    reason = state.get("lastErrorReason") or ""
    hint = None
    if reason == "timeout" and payload.get("kind") == "agentTurn" and not payload.get("lightContext"):
        hint = "Timeout + missing light-context: consider `openclaw cron edit <id> --light-context`."

    rows.append(
        {
            "agent": agent,
            "id": job.get("id") or "",
            "name": job.get("name") or "(unnamed)",
            "schedule": schedule_text(job.get("schedule")),
            "last_error": state.get("lastError") or "(none)",
            "last_error_reason": reason or "(none)",
            "consecutive_errors": consecutive,
            "last_run_age": human_age(state.get("lastRunAtMs")),
            "payload_preview": payload_preview(payload),
            "hint": hint,
        }
    )

rows.sort(key=lambda item: (-item["consecutive_errors"], item["agent"], item["name"], item["id"]))

if not rows:
    target = f" for agent {agent_filter}" if agent_filter else ""
    print(f"No erroring cron jobs found{target} with consecutiveErrors >= {consecutive_filter}.")
    raise SystemExit(0)

for item in rows:
    print(f"- {item['id']} | {item['name']}")
    print(f"  agent: {item['agent']}")
    print(f"  schedule: {item['schedule']}")
    print(f"  consecutiveErrors: {item['consecutive_errors']}")
    print(f"  last-run-age: {item['last_run_age']}")
    print(f"  state.lastErrorReason: {item['last_error_reason']}")
    print(f"  state.lastError: {item['last_error']}")
    print(f"  payload: {item['payload_preview'] or '(empty)'}")
    if item["hint"]:
        print(f"  hint: {item['hint']}")
    print("")
PY
