#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"
source "$LIB_DIR/incident-manager.sh"

require_tools python3 xargs || exit 1

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
AGENTS_DIR="${OPENCLAW_AGENTS_DIR:-$HOME/.openclaw/agents}"
STATE_DIR="${OPENCLAW_SESSION_MONITOR_DIR:-$HOME/.openclaw/session-monitor}"
LATEST_FILE="$STATE_DIR/latest.json"
LAST_RUN_FILE="${OPENCLAW_SESSION_MONITOR_LAST_RUN:-$HOME/.openclaw/session-monitor.lastrun}"
VERBOSE=0
NO_ALERT=0
FORCE=0

usage() {
  cat <<'USAGE'
Usage: scripts/session-monitor.sh [--verbose] [--no-alert] [--force]
USAGE
}

log_verbose() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    log_info "$1"
  fi
}

extract_json_field() {
  local field="$1"
  local json_payload="$2"
  python3 - "$field" "$json_payload" <<'PY'
import json
import sys

field = sys.argv[1]
payload = json.loads(sys.argv[2])
value = payload.get(field)
if isinstance(value, (dict, list)):
    print(json.dumps(value, sort_keys=True))
elif value is None:
    print("")
else:
    print(value)
PY
}

write_latest_json() {
  local payload="$1"
  mkdir -p "$STATE_DIR"
  python3 - "$LATEST_FILE" "$payload" <<'PY'
import json
import os
import sys
import tempfile

target = sys.argv[1]
payload = json.loads(sys.argv[2])
os.makedirs(os.path.dirname(target), exist_ok=True)
with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=os.path.dirname(target), delete=False) as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
    temp_path = handle.name
os.replace(temp_path, target)
PY
}

