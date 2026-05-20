#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

require_tools python3 || exit 1

OPENCLAW_STATE_HOME="${OPENCLAW_STATE_HOME:-${OPENCLAW_HOST_HOME:-$HOME}}"
BOARD_FILE="${OPENCLAW_REMEDIATION_BOARD_FILE:-$OPENCLAW_STATE_HOME/.openclaw/remediation-board.json}"
REMEDIATION_ROOT="${OPENCLAW_REMEDIATION_ROOT:-$OPENCLAW_STATE_HOME/.openclaw/remediation}"
INCIDENT_STATE_FILE="${OPENCLAW_INCIDENT_STATE_FILE:-$OPENCLAW_STATE_HOME/.openclaw/logs/incidents-state.json}"
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

  import-incidents [--state-file FILE]
      Import machine incidents from incident-manager state into the remediation board.

  add ID TITLE [--source SOURCE] [--evidence TEXT] [--next TEXT]
      Add or update a manual remediation item.

  add-incident ID TITLE [--severity low|medium|high|critical] [--source SOURCE] [--evidence TEXT] [--next TEXT]
  add-hack ID TITLE [--severity low|medium|high|critical] [--source SOURCE] [--evidence TEXT] [--next TEXT]
  add-upstream-watch ID TITLE [--severity low|medium|high|critical] [--source SOURCE] [--evidence TEXT] [--next TEXT]
  add-upgrade-blocker ID TITLE [--severity low|medium|high|critical] [--source SOURCE] [--evidence TEXT] [--next TEXT]
  add-security-hardening ID TITLE [--severity low|medium|high|critical] [--source SOURCE] [--evidence TEXT] [--next TEXT]
      Add typed remediation items for recurring bugs, workarounds, upstream watches, upgrade blockers, or hardening tasks.

  observe ID --evidence TEXT [--next TEXT]
      Append a new observation/evidence item and reopen closed/deferred items.

  tried ID --step TEXT --result TEXT [--keep TEXT]
      Record a diagnostic or fix attempt.

  hypothesis ID TEXT [--confidence low|medium|high] [--next TEXT]
      Record or update an investigation hypothesis.

  workaround ID TEXT
      Set the current working workaround/rule.

  upstream ID URL
      Link an upstream issue/PR/release note.

  close-criteria ID TEXT
      Set evidence required before the item can be closed.

  link-note ID PATH
      Link an existing markdown incident/remediation note.

  export-note ID [--path PATH]
      Write a markdown incident/remediation note. Defaults to
      $OPENCLAW_REMEDIATION_ROOT/incidents/<id>.md.

  set ID STATUS [--note TEXT] [--next TEXT]
      Update status. Status: open, in-progress, fixed-awaiting-rerun,
      verified-fixed, deferred, excluded

  list [--status STATUS|all] [--type TYPE|all] [--json|--markdown]
      List tracked items. Markdown output is default.

  show ID [--json|--markdown]
      Show one tracked item.

  close ID [--note TEXT]
      Alias for: set ID verified-fixed.

Options:
  --board FILE  Override board path. Defaults to ~/.openclaw/remediation-board.json

Purpose:
  Turn surfaced ops findings into a durable repair board: smoke alarms from
  incident-manager stay machine-readable, while recurring bugs, hacks,
  upstream watches, and fixes get human-readable notes and verification state.
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
  import-cron-errors|import-incidents|add|add-incident|add-hack|add-upstream-watch|add-upgrade-blocker|add-security-hardening|set|list|show|close|observe|tried|hypothesis|workaround|upstream|close-criteria|link-note|export-note|-h|--help) ;;
  "") usage; exit 1 ;;
  *) printf 'Unknown command: %s\n' "$COMMAND" >&2; usage >&2; exit 1 ;;
esac

if [[ "$COMMAND" == "-h" || "$COMMAND" == "--help" ]]; then
  usage
  exit 0
fi

mkdir -p "$(dirname "$BOARD_FILE")" "$REMEDIATION_ROOT"

python3 - "$BOARD_FILE" "$VALID_STATUSES" "$COMMAND" "$REMEDIATION_ROOT" "$INCIDENT_STATE_FILE" "$@" <<'PY' | sanitize_sensitive
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

board_file, valid_statuses_text, command, remediation_root, incident_state_file, *args = sys.argv[1:]
valid_statuses = set(valid_statuses_text.split())
valid_types = {"manual", "incident", "hack", "upstream-watch", "cron-error", "upgrade-blocker", "security-hardening"}
valid_severities = {"low", "medium", "high", "critical"}


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json(path, default):
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON state file {path}: {exc}")


