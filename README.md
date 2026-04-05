# openclaw-ops

OpenClaw gateway operations skill for agent environments. Covers health checks, repair workflows, continuous monitoring, session analysis, update-change detection, and security review for a local or self-hosted OpenClaw install.

Tested against OpenClaw `2026.4.2`.

## What it does

### Skill
- **`/openclaw-ops`** — full triage and configuration: gateway, auth, exec approvals, cron jobs, channels, sessions, and installation

### Scripts

| Script | Purpose |
|--------|---------|
| `scripts/heal.sh` | One-shot auto-fix for the most common gateway issues |
| `scripts/watchdog.sh` | Runs every 5 min, restarts gateway if down, escalates after 3 failures |
| `scripts/watchdog-install.sh` | Installs the watchdog as a macOS LaunchAgent |
| `scripts/watchdog-uninstall.sh` | Removes the LaunchAgent |
| `scripts/check-update.sh` | Detects version changes, explains broken config, auto-fix with `--fix` |
| `scripts/health-check.sh` | Declarative URL/process health checks; auto-generates targets file on first run |
| `scripts/security-scan.sh` | Config hardening and credential exposure scan (0–100 score) |
| `scripts/skill-audit.sh` | Static security audit for third-party skills before installation |
| `scripts/fix-cli-backend.sh` | Fixes Claude CLI subprocess backend config (wizard sets wrong key) |
| `scripts/session-monitor.sh` | Behavioral checks over live session JSONL files; detects retry loops, stuck runs, auth errors |
| `scripts/session-search.sh` | Full-text session search with structured output and secret redaction |
| `scripts/session-resume.sh` | Compaction-first markdown resume for a single session, including failure context |
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

# 2. Check if an update broke your config
bash scripts/check-update.sh        # report only
bash scripts/check-update.sh --fix  # report + auto-fix

# 3. Install always-on watchdog (macOS)
bash scripts/watchdog-install.sh

# 4. View watchdog log
tail -f ~/.openclaw/logs/watchdog.log

# 5. View incident history
cat ~/.openclaw/logs/heal-incidents.jsonl

# 6. Run health checks — targets file is auto-generated on first run
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

# 24-hour digest: incidents, activity, costs
bash scripts/daily-digest.sh --hours 24
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
- The `startup model warmup failed for claude-cli/...` warning in `gateway.err.log` is non-fatal and expected when using the Claude CLI subprocess backend.

## Running tests

```bash
bash tests/run.sh
```

## Open-Source Release Checklist

- Remove any local `~/.openclaw` state, logs, or example outputs from the repository.
- Do not publish screenshots or pasted scan output that contain real tokens, session material, or private channel identifiers.
- Keep examples generic: placeholder tokens, placeholder user IDs, and non-sensitive hostnames only.
- Run `bash tests/run.sh` before publishing changes.
