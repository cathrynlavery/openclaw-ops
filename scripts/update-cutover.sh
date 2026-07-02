#!/usr/bin/env bash
# update-cutover.sh — controlled OpenClaw upgrade cutover guardrail
#
# This script does not run `openclaw update`. It captures the before/after
# evidence and prints the human decision gates that must be satisfied around an
# update. Use it before updating and again after the update.
#
# Usage:
#   bash scripts/update-cutover.sh --preflight --target-version v2026.5.12 --lane official --app-scope cli
#   openclaw update
#   bash scripts/post-update.sh
#   bash scripts/update-cutover.sh --post --target-version v2026.5.12 --lane official --app-scope cli --cutover-dir <dir>

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

require_tools openclaw python3 || exit 1

MODE=""
TARGET_VERSION=""
LANE=""
APP_SCOPE=""
CUTOVER_DIR=""
RELEASE_NOTES=""
HACK_AUDIT_LOG="${OPENCLAW_HACK_AUDIT_LOG:-$HOME/.openclaw/hack-audit-log.md}"
RUN_SMOKE=false

usage() {
  cat <<'EOF'
Usage:
  update-cutover.sh --preflight --target-version VERSION --lane official|custom --app-scope cli|app|both|none [--release-notes PATH_OR_URL]
  update-cutover.sh --post      --target-version VERSION --lane official|custom --app-scope cli|app|both|none [--cutover-dir DIR] [--smoke]

Modes:
  --preflight   Capture read-only baseline and generate the cutover gate report.
  --post        Capture after-state and run post-cutover verification checks.

Required gates:
  --lane        official = packaged release is source of truth; custom = local/runtime checkout remains source of truth.
  --app-scope   cli, app, both, or none. On macOS, the app and CLI/gateway are separate artifacts.

Environment:
  OPENCLAW_CUTOVER_ROOT       Root for reports (default: ~/.openclaw/update-cutovers)
  OPENCLAW_HACK_AUDIT_LOG     Optional hack/workaround audit file to include in the report
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preflight) MODE="preflight"; shift ;;
    --post) MODE="post"; shift ;;
    --target-version|--lane|--app-scope|--cutover-dir|--release-notes)
      [[ $# -ge 2 && -n "${2:-}" && "${2:-}" != --* ]] || { echo "Missing value for $1" >&2; usage; exit 1; }
      case "$1" in
        --target-version) TARGET_VERSION="$2" ;;
        --lane) LANE="$2" ;;
        --app-scope) APP_SCOPE="$2" ;;
        --cutover-dir) CUTOVER_DIR="$2" ;;
        --release-notes) RELEASE_NOTES="$2" ;;
      esac
      shift 2 ;;
    --smoke) RUN_SMOKE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$MODE" ]] || { echo "Missing --preflight or --post" >&2; usage; exit 1; }
[[ "$LANE" =~ ^(official|custom)$ ]] || { echo "--lane must be official or custom" >&2; usage; exit 1; }
[[ "$APP_SCOPE" =~ ^(cli|app|both|none)$ ]] || { echo "--app-scope must be cli, app, both, or none" >&2; usage; exit 1; }
[[ -n "$TARGET_VERSION" ]] || { echo "Missing --target-version" >&2; usage; exit 1; }

CUTOVER_ROOT="${OPENCLAW_CUTOVER_ROOT:-$HOME/.openclaw/update-cutovers}"
if [[ -z "$CUTOVER_DIR" ]]; then
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  safe_target="$(printf '%s' "$TARGET_VERSION" | tr -c 'A-Za-z0-9._-' '_')"
  CUTOVER_DIR="$CUTOVER_ROOT/${stamp}-${safe_target}"
fi
mkdir -p "$CUTOVER_DIR"

log()  { echo -e "${CYN}[~]${RST} $1"; }
good() { echo -e "${GRN}[✓]${RST} $1"; }
warn() { echo -e "${YLW}[!]${RST} $1"; }
bad()  { echo -e "${RED}[✗]${RST} $1"; }

