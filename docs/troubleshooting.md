# OpenClaw Troubleshooting Guide

## Diagnostic Workflow

Always follow this order:

```bash
# 1. Version gate
openclaw --version

# 2. Quick status
openclaw status

# 3. Full diagnosis
openclaw status --all

# 4. Deep health check
openclaw status --deep

# 5. Auto-fix
openclaw doctor --fix

# 6. Live logs (Linux)
journalctl --user -u openclaw-gateway -f
# 6. Live logs (macOS)
tail -f ~/.openclaw/logs/gateway.err.log
```

## Critical: Version Check

Before troubleshooting anything else, verify you are on **v2026.2.12 or later**:

```bash
openclaw --version
```

If on an older version, upgrade immediately -- versions before v2026.2.12 contain critical security vulnerabilities including CVE-2026-25253 (one-click RCE) and 40+ additional SSRF, path traversal, and prompt injection fixes:

```bash
curl -fsSL https://openclaw.ai/install.sh | bash
openclaw gateway restart
```

## Common Issues

### Gateway Issues

#### Gateway Not Running
**Symptoms:** `openclaw status` shows gateway not reachable

**Fix:**
```bash
openclaw gateway restart
# Or manually:
openclaw gateway start
```

If the gateway was just restarted by `openclaw update`, `watchdog.sh`, or `health-check.sh`, give it a brief warm-up window before treating a low process-uptime check as a failure.

#### Port 18789 Already in Use
**Symptoms:** Gateway fails to start, port conflict

**Diagnose:**
```bash
openclaw gateway status
# Check what's using the port
lsof -i :18789
```

**Fix:**
```bash
# Stop existing process or use different port
openclaw config set gateway.port 18790
openclaw gateway restart
```

#### Gateway Mode Not Set
**Symptoms:** `Gateway start blocked`

**Fix:**
```bash
openclaw config set gateway.mode local
openclaw gateway restart
```

#### Gateway Refuses to Start After Upgrade (auth: "none" Removed)
**Symptoms:** Gateway exits immediately after upgrading to v2026.1.29+

**Cause:** `gateway.auth.mode` was set to `"none"`, which is permanently removed.

**Fix:**
```bash
openclaw config set gateway.auth.mode token
openclaw config set gateway.auth.token "$(openssl rand -hex 32)"
openclaw gateway restart
```

#### Agent Silent But Gateway Healthy (Codex Backend Failure)
**Symptoms:**
- `openclaw gateway status` shows healthy / HTTP `/health` returns 200
- Agents respond to messages but produce zero tool calls
- `daily-digest.sh` shows `tool_calls=0` and `$0.00 cost` for every agent
- Paperclip / channel sessions wedge in `processing` state

**Cause:** The gateway's bundled `codex app-server` subprocess (which bridges to OpenAI Codex models like `gpt-5.4` and `gpt-5.3-codex`) is dropping its stdio connection to the gateway mid-call. The gateway is alive at the HTTP layer but cannot complete any model call.

**This is NOT an authentication failure.** Verify by running codex CLI directly with the same auth state:
```bash
CODEX_HOME=~/.openclaw/codex-home codex exec \
  --skip-git-repo-check --sandbox read-only --color never \
  "respond with the single word: alive"
```
If that returns "alive", auth is fine and the failure is the gateway's spawn-and-pipe-stdio path.

**Detection:**
```bash
# Count distinct failure timestamps in last hour (each real failure emits 4-5 log lines)
grep "codex app-server client is closed" ~/.openclaw/logs/gateway.err.log \
  | awk '$1 >= "'"$(date -v-1H '+%Y-%m-%dT%H')"'"' \
  | awk '{print $1}' | sort -u | wc -l
```

If you see more than ~3 distinct failure timestamps per hour, the codex subprocess is unstable.

**Recovery:**
```bash
openclaw gateway restart
```

This respawns the codex subprocess fresh. The main `watchdog.sh` will detect this pattern automatically and restart on its next tick (every 5 min) — see `check_agent_layer_health()` in `scripts/watchdog.sh`. If you're hitting this often, see `docs/architecture.md` for the convention on extending detection patterns rather than adding a parallel watchdog.