analyze_file() {
  local file="$1"
  local now_epoch
  now_epoch="$(epoch_now)"
  local file_mtime_epoch
  file_mtime_epoch="$(file_mtime "$file" || true)"
  file_mtime_epoch="${file_mtime_epoch:-0}"

  python3 - "$file" "$now_epoch" "$file_mtime_epoch" <<'PY'
import json
import os
import re
import sys
from datetime import datetime, timezone

path = sys.argv[1]
now_epoch = int(float(sys.argv[2] or 0))
file_mtime_epoch = int(float(sys.argv[3] or 0))


def parse_epoch(value):
    if not value:
        return 0
    try:
        return int(datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())
    except Exception:
        try:
            return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
        except Exception:
            return 0


def emit(agent, anomaly_type, discriminator, severity, title, evidence):
    payload = {
        "dedupeKey": f"agent:{agent}:{anomaly_type}:{discriminator}",
        "severity": severity,
        "title": title,
        "evidence": evidence,
    }
    print(json.dumps(payload, sort_keys=True))


def find_agent(file_path):
    parts = file_path.replace("\\", "/").split("/")
    if "agents" in parts:
        idx = parts.index("agents")
        if idx + 1 < len(parts):
            return parts[idx + 1]
    return "unknown"


agent = find_agent(path)
header = {}
records = []
try:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        first_line = handle.readline().strip()
        if first_line:
            try:
                header = json.loads(first_line)
            except Exception:
                header = {}

    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except Exception:
                continue
except Exception:
    raise SystemExit(0)

session_id = header.get("id") or os.path.basename(path)
header_timestamp = parse_epoch(header.get("timestamp"))
last_activity = 0
meaningful_assistant_count = 0
error_like_count = 0
auth_matches = []
tool_calls = {}
max_retry_streak = {}
last_failed_tool = None
current_streak = 0

auth_pattern = re.compile(r"401|403|unauthorized|forbidden|token.{0,20}expired", re.IGNORECASE)
error_pattern = re.compile(r"error:|failed|traceback|permission denied|cannot proceed|unable to|i apologize", re.IGNORECASE)
stale_session_window = 86400

for record in records:
    if record.get("type") == "message":
        message = record.get("message", {})
        role = message.get("role")
        timestamp = parse_epoch(record.get("timestamp") or message.get("timestamp"))
        if timestamp:
            last_activity = max(last_activity, timestamp)
        content = message.get("content") or []

        if role == "assistant":
            text_chunks = []
            for item in content:
                item_type = item.get("type")
                if item_type == "toolCall":
                    tool_calls[item.get("id")] = item.get("name") or item.get("toolName") or "unknown"
                elif item_type == "text":
                    text = item.get("text", "")
                    if text:
                        text_chunks.append(text)
            if any(chunk.strip() for chunk in text_chunks):
                meaningful_assistant_count += 1
                joined = "\n".join(text_chunks)
                if error_pattern.search(joined):
                    error_like_count += 1
                if auth_pattern.search(joined):
                    auth_matches.append(joined[:240])

        elif role == "toolResult":
            tool_name = message.get("toolName") or tool_calls.get(message.get("toolCallId")) or "unknown"
            texts = [item.get("text", "") for item in content if item.get("type") == "text" and item.get("text")]
            joined = "\n".join(texts)
            is_error = bool(message.get("isError")) or (message.get("details") or {}).get("status") == "failed"

            if is_error:
                if tool_name == last_failed_tool:
                    current_streak += 1
                else:
                    last_failed_tool = tool_name
                    current_streak = 1
                max_retry_streak[tool_name] = max(max_retry_streak.get(tool_name, 0), current_streak)
            else:
                last_failed_tool = None
                current_streak = 0

            if joined and (is_error or error_pattern.search(joined)):
                error_like_count += 1
            if auth_pattern.search(joined):
                auth_matches.append(joined[:240])

retry_tool = None
retry_count = 0
for tool_name, count in max_retry_streak.items():
    if count > retry_count:
        retry_tool = tool_name
        retry_count = count

if retry_tool and retry_count >= 5:
    emit(
        agent,
        "retry-loop",
        retry_tool,
        "warning",
        f"Retry loop: {agent} calling {retry_tool} {retry_count} times",
        {"agent": agent, "tool": retry_tool, "count": retry_count, "session_id": session_id, "session_path": path},
    )

effective_last = last_activity or header_timestamp
if header_timestamp and now_epoch - header_timestamp > 600 and effective_last and now_epoch - effective_last > 1800 and meaningful_assistant_count < 2:
    emit(
        agent,
        "dead-run",
        "_",
        "info",
        f"Dead run: {agent} session produced too little output",
        {"agent": agent, "meaningful_assistant_messages": meaningful_assistant_count, "session_id": session_id, "session_path": path},
    )

if file_mtime_epoch and now_epoch - file_mtime_epoch <= stale_session_window and last_activity and now_epoch - last_activity > 1800 and meaningful_assistant_count >= 1:
    emit(
        agent,
        "stuck-run",
        "_",
        "critical",
        f"Stuck run: {agent} session stopped progressing",
        {
            "agent": agent,
            "file_mtime_epoch": file_mtime_epoch,
            "file_mtime_age_seconds": now_epoch - file_mtime_epoch,
            "last_activity_epoch": last_activity,
            "last_activity_age_seconds": now_epoch - last_activity,
            "session_id": session_id,
            "session_path": path,
        },
    )

if auth_matches:
    emit(
        agent,
        "auth-error",
        "_",
        "critical",
        f"Auth errors: {agent} session hit authentication failures",
        {"agent": agent, "matches": auth_matches[:3], "session_id": session_id, "session_path": path},
    )

if error_like_count >= 4:
    emit(
        agent,
        "error-cluster",
        "_",
        "warning",
        f"Error cluster: {agent} session accumulated {error_like_count} failures",
        {"agent": agent, "error_count": error_like_count, "session_id": session_id, "session_path": path},
    )
PY
}

