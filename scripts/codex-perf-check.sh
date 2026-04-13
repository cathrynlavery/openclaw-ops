#!/usr/bin/env bash
# codex-perf-check.sh — check and fix performance opt-ins for OpenAI/Codex agents
#
# Four settings are off by default in GPT-5.x agents but significantly improve
# reasoning depth, execution follow-through, and response quality:
#   1. Strict execution mode    (embeddedPi.executionContract per agent)
#   2. GPT personality overlay  (plugins.entries.openai.config.personality)
#   3. Thinking level           (thinkingDefault global default + per agent)
#   4. Native Codex harness     (plugins.entries.codex + agents.defaults.embeddedHarness)
#
# Requires OpenClaw v2026.4.x or later — these settings do not exist in earlier releases.
#
# Run:
#   bash codex-perf-check.sh          # check only, no changes
#   bash codex-perf-check.sh --fix    # apply fixes for issues found
#
# Safe to re-run — idempotent.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

FIX_MODE=false
[[ "${1:-}" == "--fix" ]] && FIX_MODE=true

CONFIG="$HOME/.openclaw/openclaw.json"

ISSUES=()
FIXED=()
OK=()

echo ""
echo -e "${BLD}OpenClaw Codex/GPT-5.x Performance Check${RST}"
[[ "$FIX_MODE" == true ]] && echo -e "${CYN}(fix mode — changes will be applied)${RST}" || \
  echo -e "${YLW}(check only — run with --fix to apply changes)${RST}"
echo "────────────────────────────────────────────"

# ── Preflight ─────────────────────────────────────────────────────────────────
require_tools python3 openclaw || exit 1

if [[ ! -f "$CONFIG" ]]; then
  log_error "Missing $CONFIG — run openclaw onboard first"
  exit 1
fi

# ── Version gate ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BLD}[0] Version check (requires v2026.4.x+)${RST}"

CURRENT_VERSION="$(get_openclaw_version)"
if version_below "$CURRENT_VERSION" "v2026.4.0"; then
  log_warn "Detected $CURRENT_VERSION — these settings require v2026.4.x+"
  log_info "Upgrade: curl -fsSL https://openclaw.ai/install.sh | bash"
  ISSUES+=("version too old: $CURRENT_VERSION — upgrade to v2026.4.x+ first")
else
  log_ok "Version $CURRENT_VERSION (v2026.4.x+ confirmed)"
  OK+=("version ok")
fi

# ── 1. Strict Execution Mode ──────────────────────────────────────────────────
echo ""
echo -e "${BLD}[1] Strict execution mode (executionContract)${RST}"

AGENT_CONTRACT_STATUS="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
agents = d.get('agents', {}).get('list', [])
if not agents:
    print('no-agents')
    sys.exit(0)
missing = []
for a in agents:
    pid = a.get('id', '?')
    contract = a.get('embeddedPi', {}).get('executionContract', '')
    if contract != 'strict-agentic':
        missing.append(pid)
print(' '.join(missing) if missing else 'ok')
" "$CONFIG" 2>/dev/null || echo "error")"

if [[ "$AGENT_CONTRACT_STATUS" == "ok" ]]; then
  log_ok "All agents have executionContract=strict-agentic"
  OK+=("strict execution mode")
elif [[ "$AGENT_CONTRACT_STATUS" == "no-agents" ]]; then
  log_info "No agents found in agents.list — nothing to check"
elif [[ "$AGENT_CONTRACT_STATUS" == "error" ]]; then
  log_error "Could not read agents.list from config"
  ISSUES+=("could not read agents.list")
else
  log_warn "Missing strict-agentic on: $AGENT_CONTRACT_STATUS"
  if [[ "$FIX_MODE" == true ]]; then
    python3 -c "
import json, sys
f = sys.argv[1]
d = json.load(open(f))
agents = d.get('agents', {}).get('list', [])
for a in agents:
    if a.get('embeddedPi', {}).get('executionContract', '') != 'strict-agentic':
        a.setdefault('embeddedPi', {})['executionContract'] = 'strict-agentic'
with open(f, 'w') as out:
    json.dump(d, out, indent=2)
