#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

require_tools python3 || exit 1

OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
AGENT_FILTER=""
THRESHOLD_TOKENS=10000
OUTPUT_JSON=0

usage() {
  cat <<'USAGE'
Usage: scripts/context-audit.sh [--agent NAME] [--threshold-tokens N] [--json]

Scans AGENTS.md, MEMORY.md, and SOUL*.md under ~/.openclaw, estimates tokens as chars/4,
filters to files at or above the threshold, and sorts largest-first.

Read-only. This audits file bloat only; runtime truncation belongs to prompt-truncation-report.sh.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)
      AGENT_FILTER="${2:-}"
      shift 2
      ;;
    --threshold-tokens)
      THRESHOLD_TOKENS="${2:-10000}"
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

case "$THRESHOLD_TOKENS" in
  ''|*[!0-9]*)
    printf 'Invalid threshold-tokens value: %s\n' "$THRESHOLD_TOKENS" >&2
    usage >&2
    exit 1
    ;;
esac

if [[ ! -d "$OPENCLAW_DIR" ]]; then
  if [[ "$OUTPUT_JSON" -eq 1 ]]; then
    printf '{"threshold_tokens":%s,"results":[]}\n' "$THRESHOLD_TOKENS"
  else
    log_warn "No OpenClaw directory found at $OPENCLAW_DIR"
  fi
  exit 0
fi

python3 - "$OPENCLAW_DIR" "$AGENT_FILTER" "$THRESHOLD_TOKENS" "$OUTPUT_JSON" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def matches_agent(path: Path, agent_filter: str) -> bool:
    if not agent_filter:
        return True

    parts = path.parts
    for idx, part in enumerate(parts):
        if part == "agents" and idx + 1 < len(parts) and parts[idx + 1] == agent_filter:
            return True
        if part == f"workspace-{agent_filter}":
            return True
    return False


def iso_mtime(epoch_seconds: float) -> str:
    return datetime.fromtimestamp(epoch_seconds, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


root = Path(sys.argv[1]).expanduser()
agent_filter = sys.argv[2]
threshold_tokens = int(sys.argv[3])
output_json = sys.argv[4] == "1"

results = []
for path in root.rglob("*"):
    if not path.is_file():
        continue
    if "_archived" in path.parts:
        continue
    if path.name == "AGENTS.md" or path.name == "MEMORY.md" or path.name.startswith("SOUL") and path.suffix == ".md":
        if not matches_agent(path, agent_filter):
            continue
        try:
            content = path.read_text(encoding="utf-8", errors="replace")
            stat = path.stat()
        except (FileNotFoundError, OSError):
            continue

        chars = len(content)
        token_estimate = chars // 4
        if token_estimate < threshold_tokens:
            continue

        results.append(
            {
                "path": str(path),
                "token_estimate": token_estimate,
                "chars": chars,
                "mtime": iso_mtime(stat.st_mtime),
            }
        )

results.sort(key=lambda item: (-item["token_estimate"], item["path"]))

payload = {
    "threshold_tokens": threshold_tokens,
    "results": results,
}

if output_json:
    print(json.dumps(payload, indent=2, sort_keys=True))
    raise SystemExit(0)

if not results:
    target = f" for agent {agent_filter}" if agent_filter else ""
    print(f"No context files at or above {threshold_tokens} tokens found{target}.")
    raise SystemExit(0)

path_w = max(len("path"), *(len(item["path"]) for item in results))
token_w = max(len("tokens"), *(len(str(item["token_estimate"])) for item in results))
mtime_w = max(len("mtime"), *(len(item["mtime"]) for item in results))

header = f"{'path':<{path_w}}  {'tokens':>{token_w}}  {'mtime':<{mtime_w}}"
print(header)
print("-" * len(header))
for item in results:
    print(f"{item['path']:<{path_w}}  {item['token_estimate']:>{token_w}}  {item['mtime']:<{mtime_w}}")
PY
