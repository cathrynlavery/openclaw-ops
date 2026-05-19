#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

require_tools python3 || exit 1

OPENCLAW_STATE_HOME="${OPENCLAW_STATE_HOME:-${OPENCLAW_HOST_HOME:-$HOME}}"
BOARD_FILE="${OPENCLAW_REMEDIATION_BOARD_FILE:-$OPENCLAW_STATE_HOME/.openclaw/remediation-board.json}"
COMMAND="${1:-}"
if [[ $# -gt 0 ]]; then
  shift
fi

usage() {
  cat <<'USAGE'
Usage: scripts/remediation-board.sh <command> [options]

Commands:
  import-cron-errors [--agent NAME] [--consecutive N]
      Import current `openclaw cron list --all --json` failures as tracked items.

  add ID TITLE [--source SOURCE] [--evidence TEXT] [--next TEXT]
      Add or update a manual remediation item.

  set ID STATUS [--note TEXT] [--next TEXT]
      Update item status. Status must be one of:
      open, in-progress, fixed-awaiting-rerun, verified-fixed, deferred, excluded

  list [--status STATUS|all] [--json|--markdown]
      List tracked items. Markdown output is default.

  show ID [--json|--markdown]
      Show one tracked item.

  close ID [--note TEXT]
      Alias for: set ID verified-fixed.

Options:
  --board FILE  Override board path. Defaults to ~/.openclaw/remediation-board.json

Purpose:
  Turn surfaced ops findings into a durable queue: open -> fixed-awaiting-rerun
  -> verified-fixed/deferred/excluded, with evidence, notes, and next checks.
USAGE
}

VALID_STATUSES="open in-progress fixed-awaiting-rerun verified-fixed deferred excluded"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --board)
      BOARD_FILE="${2:-}"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

case "$COMMAND" in
  import-cron-errors|add|set|list|show|close|-h|--help) ;;
  "") usage; exit 1 ;;
  *) printf 'Unknown command: %s\n' "$COMMAND" >&2; usage >&2; exit 1 ;;
esac

if [[ "$COMMAND" == "-h" || "$COMMAND" == "--help" ]]; then
  usage
  exit 0
fi

mkdir -p "$(dirname "$BOARD_FILE")"

