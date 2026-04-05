#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

INCIDENTS_DIR="${OPENCLAW_INCIDENTS_DIR:-$HOME/.openclaw/logs}"
INCIDENT_STATE_FILE="${OPENCLAW_INCIDENT_STATE_FILE:-$INCIDENTS_DIR/incidents-state.json}"
INCIDENT_LOG_FILE="${OPENCLAW_INCIDENT_LOG_FILE:-$INCIDENTS_DIR/incidents.jsonl}"
INCIDENT_LOCK_DIR="${OPENCLAW_LOCK_DIR:-$HOME/.openclaw/locks}"
INCIDENT_LOCK_FILE="${OPENCLAW_INCIDENT_LOCK_FILE:-$INCIDENT_LOCK_DIR/incidents.lock}"
INCIDENT_CONFIG_FILE="${OPENCLAW_INCIDENT_CONFIG_FILE:-$HOME/.openclaw/incidents-config.json}"

incident_init() {
  mkdir -p "$INCIDENTS_DIR" "$INCIDENT_LOCK_DIR"
  chmod 700 "$INCIDENT_LOCK_DIR" 2>/dev/null || true
}

_incident_python() {
  local action="$1"
  shift || true

  incident_init

  python3 - "$action" "$INCIDENT_STATE_FILE" "$INCIDENT_LOG_FILE" "$INCIDENT_LOCK_FILE" "$INCIDENT_CONFIG_FILE" "$@" <<'PY'
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

try:
    import fcntl
except ImportError:  # pragma: no cover
    fcntl = None

ACTION = sys.argv[1]
STATE_FILE = sys.argv[2]
LOG_FILE = sys.argv[3]
LOCK_FILE = sys.argv[4]
CONFIG_FILE = sys.argv[5]
ARGS = sys.argv[6:]

DEFAULT_SEVERITY_MAP = {
    "stuck-run": "critical",
    "auth-error": "critical",
    "retry-loop": "warning",
    "error-cluster": "warning",
    "dead-run": "info",
}
COOLDOWN_BASE = 1800
COOLDOWN_CAP = 14400
RESOLVED_TTL = 7200
MUTED_TTL = 86400
STALE_AFTER = 14400
STALE_TTL = 14400
MAX_INCIDENTS = 200
AUTO_ESCALATE_AFTER = 7200


def now_dt():
    return datetime.now(timezone.utc)


def to_iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def to_epoch(value):
    if not value:
        return 0
    try:
        if isinstance(value, (int, float)):
            return int(value)
        return int(datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())
    except Exception:
        return 0


def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return default


def atomic_write(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=os.path.dirname(path), delete=False) as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
        temp_path = handle.name
    os.replace(temp_path, path)


def maybe_rotate_log(path, epoch_value):
    if os.path.exists(path) and os.path.getsize(path) > 5 * 1024 * 1024:
        backup = f"{path}.{epoch_value}.bak"
        os.replace(path, backup)


def append_event(path, epoch_value, event):
    maybe_rotate_log(path, epoch_value)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, sort_keys=True) + "\n")


def anomaly_type_for(dedupe_key):
    parts = dedupe_key.split(":")
    return parts[2] if len(parts) >= 4 else "generic"


def incident_sort_key(item):
    return (
        to_epoch(item.get("lastObservedAt")),
        to_epoch(item.get("openedAt")),
        item.get("dedupeKey", ""),
    )


def prune_state(state, current_dt):
    incidents = state.setdefault("incidents", {})
    current_epoch = int(current_dt.timestamp())
    removed = []

    for key in list(incidents.keys()):
        incident = incidents[key]
        status = incident.get("status", "firing")
        last_observed = to_epoch(incident.get("lastObservedAt")) or current_epoch
        resolved_at = to_epoch(incident.get("resolvedAt"))
        muted_until = int(incident.get("mutedUntil", 0) or 0)

        if status in {"firing", "acknowledged"} and current_epoch - last_observed > STALE_AFTER:
            incident["status"] = "stale"
            incident["transitions"] = (incident.get("transitions") or []) + [current_epoch]
            status = "stale"

        if status == "muted" and muted_until and current_epoch >= muted_until:
            incident["status"] = "resolved"
            incident["resolvedAt"] = to_iso(current_dt)
            status = "resolved"

        if status == "resolved" and resolved_at and current_epoch - resolved_at > RESOLVED_TTL:
            removed.append(key)
        elif status == "muted" and current_epoch - last_observed > MUTED_TTL:
            removed.append(key)
        elif status == "stale" and current_epoch - last_observed > STALE_TTL:
            removed.append(key)

    for key in removed:
        incidents.pop(key, None)

    if len(incidents) > MAX_INCIDENTS:
        sortable = sorted(incidents.values(), key=incident_sort_key)
        overflow = len(incidents) - MAX_INCIDENTS
        for incident in sortable[:overflow]:
            incidents.pop(incident["dedupeKey"], None)