**Known fallback-chain trap:** if your model fallback chain is `gpt-5.4 → gpt-5.3-codex`, both targets route through the same dying subprocess, so the fallback won't save you. Add a non-codex model (Anthropic Claude or local Ollama) as the final tier.

### Authentication Issues

#### No API Key Found
**Symptoms:** Agent can't make requests, auth errors

**Fix:**
```bash
# Re-run auth setup
openclaw configure
# Or set directly
openclaw models auth setup-token --provider anthropic
```

#### Anthropic OAuth Token Rejected
**Symptoms:** `OAuth token rejected`, `unauthorized`, or auth failures when using Anthropic models

**Cause:** Anthropic has officially blocked OpenClaw from using Claude OAuth tokens. You must use direct API keys instead.

**Fix:**
```bash
# Switch to direct API key (get one from console.anthropic.com)
openclaw models auth setup-token --provider anthropic

# Verify it works
openclaw status --deep
```

**Note:** This is not a bug -- Anthropic blocked OAuth access for OpenClaw as a policy decision. The only supported method is direct API keys.

#### Claude CLI Backend: Unknown Model Errors
**Symptoms:** `FailoverError: Unknown model: claude-cli/claude-sonnet-4-6`, agents silently falling back to other providers (e.g. openai-codex), `startup model warmup failed for claude-cli/...` in gateway.err.log

**Cause:** The onboarding wizard (`models auth login --provider anthropic --method cli`) sets the `cliBackends` key to `"claude"` instead of `"claude-cli"`. Since model IDs use the `claude-cli/` prefix, the gateway can't match them to any backend and treats them as unknown.

**Fix:**
```bash
bash scripts/fix-cli-backend.sh
```

This script checks and fixes:
1. `anthropic:claude-cli` auth profile exists
2. `cliBackends` key is `"claude-cli"` (not `"claude"`)
3. No `claude-cli` entry in `models.providers` (would create a broken API path)
4. No agent-level `claude-cli` provider blocks or auth profiles

**Important:** `claude-cli` is a subprocess backend, not an API provider. The gateway spawns `claude -p ...` as a child process. Never add `claude-cli` to `models.providers`.

**Note:** After fixing, the `startup model warmup failed` warning in gateway.err.log is expected and non-fatal. The startup warmup uses static model resolution which doesn't check CLI backends — the runtime dispatch path handles it correctly.

#### OAuth Token Refresh Failed (Non-Anthropic Providers)
**Symptoms:** Token expired errors for non-Anthropic providers

**Fix:**
```bash
# Re-authenticate with the provider
openclaw models auth setup-token --provider <provider-name>
# Or re-run configure
openclaw configure
```

### Channel Issues

#### Slack: missing_scope Error
**Symptoms:** Bot receives messages but can't reply

**Cause:** Missing OAuth scopes (often `im:write`)

**Fix:**
1. Go to api.slack.com/apps → Your app
2. OAuth & Permissions → Add missing scopes
3. Reinstall to Workspace
4. Update token: `openclaw config set channels.slack.botToken "xoxb-..."`
5. Restart: `openclaw gateway restart`

**Required Slack Scopes:**
- `chat:write`, `im:write`, `channels:history`, `channels:read`
- `groups:history`, `im:history`, `mpim:history`
- `users:read`, `app_mentions:read`
- `reactions:read`, `reactions:write`

#### WhatsApp: Not Linked
**Symptoms:** `channels status` shows `linked: false`

**Fix:**
```bash
openclaw channels login
# Scan QR in WhatsApp → Settings → Linked Devices
```

#### WhatsApp: Disconnected Loop
**Symptoms:** Keeps reconnecting, not stable

**Causes:**
- Using Bun instead of Node (Bun has issues)
- Network instability
- WhatsApp account issues

**Fix:**
```bash
# Ensure using Node, not Bun
which node
node --version  # Should be v22+

# Restart gateway
openclaw gateway restart

# If persistent, re-link
openclaw channels logout
openclaw channels login
```

#### Telegram: Bot Not Responding
**Symptoms:** Messages not processed

**Check:**
```bash
openclaw channels status
openclaw config get channels.telegram
```

**Fix:**
```bash
# Verify token is set
openclaw config set channels.telegram.botToken "123:abc..."
openclaw gateway restart
```

#### iMessage: Not Working
**Symptoms:** iMessage channel not receiving messages

