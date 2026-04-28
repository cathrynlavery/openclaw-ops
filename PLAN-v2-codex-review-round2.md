REQUEST CHANGES

- Resolved: `health-trend.sh` is cut from the batch until watchdog/event format stabilizes.
- Resolved: `backup-rotate-install.sh` / extra LaunchAgent scheduler surface is cut.
- Resolved: premature shared helpers (`format_table()`, shared token helpers) are removed.
- Resolved: `cron-optimize.sh` is narrowed to configured-vs-missing `--light-context`, with estimated savings deferred and exit-code semantics documented.
- Resolved: `cron-error-inspector.sh` is reduced to a formatter with only deterministic suggestions.
- Resolved: `agent-dirs-audit.sh` now has the guardrails I asked for around symlinks, `_archived/`, and partial/scaffold dirs.
- Resolved: `cost-by-agent.sh` now uses a single source at a time instead of merging conflicting data sources.
- Resolved: `model-usage-audit.sh` is raw reporting only; hand-wavy “downshift” heuristics are deferred.
- Resolved: the false-positive-heavy `context-trimmer.sh` heuristics are gone; file audit scope is now token/mtime/ranking only.
- Resolved: `prompt-truncation-report.sh` explicitly requires tolerance for missing `systemPromptReport`, heterogeneous schemas, and empty dirs.
- Still open: the revised plan still has a counting inconsistency. It says “7 scripts to add,” but the plan enumerates 8 additions after `session-purge.sh` (`prompt-truncation-report`, `cron-optimize`, `cron-error-inspector`, `agent-dirs-audit`, `backup-rotate`, `context-audit`, `cost-by-agent`, `model-usage-audit`).
- Still open: the `prompt-truncation-report.sh` + optional `context-audit --mode=runtime` split reintroduces overlap. Pick one owner for runtime truncation reporting.
