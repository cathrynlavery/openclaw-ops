## 1. Verdict

**REQUEST CHANGES.** The direction is good, but the plan is still over-scoped for this repo’s current shell conventions and test surface. It also has a counting mismatch (`session-purge` + 9 new scripts, but the document enumerates 10 items) and proposes shared abstractions before the data contracts are stable.

## 2. Per-Script Review

1. **`cron-optimize.sh`**: Good first target. Keep it read-mostly with an explicit `--fix`; do not infer savings from bootstrap files until you prove the estimate source is available and cheap. Exit code `1` for “optimization available” is useful in cron, but document it clearly.

2. **`context-trimmer.sh`**: Useful, but duplicate-paragraph detection and “section count” heuristics smell like false-positive generators. Keep v1 to token estimate, mtime, and file ranking only; operators need triage, not speculative lint.

3. **`prompt-truncation-report.sh`**: Strong fit. This should replace the inline Python in `SKILL.md`, but only if it tolerates missing `systemPromptReport` fields and heterogeneous session schemas without exploding.

4. **`agent-dirs-audit.sh`**: Good hygiene script. The archive/delete dispositions are sensible, but the move/delete path needs strong guardrails around partial agents, symlinks, and `_archived` recursion.

5. **`backup-rotate.sh`**: The core script is fine; the extra `backup-rotate-install.sh` LaunchAgent is unnecessary bloat. Rotation should stay callable from existing operators (`post-update`, manual, or cron), not add another scheduler surface.

6. **`cost-by-agent.sh`**: Valuable, but likely data-fragile. Do not merge logs, state, and session metadata in v1 unless you have a precedence rule for conflicting numbers; otherwise you will produce operator-grade nonsense with a polished table.

7. **`cron-error-inspector.sh`**: Useful and simpler than the plan suggests. Keep it as a formatter over existing cron state; avoid “suggested fixes” beyond deterministic cases, or it becomes another weak diagnosis engine.

8. **`health-trend.sh`**: Not ready. The plan itself admits the watchdog log format is unstable; do not build trend tooling on top of an unstable event schema.

9. **`model-usage-audit.sh`**: Good idea, but the “light-workload mismatch” recommendation logic is hand-wavy. Ship raw configured-vs-actual reporting first, then add heuristics after you see real distributions.

## 3. Recommended Build Order

1. `prompt-truncation-report.sh`
2. `cron-optimize.sh`
3. `cron-error-inspector.sh`
4. `agent-dirs-audit.sh`
5. `backup-rotate.sh`
6. `context-trimmer.sh`
7. `cost-by-agent.sh`
8. `model-usage-audit.sh`

Do `health-trend.sh` last, after log/event format stabilization. Also add shared helpers only after two scripts need the exact same contract; `format_table()` is premature right now.

## 4. Scripts To Cut

Cut **`health-trend.sh`** from this batch. Cut the **LaunchAgent installer** for `backup-rotate`; it is not worth another persistent scheduler. If scope still feels heavy after that, merge `context-trimmer.sh` and `prompt-truncation-report.sh` into one “context-audit” script instead of shipping two adjacent diagnostics with overlapping operator intent.
