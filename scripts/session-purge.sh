#!/usr/bin/env bash
# openclaw session-purge.sh — reclaim disk + trim session context bloat
# Run: bash session-purge.sh [--apply] [--agent <name>] [--age-days N] [--keep-backups N]
#
# Dry-run by default. Pass --apply to actually delete.
#
# Cleans three classes of bloat that accumulate in ~/.openclaw/agents/<id>/sessions/:
#   1. sessions.json index entries older than --age-days (default 7)
#      + orphaned cron entries (cron session IDs no longer in `openclaw cron list`)
#      + subagent entries (always ephemeral)
#   2. old sessions.json.bak* backups — keeps --keep-backups newest (default 3)
#   3. orphaned .jsonl transcripts (session ID absent from sessions.json after purge)
#      + all .jsonl.reset.* archived transcripts
#
# Always creates a fresh backup of sessions.json before mutating it.
# Never touches credentials/, agent config, or the active sessions.json entries.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

APPLY=false
AGENT=""
AGE_DAYS=7
KEEP_BACKUPS=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --agent) AGENT="$2"; shift 2 ;;
    --age-days) AGE_DAYS="$2"; shift 2 ;;
    --keep-backups) KEEP_BACKUPS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

require_tools openclaw python3 || exit 1

AGENTS_DIR="$HOME/.openclaw/agents"
[[ -d "$AGENTS_DIR" ]] || { log_error "$AGENTS_DIR not found"; exit 1; }

echo ""
echo -e "${BLD}OpenClaw Session Purge${RST}"
echo "────────────────────────────────"
if ! $APPLY; then
  echo -e "${YLW}DRY RUN${RST} — re-run with --apply to actually delete"
fi
echo "  age cutoff:    ${AGE_DAYS}d"
echo "  keep backups:  ${KEEP_BACKUPS}"
echo ""

# Fetch active cron IDs once
ACTIVE_CRONS="$(openclaw cron list --json 2>/dev/null | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin)
  items = d if isinstance(d,list) else d.get('jobs',d.get('crons',[]))
  for c in items:
    if isinstance(c,dict) and c.get('id'):
      print(c['id'])
except Exception: pass
" || echo "")"

# Collect agent dirs to process
if [[ -n "$AGENT" ]]; then
  TARGETS=("$AGENTS_DIR/$AGENT")
  [[ -d "${TARGETS[0]}" ]] || { log_error "agent dir not found: ${TARGETS[0]}"; exit 1; }
else
  TARGETS=()
  while IFS= read -r -d '' d; do
    TARGETS+=("$d")
  done < <(find "$AGENTS_DIR" -mindepth 1 -maxdepth 1 -type d -not -name "_archived" -print0)
fi

TOTAL_ENTRIES_DROPPED=0
TOTAL_BACKUPS_DROPPED=0
TOTAL_TRANSCRIPTS_DROPPED=0
TOTAL_BYTES_FREED=0

for AGENT_DIR in "${TARGETS[@]}"; do
  AGENT_NAME="$(basename "$AGENT_DIR")"
  SESSIONS_DIR="$AGENT_DIR/sessions"
  SESSIONS_JSON="$SESSIONS_DIR/sessions.json"
  [[ -f "$SESSIONS_JSON" ]] || continue

  echo -e "${BLD}── $AGENT_NAME ──${RST}"

  # ─── 1. Purge sessions.json index ────────────────────────────────────────
  PURGE_RESULT="$(APPLY="$APPLY" AGE_DAYS="$AGE_DAYS" ACTIVE_CRONS="$ACTIVE_CRONS" \
    SESSIONS_JSON="$SESSIONS_JSON" python3 <<'PY'
import json, os, time, shutil
from pathlib import Path

apply = os.environ["APPLY"] == "true"
age_days = int(os.environ["AGE_DAYS"])
active_crons = set(x for x in os.environ["ACTIVE_CRONS"].splitlines() if x.strip())
p = Path(os.environ["SESSIONS_JSON"])

d = json.loads(p.read_text())
now = time.time() * 1000
cutoff = now - (age_days * 86400000)

kept, dropped = {}, []
active_keys_kept = []
for k, v in d.items():
    if not isinstance(v, dict):
        kept[k] = v
        continue
    parts = k.split(":")
    reason = None
    if "subagent" in parts:
        reason = "subagent"
    elif "cron" in parts:
        i = parts.index("cron")
        cid = parts[i+1] if i+1 < len(parts) else None
        if cid and active_crons and cid not in active_crons:
            reason = "orphan-cron"
    if reason is None:
        u = v.get("updatedAt") or v.get("createdAt") or 0
        if u and u < cutoff:
            reason = f"age>{age_days}d"
    if reason:
        dropped.append((reason, k))
    else:
        kept[k] = v
        active_keys_kept.append(k)

# Extract active session UUIDs for transcript cleanup
active_uuids = set()
for k in active_keys_kept:
    for part in k.split(":"):
        if len(part) == 36 and part.count("-") == 4:
            active_uuids.add(part)

print(f"__DROPPED__ {len(dropped)}")
print(f"__KEPT__ {len(kept)}")
for reason, _ in dropped:
    print(f"  - {reason}")

if apply and dropped:
    ts = time.strftime("%Y%m%d-%H%M%S")
    backup = p.parent / f"sessions.json.bak-{ts}"
    shutil.copy2(p, backup)
    p.write_text(json.dumps(kept, indent=2))
    os.chmod(p, 0o600)