**Causes:**
- Not on macOS (iMessage is macOS only)
- Full Disk Access not granted
- Messages app not signed in

**Fix:**
```bash
# 1. Verify macOS
uname -s  # Must be "Darwin"

# 2. Grant Full Disk Access
# System Settings → Privacy & Security → Full Disk Access → Add Terminal

# 3. Verify Messages app is signed in and iMessage is active

# 4. Enable and restart
openclaw config set channels.imessage.enabled true
openclaw gateway restart
```

#### Discord: WebSocket Disconnects (v2026.2.24 Known Issue)
**Symptoms:** Bot goes offline for 30+ minutes, WebSocket error 1005 or 1006 in logs

**Cause:** Known issue in v2026.2.24 -- Discord WebSocket resume logic fails on certain disconnects.

**Workaround:**
```bash
# Check if Discord channel is connected
openclaw channels status

# Force restart to re-establish WebSocket
openclaw gateway restart

# Monitor for recurrence
journalctl --user -u openclaw-gateway -f | grep -i discord
```

**Note:** A typing indicator may also get stuck after upgrading to v2026.2.24. Restarting the gateway clears it.

#### Teams: Plugin Not Working
**Symptoms:** Teams channel not available

**Cause:** Teams is a plugin-only channel since v2026.1.15

**Fix:**
```bash
# Install the Teams plugin
openclaw plugins install @openclaw/msteams

# Check plugin status
openclaw plugins info msteams
openclaw channels status
```

### Pairing Issues

#### Messages Not Triggering (Pairing Required)
**Symptoms:** New users can't interact with bot

**Check:**
```bash
openclaw pairing list
```

**Fix:**
```bash
# Approve pending requests
openclaw pairing approve <channel> <code>

# Or switch to allowlist mode
openclaw config set channels.<channel>.dmPolicy allowlist
openclaw config set channels.<channel>.allowFrom '["user1", "user2"]'
```

#### Pairing Code Not Arriving
**Symptoms:** User doesn't receive pairing code

**Causes:**
- Hit 3-request cap (pairing codes expire after 1 hour, max 3 pending)
- Channel not connected

**Fix:**
```bash
# Check channel status
openclaw channels status

# Clear pending and retry
openclaw pairing list
```

### Plugin Issues

#### Plugin Not Loading
**Symptoms:** Installed plugin doesn't appear in `plugins list`

**Fix:**
```bash
# Check plugin health
openclaw plugins doctor

# Verify plugin is enabled
openclaw config get plugins.entries.<plugin-id>.enabled

# Enable if needed
openclaw plugins enable <plugin-id>
openclaw gateway restart
```

#### Plugin Conflict (Slot Error)
**Symptoms:** Error about conflicting plugins in same slot

**Cause:** Two plugins competing for an exclusive slot (e.g., both memory plugins)

**Fix:**
```bash
# Choose one plugin for the slot
openclaw config set plugins.slots.memory "memory-core"
# Or
openclaw config set plugins.slots.memory "memory-lancedb"
openclaw gateway restart
```

### Skill Issues

#### ClawHub Skill Not Working
**Symptoms:** Installed ClawHub skill not available

**Fix:**
```bash
# Check skill requirements
openclaw skills check

# Verify skill is enabled
openclaw config get skills.entries.<skill-name>.enabled

# Check if skill requires specific binaries/env
openclaw skills info <skill-name>
```

### Cron Job Issues

#### Cron Job Not Running
**Symptoms:** Scheduled job doesn't execute at expected time

**Diagnose:**
```bash
# Check job status and next run time
openclaw cron status
openclaw cron list

# View run history for the job
openclaw cron runs

# Check whether agent cron jobs are missing light-context
bash scripts/cron-optimize.sh
```

**Common causes:**
- Wrong timezone: verify with `openclaw cron list` -- use `--tz` flag when creating jobs
- Gateway not running: cron requires an active gateway
- Job disabled: `openclaw cron enable <id>`

**Fix:**
```bash
# Test job manually first
openclaw cron run <id>

# Fix timezone if needed
openclaw cron edit <id>

# Or bulk-enable light-context on agent cron jobs
bash scripts/cron-optimize.sh --fix --level low

# Inspect the actual cron error state and payload preview
bash scripts/cron-error-inspector.sh
bash scripts/cron-error-inspector.sh --agent atlas --consecutive 2
```