def load_board():
    data = load_json(board_file, {"version": 2, "items": {}, "updatedAt": None})
    data.setdefault("version", 2)
    data.setdefault("items", {})
    # Backward compatible migration for v1 boards.
    for item in data["items"].values():
        item.setdefault("type", "manual")
        item.setdefault("severity", "medium")
        item.setdefault("notes", [])
        item.setdefault("observations", [])
        item.setdefault("hypotheses", [])
        item.setdefault("stepsTried", [])
        item.setdefault("upstream", [])
    return data


def write_board(board):
    board["version"] = max(int(board.get("version", 1) or 1), 2)
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


def ensure_status(status):
    if status not in valid_statuses:
        raise SystemExit(f"Invalid status: {status}. Expected one of: {', '.join(sorted(valid_statuses))}")


def ensure_type(item_type):
    if item_type not in valid_types:
        raise SystemExit(f"Invalid type: {item_type}. Expected one of: {', '.join(sorted(valid_types))}")


def ensure_severity(severity):
    if severity not in valid_severities:
        raise SystemExit(f"Invalid severity: {severity}. Expected one of: {', '.join(sorted(valid_severities))}")


def slugify(value):
    value = re.sub(r"[^A-Za-z0-9._-]+", "-", value.strip()).strip("-._")
    return value.lower() or "remediation-item"



def sanitize_value(value):
    if value is None:
        return value
    text = str(value)
    patterns = [
        (re.compile(r"sk-[A-Za-z0-9-]{20,}"), "[REDACTED_API_KEY]"),
        (re.compile(r"xoxb-[0-9A-Za-z-]+"), "[REDACTED_SLACK_TOKEN]"),
        (re.compile(r"ghp_[A-Za-z0-9]{36,}"), "[REDACTED_GH_TOKEN]"),
        (re.compile(r"AKIA[0-9A-Z]{16}"), "[REDACTED_AWS_KEY]"),
        (re.compile(r"Bearer\s+[A-Za-z0-9._-]{20,}", re.IGNORECASE), "Bearer [REDACTED]"),
        (re.compile(r"(password|secret|token|api_key|apiKey|auth_token)=([^;\s]+)", re.IGNORECASE), r"\1=[REDACTED]"),
    ]
    for pattern, replacement in patterns:
        text = pattern.sub(replacement, text)
    return text

def truncate(value, limit):
    value = " ".join(str(value or "").split())
    return value if len(value) <= limit else value[: limit - 3] + "..."


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
        parts.append(truncate(message, 80))
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


def normalize_item(current):
    current.setdefault("type", "manual")
    current.setdefault("severity", "medium")
    current.setdefault("notes", [])
    current.setdefault("observations", [])
    current.setdefault("hypotheses", [])
    current.setdefault("stepsTried", [])
    current.setdefault("upstream", [])
    return current


def upsert_item(board, item_id, title, source, evidence, next_check, status=None, item_type="manual", severity="medium"):
    ensure_type(item_type)
    ensure_severity(severity)
    items = board.setdefault("items", {})
    current = items.get(item_id)
    ts = now_iso()
    if current is None:
        current = {
            "id": item_id,
            "title": sanitize_value(title),
            "type": item_type,
            "severity": severity,
            "status": status or "open",
            "source": sanitize_value(source),
            "createdAt": ts,
            "updatedAt": ts,
            "lastObservedAt": ts,
            "evidence": sanitize_value(evidence),
            "next": sanitize_value(next_check),
            "notes": [],
            "observations": [],
            "hypotheses": [],
            "stepsTried": [],
            "upstream": [],
        }
        items[item_id] = current
    else:
        normalize_item(current)
        old_status = current.get("status", "open")
        if old_status in {"verified-fixed", "deferred", "excluded"} and (status or "open") == "open":
            current["status"] = "open"
            current.setdefault("notes", []).append({"at": ts, "note": f"Reopened by new observation; previous status was {old_status}."})
        elif status:
            current["status"] = status
        current.update({
            "title": sanitize_value(title) or current.get("title"),
            "type": item_type or current.get("type", "manual"),
            "severity": severity or current.get("severity", "medium"),
            "source": sanitize_value(source) or current.get("source"),
            "updatedAt": ts,
            "lastObservedAt": ts,
            "evidence": sanitize_value(evidence) or current.get("evidence"),
            "next": sanitize_value(next_check) or current.get("next"),
        })
    if evidence:
        current.setdefault("observations", []).append({"at": ts, "evidence": sanitize_value(evidence)})
    return current


