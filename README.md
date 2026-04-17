# openclaw-ops

OpenClaw gateway operations skill for agent environments. Covers health checks, repair workflows, continuous monitoring, session analysis, update-change detection, and security review for a local or self-hosted OpenClaw install.

Tested against OpenClaw `2026.4.11`.

## What it does

### Skill
- **`/openclaw-ops`** — full triage and configuration: gateway, auth, exec approvals, cron jobs, channels, sessions, and installation

### Scripts

| Script | Purpose |
|--------|---------|
| `scripts/heal.sh` | One-shot auto-fix for the most common gateway issues |
| `scripts/post-update.sh` | Explicit post-update orchestrator: check-update, heal, workspace reconcile, security scan, final health check, policy-guard sentinel trigger |
| `scripts/watchdog.sh` | Runs every 5 min, restarts gateway if down, escalates after 3 failures |
| `scripts/watchdog-install.sh` | Installs the watchdog as a macOS LaunchAgent |
| `scripts/watchdog-uninstall.sh` | Removes the LaunchAgent |
| `scripts/check-update.sh` | Detects version changes, explains broken config, auto-fix with `--fix` |
| `scripts/health-check.sh` | Declarative URL/process health checks; auto-generates targets file on first run |
| `scripts/security-scan.sh` | Config hardening and credential exposure scan (0–100 score) |
| `scripts/skill-audit.sh` | Static security audit for third-party skills before installation |
| `scripts/codex-perf-check.sh` | Check and fix GPT-5.x performance opt-ins that ship disabled by default; `--fix` to apply |
| `scripts/session-monitor.sh` | Behavioral checks over live session JSONL files; detects retry loops, stuck runs, auth errors |
| `scripts/session-search.sh` | Full-text session search with structured output and secret redaction |
| `scripts/session-resume.sh` | Compaction-first markdown resume for a single session, including failure context |
| `scripts/prompt-truncation-report.sh` | Reports bootstrap truncation warnings from the latest session per agent |
| `scripts/cron-optimize.sh` | Audits agent cron jobs for missing `--light-context`; `--fix` applies the safe default |
| `scripts/cron-error-inspector.sh` | Formats erroring cron jobs from cron state with last error, reason, age, and payload preview |
| `scripts/agent-dirs-audit.sh` | Audits unconfigured dirs under `~/.openclaw/agents/`; optional archive/delete for safe candidates |
| `scripts/backup-rotate.sh` | Rotates generic `*.bak*` files across `~/.openclaw`, keeping the newest N per base path |
| `scripts/context-audit.sh` | Audits AGENTS / MEMORY / SOUL files for file-bloat risk using a token estimate (`chars / 4`) |
| `scripts/session-purge.sh` | Reclaims session bloat by trimming stale session rows, orphan transcripts, and old session backups |
| `scripts/daily-digest.sh` | Incident, activity, watchdog, and cost summary for the last N hours |
| `scripts/incident-manager.sh` | Shared incident lifecycle helper (sourced by other scripts) |
| `scripts/lib.sh` | Shared helpers: logging, port resolution, state files, sanitization (sourced) |

## Prerequisites

| Tool | Required for |
|------|-------------|
| `openclaw` | everything |
| `python3` | heal.sh, lib.sh, watchdog.sh, session scripts |
| `curl` | watchdog.sh, health-check.sh HTTP checks |
| `openssl` | heal.sh auth token generation |
| `rg` (ripgrep) | session-search.sh |
| `launchctl` + macOS | watchdog-install.sh (LaunchAgent) |
| `osascript` | watchdog.sh macOS notifications (optional) |

**Linux:** `watchdog-install.sh` is macOS only. Use cron instead:
```bash
*/5 * * * * bash /path/to/scripts/watchdog.sh >> ~/.openclaw/logs/watchdog.log 2>&1
```

## Minimum version

**v2026.2.12** or later. Versions before this contain critical CVEs (including CVE-2026-25253 plus additional SSRF, path traversal, and prompt-injection fixes).

```bash
openclaw --version
```

## Quick start

```bash
# 1. One-time heal pass
bash scripts/heal.sh

# 2. After every OpenClaw update, run the explicit post-update hook
bash scripts/post-update.sh

#    The hook also runs the VPS workspace reconcile script when present and
#    touches ~/.openclaw/state/policy-guard.trigger so a VPS can react through
#    openclaw-policy-guard.path after the update.

# 3. If you only want the update triage report:
bash scripts/check-update.sh        # report only
bash scripts/check-update.sh --fix  # report + auto-fix

# 4. Install always-on watchdog (macOS)
bash scripts/watchdog-install.sh

# 5. View watchdog log
tail -f ~/.openclaw/logs/watchdog.log

# 6. View incident history
cat ~/.openclaw/logs/heal-incidents.jsonl

# 7. Run health checks — targets file is auto-generated on first run
bash scripts/health-check.sh --verbose
```

