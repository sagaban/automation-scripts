#!/usr/bin/env bash
# Launcher for `task stack`. Asks for every parameter (stack number, seed
# source, reseed, build, amplify) with sensible defaults, then runs:
#   RESEED=<0|1> BUILD=<0|1> AMPLIFY=<0|1> SEED_FROM=<suffix|path> task stack -- <N>
#
# Any parameter can be passed as a flag instead, and is then not asked for.
# With -y every parameter not given takes its default without asking (also the
# RESEED confirmation), so it can run unattended, e.g. from batuta:
#   run-stack.sh -n 4 -y
#   run-stack.sh --stack 4 --reseed --seed-from data-qa --build --amplify -y
set -euo pipefail

usage() {
  cat <<USAGE
usage: run-stack.sh [-n|--stack N] [--reseed|--no-reseed] [--seed-from <suffix|path>]
                    [--build|--no-build] [--amplify|--no-amplify] [-y|--yes]
USAGE
}

# Flag values; empty means "ask" (or "default" under -y).
ARG_N=""
ARG_RESEED=""
ARG_SEED_FROM=""
ARG_BUILD=""
ARG_AMPLIFY=""
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n | --stack) ARG_N="${2:-}"; shift 2 ;;
    --reseed) ARG_RESEED=1; shift ;;
    --no-reseed) ARG_RESEED=0; shift ;;
    --seed-from) ARG_SEED_FROM="${2:-}"; shift 2 ;;
    --build) ARG_BUILD=1; shift ;;
    --no-build) ARG_BUILD=0; shift ;;
    --amplify) ARG_AMPLIFY=1; shift ;;
    --no-amplify) ARG_AMPLIFY=0; shift ;;
    -y | --yes) ASSUME_YES=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Populates OPTIONS with the data-* dirs available as seed sources, data-local
