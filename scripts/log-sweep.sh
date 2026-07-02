#!/usr/bin/env bash
set -euo pipefail

# Sweep every active OpenClaw log surface, not just gateway.err.log.
# Usage:
#   bash scripts/log-sweep.sh 'afterTurn: ingest failed|ALL PROVIDERS EXHAUSTED'
#   bash scripts/log-sweep.sh --literal 'ALL PROVIDERS EXHAUSTED: 1 candidate tried'

MODE="regex"
if [[ "${1:-}" == "--literal" ]]; then
  MODE="literal"
  shift
fi

PATTERN="${1:-}"
if [[ -z "$PATTERN" ]]; then
  PATTERN='afterTurn: ingest failed|skipping compaction|ALL PROVIDERS EXHAUSTED|runtime\.llm\.complete is unavailable|refused replay-like message batch|bootstrap checkpoint refresh failed|empty normalized summary|all extraction attempts exhausted|provider error response|FailoverError|LLM request timed out|stuck session|codex app-server|Embedded agent failed before reply|secrets\.resolve failed|liveness warning|FATAL ERROR|heap out of memory|ENOSPC|ENOENT'
fi

FILES=()
while IFS= read -r file; do
  FILES+=("$file")
done < <(
  {
    printf '%s\n' \
      "$HOME/.openclaw/logs/gateway.err.log" \
      "$HOME/.openclaw/logs/gateway.log" \
      "$HOME/.openclaw/logs/watchdog.log" \
      "$HOME/.openclaw/logs/bluebubbles-watchdog.log"
    find /tmp/openclaw /private/tmp/openclaw -maxdepth 1 -type f -name 'openclaw-*.log' 2>/dev/null || true
  } | awk 'NF && !seen[$0]++'
)

printf '## OpenClaw log sweep\n'
printf 'pattern_mode=%s\n' "$MODE"
printf 'pattern=%s\n' "$PATTERN"
printf 'files_checked=%s\n\n' "${#FILES[@]}"

found=0
for file in "${FILES[@]}"; do
  [[ -r "$file" ]] || continue
  if [[ "$MODE" == "literal" ]]; then
    matches=$(grep -F -n -- "$PATTERN" "$file" 2>/dev/null | tail -40 || true)
  else
    matches=$(grep -E -i -n -- "$PATTERN" "$file" 2>/dev/null | tail -40 || true)
  fi
  if [[ -n "$matches" ]]; then
    found=1
    printf -- '--- %s ---\n' "$file"
    printf '%s\n\n' "$matches"
  fi
done

if [[ "$found" -eq 0 ]]; then
  printf 'No matching log lines found.\n'
fi