### Gateway port

Scripts read the gateway port directly from `~/.openclaw/openclaw.json` — no hardcoded port, no manual setup. Override with the `OPENCLAW_GATEWAY_PORT` env var if needed.

### Session monitoring

```bash
# Scan all active sessions for behavioral issues
bash scripts/session-monitor.sh --verbose

# Search session history
bash scripts/session-search.sh "unauthorized" --limit 10

# Build a resume for a specific session
bash scripts/session-resume.sh ~/.openclaw/agents/knox/sessions/<session>.jsonl

# Bootstrap truncation warnings from latest sessions
bash scripts/prompt-truncation-report.sh
bash scripts/prompt-truncation-report.sh --agent atlas --json

# 24-hour digest: incidents, activity, costs
bash scripts/daily-digest.sh --hours 24
```

### Maintenance and cleanup

```bash
# Cron hygiene
bash scripts/cron-optimize.sh
bash scripts/cron-optimize.sh --fix --level low
bash scripts/cron-error-inspector.sh

# Agent directory hygiene
bash scripts/agent-dirs-audit.sh
bash scripts/agent-dirs-audit.sh --archive --delete-empty

# Generic backup rotation
bash scripts/backup-rotate.sh
bash scripts/backup-rotate.sh --apply --keep 3

# Oversized context files
bash scripts/context-audit.sh
bash scripts/context-audit.sh --agent atlas --threshold-tokens 10000 --json

# Session bloat cleanup
bash scripts/session-purge.sh
bash scripts/session-purge.sh --apply
```

## Watchdog escalation model

1. **Tier 1** — HTTP ping every 5 min (LaunchAgent or cron)
2. **Tier 2** — Gateway restart + `heal.sh` if simple restart fails
3. **Tier 3** — macOS notification after 3 failed attempts in 15 min

## Platform support

| Platform | heal.sh | watchdog | LaunchAgent |
|----------|---------|----------|-------------|
| macOS | ✓ | ✓ | ✓ |
| Linux | ✓ | ✓ (via cron) | ✗ |
| Windows WSL2 | ✓ | ✓ (via cron) | ✗ |

## Viewing logs

**macOS:**
```bash
tail -f ~/.openclaw/logs/gateway.err.log
tail -f ~/.openclaw/logs/watchdog.log
```

**Linux (systemd):**
```bash
journalctl --user -u openclaw-gateway -f
```

## Notes

- `health-check.sh` creates `~/.openclaw/health-targets.conf` automatically on first run using the port from `openclaw.json`. Edit the file to add custom targets or adjust thresholds.
- `health-check.sh` can report a process uptime failure immediately after `openclaw gateway restart` if the target has a minimum uptime threshold (e.g. 300s). That is expected — lower the threshold during smoke tests, then restore it.
- `security-scan.sh` reports file paths and line numbers for suspected secrets, but redacts the secret values themselves.
- `check-update.sh` is intended for real post-upgrade triage. It is normal to report a version change the first time it runs after an upgrade.
- `post-update.sh` is the explicit post-update orchestrator. It skips the heavy sequence when the current version matches the stored state and otherwise runs `check-update.sh --fix`, `heal.sh`, the workspace reconcile script if present, `security-scan.sh`, and a final `openclaw health --json`.
- On the VPS, the workspace reconcile stage refreshes model policy, auth/profile state, voice defaults, and the gateway service through `openclaw_post_update_reconcile.py` (or the equivalent systemd oneshot wrapper).
- After the health check it best-effort touches `~/.openclaw/state/policy-guard.trigger` (creating parent dirs if needed). The VPS can wire `openclaw-policy-guard.path` to that sentinel after updates.
- Set `OPENCLAW_POST_UPDATE_RECONCILE_SCRIPT` (and optionally `OPENCLAW_POST_UPDATE_RECONCILE_INTERPRETER`) if the reconcile script lives somewhere other than the default workspace path.
- If another wrapper or automation layer launches the post-update hook, set `OPENCLAW_SKIP_WRAPPER_BACKUP=1` for nested `openclaw` calls so internal subcommands do not trigger backup loops.
- `codex-perf-check.sh` requires v2026.4.x or later — the four settings it checks do not exist in earlier releases.
- `prompt-truncation-report.sh` and `context-audit.sh` are intentionally separate: one shows runtime truncation warnings, the other shows oversized source files.
- `session-purge.sh` is session-specific cleanup; `backup-rotate.sh` is the broader backup-file cleanup pass across all of `~/.openclaw`.

## Running tests

```bash
bash tests/run.sh
```

## Open-Source Release Checklist

- Remove any local `~/.openclaw` state, logs, or example outputs from the repository.
- Do not publish screenshots or pasted scan output that contain real tokens, session material, or private channel identifiers.
- Keep examples generic: placeholder tokens, placeholder user IDs, and non-sensitive hostnames only.
- Run `bash tests/run.sh` before publishing changes.
