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

On Knox's machine, the canonical ops checkout is `/Users/knox/Developer/openclaw-ops`. Prefer those scripts over the installed skill snapshot under `~/.agents/skills/openclaw-ops`, which can lag behind. If the two differ, treat the Developer checkout as authoritative and sync/reinstall the skill snapshot as follow-up work.

| Script | When to use |
|--------|-------------|
| `heal.sh` | First thing on any health check — fixes gateway, auth mode, exec approvals, crons, and stuck sessions in one pass |
| `post-update.sh` | Run after `openclaw update` — orchestrates check-update, heal, workspace reconcile, security scan, and final health check in sequence |
| `watchdog.sh` | Continuous monitoring; run every 5 min via LaunchAgent. HTTP health check → auto-restart → escalation after 3 failures |
| `watchdog-install.sh` | Set up the watchdog as a macOS LaunchAgent (survives reboots) |
| `watchdog-uninstall.sh` | Remove the LaunchAgent |
| `check-update.sh` | After a version change — detects breaking config changes, explains them; `--fix` to auto-repair |
| `health-check.sh` | URL/process health checks for gateway-adjacent services; copy `templates/health-targets.conf.example` first |
| `log-sweep.sh` | Mandatory when the user says “check the logs” or quotes an error — searches gateway logs plus `/tmp/openclaw/openclaw-*.log` / `/private/tmp/openclaw/openclaw-*.log`; use the user’s exact error string first, then the default broad pattern. |
| `session-monitor.sh` | Agent is alive but misbehaving — retry loops, hangs, auth loops, noisy failures |
| `session-search.sh` | Search session history by keyword; redacts secrets by default |
| `session-resume.sh` | Build a readable markdown resume for a single session (compaction-first, then point-of-failure) |
| `prompt-truncation-report.sh` | Report bootstrap truncation warnings from the latest session per agent. Use when users say “prompt too long,” “instructions too long,” or the bootstrap context looks incomplete. |
| `cron-optimize.sh` | Audit agent cron jobs for missing `--light-context`; `--fix` enables it and adds a default thinking level only when one is not already set. |
| `cron-error-inspector.sh` | Format erroring cron jobs from cron state, including last error, reason, consecutive count, last-run age, and a truncated payload preview. |
| `remediation-board.sh` | Human/agent repair board for surfaced ops findings. Import cron or machine incidents, track recurring bugs, hacks/workarounds, upstream watches, incident notes, hypotheses, steps tried, and verification state. |
| `agent-dirs-audit.sh` | Audit unconfigured dirs under `~/.openclaw/agents/`. Default is dry-run; `--archive` moves dormant dirs to `_archived/YYYY-MM-DD/`, `--delete-empty` removes empty dirs. |
| `backup-rotate.sh` | Rotate generic `*.bak*` files across `~/.openclaw`, grouped by the path prefix before `.bak`. Keeps the newest N per group; dry-run by default, `--apply` to delete. |
| `context-audit.sh` | Audit AGENTS.md, MEMORY.md, and SOUL*.md for file bloat. Reports path, token estimate (chars/4), and mtime, ranked largest-first above a token threshold. |
| `session-purge.sh` | Reclaim disk + cut session context bloat. Purges stale session index entries, orphan cron/subagent sessions, old `.bak` files, and orphan `.jsonl` transcripts. Dry-run by default; `--apply` to execute. |
| `workspace-auto-commit.sh` | Commit dirty OpenClaw workspace repos locally. Defaults to `~/.openclaw/workspace`; use `--workspace PATH` for an agent repo or `--all` for every `workspace*` repo. Never pushes. |
| `workspace-git-audit.sh` | Audit `~/.openclaw/workspace*` repos for git status and auto-commit cron coverage. Use `--show-cron` to print suggested cron add commands for uncovered repos; `--strict` fails on uncovered or dirty repos. |
| `daily-digest.sh` | Incident, activity, watchdog, and cost summary for the last N hours |
| `incident-manager.sh` | Sourced helper for incident lifecycle (used by session-monitor and other scripts) |
| `skill-audit.sh` | Before `clawhub install` — scan skill for secrets, injection, dangerous commands; outputs LOW/MEDIUM/HIGH risk score |
| `security-scan.sh` | Config hardening compliance check (0-100); `--fix` for auto-repair; `--drift` for file change detection; `--credentials` to scan for leaked secrets; `--include-sessions` includes bulky logs/session/runtime files normally skipped |
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