" "$CONFIG" 2>/dev/null && \
      log_ok "Set executionContract=strict-agentic on all agents" && \
      FIXED+=("executionContract=strict-agentic set on: $AGENT_CONTRACT_STATUS") || \
      log_error "Failed to write config"
  else
    ISSUES+=("executionContract not set on: $AGENT_CONTRACT_STATUS")
  fi
fi

# ── 2. GPT Personality Overlay ────────────────────────────────────────────────
echo ""
echo -e "${BLD}[2] GPT personality overlay (openai plugin)${RST}"

PERSONALITY_STATUS="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
p = d.get('plugins', {}).get('entries', {}).get('openai', {})
cfg = p.get('config', {})
val = cfg.get('personality', '') if isinstance(cfg, dict) else ''
print(val if val else 'not-set')
" "$CONFIG" 2>/dev/null || echo "error")"

if [[ "$PERSONALITY_STATUS" == "friendly" || "$PERSONALITY_STATUS" == "on" ]]; then
  log_ok "Personality overlay active (value: $PERSONALITY_STATUS)"
  OK+=("GPT personality overlay")
elif [[ "$PERSONALITY_STATUS" == "off" ]]; then
  log_warn "Personality overlay explicitly disabled (set to 'off')"
  ISSUES+=("personality overlay disabled — set to 'friendly' or 'on' to enable")
elif [[ "$PERSONALITY_STATUS" == "not-set" ]]; then
  log_warn "Personality overlay not set (plugins.entries.openai.config.personality)"
  if [[ "$FIX_MODE" == true ]]; then
    openclaw config set plugins.entries.openai.config.personality friendly 2>/dev/null && \
      log_ok "Set personality=friendly" && \
      FIXED+=("openai personality overlay set to friendly") || \
      log_error "Failed — set manually: openclaw config set plugins.entries.openai.config.personality friendly"
  else
    ISSUES+=("personality overlay not set")
  fi
elif [[ "$PERSONALITY_STATUS" == "error" ]]; then
  log_error "Could not read openai plugin config"
  ISSUES+=("could not read openai plugin config")
else
  log_info "Personality overlay value: $PERSONALITY_STATUS"
  OK+=("personality overlay (custom value: $PERSONALITY_STATUS)")
fi

# ── 3. Thinking Level ─────────────────────────────────────────────────────────
echo ""
echo -e "${BLD}[3] Thinking level (thinkingDefault)${RST}"

VALID_LEVELS=("minimal" "low" "medium" "high" "xhigh" "adaptive")

python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
defaults = d.get('agents', {}).get('defaults', {})
gval = defaults.get('thinkingDefault', 'NOT SET')
print(f'global: {gval}')
for a in d.get('agents', {}).get('list', []):
    aval = a.get('thinkingDefault', 'inherits')
    print(f'  {a[\"id\"]}: {aval}')
" "$CONFIG" 2>/dev/null || echo "error reading config"

GLOBAL_THINKING="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('agents', {}).get('defaults', {}).get('thinkingDefault', ''))
" "$CONFIG" 2>/dev/null || echo "")"

WEAK_LEVELS=("" "minimal" "low" "medium")
IS_WEAK=false
for lvl in "${WEAK_LEVELS[@]}"; do
  [[ "$GLOBAL_THINKING" == "$lvl" ]] && IS_WEAK=true && break
done

if [[ "$IS_WEAK" == true ]]; then
  LABEL="${GLOBAL_THINKING:-NOT SET}"
  log_warn "Global thinkingDefault is weak ($LABEL) — recommend 'high' or 'adaptive'"
  if [[ "$FIX_MODE" == true ]]; then
    openclaw config set agents.defaults.thinkingDefault adaptive 2>/dev/null && \
      log_ok "Set agents.defaults.thinkingDefault=adaptive" && \
      FIXED+=("global thinkingDefault set to adaptive") || \
      log_error "Failed — set manually: openclaw config set agents.defaults.thinkingDefault adaptive"
  else
    ISSUES+=("global thinkingDefault is '$LABEL' — recommend high or adaptive")
  fi
else
  log_ok "Global thinkingDefault: ${GLOBAL_THINKING:-not set (check per-agent overrides)}"
  OK+=("global thinking level")
fi

log_info "Note: xhigh is available but increases latency/cost noticeably — use per-agent for deep research tasks"
log_info "To set per-agent (e.g. atlas to xhigh), edit openclaw.json directly or use the Python one-liner in the skill docs"

