#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

require_tools python3 || exit 1

INCIDENT_STATE_FILE="${OPENCLAW_INCIDENT_STATE_FILE:-$HOME/.openclaw/logs/incidents-state.json}"
AGENTS_DIR="${OPENCLAW_AGENTS_DIR:-$HOME/.openclaw/agents}"
WATCHDOG_LOG="${OPENCLAW_WATCHDOG_LOG:-$HOME/.openclaw/logs/watchdog.log}"
OUTPUT_HTML=0
SEND_NOTIFY=0
HOURS=24

usage() {
  cat <<'USAGE'
Usage: scripts/daily-digest.sh [--html] [--notify] [--hours N]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --html)
      OUTPUT_HTML=1
      shift
      ;;
    --notify)
      SEND_NOTIFY=1
      shift
      ;;
    --hours)
      HOURS="${2:-24}"
      shift 2
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

digest="$(
  python3 - "$INCIDENT_STATE_FILE" "$AGENTS_DIR" "$WATCHDOG_LOG" "$HOURS" "$OUTPUT_HTML" <<'PY'
import html
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone

incident_state_file = sys.argv[1]
agents_dir = sys.argv[2]
watchdog_log = sys.argv[3]
hours = int(sys.argv[4])
output_html = sys.argv[5] == "1"
cutoff_epoch = int(datetime.now(timezone.utc).timestamp()) - (hours * 3600)


def parse_epoch(value):
    if not value:
        return 0
    for candidate in (
        ("%Y-%m-%dT%H:%M:%SZ", value),
        ("%Y-%m-%d %H:%M:%S", value),
    ):
        try:
            return int(datetime.strptime(candidate[1], candidate[0]).replace(tzinfo=timezone.utc).timestamp())
        except ValueError:
            continue
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except Exception:
        return 0


def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return default


def active_incidents():
    state = load_json(incident_state_file, {})
    incidents = state.get("incidents", {})
    if isinstance(incidents, dict):
        return list(incidents.values())
    if isinstance(incidents, list):
        return incidents
    return []


def render_text(incident_summary, agent_rows, watchdog_rows, cost_rows):
    lines = [
        "Incident Summary",
        f"- Open incidents: {incident_summary['open_count']}",
        f"- Resolved in window: {incident_summary['resolved_count']}",
        f"- Needs human action: {incident_summary['needs_human']}",
    ]
    if incident_summary["open_titles"]:
        lines.extend(f"- {title}" for title in incident_summary["open_titles"])

    lines.append("")
    lines.append("Agent Activity")
    if agent_rows:
        lines.extend(
            f"- {row['agent']}: messages={row['messages']} tool_calls={row['tool_calls']} errors={row['errors']}"
            for row in agent_rows
        )
    else:
        lines.append("- No recent agent activity")

    lines.append("")
    lines.append("Watchdog Events")
    if watchdog_rows:
        lines.extend(f"- {row}" for row in watchdog_rows)
    else:
        lines.append("- No watchdog events in window")

    lines.append("")
    lines.append("Cost Summary")
    if cost_rows:
        lines.extend(f"- {agent}: ${cost:.4f}" for agent, cost in cost_rows)
    else:
        lines.append("- No recorded usage cost in window")

    return "\n".join(lines)


