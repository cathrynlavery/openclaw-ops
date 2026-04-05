#!/usr/bin/env bash
set -euo pipefail

# ── Source shared library ──────────────────────────────────────────────────
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

require_tools grep

# ── Usage ──────────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "Usage: skill-audit.sh <path-to-skill-directory>"
  exit 1
fi

SKILL_DIR="$1"

if [[ ! -d "$SKILL_DIR" ]]; then
  log_error "Directory not found: $SKILL_DIR"
  exit 1
fi

TOTAL_FINDINGS=0

# ── File type includes for code/config scans ───────────────────────────────
CODE_INCLUDES=(--include='*.sh' --include='*.py' --include='*.js' --include='*.json' --include='*.yaml' --include='*.yml' --include='*.md')

# ── Helper: run a grep pattern and report findings ─────────────────────────
# Filters out false-positive lines containing common placeholder words.
# Returns the count of real findings.
scan_pattern() {
  local label="$1" pattern="$2"
  shift 2
  local includes=("$@")
  local count=0

  while IFS= read -r line; do
    # Filter false positives (case-insensitive check)
    if echo "$line" | grep -iqE '(example|template|placeholder|your-|TODO|<\.\.\.>|sample|demo)'; then
      continue
    fi
    log_warn "  $line" >&2
    ((count++)) || true
  done < <(grep -rnE "$pattern" "${includes[@]}" "$SKILL_DIR" 2>/dev/null || true)

  echo "$count"
}

# ══════════════════════════════════════════════════════════════════════════
# 1. Hardcoded secrets
# ══════════════════════════════════════════════════════════════════════════
scan_secrets() {
  log_info "${BLD}[1/5] Scanning for hardcoded secrets...${RST}" >&2
  local count=0

  local patterns=(
    'sk-ant-[a-zA-Z0-9_-]{48,}'
    'sk-[a-zA-Z0-9]{20,}'
    'ghp_[a-zA-Z0-9]{36}'
    'xoxb-[0-9]{10,13}-[0-9]{10,13}-[a-zA-Z0-9]{24,32}'
    'AKIA[0-9A-Z]{16}'
    'AIza[0-9A-Za-z_-]{35}'
    'sk_live_[a-zA-Z0-9]{24,}'
    '-----BEGIN (RSA|OPENSSH|PRIVATE) KEY-----'
    'xoxp-[0-9]{10,13}'
    'rk_live_[a-zA-Z0-9]{24,}'
  )

  for pat in "${patterns[@]}"; do
    local n
    n=$(scan_pattern "secret" "$pat" "${CODE_INCLUDES[@]}")
    ((count += n)) || true
  done

  if [[ $count -eq 0 ]]; then
    log_ok "No hardcoded secrets found" >&2
  else
    log_error "Found $count hardcoded secret(s)" >&2
  fi
  echo "$count"
}

# ══════════════════════════════════════════════════════════════════════════
# 2. Suspicious network calls
# ══════════════════════════════════════════════════════════════════════════
scan_network() {
  log_info "${BLD}[2/5] Scanning for suspicious network calls...${RST}" >&2
  local count=0 n

  # curl/wget with file upload or POST data
  n=$(scan_pattern "network" '(curl|wget)\s.*-(F|d)\s' "${CODE_INCLUDES[@]}")
  ((count += n)) || true

  n=$(scan_pattern "network" '(curl|wget)\s.*--post-data' "${CODE_INCLUDES[@]}")
  ((count += n)) || true

  # curl piping file content
  n=$(scan_pattern "network" 'curl.*\$\(cat' "${CODE_INCLUDES[@]}")
  ((count += n)) || true

  # Network calls to raw IP addresses
  n=$(scan_pattern "network" '(curl|wget|http|https)://[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' "${CODE_INCLUDES[@]}")
  ((count += n)) || true

  # Suspicious domains
  n=$(scan_pattern "network" '(pastebin\.com|hastebin|\.onion|\.bit)' "${CODE_INCLUDES[@]}")
  ((count += n)) || true

  if [[ $count -eq 0 ]]; then
    log_ok "No suspicious network calls found" >&2
  else
    log_error "Found $count suspicious network call(s)" >&2
  fi
  echo "$count"
}

