#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output to not contain: $needle"
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  [[ "$actual" == "$expected" ]] || fail "expected [$expected], got [$actual]"
}

setup_fake_env() {
  TEST_ROOT="$(mktemp -d)"
  export TEST_ROOT
  export HOME="$TEST_ROOT/home"
  export PATH="$TEST_ROOT/bin:$PATH"
  mkdir -p "$HOME/.openclaw/logs" "$HOME/.openclaw" "$TEST_ROOT/bin"

  cat >"$TEST_ROOT/bin/openclaw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  --version|-V)
    printf '%s\n' "${OPENCLAW_STATUS_VERSION:-v2026.2.12}"
    ;;
  status)
    printf 'OpenClaw %s\n' "${OPENCLAW_STATUS_VERSION:-v2026.2.12}"
    ;;
  config)
    if [[ "${2:-}" == "get" ]]; then
      case "${3:-}" in
        gateway.auth.mode) echo "${OPENCLAW_AUTH_MODE:-token}" ;;
        tools.exec.security) echo "${OPENCLAW_EXEC_SECURITY:-full}" ;;
        tools.exec.strictInlineEval) echo "${OPENCLAW_EXEC_STRICT:-false}" ;;
        agents.defaults.model) echo "gpt-5.4" ;;
        agents.defaults.sandbox.mode) echo "${OPENCLAW_SANDBOX_MODE:-all}" ;;
        agents.defaults.subagents.maxSpawnDepth) echo "2" ;;
        gateway.bind) echo "${OPENCLAW_GATEWAY_BIND:-loopback}" ;;
        dmPolicy) echo "${OPENCLAW_DM_POLICY:-pairing}" ;;
        tools.deny) echo "${OPENCLAW_TOOLS_DENY:-gateway cron sessions_spawn}" ;;
        security.trust_model.multi_user_heuristic) echo "${OPENCLAW_MULTI_USER_HEURISTIC:-true}" ;;
      esac
    elif [[ "${2:-}" == "set" ]]; then
      exit 0
    fi
    ;;
  system)
    mkdir -p "$HOME/.openclaw/logs"
    printf '%s\n' "$*" >>"$HOME/.openclaw/logs/system-events.log"
    exit 0
    ;;
  doctor|gateway|cron|approvals)
    exit 0
    ;;
esac
EOF
  chmod +x "$TEST_ROOT/bin/openclaw"

  cat >"$TEST_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

out_file=""
write_fmt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out_file="$2"
      shift 2
      ;;
    -w)
      write_fmt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -n "$out_file" ]]; then
  printf '%s\n' "${CURL_BODY:-Healthy}" >"$out_file"
fi

if [[ -n "$write_fmt" ]]; then
  printf '%s' "${CURL_HTTP_STATUS:-200}"
fi
EOF
  chmod +x "$TEST_ROOT/bin/curl"

  cat >"$TEST_ROOT/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${PGREP_OUTPUT:-}" ]]; then
  printf '%s\n' "$PGREP_OUTPUT"
fi
EOF
  chmod +x "$TEST_ROOT/bin/pgrep"

  cat >"$TEST_ROOT/bin/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-o" ]]; then
  case "${2:-}" in
    etimes=)
      if [[ "${PS_ETIMES_UNSUPPORTED:-0}" == "1" ]]; then
        echo "ps: etimes: keyword not found" >&2
        exit 1
      fi
      printf '%s\n' "${PS_ETIMES:-600}"
      ;;
    etime=)
      printf '%s\n' "${PS_ETIME:-10:00}"
      ;;
    *)
      exit 1
      ;;
  esac
else
  exit 0
fi
EOF
  chmod +x "$TEST_ROOT/bin/ps"
}

install_fixture() {
  local agent="$1"
  local fixture="$2"
  local target_name="${3:-$fixture}"
  mkdir -p "$HOME/.openclaw/agents/$agent/sessions"
  cp "$ROOT_DIR/tests/fixtures/$fixture" "$HOME/.openclaw/agents/$agent/sessions/$target_name"
}

teardown_fake_env() {
  rm -rf "$TEST_ROOT"
}

