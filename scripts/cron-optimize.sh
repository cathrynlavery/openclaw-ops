#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

require_tools openclaw python3 || exit 1

AGENT_FILTER=""
APPLY_FIX=0
THINKING_LEVEL="low"

usage() {
  cat <<'USAGE'
Usage: scripts/cron-optimize.sh [--fix] [--level off|minimal|low|medium|high|xhigh] [--agent NAME]

Reports agent cron jobs missing --light-context.

Exit codes:
  0 = all listed agent cron jobs already optimized, or --fix resolved all missing jobs
  1 = one or more listed agent cron jobs still need optimization
  2 = script or CLI error
USAGE
}

validate_level() {
  case "$1" in
    off|minimal|low|medium|high|xhigh) return 0 ;;
    *) return 1 ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix)
      APPLY_FIX=1
      shift
      ;;
    --level)
      THINKING_LEVEL="${2:-}"
      shift 2
      ;;
    --agent)
      AGENT_FILTER="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      printf 'Unexpected argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! validate_level "$THINKING_LEVEL"; then
  printf 'Invalid thinking level: %s\n' "$THINKING_LEVEL" >&2
  usage >&2
  exit 2
fi

load_report() {
  local cron_tmp
  cron_tmp="$(mktemp)"
  if ! openclaw cron list --all --json >"$cron_tmp" 2>/dev/null; then
    rm -f "$cron_tmp"
    return 1
  fi

  python3 - "$AGENT_FILTER" "$cron_tmp" <<'PY'
import json
import sys


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


with open(sys.argv[2], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
jobs = payload if isinstance(payload, list) else payload.get("jobs", payload.get("crons", []))
agent_filter = sys.argv[1]
rows = []

for job in jobs:
    if not isinstance(job, dict):
        continue
    payload = job.get("payload") or {}
    if payload.get("kind") != "agentTurn":
        continue

    agent = job.get("agentId") or "unknown"
    if agent_filter and agent != agent_filter:
        continue

    light_context = bool(payload.get("lightContext"))
    thinking = payload.get("thinking")
    rows.append(
        {
            "agent": agent,
            "id": job.get("id") or "",
            "name": job.get("name") or "(unnamed)",
            "schedule": schedule_text(job.get("schedule")),
            "light_context": light_context,
            "thinking": thinking,
        }
    )

rows.sort(key=lambda item: (item["agent"], item["name"], item["id"]))
report = {
    "rows": rows,
    "missing": [row for row in rows if not row["light_context"]],
}
print(json.dumps(report, sort_keys=True))
PY
  local status=$?
  rm -f "$cron_tmp"
  return $status
}

print_report() {
  local report_json="$1"
  python3 - "$report_json" <<'PY'
import json
import sys

report = json.loads(sys.argv[1])
rows = report["rows"]
missing = report["missing"]

if not rows:
    print("No agent cron jobs found.")
    raise SystemExit(0)

agent_w = max(len("agent"), *(len(row["agent"]) for row in rows))
id_w = max(len("cron id"), *(len(row["id"]) for row in rows))
name_w = max(len("name"), *(len(row["name"]) for row in rows))
schedule_w = max(len("schedule"), *(len(row["schedule"]) for row in rows))

header = (
    f"{'agent':<{agent_w}}  {'cron id':<{id_w}}  {'name':<{name_w}}  "
    f"{'schedule':<{schedule_w}}  lightContext"
)
print(header)
print("-" * len(header))
for row in rows:
    flag = "yes" if row["light_context"] else "no"
    print(
        f"{row['agent']:<{agent_w}}  {row['id']:<{id_w}}  {row['name']:<{name_w}}  "
        f"{row['schedule']:<{schedule_w}}  {flag}"
    )

if missing:
    print("")
    print(f"Optimizations available: {len(missing)} of {len(rows)} agent cron jobs are missing --light-context.")
else:
    print("")
    print(f"All {len(rows)} listed agent cron jobs already use --light-context.")
PY
}

report_json="$(load_report)" || {
  log_error "Failed to load cron jobs from openclaw"
  exit 2
}

print_report "$report_json"

missing_count="$(python3 - "$report_json" <<'PY'
import json, sys
print(len(json.loads(sys.argv[1])["missing"]))
PY
)"

if [[ "$APPLY_FIX" -eq 1 && "$missing_count" -gt 0 ]]; then
  echo ""
  echo -e "${BLD}Applying fixes${RST}"

  failed=0
  while IFS=$'\t' read -r job_id needs_thinking; do
    [[ -n "$job_id" ]] || continue
    cmd=(openclaw cron edit "$job_id" --light-context)
    if [[ "$needs_thinking" == "1" ]]; then
      cmd+=(--thinking "$THINKING_LEVEL")
    fi
    if "${cmd[@]}"; then
      log_fixed "Cron optimized: $job_id"
    else
      failed=$((failed + 1))
      log_broken "Failed to optimize cron: $job_id"
    fi
  done < <(python3 - "$report_json" <<'PY'
import json
import sys

report = json.loads(sys.argv[1])
for row in report["missing"]:
    needs_thinking = "1" if not row.get("thinking") else "0"
    print(f"{row['id']}\t{needs_thinking}")
PY
)

  echo ""
  refreshed_report="$(load_report)" || {
    log_error "Failed to reload cron jobs after applying fixes"
    exit 2
  }
  print_report "$refreshed_report"

  remaining_missing="$(python3 - "$refreshed_report" <<'PY'
import json, sys
print(len(json.loads(sys.argv[1])["missing"]))
PY
)"

  if [[ "$remaining_missing" -eq 0 ]]; then
    exit 0
  fi
  exit 1
fi

if [[ "$missing_count" -gt 0 ]]; then
  exit 1
fi

exit 0
