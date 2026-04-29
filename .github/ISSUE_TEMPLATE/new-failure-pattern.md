---
name: Report a new failure pattern
about: A gateway failure mode that should be auto-detected by the watchdog
title: "[failure-pattern] "
labels: failure-pattern, enhancement
assignees: ''
---

## Symptoms

What did you observe? (e.g., "Agents respond but produce zero tool calls", "Gateway HTTP probe is healthy but bluebubbles sessions wedge")

## Log signature

The exact log line(s) from `~/.openclaw/logs/gateway.err.log` (or other openclaw log file) that uniquely fire when this failure occurs. Redact any personal identifiers, agent IDs, or API keys.

```
<paste log lines here>
```

## How often does the same failure produce duplicate log lines?

Many failure modes emit the same error string from multiple loggers (lane=main, lane=session:..., model-fallback/decision, etc.). If you can tell, list how many lines a single real failure produces — this affects how the watchdog should dedupe.

## OpenClaw version

```
$ openclaw --version
<paste output>
```

## Recovery (if known)

What made it go away? (e.g., `openclaw gateway restart`, config edit, wait it out, restart a specific MCP server)

## Frequency / severity

- How often did you see this? (one-off, hourly, every restart, etc.)
- What broke as a result? (channel responses, cron jobs, paperclip sessions, etc.)

## Anything else

Other context, links to OpenClaw issues, suspected upstream causes, etc.
