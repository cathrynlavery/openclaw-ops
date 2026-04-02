# openclaw-ops

OpenClaw updates break things. Gateway goes down, exec approvals start blocking your agents, config fields get reset by new defaults — and none of it announces itself. You just notice your agents have gone quiet.

This is the ops layer I built to handle that. It keeps the gateway healthy, auto-repairs the most common breakages, and tells you exactly what changed when an update rolls through. I give it to every agent environment I run.

Tested against OpenClaw `2026.4.2`.

## What it does

**As a Claude skill** — load `/openclaw-ops` and your AI does the triage: checks gateway health, auth, exec approvals, cron jobs, channels, and sessions, then explains what is broken and fixes it.

**As standalone scripts** — run these directly from any shell:

- `scripts/heal.sh` — one-shot auto-fix for the most common gateway issues
- `scripts/check-update.sh` — detects version changes and explains what config broke and why
- `scripts/watchdog.sh` — runs every 5 minutes, restarts gateway if down, escalates after 3 failures
- `scripts/watchdog-install.sh` — installs the watchdog as a macOS LaunchAgent (survives reboots)
- `scripts/health-check.sh` — declarative URL/process health checks for gateway-adjacent dependencies
- `scripts/security-scan.sh` — config hardening and credential exposure scan with redacted findings
- `scripts/skill-audit.sh` — static audit for third-party skills before installation

## Install

Clone into your OpenClaw skills folder:

```bash
git clone https://github.com/cathrynlavery/openclaw-ops.git ~/.openclaw/skills/openclaw-ops
```

Then run scripts from that path:

```bash
cd ~/.openclaw/skills/openclaw-ops
bash scripts/heal.sh
```

## Prerequisites

| Tool | Required for |
|------|-------------|
| `openclaw` | everything |
| `python3` | heal.sh, check-update.sh, watchdog.sh |
| `curl` | watchdog.sh HTTP health check |
| `openssl` | heal.sh auth token generation |
| `launchctl` + macOS | watchdog-install.sh (LaunchAgent) |
| `osascript` | watchdog.sh macOS notifications (optional) |

**Linux:** watchdog-install.sh is macOS only. Use cron instead:
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
# Run a one-time heal pass — fixes the most common issues immediately
bash scripts/heal.sh

# Check if a recent update broke your config
bash scripts/check-update.sh        # report only
bash scripts/check-update.sh --fix  # report + auto-fix

# Install the always-on watchdog (macOS)
bash scripts/watchdog-install.sh

# View watchdog log
tail -f ~/.openclaw/logs/watchdog.log

# View incident history
cat ~/.openclaw/logs/heal-incidents.jsonl

# Run dependency health checks
mkdir -p ~/.openclaw
cp templates/health-targets.conf.example ~/.openclaw/health-targets.conf
bash scripts/health-check.sh --verbose
```

## Notes

- `health-check.sh` can fail immediately after `openclaw update` or `openclaw gateway restart` if your process target requires a minimum uptime such as `300` seconds. That is expected. Lower the threshold during smoke tests, then restore it for steady-state monitoring.
- `security-scan.sh` reports file paths and line numbers for suspected secrets, but it redacts the secret values themselves.
- `check-update.sh` is intended for real post-upgrade triage. It is normal for it to report a version change the first time it runs after an upgrade.

## Watchdog escalation model

1. **Tier 1** — HTTP ping every 5 min (LaunchAgent)
2. **Tier 2** — Gateway restart + `heal.sh` if simple restart fails
3. **Tier 3** — macOS notification after 3 failed attempts in 15 min; requires manual intervention

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

## Author

[@cathrynlavery](https://twitter.com/cathrynlavery) • [founder.codes](https://founder.codes)