test_version_change_survives_watchdog_for_check_update() {
  setup_fake_env
  trap teardown_fake_env RETURN

  cat >"$HOME/.openclaw/exec-approvals.json" <<'EOF'
{"defaults":{"security":"full","ask":"off","askFallback":"full"}}
EOF

  export CURL_HTTP_STATUS=200
  export OPENCLAW_STATUS_VERSION="v2026.2.12"
  bash "$ROOT_DIR/scripts/watchdog.sh" >/dev/null

  export OPENCLAW_STATUS_VERSION="v2026.2.24"
  bash "$ROOT_DIR/scripts/watchdog.sh" >/dev/null

  local output
  output="$(bash "$ROOT_DIR/scripts/check-update.sh" 2>&1)"
  assert_contains "$output" "Version changed:"
  assert_contains "$output" "v2026.2.12"
  assert_contains "$output" "v2026.2.24"
}

test_lib_removes_generic_eval_exec_helpers() {
  local lib="$ROOT_DIR/scripts/lib.sh"
  ! grep -q 'json_read()' "$lib" || fail "json_read helper should be removed"
  ! grep -q 'json_patch()' "$lib" || fail "json_patch helper should be removed"
  ! grep -q 'eval(sys.argv\\[2\\])' "$lib" || fail "eval helper should be removed"
  ! grep -q 'exec(sys.argv\\[2\\])' "$lib" || fail "exec helper should be removed"
}

test_heal_incident_logging_no_longer_embeds_shell_generated_python() {
  local heal="$ROOT_DIR/scripts/heal.sh"
  grep -q "read_lines(sys.argv\\[3\\])" "$heal" || fail "heal incident logging should read fixed items from a file"
  grep -q "read_lines(sys.argv\\[4\\])" "$heal" || fail "heal incident logging should read broken items from a file"
  grep -q "read_lines(sys.argv\\[5\\])" "$heal" || fail "heal incident logging should read manual items from a file"
}

test_security_scan_respects_maxdepth_for_permission_checks() {
  setup_fake_env
  trap teardown_fake_env RETURN

  mkdir -p "$HOME/.openclaw/a/b"
  printf 'SAFE=1\n' >"$HOME/.openclaw/a/b/too-deep.env"
  chmod 777 "$HOME/.openclaw/a/b/too-deep.env"

  local output
  output="$(bash "$ROOT_DIR/scripts/security-scan.sh" 2>&1)"
  assert_not_contains "$output" "too-deep.env"
}

test_get_openclaw_version_normalizes_missing_v_prefix() {
  setup_fake_env
  trap teardown_fake_env RETURN

  export OPENCLAW_STATUS_VERSION="2026.4.1"

  local version
  version="$(
    source "$ROOT_DIR/scripts/lib.sh"
    get_openclaw_version
  )"
  [[ "$version" == "v2026.4.1" ]] || fail "expected normalized version, got: $version"
}

test_health_check_passes_for_valid_targets() {
  setup_fake_env
  trap teardown_fake_env RETURN

  export CURL_HTTP_STATUS=200
  export CURL_BODY="gateway healthy"
  export PGREP_OUTPUT="1234"
  export PS_ETIMES="601"

  cat >"$HOME/.openclaw/health-targets.conf" <<'EOF'
url|gateway|http://127.0.0.1:18789/health|healthy
process|worker|openclaw worker|300
EOF

  local output
  output="$(bash "$ROOT_DIR/scripts/health-check.sh" --verbose 2>&1)"
  assert_contains "$output" "All health checks passed"
}

test_health_check_falls_back_to_etime_on_macos() {
  setup_fake_env
  trap teardown_fake_env RETURN

  export CURL_HTTP_STATUS=200
  export CURL_BODY="gateway live"
  export PGREP_OUTPUT="1234"
  export PS_ETIMES_UNSUPPORTED=1
  export PS_ETIME="10:05"

  cat >"$HOME/.openclaw/health-targets.conf" <<'EOF'
url|gateway|http://127.0.0.1:18789/health|live
process|worker|openclaw worker|300
EOF

  local output
  output="$(bash "$ROOT_DIR/scripts/health-check.sh" --verbose 2>&1)"
  assert_contains "$output" "All health checks passed"
}

test_security_scan_redacts_secret_values() {
  setup_fake_env
  trap teardown_fake_env RETURN

  cat >"$HOME/.openclaw/auth-profiles.json" <<'EOF'
{"token":"sk-ant-oat01-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"}
EOF

  local output
  output="$(bash "$ROOT_DIR/scripts/security-scan.sh" --credentials 2>&1 || true)"
  assert_contains "$output" "auth-profiles.json:1"
  assert_not_contains "$output" "sk-ant-oat01-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
}