run_capture() {
  local label="$1"
  local outfile="$2"
  shift 2
  local rc=0
  set +e
  {
    printf '# %s\n' "$label"
    printf '# captured_at=%s\n\n' "$(iso_now)"
    "$@"
  } 2>&1 | sanitize_sensitive >"$outfile"
  rc=${PIPESTATUS[0]}
  set -e
  printf '%s\n' "$rc" >"$outfile.exit"
  return 0
}

config_file_path() {
  openclaw config file 2>/dev/null || printf '%s\n' "$HOME/.openclaw/openclaw.json"
}

capture_state() {
  local prefix="$1"
  local state_dir="$CUTOVER_DIR/$prefix"
  mkdir -p "$state_dir"

  run_capture "openclaw version" "$state_dir/openclaw-version.txt" openclaw --version
  run_capture "openclaw gateway status" "$state_dir/gateway-status.txt" openclaw gateway status
  run_capture "openclaw status" "$state_dir/status.txt" openclaw status
  run_capture "openclaw doctor" "$state_dir/doctor.txt" openclaw doctor
  run_capture "openclaw channels status --probe" "$state_dir/channels-status-probe.txt" openclaw channels status --probe
  run_capture "openclaw cron list --json" "$state_dir/cron-list.json" openclaw cron list --json

  local cfg
  cfg="$(config_file_path)"
  if [[ -f "$cfg" ]]; then
    sanitize_sensitive <"$cfg" >"$state_dir/openclaw-config.redacted.json" || true
  else
    printf 'config file not found: %s\n' "$cfg" >"$state_dir/openclaw-config.redacted.json"
  fi

  run_capture "openclaw binaries" "$state_dir/openclaw-binaries.txt" bash -c 'type -a openclaw; echo; command -v openclaw; echo; ls -l "$(command -v openclaw)" /opt/homebrew/bin/openclaw /usr/local/bin/openclaw 2>/dev/null || true'

  if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]]; then
    run_capture "launchd gateway service" "$state_dir/launchd-gateway.txt" bash -c 'launchctl print "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null | sed -n "1,160p" || true'
    run_capture "macOS app version" "$state_dir/macos-app-version.txt" bash -c 'if [[ -d /Applications/OpenClaw.app ]]; then defaults read /Applications/OpenClaw.app/Contents/Info CFBundleShortVersionString 2>/dev/null || true; defaults read /Applications/OpenClaw.app/Contents/Info CFBundleVersion 2>/dev/null || true; else echo "not installed"; fi'
  fi

  { launchctl print "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null || true; type -a openclaw 2>/dev/null || true; command -v openclaw 2>/dev/null || true; } \
    | grep -Ei 'openclaw.*(/tmp|/private/tmp)|(/tmp|/private/tmp).*openclaw' \
    | sanitize_sensitive >"$state_dir/temp-runtime-refs.txt" || true
}

