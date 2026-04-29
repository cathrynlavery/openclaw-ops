# Architecture

This doc explains the design decisions behind openclaw-ops that aren't obvious from script names. Read this before adding new monitoring or recovery infrastructure — there are conventions worth respecting.

## Single-owner restart policy

**Only one process is authorized to restart the gateway.** That process is `watchdog.sh` (typically installed as a `LaunchAgent` on macOS or a `systemd` timer on Linux). All other monitoring scripts in this repo — and any monitoring scripts you add — should **alert and log only**, never call `openclaw gateway restart`.

### Why this matters

Restarting the gateway is destructive enough that two scripts trying to do it simultaneously cause real problems:

- Race conditions where one process kills the gateway while another is mid-startup, leaving you with no gateway at all
- Restart-attempt counters that should rate-limit recovery get duplicated (each script tracks its own count) so the safety brake stops working
- Cooldown timers fight each other and either restart-storm or never recover
- Operator confusion: which log file actually shows what happened?

By concentrating restart authority in one place, the operator can reason about restart history, rate limits, and escalation paths from a single state file (`~/.openclaw/watchdog-state.json`) and a single log (`~/.openclaw/logs/watchdog.log`).

### What `watchdog.sh` provides

- Mutex via `~/.openclaw/watchdog.lock/` (mkdir-style lock with 15-minute stale-lock recovery)
- Restart rate limit: `MAX_RESTART_ATTEMPTS=3` per `RESTART_ATTEMPT_WINDOW=900s` (15 min)
- Health-failure threshold: `REQUIRED_HEALTH_FAILURES=2` consecutive unhealthy probes within 10 min before restarting (avoids flapping on transient network issues)
- Warm-up grace: won't restart a process younger than `GATEWAY_WARMUP_GRACE=120s`
- Escalation path: after sustained failure, runs `heal.sh` instead of restarting again
- HTTP probe **and** agent-layer log probe (see `check_agent_layer_health()`) — the HTTP probe can return 200 while every agent's `tool_calls=0` because of codex backend hangs that are silent at the HTTP layer

### How alert-only watchdogs should behave

If you're writing a watchdog that detects a specific condition (channel-specific stuck sessions, prompt truncation events, cost spikes), follow this pattern:

1. Detect and log to your own log file under `~/.openclaw/logs/`
2. **Do not** call `openclaw gateway restart`
3. If the condition is severe and you want recovery, either:
   - Write a marker file that `watchdog.sh` reads on its next tick and acts on, or
   - Page the operator via your usual channel (Slack, BlueBubbles, email)

The `bluebubbles-stuck-watchdog.sh`-style examples in user installs are good models — they detect, log, and explicitly comment that "Gateway restarts are owned by the OpenClaw watchdog."

### Extending detection (the right way)

When a new failure mode appears in `~/.openclaw/logs/gateway.err.log`, the temptation is to write a new watchdog for it. Resist that temptation. Instead:

1. Identify the log line(s) that uniquely fire on the new failure mode
2. Add the pattern to the alternation in `check_agent_layer_health()` in `watchdog.sh`
3. **Dedupe by timestamp** — one real failure typically emits 4-5 log lines across `lane=main`, `lane=session:...`, `model-fallback/decision`, and `agents/harness` loggers. Counting raw `grep -c` matches inflates the rate. Pattern: pipe to `awk '{print $1}' | sort -u | wc -l` to count distinct timestamps.
4. Tune the threshold in `check_agent_layer_health()` against historical logs before committing — verify it doesn't false-trigger on a normal day.

This keeps all agent-layer detection in one place that an operator can reason about. The `[2] Detect` issue template in `.github/ISSUE_TEMPLATE/` walks contributors through capturing a new pattern.

## State files at a glance

| File | What |
|---|---|
| `~/.openclaw/watchdog.lock/` | Main watchdog mutex (mkdir-based) |
| `~/.openclaw/watchdog-state.json` | Restart-attempt counter, version tracking, health-failure window |
| `~/.openclaw/logs/watchdog.log` | Main watchdog activity (read this for restart history) |
| `~/.openclaw/logs/gateway.err.log` | Gateway error/diagnostic stream — what watchdogs grep |
| `~/.openclaw/state/policy-guard.trigger` | Sentinel file written by `post-update.sh` after a config drift, read by the in-band policy guard |

## Why scripts can edit user config

Several scripts mutate `~/.openclaw/openclaw.json` and `~/.openclaw/exec-approvals.json` (notably `heal.sh`, `check-update.sh --fix`, `codex-perf-check.sh --fix`, `security-scan.sh --fix`). Convention:

- Always back up before edits (timestamped `.bak.*` filename)
- Each fix attempt should report success **only** if the underlying command actually succeeded — see `try_fix()` in `check-update.sh` for the pattern. The earlier `cmd 2>/dev/null && fixed || bad` style swallowed errors and produced misleading summaries (issue #3).
- Always tell the operator to run `openclaw gateway restart` after edits, since most settings reload on restart only