# Track surfaced findings through completion:
bash scripts/remediation-board.sh import-cron-errors
bash scripts/remediation-board.sh import-incidents
bash scripts/remediation-board.sh list
bash scripts/remediation-board.sh set cron:<job-id> fixed-awaiting-rerun --note "payload fixed"

# Mandatory: when investigation finds a real local OpenClaw error,
# regression, hack/workaround, security concern, or recurring ops finding,
# create/update a board item immediately. The board is the local repair loop;
# upstream links are optional metadata only when an external fix also exists.
bash scripts/remediation-board.sh add-incident log-gap "Log sweep missed runtime errors" --evidence "tmp OpenClaw log contained active failure"
bash scripts/remediation-board.sh close-criteria log-gap "Local log-sweep catches the failure class and the installed workflow is synced"

# Track a recurring bug / incident note (check existing board first):
bash scripts/remediation-board.sh list --type incident
bash scripts/remediation-board.sh show telegram-split
bash scripts/remediation-board.sh add-incident telegram-split "Telegram topic replies split" --evidence "Observed in forum topic"
bash scripts/remediation-board.sh hypothesis telegram-split "Preview draft lane sends instead of edits" --confidence medium
bash scripts/remediation-board.sh tried telegram-split --step "Checked release notes" --result "Found related Telegram delivery fixes"
bash scripts/remediation-board.sh workaround telegram-split "Use explicit message.send for topic-visible replies"
bash scripts/remediation-board.sh export-note telegram-split

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

# Commit and audit OpenClaw workspace repos locally:
bash scripts/workspace-auto-commit.sh --workspace ~/.openclaw/workspace-kazuo --label kazuo
bash scripts/workspace-git-audit.sh --show-cron
bash scripts/workspace-git-audit.sh --strict

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

## Health Check Playbook

Use this sequence when the user asks whether OpenClaw is working:

```bash
bash /Users/knox/Developer/openclaw-ops/scripts/heal.sh
bash /Users/knox/Developer/openclaw-ops/scripts/daily-digest.sh
openclaw gateway status
curl -sS -i http://127.0.0.1:51361/ | head -20
openclaw memory status --deep
CODEX_HOME=~/.openclaw/codex-home codex exec --skip-git-repo-check --sandbox read-only --color never "respond with: alive" </dev/null
bash /Users/knox/Developer/openclaw-ops/scripts/log-sweep.sh
tail -30 ~/.openclaw/logs/watchdog.log
tail -80 ~/.openclaw/logs/gateway.err.log
```

Interpretation rules:

- If the user says “check the logs” or quotes an error, do not rely on `gateway.err.log` alone. First run `log-sweep.sh --literal '<exact user-visible error>'`; if that is empty, run `log-sweep.sh` with the default broad pattern. Required surfaces: `~/.openclaw/logs/gateway.err.log`, `~/.openclaw/logs/gateway.log`, watchdog/channel logs, `/tmp/openclaw/openclaw-*.log`, and `/private/tmp/openclaw/openclaw-*.log`. Report which surfaces were checked.
- If an investigation surfaces a real local OpenClaw error/regression, hack/workaround, security concern, or recurring ops finding, create or update a remediation-board item immediately. This is about the local OpenClaw repair loop, not repository hygiene. Attach evidence and set close criteria; link upstream only if an external issue/PR also exists.
- If `heal.sh` says `Gateway failed to start`, immediately re-check with `openclaw gateway status` and an HTTP probe. `heal.sh` can retain an early failed probe in its final summary even after launchd has restarted the gateway successfully.
- If `daily-digest.sh` reports auth errors for Codex-backed agents, verify with the Codex CLI command above before calling it auth. Add `</dev/null` to avoid `codex exec` waiting forever on stdin (`Reading additional input from stdin...`). If direct Codex still times out but `openclaw agent --agent knox --session-id health-probe-$(date +%s) --message "Health probe. Reply exactly: OPENCLAW_ALIVE" --thinking low --timeout 240 --json` succeeds, treat the agent runtime as healthy and the direct CLI probe as a separate Codex CLI/harness issue. `codex app-server client is closed` is a bundled Codex subprocess failure, not an OpenClaw auth failure.
- If `openclaw gateway status` reports an entrypoint mismatch, run critical probes through the same entrypoint launchd is using before trusting CLI-only failures. Example: `/opt/homebrew/opt/node/bin/node /opt/homebrew/lib/node_modules/openclaw/dist/index.js memory status --deep`.
- If `openclaw channels status --probe` says `Gateway event loop degraded` but every channel still reports `works` and the watchdog stays HTTP 200, treat it as a load signal, not an outage. Check `openclaw status --deep`, active sessions, and recent `liveness warning` lines before restarting.
- If `openclaw doctor` warns that `openai-codex/*` refs resolve with runtime `pi`, do not automatically “fix” it. On Knox's setup this can be intentional for Codex OAuth/subscription auth through PI. Use `bash scripts/codex-perf-check.sh`; only run `--fix` if the user wants native Codex app-server and accepts the model/runtime migration.
- A green HTTP/WebSocket gateway check is not enough. Also check channels, stuck sessions, watchdog events, Codex backend health, and memory search readiness.
- For BlueBubbles, use `~/.openclaw/logs/bluebubbles-watchdog.log`; it is alert-only and should not be expected to restart the gateway.

