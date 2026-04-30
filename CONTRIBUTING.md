# Contributing to openclaw-ops

Thanks for considering a contribution. This is a maintainer-driven repo, but external contributions are welcome — especially around new failure patterns and platform parity (Linux, BSD).

## Quick rules

- **Read [`docs/architecture.md`](docs/architecture.md) first** if your change touches monitoring, recovery, or anything that could restart the gateway. The single-owner restart policy is non-obvious from script names and easy to violate.
- Keep PRs **small and focused**. One logical change per PR. A PR that fixes a bug AND adds a feature AND refactors three scripts is harder to review and harder to revert.
- Match the existing **bash style**: `set -euo pipefail`, color helpers from `lib.sh`, snake_case function names, and consistent error reporting (see `try_fix()` in `check-update.sh` for the pattern).
- **Add a test** in `tests/run.sh` for any non-trivial behavior change. Run `bash tests/run.sh` locally before opening the PR.

## Reporting a new failure pattern

The most valuable contribution is a **new failure pattern** the watchdog should detect. If you've hit a gateway issue that:

- Is silent at the HTTP `/health` layer (the gateway looks fine but agents don't work)
- Is reproducible from a log signature in `~/.openclaw/logs/gateway.err.log`
- Has a known recovery (gateway restart, config edit, or no-op wait)

…please open an issue using the **"Report a new failure pattern"** template. Even without a PR, the issue gives the maintainer enough to extend `check_agent_layer_health()` in `scripts/watchdog.sh`.

If you're submitting a PR for the pattern:

1. Add the new pattern to the alternation in `check_agent_layer_health()` in `scripts/watchdog.sh`
2. Verify your pattern doesn't false-trigger by running the dedupe pipeline against your local log (BSD `date -v-24H` for macOS; GNU `date -d` for Linux):
   ```bash
   cutoff="$( (date -u -v-24H '+%Y-%m-%dT%H' 2>/dev/null) || date -u -d '24 hours ago' '+%Y-%m-%dT%H' )"
   awk -v cut="$cutoff" -v pat='<your new pattern>' '
     $1 >= cut && $0 ~ pat { seen[$1]=1 }
     END { print length(seen) }
   ' ~/.openclaw/logs/gateway.err.log
   ```
3. Add a test fixture in `tests/run.sh` that simulates the failure log line and asserts the watchdog detects it
4. Update `docs/troubleshooting.md` with a section explaining the symptoms, cause, detection, and recovery (use the existing entries as templates)

## Other contributions worth doing

- **Linux / systemd parity** for any LaunchAgent-only flow (`watchdog-install.sh`, `bb-session-rotator`)
- **`shellcheck` fixes** — run `shellcheck scripts/*.sh` and submit a PR for any high-severity findings
- **Test coverage** — `tests/run.sh` covers a lot but not everything; new tests welcome
- **Doc clarity** — if a doc confused you on first read, your edit will help others

## What to avoid

- **New restart-capable watchdogs.** See `docs/architecture.md` — extend the existing `watchdog.sh` instead. PRs that add a second restart owner will be rejected.
- **Removing `try_fix()`-style error checks** in favor of the older `cmd 2>/dev/null && fixed || bad` pattern. The old pattern swallows errors and lies in the summary; we just fixed it (issue #3).
- **Changes to `~/.openclaw/openclaw.json` schema assumptions** without referencing the OpenClaw release that introduced the change. If a setting was added in v2026.X.Y, say so in the PR description so version-pinned users know.
- **Embedding personal paths, agent IDs, API tokens, or workspace UUIDs** in commits. Use `~/.openclaw/...` and generic identifiers.

## PR checklist

- [ ] `bash tests/run.sh` passes locally
- [ ] No personal config or secrets in the diff
- [ ] If the change touches recovery/monitoring, `docs/architecture.md` conventions are respected
- [ ] If the change adds a new behavior, `docs/troubleshooting.md` and/or `README.md` are updated
- [ ] Commit messages explain *why*, not just *what*
