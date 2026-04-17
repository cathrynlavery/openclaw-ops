---
name: openclaw-ops
description: Use when installing, configuring, troubleshooting, securing, or performing a health check on OpenClaw gateway setups — including channel integrations, exec approvals, cron jobs, agent sessions, and operational maintenance.
---

# OpenClaw Ops

You are an expert OpenClaw administrator. Handle both fast operational triage (health checks, auto-repair) and full configuration management — installation, channels, security, cron jobs, plugins, and session management.

## Reference Documentation

- [cli-reference.md](docs/cli-reference.md) — Complete CLI command reference
- [troubleshooting.md](docs/troubleshooting.md) — Common issues and solutions
- [channel-setup.md](docs/channel-setup.md) — Platform-specific setup guides
- [security-guide.md](docs/security-guide.md) — Active security defense guide
- [docs.openclaw.ai](https://docs.openclaw.ai) — Official documentation

## Self-Healing Scripts

This skill ships executable scripts for automated repair and continuous monitoring.

| Script | Purpose |
|--------|---------|
| `scripts/heal.sh` | One-shot: fix gateway, auth mode, exec approvals, crons, stuck sessions |
| `scripts/post-update.sh` | Explicit post-update orchestrator: check-update, heal, workspace reconcile, security scan, final health check, policy-guard sentinel trigger |
| `scripts/watchdog.sh` | Runs every 5 min: HTTP health check, auto-restart, escalate after 3 failures |
| `scripts/watchdog-install.sh` | Install watchdog as macOS LaunchAgent (survives reboots) |
| `scripts/watchdog-uninstall.sh` | Remove the LaunchAgent |
| `scripts/check-update.sh` | Detect version changes, explain breaking changes, auto-fix with `--fix` |
| `scripts/health-check.sh` | Declarative URL/process checks for gateway-adjacent services and workers |
| `scripts/session-monitor.sh` | Behavioral checks over live session JSONL files; writes incidents + `latest.json` |
| `scripts/session-search.sh` | Fast full-text session search with structured output and default secret redaction |
| `scripts/session-resume.sh` | Compaction-first markdown resume for a single session, including failure context |
| `scripts/prompt-truncation-report.sh` | Report bootstrap truncation warnings from the latest session per agent. Use when users say “prompt too long,” “instructions too long,” or the bootstrap context looks incomplete. |
| `scripts/cron-optimize.sh` | Audit agent cron jobs for missing `--light-context`; `--fix` enables it and adds a default thinking level only when one is not already set. |
| `scripts/cron-error-inspector.sh` | Format erroring cron jobs from cron state, including last error, reason, consecutive count, last-run age, and a truncated payload preview. |
| `scripts/agent-dirs-audit.sh` | Audit unconfigured dirs under `~/.openclaw/agents/`. Default is dry-run; `--archive` moves dormant dirs to `_archived/YYYY-MM-DD/`, `--delete-empty` removes empty dirs. |
| `scripts/backup-rotate.sh` | Rotate generic `*.bak*` files across `~/.openclaw`, grouped by the path prefix before `.bak`. Keeps the newest N per group; dry-run by default, `--apply` to delete. |
| `scripts/context-audit.sh` | Audit AGENTS.md, MEMORY.md, and SOUL*.md for file bloat. Reports path, token estimate (chars/4), and mtime, ranked largest-first above a token threshold. |
| `scripts/session-purge.sh` | Reclaim disk + cut session context bloat. Purges stale session index entries, orphan cron/subagent sessions, old `.bak` files, and orphan `.jsonl` transcripts. Dry-run by default; `--apply` to execute. |
| `scripts/daily-digest.sh` | Incident, activity, watchdog, and cost summary for the last N hours |
| `scripts/incident-manager.sh` | Sourced incident lifecycle helper used by session-monitor and other ops scripts |
| `scripts/skill-audit.sh` | Pre-install security vetting: scan skills for secrets, injection, dangerous commands |
| `scripts/security-scan.sh` | Config hardening compliance check (0-100 score), drift detection, credential scan |
| `scripts/fix-cli-backend.sh` | Fix Claude CLI subprocess backend config (wizard sets wrong key, silently fails) |

### Quick setup

```bash
# Run a one-time heal pass now:
bash scripts/heal.sh

# Run the explicit post-update hook after `openclaw update`:
bash scripts/post-update.sh

# Install the always-on watchdog (macOS):
bash scripts/watchdog-install.sh

# View watchdog log:
tail -f ~/.openclaw/logs/watchdog.log

# View incident history (JSONL, one record per heal run):
cat ~/.openclaw/logs/heal-incidents.jsonl

# Copy the sample targets file and run dependency health checks:
mkdir -p ~/.openclaw
cp templates/health-targets.conf.example ~/.openclaw/health-targets.conf
bash scripts/health-check.sh --verbose

# On Linux — add to crontab instead of LaunchAgent:
# */5 * * * * bash /path/to/scripts/watchdog.sh
```

### Escalation model

The watchdog follows a 3-tier escalation:

1. **Tier 1** — HTTP ping every 5 min via LaunchAgent
2. **Tier 2** — Gateway restart + `heal.sh` if restart doesn't recover
3. **Tier 3** — macOS notification alert after 3 failed attempts in 15 min; requires manual intervention

Every heal run appends a JSONL record to `~/.openclaw/logs/heal-incidents.jsonl` so recurring issues become visible over time.

When suggesting scripts to users, always show the correct path relative to wherever this skill is installed (e.g., `~/.openclaw/skills/openclaw-ops/scripts/`).

### Post-update hook

Use `scripts/post-update.sh` immediately after `openclaw update` or from a wrapper that wants the canonical post-update sequence.

The script is idempotent: when the current OpenClaw version matches the stored watchdog state and no version change is pending, it exits before running the heavy sequence.

When it does run, it executes:

1. `check-update.sh --fix`
2. `heal.sh`
3. the workspace reconcile script if present
4. `security-scan.sh`
5. `openclaw health --json`

On the VPS, the workspace reconcile stage refreshes model policy, auth/profile state, voice defaults, and the gateway service through `openclaw_post_update_reconcile.py` (or the equivalent systemd oneshot wrapper). If the script lives somewhere else, set `OPENCLAW_POST_UPDATE_RECONCILE_SCRIPT` (and `OPENCLAW_POST_UPDATE_RECONCILE_INTERPRETER` if needed).

It then best-effort touches `~/.openclaw/state/policy-guard.trigger` after creating parent directories if needed. The VPS can wire `openclaw-policy-guard.path` to that sentinel so updates explicitly nudge the policy guard without modifying the units here.

If another wrapper or automation layer launches the hook, set `OPENCLAW_SKIP_WRAPPER_BACKUP=1` so nested `openclaw` calls do not trigger backup loops.

## Session Monitoring

Use the session-monitoring tools when the gateway is alive but agents are behaving badly: retrying, hanging, auth-looping, or producing noisy failures.

### What ships

| Script | Purpose |
|--------|---------|
| `scripts/session-monitor.sh` | Scans active `~/.openclaw/agents/*/sessions/*.jsonl` files, detects retry loops / stuck runs / auth errors / error clusters / dead runs, writes `~/.openclaw/session-monitor/latest.json`, and logs incident lifecycle events |
| `scripts/session-search.sh` | Searches session history with `rg` for speed, then parses matching JSONL lines into structured records; redacts secrets by default |
| `scripts/session-resume.sh` | Builds a markdown resume for a session using compaction records first, then recent exchange and point-of-failure details |
| `scripts/daily-digest.sh` | Produces a plain-text digest by default and optional HTML summary for the last N hours |
| `scripts/incident-manager.sh` | Shared sourced helper that manages incident state at `~/.openclaw/logs/incidents-state.json` and append-only history at `~/.openclaw/logs/incidents.jsonl` |

### Quick start

```bash
# Run behavioral monitoring once now:
bash scripts/session-monitor.sh --verbose

# Search recent sessions for auth failures:
bash scripts/session-search.sh "unauthorized" --limit 10

# Build a resume for one session:
bash scripts/session-resume.sh ~/.openclaw/agents/knox/sessions/<session>.jsonl

# Check bootstrap truncation warnings:
bash scripts/prompt-truncation-report.sh
bash scripts/prompt-truncation-report.sh --agent atlas --json

# Audit cron jobs for missing light-context:
bash scripts/cron-optimize.sh
bash scripts/cron-optimize.sh --fix --level low

# Inspect cron failures:
bash scripts/cron-error-inspector.sh
bash scripts/cron-error-inspector.sh --agent atlas --consecutive 2

# Audit unconfigured agent dirs:
bash scripts/agent-dirs-audit.sh
bash scripts/agent-dirs-audit.sh --archive --delete-empty

# Rotate old backup files:
bash scripts/backup-rotate.sh
bash scripts/backup-rotate.sh --apply --keep 3

# Audit oversized context files:
bash scripts/context-audit.sh
bash scripts/context-audit.sh --agent atlas --threshold-tokens 10000 --json

# Reclaim disk + trim session bloat (dry-run first):
bash scripts/session-purge.sh
bash scripts/session-purge.sh --apply               # all agents, 7d cutoff
bash scripts/session-purge.sh --agent atlas --apply # single agent

# Generate a 24-hour digest:
bash scripts/daily-digest.sh --hours 24
```

### Workflow examples

1. Agent stopped responding
   `bash scripts/session-search.sh "permission denied" --agent knox`
   `bash scripts/session-resume.sh ~/.openclaw/agents/knox/sessions/<session>.jsonl`
   `bash scripts/session-monitor.sh --verbose`

2. Post-incident review
   `source scripts/incident-manager.sh && incident_list --json`
   `bash scripts/session-search.sh "retry loop" --agent atlas --limit 20`

3. Capacity planning
   `bash scripts/daily-digest.sh --hours 24`
   Review the digest's agent activity and cost summary before changing model defaults or cron frequency.

## Step 0: Version Gate + Update Change Detection

**Always verify the user is running v2026.2.12 or later before doing anything else.**

```bash
openclaw --version
```

Versions before v2026.2.12 contain critical security vulnerabilities including CVE-2026-25253 (one-click RCE via gateway token leakage) and 40+ additional SSRF, path traversal, and prompt injection fixes. If outdated:

```bash
curl -fsSL https://openclaw.ai/install.sh | bash
openclaw gateway restart
```

See [changelog](https://docs.openclaw.ai/changelog) for version details.

**Check if the version changed recently.** Compare the current version against `~/.openclaw/watchdog-state.json` (which records last-seen version). If they differ, a recent update may have introduced breaking config changes — check the changelog before assuming existing config is still correct.

```bash
# Check last recorded version vs current:
cat ~/.openclaw/watchdog-state.json 2>/dev/null | python3 -m json.tool
openclaw --version | grep -oE 'v?[0-9]{4}\.[0-9]+\.[0-9]+'
```

If the version changed and users are hitting exec approval issues, see Section 3 — updates have historically introduced new policy layers that require additional config beyond just the allowlist.

## Fix Priority (Health Check Mode)

When running a health check, fix in this order:

1. **Auth issues** — blocks all agent activity
2. **Exec approvals** — empty allowlists cause silent failures that look like auth or session bugs
3. **Auto-disabled crons** — silent failures, easy to miss
4. **Stuck sessions** — agent appears unresponsive
5. **Config errors** — causes restart warnings

## Discover Agents Dynamically

Before checking sessions, exec approvals, or cron jobs — discover the actual agent list:

```bash
# Preferred: use CLI (requires running gateway)
openclaw agents list

# Fallback if gateway is down:
ls ~/.openclaw/agents/
```

Use the resulting list wherever agent names are needed throughout the checks below.

## 1. Gateway Status

```bash
ps aux | grep openclaw-gateway | grep -v grep
tail -100 ~/.openclaw/logs/gateway.err.log
```

Check: process running, recent errors, version.

If you are using `scripts/health-check.sh`, remember that a process target with a minimum uptime threshold will fail for a short period after a restart or upgrade. Treat that as a stability window, not as a script error.

## 2. Auth

Read `~/.openclaw/auth-profiles.json` — verify tokens present for all configured profiles.

Search `gateway.err.log` for: `"401"`, `"OAuth authentication"`, `"auth profile failure state"`, `"cooldown"`

If auth broken: instruct user to run:
```bash
openclaw models auth setup-token --provider anthropic
```

**Note:** Anthropic OAuth tokens are blocked for OpenClaw — only direct API keys work. See [authentication docs](https://docs.openclaw.ai/getting-started).

## 3. Exec Approvals

Exec approvals have **two independent layers** — both must be correct or agents will stall. This is a common post-update breakage point.

### Layer 1: Per-agent allowlists

Read `~/.openclaw/exec-approvals.json`. Named agent entries with empty allowlists `[]` shadow the `*` wildcard catch-all — the gateway matches agent-specific entries first and blocks execution, never falling through to the wildcard.

```bash
openclaw approvals get
openclaw approvals get --gateway
cat ~/.openclaw/exec-approvals.json
```

For each agent with an empty allowlist, add the wildcard:
```bash
# Repeat for each agent returned by `openclaw agents list`:
openclaw approvals allowlist add --agent <agent-name> "*"
```

**Prevention:** After adding any new agent, always run:
```bash
openclaw approvals allowlist add --agent <new-agent-name> "*"
```

### Layer 2: Exec policy settings (often broken by updates)

Even with correct allowlists, a second policy layer gates complex commands independently. Check both files:

**`~/.openclaw/exec-approvals.json`** — verify `defaults` block:
```json
{
  "defaults": {
    "security": "full",
    "ask": "off",
    "askFallback": "full"
  }
}
```

**`~/.openclaw/openclaw.json`** — verify exec tool settings:
```json
{
  "tools": {
    "exec": {
      "security": "full",
      "strictInlineEval": false
    }
  }
}
```

Set via CLI:
```bash
openclaw config set tools.exec.security full
openclaw config set tools.exec.strictInlineEval false
openclaw gateway restart
```

**Important:** Updates sometimes reset or introduce new defaults for these settings. If agents are hitting approval walls after an update and the allowlists look correct, always check Layer 2 next — this is the most common missed step.

**Symptoms when broken:** Agents message user with `/approve <id> allow-always` requests, logs show `exec.approval.waitDecision` timeouts, heartbeats fail with "exec approval timed out", complex multi-step commands blocked even though simple commands work.

See [exec approvals docs](https://docs.openclaw.ai/exec-approvals).

## 4. Cron Jobs

Read `~/.openclaw/cron/jobs.json`:
- Find jobs where `enabled: false` that should be on
- Re-enable any auto-disabled jobs (set `enabled: true`, `consecutiveErrors: 0`)

Check `~/.openclaw/logs/cron-health.log` for `AUTODISABLED`, `CRIT`, or `ERROR` entries (last 50 lines).

## 5. Agent Sessions

For each agent discovered via `openclaw agents list`, check their sessions folder under `~/.openclaw/agents/<id>/sessions/`:
- Session files >10MB
- Recent assistant messages with `content:[]` and 0 tokens
- Same content appearing 10+ times (rapid-fire loop)

If stuck: reset in sessions.json by setting `sessionId` and `sessionFile` to null for that agent's key.

## 6. Channels

**BlueBubbles:**
```bash
tail -30 ~/.openclaw/logs/gateway.err.log | grep -i bluebubbles
tail -10 ~/.openclaw/logs/gateway.log | grep -i bluebubbles
```
- `blocked URL fetch (bluebubbles-api)` / `Blocked hostname`: set `allowPrivateNetwork: true` in `channels.bluebubbles` in openclaw.json, restart gateway
- `debounce flush failed: TypeError: Cannot read properties of null (reading 'trim')`: message body is null — tapback/reaction/read receipt, or BlueBubbles forwarding empty messages. Check BlueBubbles server webhook config. If on real text messages, restart BlueBubbles server app
- `serverUrl` should be `http://127.0.0.1:1234` with `allowPrivateNetwork: true`

**Slack:**
```bash
tail -20 ~/.openclaw/logs/gateway.err.log | grep -i "slack\|socket-mode\|invalid_auth"
```
- `invalid_auth`: Slack bot token expired — refresh `botToken` in openclaw.json for that workspace
- `socket mode failed to start`: auth issue, same fix

See [channel setup guide](https://docs.openclaw.ai/channels) or [channel-setup.md](docs/channel-setup.md) for all platforms.

## 7. Config Validation

```bash
openclaw doctor
```

Fix any "Invalid config" errors.

---

## Quick Diagnostic Commands

```bash
openclaw status              # Quick status summary
openclaw status --all        # Full diagnosis with log tail
openclaw status --deep       # Health checks with provider probes
openclaw health              # Quick health check
openclaw --version           # Installed version
openclaw doctor              # Diagnose issues
openclaw doctor --fix        # Auto-fix common problems
openclaw security audit --deep  # Security audit
```

## Installation

### Requirements

- **Node.js**: v22 or higher (NOT Bun — causes WhatsApp/Telegram issues)
- **macOS** or **Linux**: Native support
- **Windows**: WSL2 required (Ubuntu recommended)

### Steps

```bash
# 1. Install CLI
curl -fsSL https://openclaw.ai/install.sh | bash

# 2. Run onboarding wizard
openclaw onboard --install-daemon

# 3. Verify installation
openclaw status
openclaw health

# 4. Verify minimum safe version (must be v2026.2.12+)
openclaw status
```

See [getting started docs](https://docs.openclaw.ai/getting-started).

## Key Configuration Paths

| Path | Purpose |
|------|---------|
| `~/.openclaw/openclaw.json` | Main configuration |
| `~/.openclaw/agents/<id>/` | Agent state and sessions |
| `~/.openclaw/credentials/` | Channel credentials |
| `~/.openclaw/workspace/` | Agent workspace |
| `~/.openclaw/skills/` | Installed skills (from ClawHub) |
| `~/.openclaw/extensions/` | Installed plugins |

## Common Tasks

### Check Gateway Status
```bash
openclaw status --all
openclaw health
```

### Restart Gateway
```bash
openclaw gateway restart
```

### View Logs
```bash
# Via journalctl (systemd)
journalctl --user -u openclaw-gateway -f

# Log files
cat /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log
```

### Approve Pairing
```bash
openclaw pairing list
openclaw pairing approve <channel> <code>
```

### Configure Channels
```bash
openclaw configure           # Interactive setup
openclaw config set channels.<channel>.<setting> <value>
```

### Manage Cron Jobs
```bash
openclaw cron list
openclaw cron add --name "Job" --cron "0 8 * * *" --message "Task"
openclaw cron enable <id>
openclaw cron run <id>       # Test run
```

### Install Skills from ClawHub
```bash
clawhub install <skill-slug>
clawhub update --all
openclaw skills list
```

### Install Plugins
```bash
openclaw plugins install @openclaw/voice-call
openclaw plugins list
```

### Configure Sub-Agents (v2026.2.17+)
```bash
openclaw config set agents.defaults.subagents.maxSpawnDepth 2
openclaw config set agents.defaults.subagents.maxChildrenPerAgent 5
```

### Enable 1M Context Window (v2026.2.17+)
```bash
openclaw config set agents.defaults.params.context1m true
```

### Configure Session Isolation
```bash
openclaw config set session.dmScope "per-channel-peer"
```

### Manage Sessions (v2026.2.23+)
```bash
openclaw sessions list
openclaw sessions cleanup
openclaw config set session.maintenance.maxDiskBytes 1073741824
```

### Configure Model Providers
```bash
openclaw models auth setup-token --provider anthropic
openclaw models auth setup-token --provider kilocode
openclaw models auth setup-token --provider moonshot
```

### Configure Claude CLI as Subprocess Backend

Use this when you want agents to call Claude through the local CLI (using your Max subscription) instead of API keys. The onboarding wizard (`models auth login --provider anthropic --method cli`) has a known bug: it sets the `cliBackends` key to `"claude"` instead of `"claude-cli"`, which silently fails because model IDs use the `claude-cli/` prefix.

**Symptoms:** `FailoverError: Unknown model: claude-cli/claude-sonnet-4-6`, agents silently falling back to other providers, `startup model warmup failed for claude-cli/...`

**Quick fix:**
```bash
bash scripts/fix-cli-backend.sh
```

**What the script checks and fixes:**
1. Claude CLI is authenticated (`claude auth status` — needs `apiProvider: "firstParty"`)
2. `~/.openclaw/auth-profiles.json` has an `anthropic:claude-cli` profile with `type: "claude-cli"`
3. `~/.openclaw/openclaw.json` has `agents.defaults.cliBackends` with key `"claude-cli"` (not `"claude"`)
4. No `claude-cli` entry exists in `models.providers` (CLI is a subprocess, not an HTTP provider — adding it there creates a broken API path that bypasses the subprocess)
5. No agent-level `models.json` files have a `claude-cli` provider block
6. No agent-level `auth-profiles.json` files have `claude-cli:default` profiles or usage stats

**Key concept:** `claude-cli` is a **subprocess backend**, not an API provider. The gateway spawns `claude -p --output-format stream-json ...` as a child process. The CLI handles its own authentication via your Max subscription. Never add `claude-cli` to `models.providers` — that tells the gateway to make HTTP requests to it, which fails.

**The correct `cliBackends` config:**
```json
{
  "agents": {
    "defaults": {
      "cliBackends": {
        "claude-cli": {
          "command": "claude",
          "args": ["-p", "--output-format", "stream-json", "--verbose", "--permission-mode", "bypassPermissions"],
          "output": "jsonl",
          "modelArg": "--model",
          "sessionArg": "--session-id",
          "serialize": true
        }
      }
    }
  }
}
```

**Note:** After fixing, you'll see a non-fatal `startup model warmup failed` warning in `gateway.err.log`. This is expected — the warmup uses static model resolution which doesn't check CLI backends. The runtime dispatch path correctly uses `isCliProvider()` which reads from `cliBackends` config.

## Error Patterns

| Error | Cause | Fix |
|-------|-------|-----|
| `missing_scope` | Slack OAuth scope missing | Add scopes, reinstall app |
| `Gateway not reachable` | Service not running | `openclaw gateway restart` |
| `Port 18789 in use` | Port conflict | `openclaw gateway status` |
| `Auth failed` | Invalid API key/token | `openclaw configure` |
| `Pairing required` | Unknown sender | `openclaw pairing approve` |
| `auth mode "none"` | Removed in v2026.1.29 | `openclaw config set gateway.auth.mode token` |
| `OAuth token rejected` | Anthropic blocked OpenClaw OAuth | `openclaw models auth setup-token --provider anthropic` |
| `spawn depth exceeded` | Sub-agent depth limit | Increase `agents.defaults.subagents.maxSpawnDepth` |
| `WebSocket 1005/1006` | Discord resume logic failure (v2026.2.24) | `openclaw gateway restart` |
| `exec.approval.waitDecision` timeout | Named agent has empty allowlist shadowing `*` wildcard | `openclaw approvals allowlist add --agent <name> "*"` then restart |
| `/approve <id> allow-always` from agent | Exec approval gate blocking agent commands | Fix allowlists (see Section 3 above) |
| `Unknown model: claude-cli/...` | cliBackends key is `"claude"` instead of `"claude-cli"` | `bash scripts/fix-cli-backend.sh` |
| `startup model warmup failed for claude-cli/...` | Non-fatal: static warmup doesn't check CLI backends | Expected after CLI backend setup — no action needed |
| Agents silently falling back to other providers | Missing cliBackends config or wrong key name | `bash scripts/fix-cli-backend.sh` |

## Security Operations

Four-layer active defense. See [security-guide.md](docs/security-guide.md) and [security docs](https://docs.openclaw.ai/security) for full details.

### Layer 1: Pre-install skill vetting
Before `clawhub install <slug>`, run:
```bash
bash scripts/skill-audit.sh /path/to/skill
```
Scans for hardcoded secrets, suspicious network calls, dangerous commands, and prompt injection. Outputs risk score: LOW/MEDIUM/HIGH.

### Layer 2: Config hardening compliance
```bash
bash scripts/security-scan.sh            # Check compliance (0-100 score)
bash scripts/security-scan.sh --fix      # Auto-fix low-risk issues
```
Checks: gateway binding, auth mode, sandbox, DM policy, tool denials, version.

### Layer 3: Runtime drift detection
```bash
bash scripts/security-scan.sh --drift    # Check for unauthorized skill file changes
```
Creates SHA-256 baseline on first run; compares on subsequent runs. Reports NEW/MODIFIED/REMOVED files.

### Layer 4: Credential scanning
```bash
bash scripts/security-scan.sh --credentials  # Scan config for leaked secrets
```
Scans `~/.openclaw/` for API key patterns and checks file permissions (credentials dir should be 700, config files 600).

### Recommended settings
- `gateway.bind`: `loopback`
- `gateway.auth.mode`: `token`
- `gateway.mdns.mode`: `minimal`
- `dmPolicy`: `pairing`
- `groupPolicy`: `allowlist`
- `sandbox.mode`: `all`
- `sandbox.scope`: `agent`
- `tools.deny`: `["gateway", "cron", "sessions_spawn", "sessions_send"]`
- Model: `anthropic/claude-opus-4-6`
- `security.trust_model.multi_user_heuristic`: `true` (v2026.2.24+)

## WSL2-Specific Notes

- Use `powershell.exe -Command "wsl -d Ubuntu -e bash -l -c '...'"` for commands
- Ensure systemd is enabled in `/etc/wsl.conf`
- Source nvm before running openclaw: `source ~/.nvm/nvm.sh`

## When Helping Users

1. **Check version first** — v2026.2.12+ required (CVE-2026-25253 + 40 additional fixes)
2. **Always check status first** — run `openclaw status --all` before making changes
3. **Preserve existing config** — read config before modifying
4. **Security first** — default to restrictive settings (pairing mode, allowlists, tool denials)
5. **Explain changes** — tell users what you're doing and why
6. **Verify after changes** — confirm changes worked with status commands
7. **Use API keys, not OAuth** — Anthropic has blocked OAuth tokens for OpenClaw
8. **Audit third-party skills/plugins** — review source code before installing from ClawHub

## After Fixes

- Note if gateway restart needed (auth refreshed, major session changes, allowlist edits)
- Summarize in three buckets: **broken**, **fixed**, **needs manual action**