#### Cron Webhook SSRF (Security)
**Note:** CVE-2026-27488 (patched in v2026.2.19) allowed cron webhook targets to reach private/internal endpoints. Ensure you are on v2026.2.19+ if using cron webhooks.

### Exec Approval Issues

#### Agents Stuck on Exec Approval Prompts
**Symptoms:** Agents message user with `/approve <id> allow-always` requests, heartbeats fail silently, logs show `exec.approval.waitDecision` timeouts lasting 1800s

**Cause:** `~/.openclaw/exec-approvals.json` has named agent entries with **empty allowlists**. The gateway matches agent-specific entries first and blocks execution — it never falls through to the `*` wildcard catch-all, even if one exists.

This typically happens when agents are added to the config — creating the agent entry auto-scaffolds an empty allowlist.

**Diagnose:**
```bash
openclaw approvals get
openclaw approvals get --gateway
# Look for agents with empty allowlists vs the * wildcard having a pattern
cat ~/.openclaw/exec-approvals.json
```

**Fix:**
```bash
# First, discover all configured agents:
openclaw agents list
# Fallback if gateway is down:
ls ~/.openclaw/agents/

# Add wildcard pattern to each named agent:
openclaw approvals allowlist add --agent <agent-name> "*"
# Repeat for every agent in the list

# Restart to clear stale approval queues
openclaw gateway restart
```

**Prevention:** After adding any new agent, always run:
```bash
openclaw approvals allowlist add --agent <new-agent-name> "*"
```

#### Layer 2: Exec Policy Settings (introduced v2026.2.24)

Even with correct per-agent allowlists, a second policy layer gates complex commands independently. Check both config files:

**`~/.openclaw/exec-approvals.json`** — `defaults` block must have:
```json
{
  "defaults": {
    "security": "full",
    "ask": "off",
    "askFallback": "full"
  }
}
```

**`~/.openclaw/openclaw.json`** — exec tool settings:
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

**Fix via CLI:**
```bash
openclaw config set tools.exec.security full
openclaw config set tools.exec.strictInlineEval false
openclaw gateway restart
```

**Symptoms specific to Layer 2:** Simple commands work, but complex multi-step or inline-eval commands silently fail. Agents request approvals even after Layer 1 allowlists are correctly set.

### Sub-Agent Issues (v2026.2.17+)

#### Sub-Agent Spawn Fails
**Symptoms:** Agent cannot create sub-agents, "spawn depth exceeded" errors

**Diagnose:**
```bash
openclaw config get agents.defaults.subagents.maxSpawnDepth
openclaw config get agents.defaults.subagents.maxChildrenPerAgent
```

**Fix:**
```bash
# Increase spawn depth (default: 2)
openclaw config set agents.defaults.subagents.maxSpawnDepth 3

# Increase children per agent (default: 5)
openclaw config set agents.defaults.subagents.maxChildrenPerAgent 10

openclaw gateway restart
```

#### Sub-Agent Not Responding
**Symptoms:** Spawned sub-agent hangs or produces no output

**Common causes:**
- Model rate limits exceeded (sub-agents make additional API calls)
- Sandbox restrictions blocking sub-agent tools
- Insufficient context window for the task

**Fix:**
```bash
# Check agent status
openclaw agents list

# Review logs for sub-agent errors
openclaw logs | grep -i "sub-agent\|spawn"
```

### Session Management Issues (v2026.2.23+)

#### Prompt Too Long or Incomplete Bootstrap Context
**Symptoms:** Users report “prompt too long,” “instructions too long,” or the agent starts with obviously incomplete workspace context.

**Diagnose:**
```bash
# Check latest-session bootstrap truncation warnings across claimed agents
bash scripts/prompt-truncation-report.sh

# Inspect one agent and emit raw JSON
bash scripts/prompt-truncation-report.sh --agent atlas --json
```

If this reports truncated or near-limit files, the problem is usually prompt assembly or oversized bootstrap files, not gateway liveness.

#### Unconfigured Agent Directories Piling Up
**Symptoms:** `~/.openclaw/agents/` contains old agent dirs that are no longer configured, and you want to separate safe archive/delete candidates from recent dirs that still need inspection.