python_board() {
  python3 - "$BOARD_FILE" "$VALID_STATUSES" "$COMMAND" "$@" <<'PY'
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

board_file, valid_statuses_text, command, *args = sys.argv[1:]
valid_statuses = set(valid_statuses_text.split())


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_board():
    if not os.path.exists(board_file):
        return {"version": 1, "items": {}, "updatedAt": None}
    with open(board_file, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    data.setdefault("version", 1)
    data.setdefault("items", {})
    return data


def write_board(board):
    board["updatedAt"] = now_iso()
    directory = os.path.dirname(board_file) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".remediation-board.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(board, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, board_file)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def parse_options(tokens, allowed):
    opts = {}
    rest = []
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token in allowed:
            if i + 1 >= len(tokens):
                raise SystemExit(f"Missing value for {token}")
            opts[token] = tokens[i + 1]
            i += 2
        elif token.startswith("--"):
            raise SystemExit(f"Unknown option: {token}")
        else:
            rest.append(token)
            i += 1
    return opts, rest


def summarize_payload(payload):
    if not isinstance(payload, dict):
        return ""
    parts = []
    for key in ("kind", "model", "thinking"):
        if payload.get(key):
            parts.append(f"{key}={payload[key]}")
    if "lightContext" in payload:
        parts.append(f"lightContext={payload['lightContext']}")
    message = payload.get("message") or payload.get("text") or ""
    if message:
        message = " ".join(str(message).split())
        if len(message) > 80:
            message = message[:77] + "..."
        parts.append(message)
    return " | ".join(parts)


def schedule_text(schedule):
    if not isinstance(schedule, dict):
        return "unknown"
    kind = schedule.get("kind") or "unknown"
    if kind == "cron":
        expr = schedule.get("expr", "?")
        tz = schedule.get("tz")
        return f"{expr} ({tz})" if tz else expr
    if kind == "every":
        return f"every {schedule.get('everyMs') or schedule.get('every') or 'unknown'}"
    if kind == "at":
        return str(schedule.get("at") or schedule.get("when") or "unknown")
    return kind


def upsert_item(board, item_id, title, source, evidence, next_check, status=None):
    items = board.setdefault("items", {})
    current = items.get(item_id)
    ts = now_iso()
    if current is None:
        current = {
            "id": item_id,
            "title": title,
            "status": status or "open",
            "source": source,
            "createdAt": ts,
            "updatedAt": ts,
            "lastObservedAt": ts,
            "evidence": evidence,
            "next": next_check,
            "notes": [],
            "observations": [],
        }
        items[item_id] = current
    else:
        old_status = current.get("status", "open")
        if old_status in {"verified-fixed", "deferred", "excluded"} and (status or "open") == "open":
            current["status"] = "open"
            current.setdefault("notes", []).append({
                "at": ts,
                "note": f"Reopened by new observation; previous status was {old_status}.",
            })
        elif status:
            current["status"] = status
        current.update({
            "title": title or current.get("title"),
            "source": source or current.get("source"),
            "updatedAt": ts,
            "lastObservedAt": ts,
            "evidence": evidence or current.get("evidence"),
            "next": next_check or current.get("next"),
        })
    current.setdefault("observations", []).append({"at": ts, "evidence": evidence})
    return current


def ensure_status(status):
    if status not in valid_statuses:
        raise SystemExit(f"Invalid status: {status}. Expected one of: {', '.join(sorted(valid_statuses))}")


def render_items(items, output_format="markdown"):
    if output_format == "json":
        print(json.dumps(items, indent=2, sort_keys=True))
        return
    if not items:
        print("No remediation items found.")
        return
    for item in items:
        print(f"- [{item.get('status','open')}] {item.get('id')} — {item.get('title','(untitled)')}")
        if item.get("source"):
            print(f"  source: {item['source']}")
        if item.get("evidence"):
            evidence = " ".join(str(item["evidence"]).split())
            if len(evidence) > 220:
                evidence = evidence[:217] + "..."
            print(f"  evidence: {evidence}")
        if item.get("next"):
            print(f"  next: {item['next']}")


board = load_board()

if command == "import-cron-errors":
    opts, rest = parse_options(args, {"--agent", "--consecutive"})
    if rest:
        raise SystemExit(f"Unexpected argument: {' '.join(rest)}")
    agent_filter = opts.get("--agent", "")
    consecutive_filter = int(opts.get("--consecutive", "1"))
    result = subprocess.run(["openclaw", "cron", "list", "--all", "--json"], text=True, capture_output=True)
    if result.returncode != 0:
        raise SystemExit("Failed to load cron jobs from openclaw")
    raw = json.loads(result.stdout or "{}")
    jobs = raw if isinstance(raw, list) else raw.get("jobs", raw.get("crons", []))
    imported = []
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
        job_id = job.get("id") or job.get("jobId")
        if not job_id:
            continue
        payload = job.get("payload") or {}
        evidence_parts = [
            f"agent={agent}",
            f"schedule={schedule_text(job.get('schedule'))}",
            f"consecutiveErrors={consecutive}",
            f"lastErrorReason={state.get('lastErrorReason') or '(none)'}",
            f"lastError={state.get('lastError') or '(none)'}",
        ]
        preview = summarize_payload(payload)
        if preview:
            evidence_parts.append(f"payload={preview}")
        item = upsert_item(
            board,
            f"cron:{job_id}",
            f"Cron error: {job.get('name') or '(unnamed)'}",
            "cron-error-inspector",
            "; ".join(evidence_parts),
            "Fix root cause, then mark fixed-awaiting-rerun; after a clean run mark verified-fixed.",
            "open",
        )
        imported.append(item)
    write_board(board)
    print(f"Imported {len(imported)} cron error item(s) into {board_file}.")
    render_items(imported)

elif command == "add":
    opts, rest = parse_options(args, {"--source", "--evidence", "--next"})
    if len(rest) < 2:
        raise SystemExit("Usage: add ID TITLE [--source SOURCE] [--evidence TEXT] [--next TEXT]")
    item_id = rest[0]
    title = " ".join(rest[1:])
    item = upsert_item(board, item_id, title, opts.get("--source", "manual"), opts.get("--evidence", ""), opts.get("--next", ""), "open")
    write_board(board)
    render_items([item])

elif command in {"set", "close"}:
    opts, rest = parse_options(args, {"--note", "--next"})
    if command == "close":
        if len(rest) != 1:
            raise SystemExit("Usage: close ID [--note TEXT]")
        item_id = rest[0]
        status = "verified-fixed"
    else:
        if len(rest) != 2:
            raise SystemExit("Usage: set ID STATUS [--note TEXT] [--next TEXT]")
        item_id, status = rest
        ensure_status(status)
    item = board.setdefault("items", {}).get(item_id)
    if item is None:
        raise SystemExit(f"No such item: {item_id}")
    ts = now_iso()
    item["status"] = status
    item["updatedAt"] = ts
    if "--next" in opts:
        item["next"] = opts["--next"]
    if "--note" in opts:
        item.setdefault("notes", []).append({"at": ts, "note": opts["--note"]})
    write_board(board)
    render_items([item])

elif command == "list":
    opts, rest = parse_options(args, {"--status"})
    output_format = "markdown"
    cleaned = []
    for token in rest:
        if token == "--json":
            output_format = "json"
        elif token == "--markdown":
            output_format = "markdown"
        else:
            cleaned.append(token)
    if cleaned:
        raise SystemExit(f"Unexpected argument: {' '.join(cleaned)}")
    status_filter = opts.get("--status", "all")
    if status_filter != "all":
        ensure_status(status_filter)
    items = sorted(board.get("items", {}).values(), key=lambda i: (i.get("status", ""), i.get("id", "")))
    if status_filter != "all":
        items = [item for item in items if item.get("status") == status_filter]
    render_items(items, output_format)

elif command == "show":
    opts, rest = parse_options(args, set())
    output_format = "markdown"
    cleaned = []
    for token in rest:
        if token == "--json":
            output_format = "json"
        elif token == "--markdown":
            output_format = "markdown"
        else:
            cleaned.append(token)
    if len(cleaned) != 1:
        raise SystemExit("Usage: show ID [--json|--markdown]")
    item = board.get("items", {}).get(cleaned[0])
    if item is None:
        raise SystemExit(f"No such item: {cleaned[0]}")
    render_items([item], output_format)
PY
}

python_board "$@"
