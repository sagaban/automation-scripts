#!/usr/bin/env bash
# Interactive launcher for `task stack`. Asks for every parameter (stack
# number, seed source, reseed, build) with sensible defaults, then runs:
#   RESEED=<0|1> BUILD=<0|1> SEED_FROM=<suffix|path> task stack -- <N>
set -euo pipefail

APP_ROOT="/Users/santiago/repos/app"

# Globals used to pass arrays/results between functions (bash 3.2 compatible)
OPTIONS=()
PICK_RESULT=""

# Reads OPTIONS, writes choice into PICK_RESULT.
# Args: <prompt>
pick_option() {
  local prompt="$1"

  if [[ ${#OPTIONS[@]} -eq 0 ]]; then
    echo "No options available." >&2
    exit 1
  fi

  PICK_RESULT=""
  if command -v fzf &>/dev/null; then
    PICK_RESULT=$(printf '%s\n' "${OPTIONS[@]}" | fzf --height=~50% --reverse --cycle --header="$prompt") || true
    if [[ -z "$PICK_RESULT" ]]; then
      exit 1
    fi
  else
    echo "$prompt"
    local i
    for i in "${!OPTIONS[@]}"; do
      echo "  $((i + 1))) ${OPTIONS[$i]}"
    done
    while true; do
      local choice
      read -rp "Choose option (1-${#OPTIONS[@]}): " choice
      if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#OPTIONS[@]})); then
        PICK_RESULT="${OPTIONS[$((choice - 1))]}"
        break
      fi
      echo "Invalid choice."
    done
  fi
}

# Rename the surrounding terminal tab, when running inside one we know how to
# drive. Purely cosmetic: every call is silenced and forced to succeed so a
# missing CLI or stale id can never abort the run.
# Args: <title>
rename_tab() {
  local title="$1"

  # herdr: `herdr tab rename <tab-id> <label>`, echoes a JSON result.
  if [[ -n "${HERDR_TAB_ID:-}" ]] && command -v herdr &>/dev/null; then
    herdr tab rename "$HERDR_TAB_ID" "$title" >/dev/null 2>&1 || true
  fi

  # cmux: CMUX_WORKSPACE_ID is unset for the call because a stale value makes
  # cmux fail with "not_found: Workspace not found" before it resolves the tab.
  if [[ -n "${CMUX_SURFACE_ID:-}" ]] && command -v cmux &>/dev/null; then
    env -u CMUX_WORKSPACE_ID cmux rename-tab --tab "$CMUX_SURFACE_ID" --title "$title" >/dev/null 2>&1 || true
  fi
}

# Stacks are per-checkout: run in the current worktree when it looks like the
# app repo, otherwise fall back to the main checkout.
resolve_repo_root() {
  local root=""
  root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -n "$root" && -f "$root/Taskfile.yml" ]] && grep -q '^  stack:' "$root/Taskfile.yml"; then
    printf '%s' "$root"
    return
  fi
  printf '%s' "$APP_ROOT"
}

# Echoes the main checkout of $1 (differs from $1 only inside a worktree)
main_checkout() {
  local common=""
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  [[ -n "$common" ]] && printf '%s' "$(dirname "$common")"
}

# Populates OPTIONS with the data-* dirs available as seed sources, data-local
# first. A worktree has no data dirs of its own, so fall back to the main
# checkout (which is what stack-seed.sh resolves against anyway).
build_seed_options() {
  local repo_root="$1"
  local db_dir="$repo_root/db"

  local names=()
  local dir
  for dir in "$db_dir"/data-*; do
    [[ -d "$dir" ]] || continue
    names+=("${dir##*/}")
  done

  if [[ ${#names[@]} -eq 0 ]]; then
    local main_root
    main_root=$(main_checkout "$repo_root")
    if [[ -n "$main_root" && "$main_root" != "$repo_root" ]]; then
      for dir in "$main_root"/db/data-*; do
        [[ -d "$dir" ]] || continue
        names+=("${dir##*/}")
      done
    fi
  fi

  OPTIONS=()
  local n
  for n in "${names[@]:-}"; do
    [[ "$n" == "data-local" ]] && OPTIONS+=("$n")
  done
  for n in "${names[@]:-}"; do
    [[ -n "$n" && "$n" != "data-local" ]] && OPTIONS+=("$n")
  done
  OPTIONS+=("Other (type a suffix or path)")
}

REPO_ROOT=$(resolve_repo_root)
cd "$REPO_ROOT"
echo "Repo: $REPO_ROOT"
echo

# --- N (stack number) -------------------------------------------------------
N=""
while true; do
  read -rp "Stack number N [default: 1]: " N
  [[ -z "$N" ]] && N="1"
  if [[ "$N" =~ ^[0-9]+$ ]]; then
    break
  fi
  echo "N must be a non-negative integer (0 reuses the base ports)."
done

# --- SEED_FROM --------------------------------------------------------------
build_seed_options "$REPO_ROOT"
pick_option "Seed from which data set? (default: data-local)"
SEED_FROM="$PICK_RESULT"
if [[ "$SEED_FROM" == "Other (type a suffix or path)" ]]; then
  while true; do
    read -rp "SEED_FROM (suffix like stack-3, or path to a db/data-<X> dir): " SEED_FROM
    # A typed ~ never goes through tilde expansion, and it reaches stack-seed.sh
    # as a literal that no longer names a dir.
    [[ "$SEED_FROM" == "~/"* ]] && SEED_FROM="$HOME/${SEED_FROM#\~/}"
    [[ -n "$SEED_FROM" ]] && break
    echo "SEED_FROM cannot be empty."
  done
fi

# --- RESEED -----------------------------------------------------------------
OPTIONS=("0 - keep the stack DB if it already exists" "1 - discard the stack DB and re-clone from the seed")
pick_option "RESEED? (default: 0)"
RESEED="${PICK_RESULT:0:1}"

# --- BUILD ------------------------------------------------------------------
OPTIONS=("0 - use existing images" "1 - rebuild images")
pick_option "BUILD? (default: 0)"
BUILD="${PICK_RESULT:0:1}"

# --- confirm & run ----------------------------------------------------------
echo
echo "RESEED=$RESEED BUILD=$BUILD SEED_FROM=$SEED_FROM task stack -- $N"
echo

if [[ "$RESEED" == "1" ]]; then
  echo "RESEED=1 destroys the existing db/data-stack-$N and infrastructure/data-stack-$N."
  confirm=""
  read -rp "Proceed? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi
fi

rename_tab "stack-$N"
RESEED="$RESEED" BUILD="$BUILD" SEED_FROM="$SEED_FROM" task stack -- "$N"
