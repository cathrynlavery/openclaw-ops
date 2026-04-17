#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

require_tools python3 || exit 1

OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
AGENTS_DIR="${OPENCLAW_AGENTS_DIR:-$OPENCLAW_DIR/agents}"
CONFIG_FILE="${OPENCLAW_CONFIG_FILE:-$OPENCLAW_DIR/openclaw.json}"
AGENTS_LIST_FILE="${OPENCLAW_AGENTS_LIST_FILE:-$OPENCLAW_DIR/agents.list}"
ARCHIVE_MODE=0
DELETE_EMPTY_MODE=0

usage() {
  cat <<'USAGE'
Usage: scripts/agent-dirs-audit.sh [--archive] [--delete-empty]

Audits top-level directories under ~/.openclaw/agents that are not configured in agents.list.

Default mode is dry-run:
  --archive       Move DORMANT dirs into ~/.openclaw/agents/_archived/YYYY-MM-DD/
  --delete-empty  Remove EMPTY dirs
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)
      ARCHIVE_MODE=1
      shift
      ;;
    --delete-empty)
      DELETE_EMPTY_MODE=1
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
  log_warn "No agents directory found at $AGENTS_DIR"
  exit 0
fi

audit_tmp="$(mktemp)"
trap 'rm -f "$audit_tmp"' EXIT

python3 - "$AGENTS_DIR" "$CONFIG_FILE" "$AGENTS_LIST_FILE" >"$audit_tmp" <<'PY'
import json
import os
import sys
import time
from pathlib import Path


def load_configured_ids(config_file, agents_list_file):
    configured = set()
    agents_list_path = Path(agents_list_file)
    if agents_list_path.exists():
        try:
            for line in agents_list_path.read_text(encoding="utf-8").splitlines():
                value = line.strip()
                if value and not value.startswith("#"):
                    configured.add(value)
        except Exception:
            pass

    config_path = Path(config_file)
    if config_path.exists():
        try:
            payload = json.loads(config_path.read_text(encoding="utf-8"))
            for item in payload.get("agents", {}).get("list", []):
                if isinstance(item, dict):
                    agent_id = item.get("id")
                    if agent_id:
                        configured.add(agent_id)
                elif isinstance(item, str):
                    configured.add(item)
        except Exception:
            pass

    return configured


def format_size(num_bytes):
    value = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            if unit == "B":
                return f"{int(value)}{unit}"
            return f"{value:.1f}{unit}"
        value /= 1024.0
    return f"{int(num_bytes)}B"


def age_text(seconds):
    if seconds < 60:
        return f"{int(seconds)}s"
    if seconds < 3600:
        return f"{int(seconds // 60)}m"
    if seconds < 86400:
        return f"{int(seconds // 3600)}h"
    return f"{int(seconds // 86400)}d"


def audit_directory(path, now_epoch):
    if path.is_symlink():
        return {
            "name": path.name,
            "status": "SKIP-SYMLINK",
            "sessions": 0,
            "size_bytes": 0,
            "size_text": "0B",
            "age_days": 0,
            "age_text": "n/a",
            "note": "symlink",
        }

    sessions_dir = path / "sessions"
    agent_dir = path / "agent"
    auth_file = agent_dir / "auth-profiles.json"
    has_sessions_dir = sessions_dir.is_dir()
    has_agent_dir = agent_dir.is_dir()
    has_auth_file = auth_file.is_file()

    if not has_sessions_dir and not has_agent_dir and not has_auth_file:
        return {
            "name": path.name,
            "status": "SKIP-PARTIAL",
            "sessions": 0,
            "size_bytes": 0,
            "size_text": "0B",
            "age_days": 0,
            "age_text": "n/a",
            "note": "missing sessions/, agent/, and agent/auth-profiles.json",
        }

    session_count = 0
    size_bytes = 0
    newest_mtime = path.stat().st_mtime

    for root, dirnames, filenames in os.walk(path, topdown=True, followlinks=False):
        root_path = Path(root)
        dirnames[:] = [dirname for dirname in dirnames if dirname != "_archived"]

        for dirname in dirnames:
            child = root_path / dirname
            try:
                newest_mtime = max(newest_mtime, child.lstat().st_mtime)
            except FileNotFoundError:
                continue

        for filename in filenames:
            file_path = root_path / filename
            try:
                stat = file_path.lstat()
            except FileNotFoundError:
                continue
            size_bytes += stat.st_size
            newest_mtime = max(newest_mtime, stat.st_mtime)
            if sessions_dir in file_path.parents:
                session_count += 1

    age_seconds = max(0, now_epoch - newest_mtime)
    age_days = age_seconds / 86400.0

    if session_count == 0 and size_bytes < 1_048_576:
        status = "EMPTY"
        note = "0 session files and <1MB"
    elif age_days > 30:
        status = "DORMANT"
        note = "older than 30d with data"
    else:
        status = "RECENT"
        note = "changed within 30d"

    return {
        "name": path.name,
        "status": status,
        "sessions": session_count,
        "size_bytes": size_bytes,
        "size_text": format_size(size_bytes),
        "age_days": int(age_days),
        "age_text": age_text(age_seconds),
        "note": note,
    }