def default_state():
    return {"incidents": {}, "severity_map": DEFAULT_SEVERITY_MAP.copy()}


def lock_file(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    if fcntl is not None:
        fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def unlock_file(fd):
    if fcntl is not None:
        fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)


def make_id(current_epoch):
    return f"inc_{current_epoch}_{os.getpid()}"


def current_state(current_dt):
    state = load_json(STATE_FILE, default_state())
    state.setdefault("incidents", {})
    state["severity_map"] = DEFAULT_SEVERITY_MAP | state.get("severity_map", {}) | load_json(CONFIG_FILE, {}).get("severity_map", {})
    prune_state(state, current_dt)
    return state


def write_state(state):
    atomic_write(STATE_FILE, state)


def register_transition(incident, current_epoch):
    transitions = incident.setdefault("transitions", [])
    transitions.append(current_epoch)
    incident["transitions"] = transitions[-16:]


def maybe_auto_mute(incident, current_dt):
    current_epoch = int(current_dt.timestamp())
    recent = [ts for ts in incident.get("transitions", []) if current_epoch - int(ts) <= 3600]
    if len(recent) >= 4:
        incident["status"] = "muted"
        incident["mutedUntil"] = current_epoch + MUTED_TTL
        incident["flapCount"] = int(incident.get("flapCount", 0) or 0) + 1
        register_transition(incident, current_epoch)
        return True
    return False


def observe_related_session(incident, evidence):
    session_id = evidence.get("session_id") or evidence.get("sessionId")
    if not session_id:
        return
    sessions = incident.setdefault("relatedSessions", [])
    if session_id not in sessions:
        sessions.append(session_id)