def get_item(board, item_id):
    item = board.setdefault("items", {}).get(item_id)
    if item is None:
        raise SystemExit(f"No such item: {item_id}")
    return normalize_item(item)


def render_items(items, output_format="markdown"):
    if output_format == "json":
        print(json.dumps(items, indent=2, sort_keys=True))
        return
    if not items:
        print("No remediation items found.")
        return
    for item in items:
        prefix = f"{item.get('type','manual')}/{item.get('severity','medium')}"
        print(f"- [{item.get('status','open')}] {item.get('id')} — {item.get('title','(untitled)')} ({prefix})")
        if item.get("source"):
            print(f"  source: {item['source']}")
        if item.get("evidence"):
            print(f"  evidence: {truncate(item['evidence'], 220)}")
        if item.get("currentWorkaround"):
            print(f"  workaround: {truncate(item['currentWorkaround'], 180)}")
        if item.get("next"):
            print(f"  next: {item['next']}")
        if item.get("linkedNote"):
            print(f"  note: {item['linkedNote']}")


def default_note_path(item):
    return os.path.join(remediation_root, "incidents", slugify(item.get("id", "item")) + ".md")



def md_escape_cell(value):
    text = str(value or "")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = text.replace("|", "\\|")
    text = text.replace("\n", "<br>")
    return text

def md_list(values, key):
    if not values:
        return "- (none)\n"
    lines = []
    for value in values:
        if isinstance(value, dict):
            at = value.get("at") or value.get("date") or ""
            text = value.get(key) or value.get("evidence") or value.get("note") or value.get("step") or value.get("url") or ""
            suffix = f" — {text}" if text else ""
            lines.append(f"- {at}{suffix}".rstrip())
        else:
            lines.append(f"- {value}")
    return "\n".join(lines) + "\n"


def export_note(board, item_id, path=None):
    item = get_item(board, item_id)
    path = path or item.get("linkedNote") or default_note_path(item)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    title = item.get("title") or item_id
    content = []
    content.append(f"# {title}\n")
    content.append(f"> Origin: Exported from remediation board item `{item_id}`.\n")
    content.append("## Status\n")
    content.append(f"- State: {item.get('status','open')}\n- Type: {item.get('type','manual')}\n- Severity: {item.get('severity','medium')}\n- Source: {item.get('source','')}\n- First observed: {item.get('createdAt','')}\n- Last observed: {item.get('lastObservedAt','')}\n- Current workaround: {item.get('currentWorkaround','')}\n")
    content.append("## Symptoms / Summary\n")
    content.append((item.get("evidence") or "(none)") + "\n")
    content.append("## Timeline / Observations\n")
    content.append(md_list(item.get("observations", []), "evidence"))
    content.append("## Hypotheses\n")
    if item.get("hypotheses"):
        for idx, h in enumerate(item["hypotheses"], 1):
            content.append(f"### H{idx} — {h.get('text','')}\n\n- Confidence: {h.get('confidence','')}\n- Next test: {h.get('next','')}\n")
    else:
        content.append("- (none)\n")
    content.append("## Steps Tried\n")
    if item.get("stepsTried"):
        content.append("| Date/time | Step | Result | Keep/Discard |\n|---|---|---|---|\n")
        for step in item["stepsTried"]:
            content.append(f"| {md_escape_cell(step.get('at',''))} | {md_escape_cell(step.get('step',''))} | {md_escape_cell(step.get('result',''))} | {md_escape_cell(step.get('keep',''))} |\n")
    else:
        content.append("- (none)\n")
    content.append("## Upstream Links\n")
    content.append(md_list(item.get("upstream", []), "url"))
    content.append("## Current Working Rule / Workaround\n")
    content.append((item.get("currentWorkaround") or "(none)") + "\n")
    content.append("## Next Checks\n")
    content.append((item.get("next") or "(none)") + "\n")
    content.append("## Close Criteria\n")
    content.append((item.get("closeCriteria") or "(not set)") + "\n")
    content.append("## Changelog\n")
    content.append(f"- {now_iso()}: Exported/updated from remediation board.\n")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(content).rstrip() + "\n")
    item["linkedNote"] = path
    item["updatedAt"] = now_iso()
    return item, path


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
        elif consecutive <= 0 and last_status != "error":
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
        imported.append(upsert_item(board, f"cron:{job_id}", f"Cron error: {job.get('name') or '(unnamed)'}", "cron-error-inspector", "; ".join(evidence_parts), "Fix root cause, then mark fixed-awaiting-rerun; after a clean run mark verified-fixed.", "open", "cron-error", "medium"))
    write_board(board)
    print(f"Imported {len(imported)} cron error item(s) into {board_file}.")
    render_items(imported)