if [[ "${1:-}" == "--analyze-file" ]]; then
  analyze_file "$2"
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose)
      VERBOSE=1
      shift
      ;;
    --no-alert)
      NO_ALERT=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

mkdir -p "$STATE_DIR"

all_files=()
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  all_files+=("$file")
done < <(find "$AGENTS_DIR" -type f -name '*.jsonl' 2>/dev/null | sort)
last_run=0
if [[ "$FORCE" -eq 0 && -f "$LAST_RUN_FILE" ]]; then
  last_run="$(file_mtime "$LAST_RUN_FILE")"
  last_run="${last_run:-0}"
fi

changed_files=()
skipped_files=0
for file in "${all_files[@]}"; do
  if [[ "$FORCE" -eq 1 ]]; then
    changed_files+=("$file")
    continue
  fi

  file_m="$(file_mtime "$file")"
  file_m="${file_m:-0}"
  if (( file_m > last_run )); then
    changed_files+=("$file")
  else
    skipped_files=$((skipped_files + 1))
  fi
done

analysis_tmp="$(mktemp)"
deduped_tmp="$(mktemp)"
trap 'rm -f "$analysis_tmp" "$deduped_tmp"' EXIT

if [[ ${#changed_files[@]} -gt 0 ]]; then
  printf '%s\0' "${changed_files[@]}" | xargs -0 -n1 -P4 /bin/bash "$SCRIPT_PATH" --analyze-file >"$analysis_tmp"
fi

python3 - "$analysis_tmp" "$deduped_tmp" <<'PY'
import json
import sys

source = sys.argv[1]
target = sys.argv[2]
by_key = {}

with open(source, "r", encoding="utf-8", errors="replace") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except Exception:
            continue
        key = payload["dedupeKey"]
        current = by_key.get(key)
        if current is None:
            by_key[key] = payload
            continue
        existing_count = (current.get("evidence") or {}).get("count", 0)
        new_count = (payload.get("evidence") or {}).get("count", 0)
        if new_count >= existing_count:
            by_key[key] = payload

with open(target, "w", encoding="utf-8") as handle:
    for payload in by_key.values():
        handle.write(json.dumps(payload, sort_keys=True) + "\n")
PY

detections_json='[]'
if [[ -s "$deduped_tmp" ]]; then
  detections_json="$(python3 - "$deduped_tmp" <<'PY'
import json
import sys

items = []
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        try:
            items.append(json.loads(line))
        except Exception:
            continue
print(json.dumps(items, sort_keys=True))
PY
)"
fi

if [[ -s "$deduped_tmp" ]]; then
  while IFS= read -r payload; do
    [[ -z "$payload" ]] && continue
    dedupe_key="$(extract_json_field dedupeKey "$payload")"
    severity="$(extract_json_field severity "$payload")"
    title="$(extract_json_field title "$payload")"
    evidence="$(extract_json_field evidence "$payload")"
    incident_report "$dedupe_key" "$severity" "$title" "$evidence"

    if [[ "$severity" == "critical" && "$NO_ALERT" -eq 0 ]]; then
      openclaw system event --mode now --text "$title" >/dev/null 2>&1 || true
    fi
  done <"$deduped_tmp"
fi

summary_json="$(python3 - "${#all_files[@]}" "${#changed_files[@]}" "$skipped_files" "$detections_json" <<'PY'
import json
import sys
from datetime import datetime, timezone

payload = {
    "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "totalFiles": int(sys.argv[1]),
    "scannedFiles": int(sys.argv[2]),
    "skippedFiles": int(sys.argv[3]),
    "detections": json.loads(sys.argv[4]),
}
print(json.dumps(payload, sort_keys=True))
PY
)"

write_latest_json "$summary_json"
touch "$LAST_RUN_FILE"
log_verbose "Session monitor scanned ${#changed_files[@]} files and found $(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1]).get("detections", [])))' "$summary_json") anomalies"
