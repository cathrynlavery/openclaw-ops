---
name: openclaw-ops
description: Use when installing, configuring, troubleshooting, securing, or performing a health check on OpenClaw gateway setups — including channel integrations, exec approvals, cron jobs, agent sessions, and operational maintenance.
---

# OpenClaw Ops

You are an expert OpenClaw administrator. Use the scripts below to diagnose and fix issues — they contain the implementation logic. Reach for scripts first; only write manual steps when no script covers the case.

## Reference Documentation

- [cli-reference.md](docs/cli-reference.md) — Complete CLI command reference
- [troubleshooting.md](docs/troubleshooting.md) — Common issues and solutions
- [channel-setup.md](docs/channel-setup.md) — Platform-specific setup guides
- [security-guide.md](docs/security-guide.md) — Active security defense guide
- [docs.openclaw.ai](https://docs.openclaw.ai) — Official documentation

---

## Scripts

All scripts live in `scripts/` relative to this skill (typically `~/.openclaw/skills/openclaw-ops/scripts/`). Always use that full path when suggesting commands to users.

| Script | When to use |
|--------|-------------|
| `heal.sh` | First thing on any health check — fixes gateway, auth mode, exec approvals, crons, and stuck sessions in one pass |
| `post-update.sh` | Run after `openclaw update` — orchestrates check-update, heal, workspace reconcile, security scan, and final health check in sequence |
| `watchdog.sh` | Continuous monitoring; run every 5 min via LaunchAgent. HTTP health check → auto-restart → escalation after 3 failures |
| `watchdog-install.sh` | Set up the watchdog as a macOS LaunchAgent (survives reboots) |
| `watchdog-uninstall.sh` | Remove the LaunchAgent |
| `check-update.sh` | After a version change — detects breaking config changes, explains them; `--fix` to auto-repair |
| `health-check.sh` | URL/process health checks for gateway-adjacent services; copy `templates/health-targets.conf.example` first |
| `session-monitor.sh` | Agent is alive but misbehaving — retry loops, hangs, auth loops, noisy failures |
| `session-search.sh` | Search session history by keyword; redacts secrets by default |
| `session-resume.sh` | Build a readable markdown resume for a single session (compaction-first, then point-of-failure) |
| `daily-digest.sh` | Incident, activity, watchdog, and cost summary for the last N hours |
| `incident-manager.sh` | Sourced helper for incident lifecycle (used by session-monitor and other scripts) |
| `skill-audit.sh` | Before `clawhub install` — scan skill for secrets, injection, dangerous commands; outputs LOW/MEDIUM/HIGH risk score |
| `security-scan.sh` | Config hardening compliance check (0-100); `--fix` for auto-repair; `--drift` for file change detection; `--credentials` to scan for leaked secrets |
| `codex-perf-check.sh` | Check/fix four GPT-5.x performance opt-ins (strict execution, personality overlay, thinking level, Codex harness). Requires v2026.4.x+. `--fix` to apply. |

### Quick start examples

```bash
# One-pass heal:
bash scripts/heal.sh

# Install always-on watchdog (macOS):
bash scripts/watchdog-install.sh

# Check GPT-5.x agent performance settings:
bash scripts/codex-perf-check.sh
bash scripts/codex-perf-check.sh --fix   # apply fixes

# Run behavioral session monitoring:
bash scripts/session-monitor.sh --verbose

# Search sessions for auth failures:
bash scripts/session-search.sh "unauthorized" --limit 10

# 24-hour digest:
bash scripts/daily-digest.sh --hours 24

# Security compliance check:
bash scripts/security-scan.sh
bash scripts/security-scan.sh --fix
```

---

## Step 0: Version Gate

**Always verify v2026.2.12 or later before doing anything else.** Versions before this contain CVE-2026-25253 (one-click RCE via gateway token leakage) and 40+ additional fixes.

```bash
openclaw --version
```

If outdated: `curl -fsSL https://openclaw.ai/install.sh | bash && openclaw gateway restart`

After any version upgrade, run `check-update.sh` to catch breaking config changes.

---

## Fix Priority (Health Check Order)

1. **Auth issues** — blocks all agent activity
2. **Exec approvals** — empty allowlists cause silent failures that mimic auth or session bugs
3. **Auto-disabled crons** — silent failures, easy to miss
4. **Stuck sessions** — agent appears unresponsive
5. **Config errors** — causes restart warnings

`heal.sh` follows this order automatically.

---

## Discover Agents

Before checking sessions, exec approvals, or crons — discover the actual agent list:

```bash
openclaw agents list          # requires running gateway
ls ~/.openclaw/agents/        # fallback if gateway is down
```

---

## Non-Script Areas

These require manual steps because no script covers them yet.

### Auth

Read `~/.openclaw/auth-profiles.json` — verify tokens present for all configured profiles.

If broken: `openclaw models auth setup-token --provider anthropic`

**Note:** Anthropic OAuth tokens are blocked for OpenClaw — only direct API keys work.

### Exec Approvals

Two independent layers — both must be correct or agents stall silently.

**Layer 1 — per-agent allowlists** (named entries with empty `[]` shadow the `*` wildcard):
```bash
openclaw approvals get
# For each agent with an empty allowlist:
openclaw approvals allowlist add --agent <name> "*"
```

**Layer 2 — policy settings** (often reset by updates):
```bash
openclaw config set tools.exec.security full
openclaw config set tools.exec.strictInlineEval false
openclaw gateway restart
```

Check `~/.openclaw/exec-approvals.json` `defaults` block: `security: full`, `ask: off`, `askFallback: full`.

### Channels

**BlueBubbles:**
- `blocked URL fetch` / `Blocked hostname` → set `allowPrivateNetwork: true` in `channels.bluebubbles`, restart
- `debounce flush failed: TypeError … null (reading 'trim')` → tapback/reaction/read receipt; check BlueBubbles webhook config
- `serverUrl` should be `http://127.0.0.1:1234`

**Slack:**
- `invalid_auth` → bot token expired; refresh `botToken` in openclaw.json
- `socket mode failed to start` → same fix

See [channel-setup.md](docs/channel-setup.md) for all platforms.

---

## Quick Diagnostic Commands

```bash
openclaw status              # Quick status summary
openclaw status --all        # Full diagnosis with log tail
openclaw status --deep       # Health checks with provider probes
openclaw health              # Quick health check
openclaw doctor              # Diagnose issues
openclaw doctor --fix        # Auto-fix common problems
openclaw security audit --deep
```

---

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
| `WebSocket 1005/1006` | Discord resume logic failure | `openclaw gateway restart` |
| `exec.approval.waitDecision` timeout | Named agent has empty allowlist shadowing `*` | `openclaw approvals allowlist add --agent <name> "*"` + restart |
| `/approve <id> allow-always` from agent | Exec approval gate blocking commands | Fix allowlists (see Exec Approvals above) |

---

## Security Operations

Run `security-scan.sh` for config hardening compliance, drift detection, and credential scanning. Run `skill-audit.sh` before installing any third-party skill.

**Recommended settings:**
- `gateway.bind`: `loopback`
- `gateway.auth.mode`: `token`
- `gateway.mdns.mode`: `minimal`
- `dmPolicy`: `pairing`
- `groupPolicy`: `allowlist`
- `sandbox.mode`: `all`, `sandbox.scope`: `agent`
- `tools.deny`: `["gateway", "cron", "sessions_spawn", "sessions_send"]`
- `security.trust_model.multi_user_heuristic`: `true` (v2026.2.24+)

See [security-guide.md](docs/security-guide.md) for full details.

---

## Installation

**Requirements:** Node.js v22+, macOS or Linux (Windows: WSL2/Ubuntu)

```bash
curl -fsSL https://openclaw.ai/install.sh | bash
openclaw onboard --install-daemon
openclaw status
```

---

## Key Config Paths

| Path | Purpose |
|------|---------|
| `~/.openclaw/openclaw.json` | Main configuration |
| `~/.openclaw/agents/<id>/` | Agent state and sessions |
| `~/.openclaw/credentials/` | Channel credentials |
| `~/.openclaw/skills/` | Installed skills |
| `~/.openclaw/extensions/` | Installed plugins |

---

## When Helping Users

1. **Check version first** — v2026.2.12+ required
2. **Run `heal.sh` before manual fixes** — it handles auth, exec approvals, crons, sessions in one pass
3. **Preserve existing config** — read before modifying
4. **Security first** — default to restrictive settings
5. **Explain changes** — tell users what you're doing and why
6. **Verify after changes** — confirm with status commands
7. **Use API keys, not OAuth** — Anthropic has blocked OAuth tokens for OpenClaw
8. **Audit third-party skills/plugins** — run `skill-audit.sh` before installing

## After Fixes

Note if gateway restart is needed. Summarize in three buckets: **broken**, **fixed**, **needs manual action**.