# ══════════════════════════════════════════════════════════════════════════
# 3. Dangerous shell commands
# ══════════════════════════════════════════════════════════════════════════
scan_dangerous() {
  log_info "${BLD}[3/5] Scanning for dangerous shell commands...${RST}" >&2
  local count=0 n

  # chmod 777
  n=$(scan_pattern "dangerous" 'chmod\s+777' "${CODE_INCLUDES[@]}")
  ((count += n)) || true

  # rm -rf /
  n=$(scan_pattern "dangerous" 'rm\s+-rf\s+/' "${CODE_INCLUDES[@]}")
  ((count += n)) || true

  # kill -9 -1 (kill all processes)
  n=$(scan_pattern "dangerous" 'kill\s+-9\s+-1' "${CODE_INCLUDES[@]}")
  ((count += n)) || true

  # sudoers / cron manipulation
  n=$(scan_pattern "dangerous" 'echo\s.*>>\s*/etc/(sudoers|cron)' "${CODE_INCLUDES[@]}")
  ((count += n)) || true

  # Backdoor injection into system dirs
  n=$(scan_pattern "dangerous" '(mv|cp)\s+.*\s+/(usr/bin|lib)' "${CODE_INCLUDES[@]}")
  ((count += n)) || true

  # Disk overwrite
  n=$(scan_pattern "dangerous" 'dd\s+if=.*of=/dev' "${CODE_INCLUDES[@]}")
  ((count += n)) || true

  if [[ $count -eq 0 ]]; then
    log_ok "No dangerous shell commands found" >&2
  else
    log_error "Found $count dangerous shell command(s)" >&2
  fi
  echo "$count"
}

# ══════════════════════════════════════════════════════════════════════════
# 4. Prompt injection in markdown
# ══════════════════════════════════════════════════════════════════════════
scan_prompt_injection() {
  log_info "${BLD}[4/5] Scanning for prompt injection patterns...${RST}" >&2
  local count=0 n
  local md_includes=(--include='*.md' --include='*.txt')

  n=$(scan_pattern "injection" 'ignore.*instruction' "${md_includes[@]}")
  ((count += n)) || true

  n=$(scan_pattern "injection" 'forget.*previous' "${md_includes[@]}")
  ((count += n)) || true

  n=$(scan_pattern "injection" 'disregard.*prompt' "${md_includes[@]}")
  ((count += n)) || true

  n=$(scan_pattern "injection" 'pretend.*to be' "${md_includes[@]}")
  ((count += n)) || true

  n=$(scan_pattern "injection" 'bypass.*restriction' "${md_includes[@]}")
  ((count += n)) || true

  n=$(scan_pattern "injection" 'reveal.*password' "${md_includes[@]}")
  ((count += n)) || true

  n=$(scan_pattern "injection" 'show.*secret' "${md_includes[@]}")
  ((count += n)) || true

  if [[ $count -eq 0 ]]; then
    log_ok "No prompt injection patterns found" >&2
  else
    log_error "Found $count prompt injection pattern(s)" >&2
  fi
  echo "$count"
}

# ══════════════════════════════════════════════════════════════════════════
# 5. File structure validation
# ══════════════════════════════════════════════════════════════════════════
scan_structure() {
  log_info "${BLD}[5/5] Validating file structure...${RST}" >&2
  local count=0

  if [[ ! -f "$SKILL_DIR/SKILL.md" ]]; then
    log_warn "  Missing required SKILL.md" >&2
    ((count++)) || true
  else
    log_ok "SKILL.md present" >&2
  fi

  echo "$count"
}

# ══════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BLD}═══ OpenClaw Skill Security Audit ═══${RST}"
echo -e "Target: ${CYN}$SKILL_DIR${RST}"
echo ""

secrets_count=$(scan_secrets)
echo ""
network_count=$(scan_network)
echo ""
dangerous_count=$(scan_dangerous)
echo ""
injection_count=$(scan_prompt_injection)
echo ""
structure_count=$(scan_structure)
echo ""

TOTAL_FINDINGS=$((secrets_count + network_count + dangerous_count + injection_count + structure_count))

# ── Summary ────────────────────────────────────────────────────────────────
echo -e "${BLD}═══ Audit Summary ═══${RST}"
echo -e "  Hardcoded secrets:      $secrets_count"
echo -e "  Suspicious network:     $network_count"
echo -e "  Dangerous commands:     $dangerous_count"
echo -e "  Prompt injection:       $injection_count"
echo -e "  Structure issues:       $structure_count"
echo -e "  ${BLD}Total findings:         $TOTAL_FINDINGS${RST}"
echo ""

if [[ $TOTAL_FINDINGS -eq 0 ]]; then
  log_ok "${GRN}Risk: LOW${RST} — no findings"
  exit 0
elif [[ $TOTAL_FINDINGS -le 2 ]]; then
  log_warn "${YLW}Risk: MEDIUM${RST} — $TOTAL_FINDINGS finding(s), review recommended"
  exit 1
else
  log_error "${RED}Risk: HIGH${RST} — $TOTAL_FINDINGS finding(s), do not install without review"
  exit 2
fi