write_preflight_report() {
  local report="$CUTOVER_DIR/CUTOVER.md"
  local current_version
  local created_at
  local release_notes
  current_version="$(get_openclaw_version)"
  created_at="$(iso_now)"
  release_notes="${RELEASE_NOTES:-not supplied}"
  cat >"$report" <<'EOF'
# OpenClaw Update Cutover

- Created: __CREATED_AT__
- Target release: __TARGET_VERSION__
- Lane: __LANE__
- App scope: __APP_SCOPE__
- Current CLI/gateway version: __CURRENT_VERSION__
- Release notes: __RELEASE_NOTES__
- Cutover dir: __CUTOVER_DIR__

## Gap closure this report enforces

The old post-update path starts after `openclaw update`; this cutover gate adds the missing before-change decisions:

- [ ] Release notes reviewed against current setup
- [ ] Required fixes are confirmed present or explicitly accepted as missing
- [ ] Lane chosen before update: official/custom
- [ ] macOS app scope chosen before update: cli/app/both/none
- [ ] Current config, cron jobs, gateway path, launch target, and app version captured
- [ ] Hack/workaround audit reviewed
- [ ] Rollback target/path confirmed
- [ ] Single restart plan chosen

## Release compatibility review

Classify each relevant release-note item:

| Area | Safe | Needs migration | Blocker | Notes |
|---|---:|---:|---:|---|
| channels / routing / delivery | [ ] | [ ] | [ ] | |
| cron / announcements | [ ] | [ ] | [ ] | |
| auth / profiles / provider runtime | [ ] | [ ] | [ ] | |
| model IDs / aliases / fallbacks | [ ] | [ ] | [ ] | |
| plugin slots / runtime deps | [ ] | [ ] | [ ] | |
| sessions / compaction / memory | [ ] | [ ] | [ ] | |
| macOS app ↔ gateway compatibility | [ ] | [ ] | [ ] | |

## Hack/workaround audit

Hack audit source: `__HACK_AUDIT_LOG__`

- [ ] No relevant hacks found, or no audit file exists
- [ ] Relevant hacks reviewed and classified below

| Hack/workaround | Keep | Retire | Modify | Expected post-update behavior |
|---|---:|---:|---:|---|
| | [ ] | [ ] | [ ] | |

High-risk if it touches runtime paths, launch behavior, cron behavior, auth/secrets, or plugin loading.

## Cutover gate

Do not run the update until these are true:

- [ ] Lane is correct: __LANE__
- [ ] App scope is correct: __APP_SCOPE__
- [ ] One runtime target path selected
- [ ] Rollback target/path confirmed
- [ ] Baseline files under `before/` reviewed
- [ ] No unexpected /tmp or /private/tmp runtime references
- [ ] Single restart/update plan prepared

## Post-cutover verification checklist

Run after update:

```bash
bash scripts/post-update.sh
bash scripts/update-cutover.sh --post --target-version "__TARGET_VERSION__" --lane "__LANE__" --app-scope "__APP_SCOPE__" --cutover-dir "__CUTOVER_DIR__"
```

Pass criteria:

- [ ] Service version matches target release
- [ ] macOS app version recorded and compatible with chosen app scope
- [ ] Gateway status clean enough for operation
- [ ] Channels probe passes for required channels
- [ ] Cron list readable and announcements/delivery bindings still make sense
- [ ] No config-version mismatch warnings
- [ ] No /tmp or /private/tmp runtime references
- [ ] No missing control-ui/plugin asset errors in doctor/log probes
- [ ] ACP/subagent smoke test passes if used on this host
- [ ] Channel smoke tests pass for the host's important channels

## Rollback rule

If verification fails, stop layering fixes. Roll back to the prior known-good runtime target, then verify restored health.
EOF

  python3 - "$report" "$created_at" "$TARGET_VERSION" "$LANE" "$APP_SCOPE" "$current_version" "$release_notes" "$CUTOVER_DIR" "$HACK_AUDIT_LOG" <<'PY'
from pathlib import Path
import sys

report = Path(sys.argv[1])
replacements = {
    "__CREATED_AT__": sys.argv[2],
    "__TARGET_VERSION__": sys.argv[3],
    "__LANE__": sys.argv[4],
    "__APP_SCOPE__": sys.argv[5],
    "__CURRENT_VERSION__": sys.argv[6],
    "__RELEASE_NOTES__": sys.argv[7],
    "__CUTOVER_DIR__": sys.argv[8],
    "__HACK_AUDIT_LOG__": sys.argv[9],
}
text = report.read_text(encoding="utf-8")
for marker, value in replacements.items():
    text = text.replace(marker, value)
report.write_text(text, encoding="utf-8")
PY

  if [[ -f "$HACK_AUDIT_LOG" ]]; then
    {
      printf '\n## Hack audit excerpt\n\n'
      sed -n '1,120p' "$HACK_AUDIT_LOG" | sanitize_sensitive
    } >>"$report"
  fi
}

capture_exit_ok() {
  local label="$1"
  local exit_file="$2"
  local rc
  rc="$(cat "$exit_file" 2>/dev/null || printf 'missing')"
  if [[ "$rc" == "0" ]]; then
    good "$label completed successfully"
    return 0
  fi
  bad "$label failed or was not captured (exit=$rc)"
  return 1
}