elif command == "import-incidents":
    opts, rest = parse_options(args, {"--state-file"})
    if rest:
        raise SystemExit(f"Unexpected argument: {' '.join(rest)}")
    state_path = opts.get("--state-file", incident_state_file)
    state = load_json(state_path, {"incidents": {}})
    imported = []
    severity_map = {"info": "low", "warning": "medium", "critical": "critical", "error": "high"}
    for key, inc in (state.get("incidents") or {}).items():
        if not isinstance(inc, dict):
            continue
        status = inc.get("status", "firing")
        if status in {"resolved", "muted"}:
            continue
        sev = severity_map.get(str(inc.get("severity", "warning")), str(inc.get("severity", "medium")))
        if sev not in valid_severities:
            sev = "medium"
        evidence = inc.get("summary") or inc.get("message") or json.dumps(inc.get("lastEvidence", {}), sort_keys=True)
        next_check = "Review machine incident evidence, decide whether to fix, defer, or export an incident note."
        imported.append(upsert_item(board, f"incident:{key}", f"Machine incident: {key}", "incident-manager", evidence, next_check, "open", "incident", sev))
    write_board(board)
    print(f"Imported {len(imported)} machine incident item(s) into {board_file}.")
    render_items(imported)

elif command in {"add", "add-incident", "add-hack", "add-upstream-watch", "add-upgrade-blocker", "add-security-hardening"}:
    opts, rest = parse_options(args, {"--source", "--evidence", "--next", "--severity"})
    if len(rest) < 2:
        raise SystemExit(f"Usage: {command} ID TITLE [--source SOURCE] [--evidence TEXT] [--next TEXT]")
    type_for_command = {"add": "manual", "add-incident": "incident", "add-hack": "hack", "add-upstream-watch": "upstream-watch", "add-upgrade-blocker": "upgrade-blocker", "add-security-hardening": "security-hardening"}[command]
    item_id = rest[0]
    title = " ".join(rest[1:])
    item = upsert_item(board, item_id, title, opts.get("--source", "manual"), opts.get("--evidence", ""), opts.get("--next", ""), "open", type_for_command, opts.get("--severity", "medium"))
    write_board(board)
    render_items([item])

elif command in {"set", "close"}:
    opts, rest = parse_options(args, {"--note", "--next"})
    if command == "close":
        if len(rest) != 1:
            raise SystemExit("Usage: close ID [--note TEXT]")
        item_id, status = rest[0], "verified-fixed"
    else:
        if len(rest) != 2:
            raise SystemExit("Usage: set ID STATUS [--note TEXT] [--next TEXT]")
        item_id, status = rest
        ensure_status(status)
    item = get_item(board, item_id)
    ts = now_iso()
    item["status"] = status
    item["updatedAt"] = ts
    if "--next" in opts:
        item["next"] = sanitize_value(opts["--next"])
    if "--note" in opts:
        item.setdefault("notes", []).append({"at": ts, "note": sanitize_value(opts["--note"])})
    write_board(board)
    render_items([item])

elif command == "observe":
    opts, rest = parse_options(args, {"--evidence", "--next"})
    if len(rest) != 1 or "--evidence" not in opts:
        raise SystemExit("Usage: observe ID --evidence TEXT [--next TEXT]")
    item = get_item(board, rest[0])
    old_status = item.get("status", "open")
    ts = now_iso()
    if old_status in {"verified-fixed", "deferred", "excluded"}:
        item["status"] = "open"
        item.setdefault("notes", []).append({"at": ts, "note": f"Reopened by new observation; previous status was {old_status}."})
    item["lastObservedAt"] = ts
    item["updatedAt"] = ts
    item["evidence"] = sanitize_value(opts["--evidence"])
    item.setdefault("observations", []).append({"at": ts, "evidence": sanitize_value(opts["--evidence"])})
    if "--next" in opts:
        item["next"] = sanitize_value(opts["--next"])
    write_board(board)
    render_items([item])