def render_html(incident_summary, agent_rows, watchdog_rows, cost_rows):
    def lis(items):
        return "".join(f"<li>{html.escape(item)}</li>" for item in items)

    incident_items = [
        f"Open incidents: {incident_summary['open_count']}",
        f"Resolved in window: {incident_summary['resolved_count']}",
        f"Needs human action: {incident_summary['needs_human']}",
    ] + incident_summary["open_titles"]

    agent_items = (
        [
            f"{row['agent']}: messages={row['messages']} tool_calls={row['tool_calls']} errors={row['errors']}"
            for row in agent_rows
        ]
        or ["No recent agent activity"]
    )
    watchdog_items = watchdog_rows or ["No watchdog events in window"]
    cost_items = [f"{agent}: ${cost:.4f}" for agent, cost in cost_rows] or ["No recorded usage cost in window"]

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>OpenClaw Daily Digest</title>
  <style>
    :root {{
      color-scheme: light;
      --bg: #f6f0e8;
      --card: #fffaf5;
      --ink: #1f1f1a;
      --accent: #8b4513;
      --muted: #6d665d;
      --line: #dcccb8;
    }}
    body {{
      margin: 0;
      padding: 32px;
      font-family: Georgia, "Times New Roman", serif;
      background: linear-gradient(180deg, #f6f0e8 0%, #efe3d4 100%);
      color: var(--ink);
    }}
    main {{
      max-width: 900px;
      margin: 0 auto;
      display: grid;
      gap: 20px;
    }}
    section {{
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 18px;
      padding: 22px 24px;
      box-shadow: 0 12px 32px rgba(72, 42, 20, 0.08);
    }}
    h1 {{
      margin: 0;
      font-size: 34px;
      color: var(--accent);
    }}
    h2 {{
      margin: 0 0 12px;
      font-size: 21px;
    }}
    p {{
      margin: 4px 0 0;
      color: var(--muted);
    }}
    ul {{
      margin: 0;
      padding-left: 20px;
    }}
    li {{
      margin: 6px 0;
    }}
  </style>
</head>
<body>
  <main>
    <section>
      <h1>OpenClaw Daily Digest</h1>
      <p>Window: last {hours} hours</p>
    </section>
    <section>
      <h2>Incident Summary</h2>
      <ul>{lis(incident_items)}</ul>
    </section>
    <section>
      <h2>Agent Activity</h2>
      <ul>{lis(agent_items)}</ul>
    </section>
    <section>
      <h2>Watchdog Events</h2>
      <ul>{lis(watchdog_items)}</ul>
    </section>
    <section>
      <h2>Cost Summary</h2>
      <ul>{lis(cost_items)}</ul>
    </section>
  </main>
</body>
</html>"""


incidents = active_incidents()
open_incidents = [item for item in incidents if item.get("status") in {"firing", "acknowledged", "muted"}]
resolved_incidents = [
    item
    for item in incidents
    if item.get("status") == "resolved" and parse_epoch(item.get("resolvedAt")) >= cutoff_epoch
]
needs_human = [
    item
    for item in open_incidents
    if item.get("severity") == "critical" and parse_epoch(item.get("openedAt")) <= cutoff_epoch + max(0, hours - 1) * 3600
]
incident_summary = {
    "open_count": len(open_incidents),
    "resolved_count": len(resolved_incidents),
    "needs_human": len(needs_human),
    "open_titles": [item.get("title", item.get("dedupeKey", "unknown incident")) for item in open_incidents[:5]],
}

agent_activity = defaultdict(lambda: {"messages": 0, "tool_calls": 0, "errors": 0})
agent_costs = defaultdict(float)
for root, _, files in os.walk(agents_dir):
    for name in files:
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(root, name)
        agent = "unknown"
        parts = path.split(os.sep)
        if "agents" in parts:
            idx = parts.index("agents")
            if idx + 1 < len(parts):
                agent = parts[idx + 1]
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                for raw_line in handle:
                    line = raw_line.strip()
                    if not line:
                        continue
                    try:
                        record = json.loads(line)
                    except Exception:
                        continue
                    timestamp = parse_epoch(record.get("timestamp") or (record.get("message") or {}).get("timestamp"))
                    if timestamp and timestamp < cutoff_epoch:
                        continue
                    if record.get("type") == "message":
                        agent_activity[agent]["messages"] += 1
                        message = record.get("message", {})
                        if message.get("role") == "assistant":
                            for item in message.get("content", []) or []:
                                if item.get("type") == "toolCall":
                                    agent_activity[agent]["tool_calls"] += 1
                        if message.get("role") == "toolResult":
                            if message.get("isError") or (message.get("details") or {}).get("status") == "failed":
                                agent_activity[agent]["errors"] += 1
                    usage_sources = [record, record.get("message") or {}]
                    for candidate in usage_sources:
                        usage = candidate.get("usage") or {}
                        if isinstance(usage, dict):
                            cost = ((usage.get("cost") or {}).get("total")) if isinstance(usage.get("cost"), dict) else usage.get("cost")
                            try:
                                if cost is not None:
                                    agent_costs[agent] += float(cost)
                            except (TypeError, ValueError):
                                pass
        except Exception:
            continue

agent_rows = [
    {"agent": agent, **payload}
    for agent, payload in sorted(agent_activity.items())
]
cost_rows = sorted(agent_costs.items())

watchdog_rows = []
timestamp_pattern = re.compile(r"^\[(?P<ts>[0-9:-]{10} [0-9:]{8})\]\s*(?P<body>.*)$")
if os.path.exists(watchdog_log):
    with open(watchdog_log, "r", encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            line = raw_line.rstrip("\n")
            match = timestamp_pattern.match(line)
            if not match:
                continue
            if parse_epoch(match.group("ts")) < cutoff_epoch:
                continue
            watchdog_rows.append(match.group("body"))
watchdog_rows = watchdog_rows[-8:]

if output_html:
    print(render_html(incident_summary, agent_rows, watchdog_rows, cost_rows))
else:
    print(render_text(incident_summary, agent_rows, watchdog_rows, cost_rows))
PY
)"

digest="$(printf '%s\n' "$digest" | sanitize_sensitive)"

if [[ "$SEND_NOTIFY" -eq 1 && -n "$digest" ]] && command -v osascript >/dev/null 2>&1; then
  summary="$(printf '%s\n' "$digest" | head -n 3 | tr '\n' ' ' | sed 's/"/\\"/g')"
  osascript -e "display notification \"$summary\" with title \"OpenClaw Daily Digest\"" >/dev/null 2>&1 || true
fi

printf '%s\n' "$digest"