# Emit UUIDs for next phase
uuid_file = p.parent / ".active_uuids.tmp"
uuid_file.write_text("\n".join(sorted(active_uuids)))
PY
)"

  DROPPED="$(echo "$PURGE_RESULT" | grep '^__DROPPED__' | awk '{print $2}')"
  KEPT="$(echo "$PURGE_RESULT" | grep '^__KEPT__' | awk '{print $2}')"
  REASONS="$(echo "$PURGE_RESULT" | grep '^  - ' | sort | uniq -c || true)"
  echo "  index: $KEPT kept, $DROPPED dropped"
  [[ -n "$REASONS" ]] && echo "$REASONS" | sed 's/^/    /'
  TOTAL_ENTRIES_DROPPED=$((TOTAL_ENTRIES_DROPPED + ${DROPPED:-0}))

  # ─── 2. Old backup files ────────────────────────────────────────────────
  BACKUPS=()
  while IFS= read -r line; do BACKUPS+=("$line"); done < <(ls -t "$SESSIONS_DIR"/sessions.json.bak* 2>/dev/null || true)
  if [[ ${#BACKUPS[@]} -gt $KEEP_BACKUPS ]]; then
    TO_DELETE=("${BACKUPS[@]:$KEEP_BACKUPS}")
    BACKUP_BYTES=0
    for f in "${TO_DELETE[@]}"; do
      sz=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
      BACKUP_BYTES=$((BACKUP_BYTES + sz))
    done
    echo "  backups: ${#TO_DELETE[@]} old files ($(numfmt --to=iec --suffix=B $BACKUP_BYTES 2>/dev/null || echo ${BACKUP_BYTES}B))"
    if $APPLY; then
      for f in "${TO_DELETE[@]}"; do rm "$f"; done
    fi
    TOTAL_BACKUPS_DROPPED=$((TOTAL_BACKUPS_DROPPED + ${#TO_DELETE[@]}))
    TOTAL_BYTES_FREED=$((TOTAL_BYTES_FREED + BACKUP_BYTES))
  fi

  # ─── 3. Orphaned .jsonl transcripts + .reset.* archives ─────────────────
  UUID_FILE="$SESSIONS_DIR/.active_uuids.tmp"
  if [[ -f "$UUID_FILE" ]]; then
    TRANSCRIPT_BYTES=0
    TRANSCRIPT_COUNT=0
    # All .jsonl.reset.* are safe to delete (archived)
    while IFS= read -r -d '' f; do
      sz=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
      TRANSCRIPT_BYTES=$((TRANSCRIPT_BYTES + sz))
      TRANSCRIPT_COUNT=$((TRANSCRIPT_COUNT + 1))
      $APPLY && rm "$f"
    done < <(find "$SESSIONS_DIR" -maxdepth 1 -name "*.jsonl.reset.*" -print0 2>/dev/null)

    # Orphaned .jsonl: uuid not in active set
    while IFS= read -r -d '' f; do
      base="$(basename "$f")"
      uuid="${base%%.jsonl*}"
      if ! grep -qx "$uuid" "$UUID_FILE"; then
        sz=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
        TRANSCRIPT_BYTES=$((TRANSCRIPT_BYTES + sz))
        TRANSCRIPT_COUNT=$((TRANSCRIPT_COUNT + 1))
        $APPLY && rm "$f"
        # Also remove paired .codex-app-server.json
        paired="$SESSIONS_DIR/$base.codex-app-server.json"
        if [[ -f "$paired" ]]; then
          psz=$(stat -f%z "$paired" 2>/dev/null || stat -c%s "$paired" 2>/dev/null || echo 0)
          TRANSCRIPT_BYTES=$((TRANSCRIPT_BYTES + psz))
          TRANSCRIPT_COUNT=$((TRANSCRIPT_COUNT + 1))
          $APPLY && rm "$paired"
        fi
      fi
    done < <(find "$SESSIONS_DIR" -maxdepth 1 -name "*.jsonl" -not -name "*.reset.*" -print0 2>/dev/null)

    if [[ $TRANSCRIPT_COUNT -gt 0 ]]; then
      echo "  transcripts: $TRANSCRIPT_COUNT orphan/reset files ($(numfmt --to=iec --suffix=B $TRANSCRIPT_BYTES 2>/dev/null || echo ${TRANSCRIPT_BYTES}B))"
      TOTAL_TRANSCRIPTS_DROPPED=$((TOTAL_TRANSCRIPTS_DROPPED + TRANSCRIPT_COUNT))
      TOTAL_BYTES_FREED=$((TOTAL_BYTES_FREED + TRANSCRIPT_BYTES))
    fi
    rm -f "$UUID_FILE"
  fi
  echo ""
done

echo "════════════════════════════════"
echo -e "${BLD}Summary${RST}"
echo "════════════════════════════════"
echo "  index entries dropped: $TOTAL_ENTRIES_DROPPED"
echo "  backup files dropped:  $TOTAL_BACKUPS_DROPPED"
echo "  transcripts dropped:   $TOTAL_TRANSCRIPTS_DROPPED"
echo "  bytes freed:           $(numfmt --to=iec --suffix=B $TOTAL_BYTES_FREED 2>/dev/null || echo ${TOTAL_BYTES_FREED}B)"
if ! $APPLY; then
  echo ""
  echo -e "${YLW}DRY RUN — nothing was deleted. Re-run with --apply to execute.${RST}"
fi