fd = lock_file(LOCK_FILE)
try:
    current_dt = now_dt()
    current_epoch = int(current_dt.timestamp())
    current_iso = to_iso(current_dt)
    state = current_state(current_dt)
    incidents = state["incidents"]
    event = None
    payload = None

    if ACTION == "report":
        dedupe_key, severity, title, evidence_json = ARGS
        evidence = json.loads(evidence_json)
        anomaly_type = anomaly_type_for(dedupe_key)
        severity = state["severity_map"].get(anomaly_type, severity or "warning")
        incident = incidents.get(dedupe_key)

        if incident is None:
            incident = {
                "id": make_id(current_epoch),
                "dedupeKey": dedupe_key,
                "status": "firing",
                "severity": severity,
                "title": title,
                "openedAt": current_iso,
                "lastObservedAt": current_iso,
                "resolvedAt": None,
                "eventCount": 1,
                "flapCount": 0,
                "transitions": [current_epoch],
                "relatedSessions": [],
                "evidence": evidence,
            }
            observe_related_session(incident, evidence)
            incidents[dedupe_key] = incident
            event_action = "opened"
        else:
            previous_status = incident.get("status", "firing")
            event_action = "observed"
            should_record_observation = True

            if previous_status == "resolved":
                cooldown = min(COOLDOWN_BASE * (2 ** int(incident.get("flapCount", 0) or 0)), COOLDOWN_CAP)
                resolved_epoch = to_epoch(incident.get("resolvedAt"))
                if resolved_epoch and current_epoch - resolved_epoch < cooldown:
                    should_record_observation = False
                    incident["suppressedCount"] = int(incident.get("suppressedCount", 0) or 0) + 1
                    event_action = "suppressed"
                else:
                    incident["status"] = "firing"
                    incident["resolvedAt"] = None
                    incident["severity"] = severity
                    incident["flapCount"] = int(incident.get("flapCount", 0) or 0) + 1
                    register_transition(incident, current_epoch)
                    event_action = "reopened"
            elif previous_status == "stale":
                incident["status"] = "firing"
                incident["severity"] = severity
                register_transition(incident, current_epoch)
                event_action = "reopened"
            elif previous_status == "muted":
                muted_until = int(incident.get("mutedUntil", 0) or 0)
                if muted_until and current_epoch >= muted_until:
                    incident["status"] = "firing"
                    incident["severity"] = severity
                    incident["resolvedAt"] = None
                    register_transition(incident, current_epoch)
                    event_action = "reopened"
            else:
                incident["severity"] = severity

            if should_record_observation:
                incident["eventCount"] = int(incident.get("eventCount", 0) or 0) + 1
                incident["lastObservedAt"] = current_iso
                incident["title"] = title or incident.get("title")
                incident["evidence"] = evidence
                observe_related_session(incident, evidence)

        if incident.get("status") == "firing":
            opened_epoch = to_epoch(incident.get("openedAt")) or current_epoch
            if incident.get("severity") == "warning" and current_epoch - opened_epoch > AUTO_ESCALATE_AFTER:
                incident["severity"] = "critical"

        auto_muted = maybe_auto_mute(incident, current_dt)
        if auto_muted:
            event_action = "auto-muted"

        event = {
            "timestamp": current_iso,
            "action": event_action,
            "dedupeKey": dedupe_key,
            "status": incident.get("status"),
            "severity": incident.get("severity"),
            "title": incident.get("title"),
        }
        payload = incident

    elif ACTION == "resolve":
        dedupe_key = ARGS[0]
        incident = incidents.get(dedupe_key)
        if incident:
            incident["status"] = "resolved"
            incident["resolvedAt"] = current_iso
            incident["lastObservedAt"] = current_iso
            register_transition(incident, current_epoch)
            event = {
                "timestamp": current_iso,
                "action": "resolved",
                "dedupeKey": dedupe_key,
                "status": "resolved",
                "severity": incident.get("severity"),
                "title": incident.get("title"),
            }
            payload = incident

    elif ACTION == "ack":
        dedupe_key = ARGS[0]
        incident = incidents.get(dedupe_key)
        if incident:
            incident["status"] = "acknowledged"
            incident["lastObservedAt"] = current_iso
            register_transition(incident, current_epoch)
            event = {
                "timestamp": current_iso,
                "action": "acknowledged",
                "dedupeKey": dedupe_key,
                "status": "acknowledged",
                "severity": incident.get("severity"),
                "title": incident.get("title"),
            }
            payload = incident

    elif ACTION == "mute":
        dedupe_key = ARGS[0]
        incident = incidents.get(dedupe_key)
        if incident:
            incident["status"] = "muted"
            incident["mutedUntil"] = current_epoch + MUTED_TTL
            incident["lastObservedAt"] = current_iso
            register_transition(incident, current_epoch)
            event = {
                "timestamp": current_iso,
                "action": "muted",
                "dedupeKey": dedupe_key,
                "status": "muted",
                "severity": incident.get("severity"),
                "title": incident.get("title"),
            }
            payload = incident

    elif ACTION == "is_open":
        dedupe_key = ARGS[0]
        incident = incidents.get(dedupe_key)
        if incident and incident.get("status") in {"firing", "acknowledged"}:
            print("open")
        else:
            print("closed")

    elif ACTION == "list":
        status_filter = ARGS[0]
        output_format = ARGS[1]
        incidents_list = sorted(incidents.values(), key=incident_sort_key, reverse=True)
        if status_filter != "all":
            incidents_list = [item for item in incidents_list if item.get("status") == status_filter]
        if output_format == "json":
            print(json.dumps(incidents_list, indent=2, sort_keys=True))
        else:
            for item in incidents_list:
                print(f"{item.get('status','unknown')} [{item.get('severity','warning')}] {item.get('dedupeKey')} {item.get('title','')}")

    write_state(state)
    if event is not None:
        append_event(LOG_FILE, current_epoch, event)
    if payload is not None:
        print(json.dumps(payload, sort_keys=True))
finally:
    unlock_file(fd)
PY
}

incident_report() {
  local dedupe_key="$1"
  local severity="$2"
  local title="$3"
  local evidence_json="${4-}"
  if [[ -z "$evidence_json" ]]; then
    evidence_json='{}'
  fi
  _incident_python report "$dedupe_key" "$severity" "$title" "$evidence_json" >/dev/null
}

incident_resolve() {
  local dedupe_key="$1"
  _incident_python resolve "$dedupe_key" >/dev/null
}

incident_ack() {
  local dedupe_key="$1"
  _incident_python ack "$dedupe_key" >/dev/null
}

incident_mute() {
  local dedupe_key="$1"
  _incident_python mute "$dedupe_key" >/dev/null
}

incident_is_open() {
  local dedupe_key="$1"
  local state
  state="$(_incident_python is_open "$dedupe_key")"
  [[ "$state" == "open" ]]
}

incident_list() {
  local status_filter="all"
  local output_format="text"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status)
        status_filter="${2:-all}"
        shift 2
        ;;
      --json)
        output_format="json"
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  _incident_python list "$status_filter" "$output_format"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "incident-manager.sh is a sourced library. Source it from another script." >&2
  exit 1
fi