test_lib_time_and_sanitization_helpers() {
  local output
  output="$(
    source "$ROOT_DIR/scripts/lib.sh"
    epoch="$(epoch_now)"
    iso="$(iso_now)"
    sample='sk-1234567890abcdefghijklmn xoxb-123456789012-abcdef ghp_123456789012345678901234567890123456 AKIAABCDEFGHIJKLMNOP Bearer abcdefghijklmnopqrstuvwxyz123456 {"password":"secret","api_key":"value"}'
    sanitized="$(printf '%s\n' "$sample" | sanitize_sensitive)"
    printf 'epoch=%s\niso=%s\nsanitized=%s\n' "$epoch" "$iso" "$sanitized"
  )"

  assert_contains "$output" "epoch="
  assert_contains "$output" "iso="
  assert_contains "$output" "[REDACTED_API_KEY]"
  assert_contains "$output" "[REDACTED_SLACK_TOKEN]"
  assert_contains "$output" "[REDACTED_GH_TOKEN]"
  assert_contains "$output" "[REDACTED_AWS_KEY]"
  assert_contains "$output" "Bearer [REDACTED]"
  assert_contains "$output" "\"password\":\"[REDACTED]\""
  assert_contains "$output" "\"api_key\":\"[REDACTED]\""
}

test_incident_lifecycle_and_dedup() {
  setup_fake_env
  trap teardown_fake_env RETURN

  local output
  output="$(
    source "$ROOT_DIR/scripts/lib.sh"
    source "$ROOT_DIR/scripts/incident-manager.sh"

    incident_report "agent:knox:retry-loop:exec" "warning" "Retry loop: knox calling exec 7 times" '{"agent":"knox","tool":"exec","count":7,"session_id":"sess-alpha"}'
    incident_report "agent:knox:retry-loop:exec" "warning" "Retry loop: knox calling exec 8 times" '{"agent":"knox","tool":"exec","count":8,"session_id":"sess-beta"}'
    incident_list --json
    incident_resolve "agent:knox:retry-loop:exec"
    incident_report "agent:knox:retry-loop:exec" "warning" "Retry loop should stay cooled down" '{"agent":"knox","tool":"exec","count":9,"session_id":"sess-gamma"}'
    printf '\n---\n'
    incident_list --json
  )"

  assert_contains "$output" "\"dedupeKey\": \"agent:knox:retry-loop:exec\""
  assert_contains "$output" "\"eventCount\": 2"
  assert_contains "$output" "\"relatedSessions\": ["
  assert_contains "$output" "sess-alpha"
  assert_contains "$output" "sess-beta"
  assert_contains "$output" "\"status\": \"resolved\""
  assert_not_contains "$output" "sess-gamma"
}

test_session_monitor_detects_retry_loops_and_writes_latest_json() {
  setup_fake_env
  trap teardown_fake_env RETURN

  install_fixture "knox" "session-retry-loop.jsonl"
  install_fixture "atlas" "session-normal.jsonl"

  bash "$ROOT_DIR/scripts/session-monitor.sh" --no-alert >/dev/null

  local latest_json
  latest_json="$(cat "$HOME/.openclaw/session-monitor/latest.json")"
  assert_contains "$latest_json" "\"dedupeKey\": \"agent:knox:retry-loop:exec\""
  assert_not_contains "$latest_json" "\"dedupeKey\": \"agent:atlas:retry-loop:exec\""

  local incidents
  incidents="$(cat "$HOME/.openclaw/logs/incidents-state.json")"
  assert_contains "$incidents" "\"dedupeKey\": \"agent:knox:retry-loop:exec\""
}

test_session_monitor_detects_stuck_runs() {
  setup_fake_env
  trap teardown_fake_env RETURN

  install_fixture "atlas" "session-stuck.jsonl"
  touch "$HOME/.openclaw/agents/atlas/sessions/session-stuck.jsonl"

  bash "$ROOT_DIR/scripts/session-monitor.sh" --no-alert >/dev/null

  local latest_json
  latest_json="$(cat "$HOME/.openclaw/session-monitor/latest.json")"
  assert_contains "$latest_json" "\"dedupeKey\": \"agent:atlas:stuck-run:_\""
  assert_contains "$latest_json" "\"severity\": \"critical\""
}

