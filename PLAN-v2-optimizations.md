# openclaw-ops v2 Optimization Plan (revised)

**Status:** Revised after codex review (see `PLAN-v2-codex-review.md`). Verdict was REQUEST CHANGES; this revision addresses every point.

## Context

openclaw-ops currently covers **diagnostic + heal**. This plan adds scripts addressing **accumulated bloat that degrades performance over weeks** — 240MB of dead transcripts, 275+ stale session index entries, 125MB of old backups, and crons missing `--light-context`. Real example from the session that prompted this: freed 360MB + cut ~400 stale index entries across 23 agents in one run of session-purge.sh.

## Changes from v1

- **Cut `health-trend.sh`** — built on unstable watchdog log format
- **Cut `backup-rotate-install.sh`** LaunchAgent installer — existing schedulers (cron, post-update hooks) are enough
- **Renamed `context-trimmer.sh` → `context-audit.sh`** (file-bloat only). Runtime truncation reporting stays in `prompt-truncation-report.sh` — no merge, no overlap.
- **Trimmed script scopes** — v1 ships raw data; heuristics come after real distributions
- **Removed premature shared helpers** (`format_table()`, `estimate_tokens()`) — each script self-contained until 2+ need same contract
- **Corrected count** — 8 scripts to add (not 9)

## Scripts

### 0. `session-purge.sh` ✅ DONE

Live in private skill. Needs merge to public repo as first PR.

---

### 1. `prompt-truncation-report.sh` — **build first**

Promotes the inline Python snippet in `SKILL.md` to a real script. Reports per-agent bootstrap truncation: warning shown? truncated files? near-limit files?

**Must tolerate** missing `systemPromptReport`, heterogeneous session schemas, empty sessions dirs — no exploding.

**Flags:** `--agent <name>`, `--json`

**Remove:** inline Python from SKILL.md when merged.

---

### 2. `cron-optimize.sh`

Flags crons missing `--light-context`; optional `--fix` applies it.

**v1 output:** agent | cron id | name | schedule | lightContext set?

**Skip estimated-savings column for v1** — only add once we can cheaply measure actual bootstrap tokens.

**Exit codes:** 0 = all optimized, 1 = optimizations available (daily-digest can nag). **Document this clearly in help text.**

**Flags:** `--fix`, `--level (off|minimal|low|medium|high|xhigh)` default `low`, `--agent <name>`

---

### 3. `cron-error-inspector.sh`

**Pure formatter** over `openclaw cron list --json` state fields. No suggested fixes beyond deterministic cases (e.g., `reason=timeout` → mention `--light-context`; anything fuzzier is cut).

**Output per erroring cron:** id, name, schedule, agent, `state.lastError`, `state.lastErrorReason`, `consecutiveErrors`, last-run-age, first 500 chars of payload (truncated).

**Flags:** `--agent <name>`, `--consecutive N`

---

### 4. `agent-dirs-audit.sh`

Finds dirs under `~/.openclaw/agents/` not in `agents.list`. Dispositions: `EMPTY` (0 sessions, <1MB) → delete candidate; `DORMANT` (>30d old with data) → archive candidate; `RECENT` (<30d) → ⚠️ investigate.

**Hard guardrails:**
- Never follow symlinks out of `~/.openclaw/agents/`
- Never recurse into `_archived/`
- Never act on a dir missing `auth-profiles.json` AND `sessions/` AND `agent/` (partial/scaffold dir)

**Flags:** `--archive` moves DORMANT to `_archived/<YYYY-MM-DD>/`, `--delete-empty` removes EMPTY, default dry-run

---

### 5. `backup-rotate.sh`

Generalized backup rotation beyond session stores. Scans `~/.openclaw/**/*.bak*` patterns. Keeps N newest per path.

**No LaunchAgent installer.** Users invoke manually, wire into existing cron, or add to `heal.sh` tail — not another persistent scheduler.

**Flags:** `--apply`, `--keep N` (default 3), `--dry-run` (default)

---

### 6. `context-audit.sh`

Scans AGENTS.md / MEMORY.md / SOUL*.md across agents. Reports **only**: path, token estimate (chars/4), mtime, ranked largest-first. **No** dup-paragraph detection, **no** section-count heuristics — those are false-positive generators.

**Scope boundary:** file-bloat audit only. Runtime truncation reporting lives in `prompt-truncation-report.sh` (step 1). No overlap.

Read-only. No `--apply`.

**Flags:** `--agent <name>`, `--threshold-tokens N` default 10000, `--json`

---

### 7. `cost-by-agent.sh`

Per-agent cost/token breakdown for last N days.

**v1 single source only.** Pick one: `~/.openclaw/state/cost-events.json` if populated, else session metadata token counts. Document which source is used in output. Do **not** merge logs + state + sessions without a precedence rule — that produces "operator-grade nonsense with a polished table" (codex).

**Flags:** `--days N` default 7, `--source (state|sessions)`, `--json`, `--agent <name>`

---

### 8. `model-usage-audit.sh`

**v1 is raw reporting only.** Columns: agent | configured model | actual (N-day avg) | avg tokens/turn. **No** "downshift" suggestions in v1 — ship the data, add heuristics after observing real distributions for 2-4 weeks.

**Flags:** `--days N` default 7, `--json`

**Prerequisite research** before building: confirm actual-model-used field is stable across openclaw versions. If not, defer.

---

## Deferred (not in this plan)

- **`health-trend.sh`** — reopens when watchdog log format stabilizes
- **Shared `lib.sh` additions** — add `get_active_cron_ids()` etc. **only** when 2+ scripts need the exact same contract. Right now: each script inlines what it needs.
- **Auto-editing AGENTS.md / SOUL / MEMORY** — explicit non-goal
- **Per-agent cost alerting** — lives elsewhere (Paperclip or billing skill)

## Build order

1. **Merge `session-purge.sh` + SKILL.md update** to public repo (single PR)
2. **`prompt-truncation-report.sh`** — smallest, replaces existing code, validates PR workflow
3. **`cron-optimize.sh`**
4. **`cron-error-inspector.sh`**
5. **`agent-dirs-audit.sh`**
6. **`backup-rotate.sh`**
7. **`context-audit.sh`** (file-bloat audit only)
8. **`cost-by-agent.sh`**
9. **`model-usage-audit.sh`** (after field-stability research)

## Testing

Each script ships with a `tests/test-<script>.sh` running against `tests/fixtures/mock-openclaw-home/`. Extend existing `tests/` harness — don't rewrite.