# first. Always read from the main checkout's db/ — worktrees have no data dirs
# of their own (gitignored, never symlinked), so that is the only place a full
# set of seed sources exists.
build_seed_options() {
  local names=()
  local dir
  for dir in "$SEED_DB_DIR"/data-*; do
    [[ -d "$dir" ]] || continue
    # A stack can't seed from itself — stack-seed.sh rejects it, so don't offer
    # it. Only matters when this checkout IS the one holding the seed dirs.
    [[ "$dir" -ef "$STACK_DB_DIR" ]] && continue
    names+=("${dir##*/}")
  done

  if [[ ${#names[@]} -eq 0 ]]; then
    echo "No data-* dirs found in $SEED_DB_DIR" >&2
    exit 1
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
SEED_DB_DIR="$APP_ROOT/db"
cd "$REPO_ROOT"
echo "Repo: $REPO_ROOT"
echo

# --- N (stack number) -------------------------------------------------------
N="$ARG_N"
if [[ -n "$N" ]]; then
  if [[ ! "$N" =~ ^[0-9]+$ ]]; then
    echo "N must be a non-negative integer (0 reuses the base ports)." >&2
    exit 1
  fi
elif [[ "$ASSUME_YES" == "1" ]]; then
  # No default under -y: `task stack-down` below stops whatever runs on stack N,
  # from ANY checkout, so guessing a number could kill someone else's stack.
  echo "-y needs an explicit stack number (-n N)." >&2
  exit 1
else
  while true; do
    read -rp "Stack number N [default: 1]: " N
    [[ -z "$N" ]] && N="1"
    if [[ "$N" =~ ^[0-9]+$ ]]; then
      break
    fi
    echo "N must be a non-negative integer (0 reuses the base ports)."
  done
fi

# --- RESEED -----------------------------------------------------------------
if [[ -n "$ARG_RESEED" ]]; then
  RESEED="$ARG_RESEED"
elif [[ "$ASSUME_YES" == "1" ]]; then
  RESEED="0"
else
  OPTIONS=("0 - keep the stack DB if it already exists" "1 - discard the stack DB and re-clone from the seed")
  pick_option "RESEED? (default: 0)"
  RESEED="${PICK_RESULT:0:1}"
fi

# --- SEED_FROM --------------------------------------------------------------
# Only worth asking when something will actually be seeded: RESEED=1 discards
# the stack DB and re-clones, and a missing/empty stack data dir cold-starts.
# With an existing DB and RESEED=0, stack-seed.sh ignores the seed source
# entirely, so a prompt here would be a lie.
SEED_FROM=""
STACK_DB_DIR="$REPO_ROOT/db/data-stack-$N"
if [[ "$RESEED" == "1" ]] || [[ -z $(ls -A "$STACK_DB_DIR" 2>/dev/null) ]]; then
  if [[ "$RESEED" != "1" ]]; then
    echo "No existing data in $STACK_DB_DIR — this stack needs a seed."
  fi
  if [[ -n "$ARG_SEED_FROM" ]]; then
    SEED_FROM="$ARG_SEED_FROM"
  elif [[ "$ASSUME_YES" == "1" ]]; then
    SEED_FROM="data-local"
  else
    build_seed_options
    pick_option "Seed from which data set in $SEED_DB_DIR? (default: data-local)"
    SEED_FROM="$PICK_RESULT"
  fi
  if [[ "$SEED_FROM" == "Other (type a suffix or path)" ]]; then
    while true; do
      read -rp "SEED_FROM (suffix like stack-3, or path to a db/data-<X> dir): " SEED_FROM
      # A typed ~ never goes through tilde expansion, and it reaches
      # stack-seed.sh as a literal that no longer names a dir.
      [[ "$SEED_FROM" == "~/"* ]] && SEED_FROM="$HOME/${SEED_FROM#\~/}"
      [[ -n "$SEED_FROM" ]] && break
      echo "SEED_FROM cannot be empty."
    done
  elif [[ "$SEED_FROM" != */* ]]; then
    # Pass the absolute path, not the bare suffix: a bare suffix resolves
    # against the current checkout first, so running in a worktree that happens
    # to have a same-named data dir would seed from there instead of from
    # $SEED_DB_DIR. (A path given with --seed-from is passed through as is.)
    SEED_FROM="$SEED_DB_DIR/$SEED_FROM"
  fi
fi

# --- BUILD ------------------------------------------------------------------
if [[ -n "$ARG_BUILD" ]]; then
  BUILD="$ARG_BUILD"
elif [[ "$ASSUME_YES" == "1" ]]; then
  BUILD="0"
else
  OPTIONS=("0 - use existing images" "1 - rebuild images")
  pick_option "BUILD? (default: 0)"
  BUILD="${PICK_RESULT:0:1}"
fi

# --- AMPLIFY ----------------------------------------------------------------
# Off by default, same as `task stack` itself: it keeps boots fast and avoids
# building the amplify image unless asked for.
if [[ -n "$ARG_AMPLIFY" ]]; then
  AMPLIFY="$ARG_AMPLIFY"
elif [[ "$ASSUME_YES" == "1" ]]; then
  AMPLIFY="0"
else
  OPTIONS=("0 - no Amplify" "1 - also run this stack's monorepo Amplify service")
  pick_option "AMPLIFY? (default: 0)"
  AMPLIFY="${PICK_RESULT:0:1}"
fi

# --- confirm & run ----------------------------------------------------------
# RESEED, BUILD and AMPLIFY are NON-EMPTY tests downstream, not == 1:
# stack-seed.sh does `[ -n "$RESEED" ]` and the Taskfile does
# `[ -n "{{.BUILD}}" ]` / `[ -n "{{.AMPLIFY}}" ]`. Passing the literal "0" is
# therefore truthy — it would reseed the DB, force a rebuild and add the
# amplify profile. A 0 answer must pass nothing at all, so only the vars
# actually turned on get into the command.
ENV_ARGS=()
[[ "$RESEED" == "1" ]] && ENV_ARGS+=("RESEED=1")
[[ "$BUILD" == "1" ]] && ENV_ARGS+=("BUILD=1")
[[ "$AMPLIFY" == "1" ]] && ENV_ARGS+=("AMPLIFY=1")
[[ -n "$SEED_FROM" ]] && ENV_ARGS+=("SEED_FROM=$SEED_FROM")

echo
if [[ ${#ENV_ARGS[@]} -gt 0 ]]; then
  echo "${ENV_ARGS[*]} task stack -- $N"
else
  echo "task stack -- $N"
fi
echo

if [[ "$RESEED" == "1" ]]; then
  echo "RESEED=1 destroys $STACK_DB_DIR and $REPO_ROOT/infrastructure/data-stack-$N."
  confirm=""
  [[ "$ASSUME_YES" == "1" ]] && confirm="y" || read -rp "Proceed? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi
fi

# `task stack` resolves CODEARTIFACT_AUTH_TOKEN in its `env:` block on EVERY
# run, build or not, so a dead SSO session kills it before the first container
# ("Token has expired and refresh failed"). BUILD=1 additionally pulls the base
# images from ECR. Refresh before anything is torn down, so a failed login
# doesn't leave the stack stopped.
"$SCRIPT_DIR/ensure-aws-session.sh"

rename_tab "Stack $N"

# Tear down whatever is already running on this stack's project so the new run
# starts from clean containers/network. Data dirs are kept, and the compose
# project name is global (stack-$N), so this reaches a stack started from any
# checkout. Forced to succeed: nothing running is the normal case.
echo "Stopping stack $N if it is running..."
task stack-down -- "$N" || true
"$SCRIPT_DIR/prune-orphan-volumes.sh"

# The guard matters under `set -u` on bash 3.2, where expanding an empty array
# is an error — and `env ""` would try to run the empty string as a command.
if [[ ${#ENV_ARGS[@]} -gt 0 ]]; then
  env "${ENV_ARGS[@]}" task stack -- "$N"
else
  task stack -- "$N"
fi