test_watchdog_throttles_session_monitor_invocation() {
  setup_fake_env
  trap teardown_fake_env RETURN

  cat >"$ROOT_DIR/tests/.session-monitor-stub.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'tick\n' >>"${SESSION_MONITOR_STUB_LOG:?}"
EOF
  chmod +x "$ROOT_DIR/tests/.session-monitor-stub.sh"

  export CURL_HTTP_STATUS=200
  export SESSION_MONITOR_STUB_LOG="$HOME/.openclaw/logs/session-monitor-stub.log"
  export OPENCLAW_SESSION_MONITOR_SCRIPT="$ROOT_DIR/tests/.session-monitor-stub.sh"

  bash "$ROOT_DIR/scripts/watchdog.sh" >/dev/null
  bash "$ROOT_DIR/scripts/watchdog.sh" >/dev/null

  local count
  count="$(wc -l <"$SESSION_MONITOR_STUB_LOG" | tr -d ' ')"
  assert_eq "$count" "1"

  rm -f "$ROOT_DIR/tests/.session-monitor-stub.sh"
}

test_session_search_sanitizes_and_handles_corruption() {
  setup_fake_env
  trap teardown_fake_env RETURN

  install_fixture "atlas" "session-with-secrets.jsonl"
  install_fixture "atlas" "session-corrupted.jsonl"

  local output
  output="$(bash "$ROOT_DIR/scripts/session-search.sh" "sk-" --limit 5 2>&1)"
  assert_contains "$output" "[REDACTED_API_KEY]"
  assert_not_contains "$output" "sk-1234567890abcdefghijklmn"

  local corrupted
  corrupted="$(bash "$ROOT_DIR/scripts/session-search.sh" "malformed" --limit 5 2>&1)"
  assert_contains "$corrupted" "sess-corrupted"
}

test_session_resume_uses_compaction_and_detects_failure() {
  setup_fake_env
  trap teardown_fake_env RETURN

  install_fixture "knox" "session-retry-loop.jsonl"

  local resume_file
  resume_file="$HOME/.openclaw/agents/knox/sessions/session-retry-loop.jsonl"

  local output
  output="$(bash "$ROOT_DIR/scripts/session-resume.sh" "$resume_file" 2>&1)"
  assert_contains "$output" "## Session Resume: sess-retry"
  assert_contains "$output" "### Session Context (from compaction)"
  assert_contains "$output" "Goal: restore a failing OpenClaw worker."
  assert_contains "$output" "### Point of Failure"
  assert_contains "$output" "permission denied"
}

test_daily_digest_summarizes_incidents_activity_and_watchdog() {
  setup_fake_env
  trap teardown_fake_env RETURN

  install_fixture "knox" "session-normal.jsonl"

  printf '[2026-04-04 09:00:00] Gateway healthy (HTTP 200)\n' >"$HOME/.openclaw/logs/watchdog.log"
  printf '[2026-04-04 09:05:00] Running session monitor\n' >>"$HOME/.openclaw/logs/watchdog.log"

  bash -lc "source '$ROOT_DIR/scripts/lib.sh'; source '$ROOT_DIR/scripts/incident-manager.sh'; incident_report 'agent:knox:retry-loop:exec' 'warning' 'Retry loop: knox calling exec 7 times' '{\"agent\":\"knox\",\"tool\":\"exec\",\"count\":7,\"session_id\":\"sess-normal\"}'"

  local output
  output="$(bash "$ROOT_DIR/scripts/daily-digest.sh" --hours 48 2>&1)"
  assert_contains "$output" "Incident Summary"
  assert_contains "$output" "Retry loop: knox calling exec 7 times"
  assert_contains "$output" "Agent Activity"
  assert_contains "$output" "knox"
  assert_contains "$output" "Watchdog Events"
  assert_contains "$output" "Running session monitor"
  assert_contains "$output" "Cost Summary"
}

run_test() {
  local name="$1"
  printf 'Running %s\n' "$name"
  "$name"
}

run_test test_version_change_survives_watchdog_for_check_update
run_test test_lib_removes_generic_eval_exec_helpers
run_test test_heal_incident_logging_no_longer_embeds_shell_generated_python
run_test test_security_scan_respects_maxdepth_for_permission_checks
run_test test_get_openclaw_version_normalizes_missing_v_prefix
run_test test_health_check_passes_for_valid_targets
run_test test_health_check_falls_back_to_etime_on_macos
run_test test_security_scan_redacts_secret_values
run_test test_lib_time_and_sanitization_helpers
run_test test_incident_lifecycle_and_dedup
run_test test_session_monitor_detects_retry_loops_and_writes_latest_json
run_test test_session_monitor_detects_stuck_runs
run_test test_watchdog_throttles_session_monitor_invocation
run_test test_session_search_sanitizes_and_handles_corruption
run_test test_session_resume_uses_compaction_and_detects_failure
run_test test_daily_digest_summarizes_incidents_activity_and_watchdog
printf 'All openclaw-ops tests passed\n'