# ── 4. Native Codex Harness ───────────────────────────────────────────────────
echo ""
echo -e "${BLD}[4] Native Codex harness${RST}"

CODEX_STATUS="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
plugin_enabled = d.get('plugins', {}).get('entries', {}).get('codex', {}).get('enabled', False)
harness = d.get('agents', {}).get('defaults', {}).get('embeddedHarness', {})
runtime = harness.get('runtime', '') if isinstance(harness, dict) else ''
print(f'plugin={plugin_enabled} runtime={runtime}')
" "$CONFIG" 2>/dev/null || echo "error")"

PLUGIN_ENABLED="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(str(d.get('plugins', {}).get('entries', {}).get('codex', {}).get('enabled', False)).lower())
" "$CONFIG" 2>/dev/null || echo "false")"

HARNESS_RUNTIME="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
h = d.get('agents', {}).get('defaults', {}).get('embeddedHarness', {})
print(h.get('runtime', '') if isinstance(h, dict) else '')
" "$CONFIG" 2>/dev/null || echo "")"

log_info "codex plugin enabled: $PLUGIN_ENABLED"
log_info "embeddedHarness.runtime: ${HARNESS_RUNTIME:-not set}"

HARNESS_OK=true
if [[ "$PLUGIN_ENABLED" != "true" ]]; then
  log_warn "Codex plugin not enabled (plugins.entries.codex.enabled)"
  HARNESS_OK=false
fi
if [[ "$HARNESS_RUNTIME" != "codex" ]]; then
  log_warn "embeddedHarness.runtime is not 'codex' (currently: '${HARNESS_RUNTIME:-not set}')"
  HARNESS_OK=false
fi

if [[ "$HARNESS_OK" == true ]]; then
  log_ok "Native Codex harness active"
  OK+=("native Codex harness")
elif [[ "$FIX_MODE" == true ]]; then
  openclaw config set plugins.entries.codex.enabled true 2>/dev/null && \
    log_ok "Set plugins.entries.codex.enabled=true" || log_error "Failed to enable codex plugin"
  openclaw config set agents.defaults.embeddedHarness.runtime codex 2>/dev/null && \
    log_ok "Set agents.defaults.embeddedHarness.runtime=codex" || log_error "Failed to set harness runtime"
  openclaw config set agents.defaults.embeddedHarness.fallback none 2>/dev/null && \
    log_ok "Set agents.defaults.embeddedHarness.fallback=none" || log_error "Failed to set harness fallback"
  FIXED+=("native Codex harness enabled")
  log_info "Note: set fallback=embedded if you want a safety net at the cost of native thread management"
else
  ISSUES+=("native Codex harness not configured")
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo -e "${BLD}Summary${RST}"
echo "════════════════════════════════════════════"

if [[ ${#FIXED[@]} -gt 0 ]]; then
  echo -e "${GRN}Fixed (${#FIXED[@]}):${RST}"
  for item in "${FIXED[@]}"; do echo "  + $item"; done
fi

if [[ ${#ISSUES[@]} -gt 0 ]]; then
  echo -e "${YLW}Issues (${#ISSUES[@]}):${RST}"
  for item in "${ISSUES[@]}"; do echo "  ! $item"; done
fi

if [[ ${#OK[@]} -gt 0 ]]; then
  echo -e "${GRN}Already correct (${#OK[@]}):${RST}"
  for item in "${OK[@]}"; do echo "  = $item"; done
fi

if [[ ${#FIXED[@]} -gt 0 ]]; then
  echo ""
  echo -e "${CYN}Restarting gateway to apply changes...${RST}"
  openclaw gateway restart 2>/dev/null && log_ok "Gateway restarted" || log_error "Gateway restart failed"
  echo ""
  echo -e "${GRN}Done. Send a test message to verify agent behavior.${RST}"
elif [[ ${#ISSUES[@]} -gt 0 ]]; then
  echo ""
  echo -e "${YLW}Run with --fix to apply the above changes:${RST}"
  echo "  bash codex-perf-check.sh --fix"
elif [[ ${#OK[@]} -gt 0 ]]; then
  echo ""
  echo -e "${GRN}All performance settings look good. No changes needed.${RST}"
fi
