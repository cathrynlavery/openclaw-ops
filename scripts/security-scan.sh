#!/usr/bin/env bash
# security-scan.sh — OpenClaw config hardening and compliance scoring
# Run: bash security-scan.sh [--fix] [--drift] [--credentials]
# Default (no flags): run full compliance check + credential scan

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

# ── Preflight ────────────────────────────────────────────────────────────────
require_tools openclaw python3 openssl || exit 1
CONFIG_FILE="$(openclaw config file 2>/dev/null || echo "$HOME/.openclaw/openclaw.json")"
CONFIG_FILE="$(python3 -c 'import os, sys; print(os.path.expanduser(sys.argv[1]))' "$CONFIG_FILE" 2>/dev/null || echo "$HOME/.openclaw/openclaw.json")"

# ── Flags ────────────────────────────────────────────────────────────────────
FLAG_FIX=false
FLAG_DRIFT=false
FLAG_CREDENTIALS=false
FLAG_DEFAULT=true   # no flags = full scan

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix)         FLAG_FIX=true;         FLAG_DEFAULT=false; shift ;;
    --drift)       FLAG_DRIFT=true;       FLAG_DEFAULT=false; shift ;;
    --credentials) FLAG_CREDENTIALS=true; FLAG_DEFAULT=false; shift ;;
    *)             echo "Unknown flag: $1"; echo "Usage: security-scan.sh [--fix] [--drift] [--credentials]"; exit 1 ;;
  esac
done

# Default mode: run everything
if [[ "$FLAG_DEFAULT" == "true" ]]; then
  FLAG_CREDENTIALS=true
fi

# ── Globals ──────────────────────────────────────────────────────────────────
SCORE=100
FIXES_APPLIED=()
FIXES_SUGGESTED=()

deduct() {
  local points="$1" reason="$2"
  SCORE=$((SCORE - points))
  log_error "$reason (-${points})"
}

pass() {
  log_ok "$1"
}

config_get_optional() {
  openclaw config get "$1" 2>/dev/null || true
}

enabled_channel_dm_policy_status() {
  python3 -c '
import json, sys

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print("OK:")
    print("BAD:")
    print("MISSING:")
    raise SystemExit(0)

ok = []
bad = []
missing = []

for name, cfg in (data.get("channels") or {}).items():
    if not isinstance(cfg, dict) or not cfg.get("enabled"):
        continue

    policy = cfg.get("dmPolicy")
    if policy is None:
        missing.append(name)
    elif policy in ("pairing", "allowlist"):
        ok.append(f"{name}={policy}")
    else:
        bad.append(f"{name}={policy}")

print("OK:" + ",".join(ok))
print("BAD:" + ",".join(bad))
print("MISSING:" + ",".join(missing))
' "$CONFIG_FILE" 2>/dev/null || printf 'OK:\nBAD:\nMISSING:\n'
}

exec_auto_allow_skills() {
  python3 -c '
import json, sys

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print("")
    raise SystemExit(0)

value = (data.get("defaults") or {}).get("autoAllowSkills")
if value is None:
    print("")
elif value:
    print("true")
else:
    print("false")
' "$HOME/.openclaw/exec-approvals.json" 2>/dev/null || true
}

