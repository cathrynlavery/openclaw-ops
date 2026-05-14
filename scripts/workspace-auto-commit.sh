#!/usr/bin/env bash
# workspace-auto-commit.sh — deterministic local git snapshots for OpenClaw workspaces.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

command -v git >/dev/null 2>&1 || { printf 'Missing required tool: git\n' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf 'Missing required tool: python3\n' >&2; exit 1; }

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
MAIN_WORKSPACE="${OPENCLAW_WORKSPACE_ROOT:-$OPENCLAW_HOME/workspace}"

DRY_RUN=0
JSON_OUTPUT=0
ALL_WORKSPACES=0
MESSAGE=""
LABEL=""
WORKSPACES=()

usage() {
  cat <<'USAGE'
Usage: scripts/workspace-auto-commit.sh [--workspace PATH ...] [--all] [--label NAME] [--message TEXT] [--dry-run] [--json]

Creates local git commits for OpenClaw workspace repos when they have dirty or
untracked files. It never pushes.

Defaults to ~/.openclaw/workspace. Use --all to include ~/.openclaw/workspace
and every ~/.openclaw/workspace-* directory.

Exit codes:
  0 = all repos clean or committed successfully
  1 = one or more repos could not be committed
  2 = usage error
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace|--path)
      [[ $# -ge 2 ]] || { printf '%s\n' "--workspace requires a path" >&2; exit 2; }
      WORKSPACES+=("$2")
      shift 2
      ;;
    --all)
      ALL_WORKSPACES=1
      shift
      ;;
    --label)
      [[ $# -ge 2 ]] || { printf '%s\n' "--label requires a value" >&2; exit 2; }
      LABEL="$2"
      shift 2
      ;;
    --message)
      [[ $# -ge 2 ]] || { printf '%s\n' "--message requires text" >&2; exit 2; }
      MESSAGE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --json)
      JSON_OUTPUT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

expand_path() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${1#~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

workspace_slug() {
  local path="$1"
  local base
  base="$(basename "$path")"
  if [[ -n "$LABEL" && "${#WORKSPACES[@]}" -le 1 && "$ALL_WORKSPACES" -eq 0 ]]; then
    printf '%s' "$LABEL" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
  elif [[ "$base" == "workspace" ]]; then
    printf 'workspace'
  else
    printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
  fi
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

emit_json_object() {
  local path="$1" status="$2" dirty="$3" commit="$4" message="$5"
  local comma="$6"
  local path_json status_json commit_json message_json
  path_json="$(printf '%s' "$path" | json_escape)"
  status_json="$(printf '%s' "$status" | json_escape)"
  commit_json="$(printf '%s' "$commit" | json_escape)"
  message_json="$(printf '%s' "$message" | json_escape)"
  printf '%s{"path":%s,"status":%s,"dirty_count":%s,"commit":%s,"message":%s}' \
    "$comma" "$path_json" "$status_json" "$dirty" "$commit_json" "$message_json"
}

if [[ "$ALL_WORKSPACES" -eq 1 ]]; then
  WORKSPACES+=("$MAIN_WORKSPACE")
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] && WORKSPACES+=("$candidate")
  done < <(find "$OPENCLAW_HOME" -maxdepth 1 -type d -name 'workspace-*' -print 2>/dev/null | sort)
fi

if [[ "${#WORKSPACES[@]}" -eq 0 ]]; then
  WORKSPACES+=("$MAIN_WORKSPACE")
fi

FAILED=0
first=1
if [[ "$JSON_OUTPUT" -eq 1 ]]; then
  printf '['
fi

for workspace in "${WORKSPACES[@]}"; do
  path="$(expand_path "$workspace")"
  slug="$(workspace_slug "$path")"
  commit_message="$MESSAGE"
  if [[ -z "$commit_message" ]]; then
    commit_message="auto: hourly ${slug} snapshot"
  fi

  status="clean"
  commit_hash=""
  dirty_count=0
  note=""

  if [[ ! -d "$path" ]]; then
    status="missing"
    note="workspace path does not exist"
    FAILED=1
  elif ! git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    status="not-git"
    note="workspace is not a git repository"
    FAILED=1
  else
    dirty_count="$(git -C "$path" status --short --untracked-files=all | wc -l | tr -d ' ')"
    if [[ "$dirty_count" == "0" ]]; then
      status="clean"
      note="clean"
    elif [[ "$DRY_RUN" -eq 1 ]]; then
      status="dirty"
      note="dry-run: would commit"
    else
      if git -C "$path" add -A && git -C "$path" commit -m "$commit_message" >/dev/null; then
        status="committed"
        commit_hash="$(git -C "$path" rev-parse --short HEAD)"
        note="$commit_message"
      else
        status="commit-failed"
        note="git commit failed"
        FAILED=1
      fi
    fi
  fi

  if [[ "$JSON_OUTPUT" -eq 1 ]]; then
    comma=""
    if [[ "$first" -eq 0 ]]; then
      comma=","
    fi
    first=0
    emit_json_object "$path" "$status" "$dirty_count" "$commit_hash" "$note" "$comma"
  else
    printf 'Workspace: %s\n' "$path"
    printf '  status: %s\n' "$status"
    printf '  dirty files: %s\n' "$dirty_count"
    if [[ -n "$commit_hash" ]]; then
      printf '  commit: %s\n' "$commit_hash"
    fi
    if [[ -n "$note" ]]; then
      printf '  note: %s\n' "$note"
    fi
  fi
done

if [[ "$JSON_OUTPUT" -eq 1 ]]; then
  printf ']\n'
fi

exit "$FAILED"