### Duplicate install cleanup

If CLI probes and the LaunchAgent disagree, check whether multiple OpenClaw installs exist:

```bash
type -a openclaw
ls -l "$(command -v openclaw)" /opt/homebrew/bin/openclaw /usr/local/bin/openclaw 2>/dev/null || true
npm list -g --prefix ~/.npm-global openclaw --depth=0
npm list -g --prefix /opt/homebrew openclaw --depth=0
launchctl print gui/$(id -u)/ai.openclaw.gateway | sed -n '1,80p'
```

Keep the install used by the gateway LaunchAgent unless there is a specific reason to migrate it. Remove stale npm-global duplicates only after confirming launchd is not using them:

```bash
npm uninstall -g --prefix ~/.npm-global openclaw
hash -r
type -a openclaw
openclaw gateway status
```

If `/usr/local/bin/openclaw` is a root-owned symlink to the removed install, remove it with an interactive sudo shell or leave it documented if it is not on the active PATH. Do not delete unrelated globally installed npm packages.

### LaunchAgent quarantine reset

Use this when OpenClaw keeps breaking after normal heal/restart cycles and there are custom LaunchAgents in the restart path. The goal is a reversible clean room: leave the main gateway LaunchAgent loaded, quarantine everything custom, and verify before adding anything back.

```bash
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
quarantine="$HOME/.openclaw/quarantine/launchagents/$stamp"
mkdir -p "$quarantine"

launchctl list | rg 'openclaw|paperclip-openclaw|skills-index' || true
ls "$HOME/Library/LaunchAgents"/*openclaw*.plist "$HOME/Library/LaunchAgents"/*paperclip-openclaw*.plist 2>/dev/null || true
```

Move only non-gateway/custom jobs after inspecting the list. Keep `ai.openclaw.gateway.plist` in place unless you are intentionally stopping the gateway too.

```bash
for plist in \
  "$HOME/Library/LaunchAgents/ai.openclaw.watchdog.plist" \
  "$HOME/Library/LaunchAgents/ai.openclaw.gateway-watchdog.plist" \
  "$HOME/Library/LaunchAgents/co.bestself.openclaw.skills-index.plist" \
  "$HOME/Library/LaunchAgents/com.bestself.paperclip-openclaw-ops.plist" \
  "$HOME/Library/LaunchAgents"/com.knox.openclaw-*.plist
do
  [[ -e "$plist" ]] || continue
  label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist" 2>/dev/null || basename "$plist" .plist)"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  mv "$plist" "$quarantine/"
done

launchctl list | rg 'openclaw|paperclip-openclaw|skills-index' || true
openclaw gateway status
```

After quarantine, verify `launchctl list` shows only `ai.openclaw.gateway` for OpenClaw unless you deliberately reloaded another job. Restore one quarantined plist at a time only after the gateway and channels are stable.

