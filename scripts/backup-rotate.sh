#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

require_tools python3 || exit 1

OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
APPLY_MODE=0
KEEP_COUNT=3

usage() {
  cat <<'USAGE'
Usage: scripts/backup-rotate.sh [--dry-run] [--apply] [--keep N]

Scans ~/.openclaw for *.bak* files, groups them by the path prefix before the first
.bak, and keeps the newest N files per group.

Default mode is dry-run.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY_MODE=1
      shift
      ;;
    --dry-run)
      APPLY_MODE=0
      shift
      ;;
    --keep)
      KEEP_COUNT="${2:-3}"
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

case "$KEEP_COUNT" in
  ''|*[!0-9]*)
    printf 'Invalid keep count: %s\n' "$KEEP_COUNT" >&2
    usage >&2
    exit 1
    ;;
esac

if [[ ! -d "$OPENCLAW_DIR" ]]; then
  log_warn "No OpenClaw directory found at $OPENCLAW_DIR"
  exit 0
fi

report_tmp="$(mktemp)"
trap 'rm -f "$report_tmp"' EXIT

python3 - "$OPENCLAW_DIR" "$KEEP_COUNT" >"$report_tmp" <<'PY'
import json
import sys
from pathlib import Path


def base_key(path):
    text = str(path)
    index = text.find(".bak")
    return text[:index] if index != -1 else text


root = Path(sys.argv[1]).expanduser()
keep_count = int(sys.argv[2])
groups = {}

for path in root.rglob("*"):
    if not path.is_file():
        continue
    if ".bak" not in path.name:
        continue

    try:
        stat = path.stat()
    except FileNotFoundError:
        continue

    key = base_key(path)
    groups.setdefault(key, []).append(
        {
            "path": str(path),
            "name": path.name,
            "mtime": stat.st_mtime,
            "size": stat.st_size,
        }
    )

results = []
for key, items in sorted(groups.items()):
    items.sort(key=lambda item: (-item["mtime"], item["path"]))
    keep = items[:keep_count]
    remove = items[keep_count:]
    if not remove:
        continue
    results.append(
        {
            "base": key,
            "keep": keep,
            "remove": remove,
            "remove_count": len(remove),
            "remove_bytes": sum(item["size"] for item in remove),
        }
    )

print(json.dumps({"results": results}, sort_keys=True))
PY

report_json="$(cat "$report_tmp")"

group_count="$(python3 - "$report_json" <<'PY'
import json, sys
print(len(json.loads(sys.argv[1])["results"]))
PY
)"

if [[ "$group_count" -eq 0 ]]; then
  echo "No backup rotation needed under $OPENCLAW_DIR."
  exit 0
fi

python3 - "$report_json" "$KEEP_COUNT" <<'PY'
import json
import sys


def fmt_size(num_bytes):
    value = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            if unit == "B":
                return f"{int(value)}{unit}"
            return f"{value:.1f}{unit}"
        value /= 1024.0
    return f"{int(num_bytes)}B"


payload = json.loads(sys.argv[1])
keep_count = int(sys.argv[2])
rows = payload["results"]

base_w = max(len("base"), *(len(row["base"]) for row in rows))
remove_w = max(len("remove"), *(len(str(row["remove_count"])) for row in rows))
bytes_w = max(len("bytes"), *(len(fmt_size(row["remove_bytes"])) for row in rows))

header = f"{'base':<{base_w}}  {'remove':>{remove_w}}  {'bytes':>{bytes_w}}  keeping"
print(header)
print("-" * len(header))
for row in rows:
    kept_names = ", ".join(item["name"] for item in row["keep"][:keep_count])
    print(
        f"{row['base']:<{base_w}}  {row['remove_count']:>{remove_w}}  "
        f"{fmt_size(row['remove_bytes']):>{bytes_w}}  {kept_names}"
    )
PY

echo ""
if [[ "$APPLY_MODE" -eq 0 ]]; then
  echo "DRY RUN — no backup files deleted."
fi

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  if [[ "$APPLY_MODE" -eq 1 ]]; then
    rm -f -- "$path"
    log_fixed "Removed backup: $path"
  fi
done < <(python3 - "$report_json" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
for row in payload["results"]:
    for item in row["remove"]:
        print(item["path"])
PY
)