agents_dir = Path(sys.argv[1]).expanduser()
config_file = sys.argv[2]
agents_list_file = sys.argv[3]
configured = load_configured_ids(config_file, agents_list_file)
now_epoch = time.time()

results = []
for child in sorted(agents_dir.iterdir(), key=lambda item: item.name):
    if child.name == "_archived":
        continue
    if not child.is_dir():
        continue
    if child.name in configured:
        continue
    row = audit_directory(child, now_epoch)
    row["path"] = str(child)
    results.append(row)

print(json.dumps({"configured": sorted(configured), "results": results}, sort_keys=True))
PY

report_json="$(cat "$audit_tmp")"

count="$(python3 - "$report_json" <<'PY'
import json, sys
print(len(json.loads(sys.argv[1])["results"]))
PY
)"

if [[ "$count" -eq 0 ]]; then
  echo "No unconfigured agent directories found under $AGENTS_DIR."
  exit 0
fi

python3 - "$report_json" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
rows = payload["results"]

name_w = max(len("dir"), *(len(row["name"]) for row in rows))
status_w = max(len("status"), *(len(row["status"]) for row in rows))
sessions_w = max(len("sessions"), *(len(str(row["sessions"])) for row in rows))
size_w = max(len("size"), *(len(row.get("size_text", "0B")) for row in rows))
age_w = max(len("age"), *(len(row.get("age_text", "n/a")) for row in rows))

header = (
    f"{'dir':<{name_w}}  {'status':<{status_w}}  {'sessions':>{sessions_w}}  "
    f"{'size':>{size_w}}  {'age':>{age_w}}  note"
)
print(header)
print("-" * len(header))

for row in rows:
    print(
        f"{row['name']:<{name_w}}  {row['status']:<{status_w}}  {row['sessions']:>{sessions_w}}  "
        f"{row.get('size_text', '0B'):>{size_w}}  {row.get('age_text', 'n/a'):>{age_w}}  {row['note']}"
    )
PY

echo ""
if [[ "$ARCHIVE_MODE" -eq 0 && "$DELETE_EMPTY_MODE" -eq 0 ]]; then
  echo "DRY RUN — no directories moved or deleted."
fi

archive_date="$(date +%F)"
archive_base="$AGENTS_DIR/_archived/$archive_date"

while IFS=$'\t' read -r path status name; do
  [[ -n "$path" ]] || continue
  case "$status" in
    EMPTY)
      if [[ "$DELETE_EMPTY_MODE" -eq 1 ]]; then
        rm -rf -- "$path"
        log_fixed "Deleted empty dir: $name"
      fi
      ;;
    DORMANT)
      if [[ "$ARCHIVE_MODE" -eq 1 ]]; then
        mkdir -p "$archive_base"
        target="$archive_base/$name"
        if [[ -e "$target" ]]; then
          suffix=1
          while [[ -e "${target}-$suffix" ]]; do
            suffix=$((suffix + 1))
          done
          target="${target}-$suffix"
        fi
        mv -- "$path" "$target"
        log_fixed "Archived dormant dir: $name"
      fi
      ;;
  esac
done < <(python3 - "$report_json" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
for row in payload["results"]:
    print(f"{row['path']}\t{row['status']}\t{row['name']}")
PY
)