**Diagnose / act:**
```bash
bash scripts/agent-dirs-audit.sh
bash scripts/agent-dirs-audit.sh --archive --delete-empty
```

#### Backup Files Multiplying Everywhere
**Symptoms:** `*.bak*` files accumulate across `~/.openclaw`, not just in session stores.

**Diagnose / act:**
```bash
bash scripts/backup-rotate.sh
bash scripts/backup-rotate.sh --apply --keep 3
```

#### Oversized AGENTS / MEMORY / SOUL Files
**Symptoms:** Bootstrap context feels heavier over time and you want to identify large context files without mixing that audit into runtime truncation checks.

**Diagnose:**
```bash
bash scripts/context-audit.sh
bash scripts/context-audit.sh --agent atlas --threshold-tokens 10000 --json
```

#### Disk Space Growing from Sessions
**Symptoms:** `~/.openclaw/agents/` directory consuming excessive disk

**Fix:**
```bash
# Clean up old sessions
openclaw sessions cleanup

# Set disk budget to auto-manage
openclaw config set session.maintenance.maxDiskBytes 1073741824
openclaw config set session.maintenance.highWaterBytes 858993459
```

#### Slow Gateway or Session Bloat
**Symptoms:** Gateway feels sluggish after weeks of uptime, `sessions.json` has hundreds of stale entries, cron/subagent runs leave orphaned transcripts behind, prompt bootstrap gets heavier over time.

**Diagnose:**
```bash
# Dry-run the targeted purge first
bash scripts/session-purge.sh

# Inspect a single noisy agent
bash scripts/session-purge.sh --agent atlas
```

**Fix:**
```bash
# Purge stale session index entries, orphan cron/subagent sessions,
# old backups, and orphaned transcript files
bash scripts/session-purge.sh --apply

# Or limit to one agent
bash scripts/session-purge.sh --agent atlas --apply
```

`session-purge.sh` keeps active sessions intact, creates a fresh `sessions.json` backup before mutating, and preserves the newest backup files by default. Use this when `openclaw sessions cleanup` is not enough because the bloat lives in stale index rows, `.bak` files, or orphan `.jsonl` transcripts outside the normal maintenance path.

### Service Issues (systemd)

#### Service Not Starting
**Check:**
```bash
systemctl --user status openclaw-gateway
journalctl --user -u openclaw-gateway -n 50
```

**Fix:**
```bash
# Reinstall service
openclaw onboard --install-daemon

# Or manually enable
systemctl --user enable openclaw-gateway
systemctl --user start openclaw-gateway
```

#### Service Crashes on Restart
**Check logs:**
```bash
journalctl --user -u openclaw-gateway -f
```

**Common causes:**
- Config syntax error: `openclaw doctor`
- Port conflict: Check other processes
- Missing dependencies: Reinstall
- `auth: "none"` in config after upgrade (see above)

### WSL2-Specific Issues

#### Commands Not Found
**Cause:** nvm/node not in path

**Fix:**
```bash
# Always source nvm first
source ~/.nvm/nvm.sh
openclaw status
```

#### systemd Not Available
**Check:**
```bash
ps -p 1 -o comm=  # Should show "systemd"
```

**Fix:** Enable systemd in WSL
```bash
sudo nano /etc/wsl.conf
# Add:
# [boot]
# systemd=true

# Then in PowerShell:
wsl --shutdown
wsl -d Ubuntu
```

## Log Locations

| Location | Content |
|----------|---------|
| `journalctl --user -u openclaw-gateway` | systemd service logs |
| `/tmp/openclaw/openclaw-YYYY-MM-DD.log` | Gateway log file |
| `~/.openclaw/agents/<id>/sessions/` | Session transcripts |

## Reset & Recovery

### Soft Reset (Keep Credentials)
```bash
openclaw reset
openclaw onboard --install-daemon
```

### Hard Reset (Full Clean)
```bash
openclaw gateway stop
rm -rf ~/.openclaw
openclaw onboard --install-daemon
```

**Warning:** Hard reset loses all sessions, credentials, and pairings.

## Getting Help

```bash
# Command help
openclaw --help
openclaw <command> --help

# Documentation
https://docs.openclaw.ai

# Troubleshooting guide
https://docs.openclaw.ai/gateway/troubleshooting
```