post_verify() {
  local failed=0
  local after_dir="$CUTOVER_DIR/after"
  local current_version
  current_version="$(get_openclaw_version)"

  if [[ "$current_version" == "$TARGET_VERSION" || "$current_version" == "v${TARGET_VERSION#v}" ]]; then
    good "service version matches target: $current_version"
  else
    bad "service version mismatch: current=$current_version target=$TARGET_VERSION"
    failed=1
  fi

  for check in \
    "gateway status:$after_dir/gateway-status.txt.exit" \
    "doctor:$after_dir/doctor.txt.exit" \
    "channels probe:$after_dir/channels-status-probe.txt.exit" \
    "cron list:$after_dir/cron-list.json.exit"
  do
    if ! capture_exit_ok "${check%%:*}" "${check#*:}"; then
      failed=1
    fi
  done

  if grep -qE '/private/tmp|(^|[^[:alpha:]])/tmp([^[:alpha:]]|$)' "$after_dir/temp-runtime-refs.txt" 2>/dev/null; then
    bad "temp-backed runtime references found: $after_dir/temp-runtime-refs.txt"
    failed=1
  else
    good "no /tmp or /private/tmp runtime references found in captured service/path probes"
  fi

  if grep -qiE 'missing.*(asset|plugin|control-ui)|version mismatch|entrypoint mismatch' "$after_dir/doctor.txt" "$after_dir/gateway-status.txt" 2>/dev/null; then
    bad "doctor/status output contains mismatch or missing asset warnings"
    failed=1
  else
    good "no obvious version/asset mismatch warnings in doctor/status capture"
  fi

  if [[ "$APP_SCOPE" =~ ^(app|both)$ ]]; then
    if [[ "$(uname -s 2>/dev/null || true)" != "Darwin" ]]; then
      warn "app scope is $APP_SCOPE but host is not macOS; skipping app bundle verification"
    elif [[ ! -d /Applications/OpenClaw.app ]]; then
      bad "app scope is $APP_SCOPE but /Applications/OpenClaw.app is not installed"
      failed=1
    elif ! grep -Eq "${TARGET_VERSION#v}|$TARGET_VERSION" "$after_dir/macos-app-version.txt" 2>/dev/null; then
      bad "macOS app version capture does not mention target $TARGET_VERSION"
      failed=1
    else
      good "macOS app version capture mentions target $TARGET_VERSION"
    fi
  elif [[ "$APP_SCOPE" == "cli" && "$(uname -s 2>/dev/null || true)" == "Darwin" && -d /Applications/OpenClaw.app ]]; then
    warn "CLI-only cutover with /Applications/OpenClaw.app installed; app/gateway split must be intentionally accepted"
  fi

  if [[ "$RUN_SMOKE" == "true" ]]; then
    run_capture "agent smoke" "$after_dir/agent-smoke.txt" openclaw agent --session-id "update-cutover-smoke-$(date +%s)" --message "Health probe. Reply exactly: OPENCLAW_ALIVE" --thinking low --timeout 240 --json
    if [[ "$(cat "$after_dir/agent-smoke.txt.exit" 2>/dev/null || printf '1')" == "0" ]] && grep -q 'OPENCLAW_ALIVE' "$after_dir/agent-smoke.txt"; then
      good "agent smoke passed"
    else
      bad "agent smoke did not return expected sentinel"
      failed=1
    fi
  else
    warn "agent/channel smoke tests not run; use --smoke or run host-specific channel tests manually"
  fi

  return "$failed"
}

case "$MODE" in
  preflight)
    log "Capturing preflight baseline in $CUTOVER_DIR"
    capture_state before
    write_preflight_report
    good "Preflight report written: $CUTOVER_DIR/CUTOVER.md"
    warn "Review and complete the cutover gate before running openclaw update"
    ;;
  post)
    log "Capturing post-update state in $CUTOVER_DIR"
    capture_state after
    if post_verify; then
      good "Post-cutover verification passed"
    else
      bad "Post-cutover verification failed — use the rollback rule before layering more fixes"
      exit 1
    fi
    ;;
esac
