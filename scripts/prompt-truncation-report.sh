#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

require_tools python3 || exit 1

AGENTS_DIR="${OPENCLAW_AGENTS_DIR:-$HOME/.openclaw/agents}"
AGENT_FILTER=""
OUTPUT_JSON=0

usage() {
  cat <<'USAGE'
Usage: scripts/prompt-truncation-report.sh [--agent NAME] [--json]

Reports bootstrap truncation warnings from the latest session per agent.
Defaults to claimed local agents when available, otherwise scans all agents.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)
      AGENT_FILTER="${2:-}"
      shift 2
      ;;
    --json)
      OUTPUT_JSON=1
      shift
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

if [[ ! -d "$AGENTS_DIR" ]]; then
  if [[ "$OUTPUT_JSON" -eq 1 ]]; then
    printf '{"checked_agents":0,"affected_agents":0,"results":[]}\n'
  else
    log_warn "No agents directory found at $AGENTS_DIR"
  fi
  exit 0
fi

result="$(
  python3 - "$AGENTS_DIR" "$AGENT_FILTER" "$OUTPUT_JSON" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def parse_timestamp(value):
    if value is None:
        return 0.0
    if isinstance(value, (int, float)):
        value = float(value)
        return value / 1000.0 if value > 10_000_000_000 else value
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return 0.0
        try:
            number = float(text)
            return number / 1000.0 if number > 10_000_000_000 else number
        except ValueError:
            pass
        for candidate in (text, text.replace("Z", "+00:00")):
            try:
                dt = datetime.fromisoformat(candidate)
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
                return dt.timestamp()
            except ValueError:
                continue
    return 0.0


def normalize_session_items(payload):
    if isinstance(payload, dict):
        if any(isinstance(v, dict) for v in payload.values()):
            return list(payload.items())
        nested = payload.get("sessions")
        if isinstance(nested, dict):
            return list(nested.items())
        if isinstance(nested, list):
            return [(str(index), item) for index, item in enumerate(nested)]
    if isinstance(payload, list):
        return [(str(index), item) for index, item in enumerate(payload)]
    return []


def truthy(value):
    if isinstance(value, bool):
      return value
    if value in (None, "", 0, 0.0, [], {}):
      return False
    return True


def latest_session_entry(agent_dir):
    sessions_path = agent_dir / "sessions" / "sessions.json"
    if not sessions_path.exists():
        return None, "missing sessions.json"

    try:
        payload = json.loads(sessions_path.read_text(encoding="utf-8"))
    except Exception as exc:
        return None, f"invalid sessions.json: {exc}"

    latest = None
    for key, session in normalize_session_items(payload):
        if not isinstance(session, dict):
            continue
        updated = (
            parse_timestamp(session.get("updatedAt"))
            or parse_timestamp(session.get("createdAt"))
            or parse_timestamp(session.get("timestamp"))
        )
        session_key = session.get("id") or key
        candidate = (updated, session_key, session)
        if latest is None or candidate[0] > latest[0]:
            latest = candidate

    if latest is None:
        return None, "no session records"

    return latest, None


def model_provider(session):
    return (
        session.get("modelProvider")
        or (session.get("model") or {}).get("provider")
        or "unknown"
    )


def agent_dirs(base_dir, agent_filter):
    if agent_filter:
        target = base_dir / agent_filter
        return [target] if target.is_dir() else []

    dirs = sorted([path for path in base_dir.iterdir() if path.is_dir() and path.name != "_archived"])
    claimed = [path for path in dirs if (path / "paperclip-claimed-api-key.json").exists()]
    return claimed or dirs


base_dir = Path(sys.argv[1]).expanduser()
agent_filter = sys.argv[2]
output_json = sys.argv[3] == "1"

results = []
checked_agents = 0

for agent_dir in agent_dirs(base_dir, agent_filter):
    checked_agents += 1
    latest, error = latest_session_entry(agent_dir)
    if error:
        continue

    _, session_key, session = latest
    report = session.get("systemPromptReport") or {}
    truncation = report.get("bootstrapTruncation") or {}

    if not isinstance(truncation, dict):
        continue

    warning_shown = bool(truncation.get("warningShown"))
    truncated_files = truncation.get("truncatedFiles") or []
    near_limit_files = truncation.get("nearLimitFiles") or []
    total_near_limit = truncation.get("totalNearLimit") or 0

    if not (
        warning_shown
        or truthy(truncated_files)
        or truthy(near_limit_files)
        or truthy(total_near_limit)
    ):
        continue

    results.append(
        {
            "agent": agent_dir.name,
            "session_key": session_key,
            "model_provider": model_provider(session),
            "updated_at": session.get("updatedAt") or session.get("createdAt") or session.get("timestamp"),
            "warning_shown": warning_shown,
            "truncated_files": truncated_files,
            "truncated_count": len(truncated_files) if isinstance(truncated_files, list) else 0,
            "near_limit_files": near_limit_files,
            "near_limit_count": len(near_limit_files) if isinstance(near_limit_files, list) else 0,
            "total_near_limit": total_near_limit,
        }
    )

results.sort(key=lambda item: (item["agent"], item["session_key"]))

payload = {
    "checked_agents": checked_agents,
    "affected_agents": len(results),
    "results": results,
}

if output_json:
    print(json.dumps(payload, indent=2, sort_keys=True))
    raise SystemExit(0)

if not results:
    print(f"No bootstrap truncation warnings found across {checked_agents} checked agents.")
    raise SystemExit(0)

print(f"Bootstrap truncation warnings found in {len(results)} of {checked_agents} checked agents:")
for item in results:
    print(
        f"- {item['agent']} ({item['session_key']}) provider={item['model_provider']} "
        f"warning={str(item['warning_shown']).lower()} truncated={item['truncated_count']} "
        f"near_limit={item['near_limit_count']} total_near_limit={item['total_near_limit']}"
    )

    if item["truncated_count"]:
        for entry in item["truncated_files"]:
            if isinstance(entry, dict):
                path = entry.get("path") or entry.get("file") or "unknown"
                print(f"    truncated: {path}")
            else:
                print(f"    truncated: {entry}")

    if item["near_limit_count"]:
        for entry in item["near_limit_files"]:
            if isinstance(entry, dict):
                path = entry.get("path") or entry.get("file") or "unknown"
                print(f"    near-limit: {path}")
            else:
                print(f"    near-limit: {entry}")
PY
)"

printf '%s\n' "$result"
