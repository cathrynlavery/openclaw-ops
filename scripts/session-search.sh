#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

require_tools python3 rg || exit 1

AGENTS_DIR="${OPENCLAW_AGENTS_DIR:-$HOME/.openclaw/agents}"
QUERY=""
AGENT_FILTER=""
SINCE_FILTER=""
ROLE_FILTER=""
LIMIT=20
OUTPUT_JSON=0
USE_REGEX=0
INCLUDE_ALL=0
RAW_OUTPUT=0

usage() {
  cat <<'USAGE'
Usage: scripts/session-search.sh <query> [--agent NAME] [--since DATE] [--role user|assistant|toolResult] [--limit N] [--json] [--regex] [--all] [--raw]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)
      AGENT_FILTER="${2:-}"
      shift 2
      ;;
    --since)
      SINCE_FILTER="${2:-}"
      shift 2
      ;;
    --role)
      ROLE_FILTER="${2:-}"
      shift 2
      ;;
    --limit)
      LIMIT="${2:-20}"
      shift 2
      ;;
    --json)
      OUTPUT_JSON=1
      shift
      ;;
    --regex)
      USE_REGEX=1
      shift
      ;;
    --all)
      INCLUDE_ALL=1
      shift
      ;;
    --raw)
      RAW_OUTPUT=1
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
      if [[ -z "$QUERY" ]]; then
        QUERY="$1"
      else
        printf 'Unexpected argument: %s\n' "$1" >&2
        usage >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$QUERY" ]]; then
  usage >&2
  exit 1
fi

files=()
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  files+=("$file")
done < <(
  if [[ "$INCLUDE_ALL" -eq 1 ]]; then
    find "$AGENTS_DIR" -type f \( -name '*.jsonl' -o -name '*.jsonl.deleted' -o -name '*.jsonl.reset' -o -name '*.jsonl.archived' \) 2>/dev/null | sort
  else
    find "$AGENTS_DIR" -type f -name '*.jsonl' 2>/dev/null | sort
  fi
)

filtered_files=()
since_epoch=0
if [[ -n "$SINCE_FILTER" ]]; then
  since_epoch="$(python3 - "$SINCE_FILTER" <<'PY'
from datetime import datetime, timezone
import sys

value = sys.argv[1]
formats = ["%Y-%m-%d", "%Y-%m-%dT%H:%M:%SZ"]
for fmt in formats:
    try:
        dt = datetime.strptime(value, fmt)
        if fmt == "%Y-%m-%d":
            dt = dt.replace(tzinfo=timezone.utc)
        else:
            dt = dt.replace(tzinfo=timezone.utc)
        print(int(dt.timestamp()))
        raise SystemExit(0)
    except ValueError:
        continue
print(0)
PY
)"
fi

for file in "${files[@]}"; do
  if [[ -n "$AGENT_FILTER" ]]; then
    case "$file" in
      *"/agents/$AGENT_FILTER/"*) ;;
      *) continue ;;
    esac
  fi

  if [[ "$since_epoch" -gt 0 ]]; then
    file_mtime="$(file_mtime "$file" || true)"
    file_mtime="${file_mtime:-0}"
    if (( file_mtime < since_epoch )); then
      continue
    fi
  fi

  filtered_files+=("$file")
done

if [[ ${#filtered_files[@]} -eq 0 ]]; then
  exit 0
fi

rg_tmp="$(mktemp)"
trap 'rm -f "$rg_tmp"' EXIT

rg_args=(--json --no-heading --color never)
if [[ "$USE_REGEX" -eq 0 ]]; then
  rg_args+=(-F)
fi

if ! rg "${rg_args[@]}" -- "$QUERY" "${filtered_files[@]}" >"$rg_tmp" 2>/dev/null; then
  if [[ ! -s "$rg_tmp" ]]; then
    exit 0
  fi
fi

result="$(
  python3 - "$rg_tmp" "$ROLE_FILTER" "$LIMIT" "$OUTPUT_JSON" <<'PY'
import json
import os
import sys

rg_path = sys.argv[1]
role_filter = sys.argv[2]
limit = int(sys.argv[3])
output_json = sys.argv[4] == "1"


def find_agent(path):
    parts = path.split(os.sep)
    if "agents" in parts:
        idx = parts.index("agents")
        if idx + 1 < len(parts):
            return parts[idx + 1]
    return "unknown"


def safe_json_load_line(path, line_number):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for index, raw_line in enumerate(handle, start=1):
                if index == line_number:
                    return json.loads(raw_line)
    except Exception:
        return None
    return None


def stringify_record(record):
    record_type = record.get("type")
    if record_type == "compaction":
        return record.get("summary", "")
    if record_type == "session":
        return " ".join(
            str(value)
            for value in [record.get("id"), record.get("timestamp"), record.get("cwd")]
            if value
        )

    message = record.get("message", {})
    chunks = []
    for item in message.get("content", []) or []:
        item_type = item.get("type")
        if item_type in {"thinking", "thinkingSignature"}:
            continue
        if item_type == "text" and item.get("text"):
            chunks.append(item["text"])
        elif item_type == "toolCall":
            chunks.append(f"toolCall {item.get('name') or item.get('toolName') or 'unknown'}")
    if message.get("toolName"):
        chunks.append(message.get("toolName"))
    return "\n".join(chunks).strip()


def record_metadata(path, line_number, submatch):
    record = safe_json_load_line(path, line_number)
    if record is None:
        return None

    message = record.get("message", {})
    role = message.get("role") or record.get("type") or "unknown"
    if role_filter and role != role_filter:
        return None

    session_id = record.get("id")
    if record.get("type") != "session":
        session_id = None
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                first = json.loads(handle.readline())
                session_id = first.get("id")
        except Exception:
            session_id = os.path.basename(path)

    text = stringify_record(record)
    snippet = text.strip()[:240] if text else submatch.get("match", {}).get("text", "").strip()[:240]
    return {
        "agent": find_agent(path),
        "session_id": session_id or os.path.basename(path),
        "line_number": line_number,
        "timestamp": record.get("timestamp") or message.get("timestamp") or "",
        "role": role,
        "tool_name": message.get("toolName"),
        "snippet": snippet,
        "match_offset": submatch.get("start", 0),
    }


results = []
with open(rg_path, "r", encoding="utf-8", errors="replace") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except Exception:
            continue
        if payload.get("type") != "match":
            continue
        data = payload.get("data", {})
        path = (data.get("path") or {}).get("text")
        line_number = data.get("line_number")
        if not path or not line_number:
            continue
        for submatch in data.get("submatches", []) or [{}]:
            item = record_metadata(path, line_number, submatch)
            if item is None:
                continue
            results.append(item)
            if len(results) >= limit:
                break
        if len(results) >= limit:
            break

if output_json:
    print(json.dumps(results, indent=2, sort_keys=True))
else:
    lines = []
    for item in results:
        header = f"{item['agent']} {item['session_id']}:{item['line_number']} [{item['role']}] {item['timestamp']}".strip()
        lines.append(header)
        if item["snippet"]:
            lines.append(f"  {item['snippet']}")
    print("\n".join(lines))
PY
)"

if [[ -z "$result" ]]; then
  exit 0
fi

if [[ "$RAW_OUTPUT" -eq 1 ]]; then
  printf '%s\n' "$result"
else
  printf '%s\n' "$result" | sanitize_sensitive
fi
