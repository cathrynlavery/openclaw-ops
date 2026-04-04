# openclaw-ops

![](assets/lobster-coding.gif)


OpenClaw updates break things. Gateway goes down, exec approvals start blocking your agents, config fields get reset by new defaults — and none of it announces itself. You just notice your agents have gone quiet.

This is the ops layer I built to handle that. It keeps the gateway healthy, auto-repairs the most common breakages, and tells you exactly what changed when an update rolls through. I give it to every agent environment I run.

Tested against OpenClaw `2026.4.2`.

## What it fixes

**Gateway**
- Gateway went down (overnight or after an update)
- Port conflict blocking startup
- `auth: "none"` removed in v2026.1.29 — gateway exits immediately after upgrade
- Discord WebSocket disconnects + stuck typing indicator (v2026.2.24)

**Exec approvals** *(most common post-update breakage)*
- Named agent entries with empty allowlists silently shadow the `*` wildcard — agents stall even though the global rule looks correct
- `tools.exec.ask` and `tools.exec.security` reset by update defaults — complex commands blocked even after allowlists are fixed
- Both layers must be correct or agents keep sending `/approve <id> allow-always` requests

**Auth**
- No API key / broken auth — blocks all agent activity
- Anthropic OAuth token rejected (policy block — must switch to direct API key)
- Non-Anthropic provider token expired

**Claude CLI backend** *(silent failure most people don't catch)*
- The onboarding wizard sets `cliBackends` key to `"claude"` instead of `"claude-cli"` — model dispatch silently fails and agents fall back to other providers without telling you
- Stale `claude-cli` entries in `models.providers` create a broken API path that bypasses the subprocess entirely
- Agent-level config files accumulate orphaned provider blocks that conflict with global settings

**Cron jobs**
- Jobs auto-disabled after consecutive errors — silent, easy to miss for days

**Sessions**
- Agents stuck in a rapid-fire loop
- Session files bloated past 10MB
- Dead sessions that appear to be running (0 tokens, empty content)

**Channels**
- Slack: bot receives but can't reply (`missing_scope`); token expired (`invalid_auth`)
- WhatsApp: disconnection loop (usually Bun instead of Node)
- Telegram: bot token not set or not responding
- iMessage: Full Disk Access not granted
- BlueBubbles: private network fetch blocked; null message body from tapbacks crashing gateway
- Discord: WebSocket 1005/1006, goes offline for 30+ min
- Teams: not available until the plugin is installed (moved to plugin in v2026.1.15)

**Security**
- Config hardening gaps — scored 0-100 with specific fixes
- `config.get` leaking unredacted secrets via `sourceConfig`
- Unauthorized skill file changes detected via SHA-256 drift
- Credential patterns leaked into `~/.openclaw/` files or wrong file permissions
- Third-party ClawHub skills with hardcoded secrets, suspicious network calls, or prompt injection

**Updates**
- Version change detection — explains what config broke and why after a specific bump
- CVE-2026-25253 (one-click RCE via token leakage) + 40+ SSRF, path traversal, and prompt injection fixes in v2026.2.12

## What it does

**As a Claude skill** — load `/openclaw-ops` and your AI does the triage: checks gateway health, auth, exec approvals, cron jobs, channels, and sessions, then explains what is broken and fixes it.

**As standalone scripts** — run these directly from any shell:

| Script | What it does |
|--------|-------------|
| `scripts/heal.sh` | One-shot auto-fix for the most common gateway issues |
| `scripts/fix-cli-backend.sh` | Fixes the wizard bug that silently breaks Claude CLI model dispatch |
| `scripts/check-update.sh` | Detects version changes and explains what config broke and why |
| `scripts/watchdog.sh` | Runs every 5 min, restarts gateway if down, escalates after 3 failures |
| `scripts/watchdog-install.sh` | Installs the watchdog as a macOS LaunchAgent (survives reboots) |
| `scripts/health-check.sh` | Declarative URL/process health checks for gateway-adjacent dependencies |
| `scripts/security-scan.sh` | Config hardening and credential exposure scan with redacted findings |
| `scripts/skill-audit.sh` | Static audit for third-party skills before installation |

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
| `python3` | heal.sh, fix-cli-backend.sh, check-update.sh, watchdog.sh |
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

# Fix Claude CLI backend dispatch (run this if agents are silently falling back to other providers)
bash scripts/fix-cli-backend.sh

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

- `health-check.sh` can fail immediately after `openclaw update` or `openclaw gateway restart` if your process target requires a minimum uptime such as `300` seconds. That is expected — lower the threshold during smoke tests, then restore it for steady-state monitoring.
- `security-scan.sh` reports file paths and line numbers for suspected secrets, but it redacts the secret values themselves.
- `check-update.sh` is intended for real post-upgrade triage. It is normal for it to report a version change the first time it runs after an upgrade.
- `fix-cli-backend.sh` is idempotent — safe to re-run. After fixing, the `startup model warmup failed` warning in `gateway.err.log` is expected and non-fatal.

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
