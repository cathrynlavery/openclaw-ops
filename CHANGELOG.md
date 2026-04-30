# Changelog

Notable changes to openclaw-ops. Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- `docs/architecture.md` — documents the single-owner restart policy and conventions for extending detection patterns rather than adding parallel watchdogs.
- `CONTRIBUTING.md` with guidance on what to contribute and what to avoid (especially: don't add new restart-capable watchdogs).
- `.github/ISSUE_TEMPLATE/new-failure-pattern.md` — structured way for users to report new failure modes worth detecting.
- `.github/ISSUE_TEMPLATE/bug-report.md` — generic bug report template.
- `scripts/watchdog.sh` `check_agent_layer_health()` now also detects `codex app-server client is closed` — a common failure mode where the bundled codex subprocess drops its stdio connection mid-call. Gateway HTTP `/health` returns 200 but no agent calls succeed.
- `docs/troubleshooting.md`: new "Agent Silent But Gateway Healthy (Codex Backend Failure)" entry documenting symptoms, detection, recovery, and the fallback-chain trap.

### Changed
- `scripts/watchdog.sh` `check_agent_layer_health()` now dedupes by timestamp before counting. A single real failure emits 4-5 log lines across different loggers (lane=main, lane=session:..., model-fallback/decision, agents/harness) — counting raw matches inflated the apparent failure rate by 4-5x and would have false-triggered the restart threshold.
- `scripts/check-update.sh`: the `--fix` mode now actually checks each command's exit code via a new `try_fix()` helper. Previously the pattern `cmd 2>/dev/null && fixed || bad` followed by an unconditional `FIXES_APPLIED=$((FIXES_APPLIED + 1))` claimed success even when the underlying command failed silently. Closes [#3](https://github.com/cathrynlavery/openclaw-ops/issues/3) (thanks @tyeth).
- `scripts/check-update.sh`: summary now distinguishes "X applied, Y failed" and exits non-zero if any fix failed, so callers (CI, `post-update.sh`) can tell.

### Fixed
- `.gitignore` now excludes `*.bak` and `*.bak.*` patterns so script-generated backup files don't get committed.

## Earlier

For history before this changelog was started, see `git log`.