redact_match() {
  local match="$1"
  if [[ "$match" =~ ^(.*):([0-9]+): ]]; then
    printf '%s:%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '%s' "${match%%:*}"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Compliance Checks (scored 0-100)
# ══════════════════════════════════════════════════════════════════════════════
run_compliance() {
  echo ""
  echo -e "${BLD}OpenClaw Security Compliance Scan${RST}"
  echo "──────────────────────────────────────"

  # ── 1. Gateway binding (-20) ─────────────────────────────────────────────
  echo ""
  echo -e "${BLD}[1/7] Gateway binding${RST}"
  BIND=$(openclaw config get gateway.bind 2>/dev/null || echo "unknown")
  if [[ "$BIND" == "loopback" ]] || [[ "$BIND" == "127.0.0.1" ]]; then
    pass "gateway.bind = $BIND (loopback only)"
  else
    deduct 20 "gateway.bind = $BIND (should be loopback or 127.0.0.1)"
    if [[ "$FLAG_FIX" == "true" ]]; then
      FIXES_SUGGESTED+=("openclaw config set gateway.bind loopback")
      log_warn "  Suggested fix: openclaw config set gateway.bind loopback"
    fi
  fi

  # ── 2. Auth mode (-15) ───────────────────────────────────────────────────
  echo ""
  echo -e "${BLD}[2/7] Auth mode${RST}"
  AUTH=$(openclaw config get gateway.auth.mode 2>/dev/null || echo "unknown")
  if [[ "$AUTH" == "token" ]] || [[ "$AUTH" == "trusted-proxy" ]]; then
    pass "gateway.auth.mode = $AUTH"
  else
    deduct 15 "gateway.auth.mode = $AUTH (should be token or trusted-proxy)"
    if [[ "$FLAG_FIX" == "true" ]]; then
      FIXES_SUGGESTED+=("openclaw config set gateway.auth.mode token")
      log_warn "  Suggested fix: openclaw config set gateway.auth.mode token"
    fi
  fi

  # ── 3. Sandbox mode (-15) ────────────────────────────────────────────────
  echo ""
  echo -e "${BLD}[3/7] Sandbox mode${RST}"
  SANDBOX="$(config_get_optional agents.defaults.sandbox.mode)"
  if [[ "$SANDBOX" == "all" ]] || [[ "$SANDBOX" == "non-main" ]]; then
    pass "agents.defaults.sandbox.mode = $SANDBOX"
  elif [[ -z "$SANDBOX" ]]; then
    log_info "agents.defaults.sandbox.mode is not explicitly set in this config"
  else
    deduct 15 "agents.defaults.sandbox.mode = $SANDBOX (should be all or non-main)"
  fi

  # ── 4. DM policy (-15) ──────────────────────────────────────────────────
  echo ""
  echo -e "${BLD}[4/7] DM policy${RST}"
  DM_STATUS="$(enabled_channel_dm_policy_status)"
  DM_OK="$(printf '%s\n' "$DM_STATUS" | sed -n '1s/^OK://p')"
  DM_BAD="$(printf '%s\n' "$DM_STATUS" | sed -n '2s/^BAD://p')"
  DM_MISSING="$(printf '%s\n' "$DM_STATUS" | sed -n '3s/^MISSING://p')"
  if [[ -n "$DM_BAD" ]]; then
    deduct 15 "enabled channel dmPolicy values need review: ${DM_BAD//,/ }"
  elif [[ -n "$DM_OK" ]]; then
    pass "enabled channel dmPolicy values OK: ${DM_OK//,/ }"
    if [[ -n "$DM_MISSING" ]]; then
      log_info "dmPolicy not set on enabled channels: ${DM_MISSING//,/ }"
    fi
  else
    log_info "No enabled channel dmPolicy values found in $CONFIG_FILE"
  fi

  # ── 5. Exec approval skill auto-allow (-10) ────────────────────────────
  echo ""
  echo -e "${BLD}[5/7] Exec approval auto-allow${RST}"
  AUTO_ALLOW_SKILLS="$(exec_auto_allow_skills)"
  if [[ "$AUTO_ALLOW_SKILLS" == "false" ]]; then
    pass "defaults.autoAllowSkills = false"
  elif [[ "$AUTO_ALLOW_SKILLS" == "true" ]]; then
    deduct 10 "defaults.autoAllowSkills = true (widens host exec trust)"
  else
    log_info "defaults.autoAllowSkills not set in ~/.openclaw/exec-approvals.json"
  fi

  # ── 6. Version (-20) ────────────────────────────────────────────────────
  echo ""
  echo -e "${BLD}[6/7] Version check${RST}"
  CURRENT_VERSION=$(get_openclaw_version)
  if [[ "$CURRENT_VERSION" == "unknown" ]]; then
    deduct 20 "Could not determine OpenClaw version"
  elif version_below "$CURRENT_VERSION" "v2026.2.12"; then
    deduct 20 "Version $CURRENT_VERSION is below required v2026.2.12"
  else
    pass "Version $CURRENT_VERSION >= v2026.2.12"
  fi

  # ── 7. Multi-user heuristic (-5) ────────────────────────────────────────
  echo ""
  echo -e "${BLD}[7/7] Multi-user heuristic${RST}"
  MULTI_USER="$(config_get_optional security.trust_model.multi_user_heuristic)"
  if [[ "$MULTI_USER" == "true" ]]; then
    pass "security.trust_model.multi_user_heuristic = true"
  elif [[ -z "$MULTI_USER" ]]; then
    log_info "security.trust_model.multi_user_heuristic is not explicitly set"
  else
    # Only deduct if version supports it (v2026.2.24+)
    if [[ "$CURRENT_VERSION" != "unknown" ]] && ! version_below "$CURRENT_VERSION" "v2026.2.24"; then
      deduct 5 "multi_user_heuristic = $MULTI_USER (should be true for v2026.2.24+)"
    else
      log_info "multi_user_heuristic not applicable (requires v2026.2.24+, running $CURRENT_VERSION)"
    fi
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Credential Scanning
# ══════════════════════════════════════════════════════════════════════════════
run_credentials() {
  echo ""
  echo -e "${BLD}Credential Scan${RST}"
  echo "──────────────────────────────────────"

  local CRED_ISSUES=0
  local CONFIG_DIR="$HOME/.openclaw"
  local BACKUP_DIR="$HOME/.openclaw-update-backups"
  local SYSTEMD_USER_DIR="${OPENCLAW_SECURITY_SCAN_SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
  local SYSTEMD_SYSTEM_DIR="${OPENCLAW_SECURITY_SCAN_SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"

  local scan_roots=()
  for root in "$CONFIG_DIR" "$BACKUP_DIR" "$SYSTEMD_USER_DIR" "$SYSTEMD_SYSTEM_DIR"; do
    [[ -d "$root" ]] && scan_roots+=("$root")
  done

  if [[ ${#scan_roots[@]} -eq 0 ]]; then
    log_warn "No OpenClaw config roots found — skipping credential scan"
    return
  fi

  # ── Secret patterns (same 20 as skill-audit.sh) ────────────────────────
  echo ""
  echo -e "${BLD}[cred] Scanning config files for leaked secrets...${RST}"
  local SECRET_PATTERNS=(
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
    'shpat_[a-zA-Z0-9]{32,}'
    'glpat-[a-zA-Z0-9_-]{20,}'
    'npm_[a-zA-Z0-9]{36}'
    'pypi-[a-zA-Z0-9]{32,}'
    'SG\.[a-zA-Z0-9_-]{22}\.[a-zA-Z0-9_-]{43}'
    'sq0atp-[a-zA-Z0-9_-]{22}'
    'AC[a-f0-9]{32}'
    'eyJ[a-zA-Z0-9_-]{20,}\.eyJ[a-zA-Z0-9_-]{20,}'
    'dop_v1_[a-f0-9]{64}'
    'vault\.hashicorp\.com/.*token'
  )
  local FILE_MATCH_ARGS=(
    -name '*.json' -o
    -name '*.jsonl' -o
    -name '*.yaml' -o
    -name '*.yml' -o
    -name '*.toml' -o
    -name '*.conf' -o
    -name '*.env' -o
    -name '*.service' -o
    -name '*.ini' -o
    -name '*.log' -o
    -name '*.bak' -o
    -name '*.bak.*' -o
    -name '*.backup'
  )

  local secret_count=0
  for pat in "${SECRET_PATTERNS[@]}"; do
    while IFS= read -r -d '' cfg_file; do
      while IFS= read -r match; do
        [[ -z "$match" ]] && continue
        # Skip false positives
        if echo "$match" | grep -iqE '(example|template|placeholder|your-|TODO|sample|demo)'; then
          continue
        fi
        log_error "  Secret found: $(redact_match "$match")"
        ((secret_count++)) || true
      done < <(grep -nH -E "$pat" "$cfg_file" 2>/dev/null || true)
    done < <(
      find "${scan_roots[@]}" -type f \( "${FILE_MATCH_ARGS[@]}" \) -print0 2>/dev/null || true
    )
  done

  if [[ $secret_count -eq 0 ]]; then
    log_ok "No leaked secrets in config files"
  else
    log_error "Found $secret_count secret pattern(s) in config files"
    ((CRED_ISSUES += secret_count)) || true
  fi

  # ── File permissions ───────────────────────────────────────────────────
  echo ""
  echo -e "${BLD}[cred] Checking file permissions...${RST}"

  # Credentials directory should be 700
  local CRED_DIR="$CONFIG_DIR/credentials"
  if [[ -d "$CRED_DIR" ]]; then
    local dir_perms
    dir_perms=$(file_perms "$CRED_DIR")
    if [[ "$dir_perms" != "700" ]]; then
      log_error "  $CRED_DIR has permissions $dir_perms (should be 700)"
      ((CRED_ISSUES++)) || true
      if [[ "$FLAG_FIX" == "true" ]]; then
        chmod 700 "$CRED_DIR" && {
          log_ok "  Fixed: chmod 700 $CRED_DIR"
          FIXES_APPLIED+=("chmod 700 $CRED_DIR")
        }
      fi
    else
      log_ok "credentials/ directory: 700"
    fi
  fi

  # Config files should be 600
  local perm_issues=0
  while IFS= read -r cfg_file; do
    [[ -z "$cfg_file" ]] && continue
    local fperms
    fperms=$(file_perms "$cfg_file")
    if [[ "$fperms" != "600" ]] && [[ "$fperms" != "400" ]]; then
      log_error "  $cfg_file has permissions $fperms (should be 600)"
      ((perm_issues++)) || true
      ((CRED_ISSUES++)) || true
      if [[ "$FLAG_FIX" == "true" ]]; then
        chmod 600 "$cfg_file" && {
          log_ok "  Fixed: chmod 600 $cfg_file"
          FIXES_APPLIED+=("chmod 600 $(basename "$cfg_file")")
        }
      fi
    fi
  done < <(
    find "${scan_roots[@]}" -type f \( "${FILE_MATCH_ARGS[@]}" \) 2>/dev/null || true
  )

  if [[ $perm_issues -eq 0 ]]; then
    log_ok "Config file permissions OK"
  fi

  if [[ $CRED_ISSUES -eq 0 ]]; then
    echo ""
    log_ok "Credential scan clean"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Drift Detection
# ══════════════════════════════════════════════════════════════════════════════
run_drift() {
  echo ""
  echo -e "${BLD}Skill File Drift Detection${RST}"
  echo "──────────────────────────────────────"

  local SKILLS_DIR="$HOME/.openclaw/skills"
  local BASELINE="$HOME/.openclaw/security/skill-hashes.json"
  local BASELINE_DIR
  BASELINE_DIR="$(dirname "$BASELINE")"

  if [[ ! -d "$SKILLS_DIR" ]]; then
    log_warn "No ~/.openclaw/skills/ directory — nothing to scan"
    return
  fi

  mkdir -p "$BASELINE_DIR"

  # Build current hash map using python3 (no shell interpolation)
  local CURRENT_HASHES
  CURRENT_HASHES=$(python3 -c "
import json, subprocess, sys, os

skills_dir = sys.argv[1]
hashes = {}
for root, dirs, files in os.walk(skills_dir):
    for f in files:
        path = os.path.join(root, f)
        relpath = os.path.relpath(path, skills_dir)
        result = subprocess.run(
            ['shasum', '-a', '256', path],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            hashes[relpath] = result.stdout.strip().split()[0]
        else:
            # fallback to openssl
            result2 = subprocess.run(
                ['openssl', 'dgst', '-sha256', path],
                capture_output=True, text=True
            )
            if result2.returncode == 0:
                hashes[relpath] = result2.stdout.strip().split()[-1]
            else:
                hashes[relpath] = 'error'
print(json.dumps(hashes))
" "$SKILLS_DIR" 2>/dev/null)

  if [[ ! -f "$BASELINE" ]]; then
    # First run: create baseline
    echo "$CURRENT_HASHES" > "$BASELINE"
    local file_count
    file_count=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
print(len(data))
" "$CURRENT_HASHES" 2>/dev/null)
    log_ok "Baseline created with $file_count files at $BASELINE"
    return
  fi

  # Compare against baseline
  python3 -c "
import json, sys

baseline_path = sys.argv[1]
current_json = sys.argv[2]

with open(baseline_path) as f:
    baseline = json.load(f)

current = json.loads(current_json)

new_files = sorted(set(current.keys()) - set(baseline.keys()))
removed_files = sorted(set(baseline.keys()) - set(current.keys()))
modified_files = sorted(
    k for k in set(current.keys()) & set(baseline.keys())
    if current[k] != baseline[k]
)

changes = len(new_files) + len(removed_files) + len(modified_files)

for f in new_files:
    print(f'  [NEW]      {f}')
for f in modified_files:
    print(f'  [MODIFIED] {f}')
for f in removed_files:
    print(f'  [REMOVED]  {f}')

if changes == 0:
    print('  No drift detected')
else:
    print(f'  {changes} file(s) changed since baseline')
" "$BASELINE" "$CURRENT_HASHES" 2>/dev/null

  # Prompt to update baseline
  echo ""
  log_info "To update baseline: cp current hashes over baseline"
  log_info "  Run: bash -c 'echo $(printf '%q' "$CURRENT_HASHES") > $BASELINE'"
}

# ══════════════════════════════════════════════════════════════════════════════
# Auto-fix mode
# ══════════════════════════════════════════════════════════════════════════════
print_fix_summary() {
  if [[ ${#FIXES_APPLIED[@]} -gt 0 ]]; then
    echo ""
    echo -e "${GRN}Auto-fixes applied:${RST}"
    for fix in "${FIXES_APPLIED[@]}"; do
      echo "  [fixed] $fix"
    done
  fi

  if [[ ${#FIXES_SUGGESTED[@]} -gt 0 ]]; then
    echo ""
    echo -e "${YLW}Suggested fixes (manual — review before applying):${RST}"
    for fix in "${FIXES_SUGGESTED[@]}"; do
      echo "  [manual] $fix"
    done
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════

# Always run compliance
run_compliance

# Credential scan (default or --credentials)
if [[ "$FLAG_CREDENTIALS" == "true" ]]; then
  run_credentials
fi

# Drift detection (--drift only)
if [[ "$FLAG_DRIFT" == "true" ]]; then
  run_drift
fi

# Fix summary
if [[ "$FLAG_FIX" == "true" ]]; then
  print_fix_summary
fi

# ── Final score ──────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
if [[ $SCORE -ge 80 ]]; then
  echo -e "${GRN}${BLD}Compliance Score: ${SCORE}/100${RST} ${GRN}PASS${RST}"
else
  echo -e "${RED}${BLD}Compliance Score: ${SCORE}/100${RST} ${RED}FAIL${RST}"
fi
echo "════════════════════════════════════════"
echo ""

if [[ $SCORE -lt 80 ]]; then
  exit 1
fi