elif command == "tried":
    opts, rest = parse_options(args, {"--step", "--result", "--keep"})
    if len(rest) != 1 or "--step" not in opts or "--result" not in opts:
        raise SystemExit("Usage: tried ID --step TEXT --result TEXT [--keep TEXT]")
    item = get_item(board, rest[0])
    item.setdefault("stepsTried", []).append({"at": now_iso(), "step": sanitize_value(opts["--step"]), "result": sanitize_value(opts["--result"]), "keep": sanitize_value(opts.get("--keep", ""))})
    item["updatedAt"] = now_iso()
    write_board(board)
    render_items([item])

elif command == "hypothesis":
    opts, rest = parse_options(args, {"--confidence", "--next"})
    if len(rest) < 2:
        raise SystemExit("Usage: hypothesis ID TEXT [--confidence low|medium|high] [--next TEXT]")
    confidence = opts.get("--confidence", "medium")
    if confidence not in {"low", "medium", "high"}:
        raise SystemExit("Invalid confidence: expected low, medium, or high")
    item = get_item(board, rest[0])
    item.setdefault("hypotheses", []).append({"at": now_iso(), "text": sanitize_value(" ".join(rest[1:])), "confidence": confidence, "next": sanitize_value(opts.get("--next", ""))})
    if "--next" in opts:
        item["next"] = sanitize_value(opts["--next"])
    item["updatedAt"] = now_iso()
    write_board(board)
    render_items([item])

elif command in {"workaround", "close-criteria"}:
    if len(args) < 2:
        raise SystemExit(f"Usage: {command} ID TEXT")
    item = get_item(board, args[0])
    key = "currentWorkaround" if command == "workaround" else "closeCriteria"
    item[key] = sanitize_value(" ".join(args[1:]))
    item["updatedAt"] = now_iso()
    write_board(board)
    render_items([item])

elif command == "upstream":
    if len(args) != 2:
        raise SystemExit("Usage: upstream ID URL")
    item = get_item(board, args[0])
    entry = {"at": now_iso(), "url": sanitize_value(args[1])}
    if entry["url"] not in [u.get("url") for u in item.get("upstream", []) if isinstance(u, dict)]:
        item.setdefault("upstream", []).append(entry)
    item["updatedAt"] = now_iso()
    write_board(board)
    render_items([item])

elif command == "link-note":
    if len(args) != 2:
        raise SystemExit("Usage: link-note ID PATH")
    item = get_item(board, args[0])
    item["linkedNote"] = sanitize_value(args[1])
    item["updatedAt"] = now_iso()
    write_board(board)
    render_items([item])

elif command == "export-note":
    opts, rest = parse_options(args, {"--path"})
    if len(rest) != 1:
        raise SystemExit("Usage: export-note ID [--path PATH]")
    item, path = export_note(board, rest[0], sanitize_value(opts.get("--path")) if opts.get("--path") else None)
    write_board(board)
    print(f"Wrote incident note: {path}")
    render_items([item])

elif command == "list":
    format_tokens = [token for token in args if token in {"--json", "--markdown"}]
    option_args = [token for token in args if token not in {"--json", "--markdown"}]
    opts, rest = parse_options(option_args, {"--status", "--type"})
    output_format = "markdown"
    cleaned = []
    for token in format_tokens:
        if token == "--json":
            output_format = "json"
        elif token == "--markdown":
            output_format = "markdown"
        else:
            cleaned.append(token)
    if cleaned:
        raise SystemExit(f"Unexpected argument: {' '.join(cleaned)}")
    status_filter = opts.get("--status", "all")
    type_filter = opts.get("--type", "all")
    if status_filter != "all":
        ensure_status(status_filter)
    if type_filter != "all":
        ensure_type(type_filter)
    items = [normalize_item(item) for item in board.get("items", {}).values()]
    items = sorted(items, key=lambda i: (i.get("status", ""), i.get("type", ""), i.get("id", "")))
    if status_filter != "all":
        items = [item for item in items if item.get("status") == status_filter]
    if type_filter != "all":
        items = [item for item in items if item.get("type") == type_filter]
    render_items(items, output_format)

elif command == "show":
    output_format = "markdown"
    cleaned = []
    for token in args:
        if token == "--json":
            output_format = "json"
        elif token == "--markdown":
            output_format = "markdown"
        else:
            cleaned.append(token)
    if len(cleaned) != 1:
        raise SystemExit("Usage: show ID [--json|--markdown]")
    render_items([get_item(board, cleaned[0])], output_format)
PY