If the failure was `codex app-server client is closed`, do not treat the tapback/ack as proof the agent is working. Check the session transcript and queue state:

```bash
openclaw sessions --agent knox --active 15 --json
tail -80 ~/.openclaw/logs/gateway.err.log | rg 'codex app-server|stuck session|state=processing|queueDepth'
```

If the active BlueBubbles session is genuinely wedged, back up `sessions.json` and remove or mark only the session index row; do not delete `*.jsonl` transcript history without explicit user approval.

### Local memory dependencies

For `agents.defaults.memorySearch.provider = "local"`, both embeddings and vector search need to be ready. These failures mean the runtime-deps tree is incomplete:

| Error | Meaning | Fix |
|-------|---------|-----|
| `Local embeddings unavailable` / missing `node-llama-cpp` | embedding model runtime is absent | Install `node-llama-cpp@3.18.1` into the active `~/.openclaw/plugin-runtime-deps/openclaw-<version>-<hash>` tree |
| missing `sqlite-vec` / `Vector: unavailable` | vector storage extension is absent | Install `sqlite-vec` into the same active runtime-deps tree |

Install both together so npm does not prune one while adding the other:

```bash
npm install --prefix ~/.openclaw/plugin-runtime-deps/<active-openclaw-runtime-dir> node-llama-cpp@3.18.1 sqlite-vec
openclaw memory status --deep
```

If multiple OpenClaw installs exist, use the runtime-deps hash associated with the service entrypoint, not whichever `openclaw` binary appears first in `PATH`.

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
- If BlueBubbles probes green but texts still do not get replies, check disk pressure and session health before changing config: `df -h ~ ~/.openclaw /tmp`, `grep -iE 'ENOSPC|context-overflow|final reply failed|bluebubbles.*long-running|stuck session.*bluebubbles' ~/.openclaw/logs/gateway.err.log | tail -80`.
- When resetting BlueBubbles sessions, narrow the edit to keys that literally contain `:bluebubbles:` and the affected chat/sender. Do not reset `agent:<id>:main` or unrelated subagents just because `lastChannel` was BlueBubbles.

**Slack:**
- `invalid_auth` → bot token expired; refresh `botToken` in openclaw.json
- `socket mode failed to start` with `unknown error` can be transient during gateway start/post-attach. If `openclaw channels status --probe` reports Slack `works`, do not rotate tokens or restart blindly.

**Telegram:**
- Enable both `channels.telegram.enabled=true` and the bundled plugin (`plugins.allow` includes `telegram`, `plugins.entries.telegram.enabled=true`). If only the channel config is set, Telegram may not appear in `channels status`.
- On v2026.5.2+, do not set `channels.telegram.requireMention`; it is rejected by config validation.
- Verify final state with `openclaw channels status --probe`; plain status can briefly show `disconnected` before the probe confirms polling works.
- `sendVoice failed` / `final reply failed: HttpError: Network request for 'sendVoice' failed!` can be a Telegram voice-delivery/network failure, not an agent failure. If the text channel probe is green and the session completed, fall back to text or retry media delivery instead of resetting the gateway.

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
| `FailoverError: Failed to extract accountId from token` | OpenAI-Codex auth file/profile shape or stale per-agent auth cooldown state is broken, even if the gateway is reachable | First prove a working Codex auth source with direct `CODEX_HOME=... codex exec`; back up auth/config/state files; copy/update the working auth context only if intentionally chosen; clear stale `openai-codex:*` cooldowns for active agents; restart gateway and verify with an `openclaw agent` sentinel probe. |
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

Security-scan caveats on Knox's machine:
- The scanner intentionally scans config-like files for leaked secrets, but it skips permission hardening for installed plugin/runtime package contents because package manifests and fixtures are normally 644. Treat permission findings under `workspace/`, `credentials/`, auth-state, or LaunchAgent/systemd files as higher signal than plugin source files.
- Prefer `OPENCLAW_SECURITY_SCAN_MAX_FINDINGS=20 bash /Users/knox/Developer/openclaw-ops/scripts/security-scan.sh` for readable output.
- Use `--include-sessions` only for a deep forensic pass; default mode skips bulky logs, session transcripts, runtime deps, and canvas artifacts to avoid slow/noisy scans.

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
