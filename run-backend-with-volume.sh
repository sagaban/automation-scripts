#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="/Users/santiago/repos/app"
DB_DIR="$APP_ROOT/db"
INFRASTRUCTURE_DIR="$APP_ROOT/infrastructure"

# Globals used to pass arrays/results between functions (bash 3.2 compatible)
SUFFIXES=()
OPTIONS=()
PICK_RESULT=""

# Populates SUFFIXES with existing data-* suffixes found in DB_DIR
collect_suffixes() {
  SUFFIXES=()
  for dir in "$DB_DIR"/data-*; do
    [[ -d "$dir" ]] || continue
    local s="${dir##*/data-}"
    [[ -z "$s" ]] && continue
    SUFFIXES+=("$s")
  done
}

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

# Reads SUFFIXES, writes OPTIONS with "local" first (when present)
build_options_local_first() {
  OPTIONS=()
  local has_local=0
  local s
  for s in "${SUFFIXES[@]}"; do
    if [[ "$s" == "local" ]]; then
      has_local=1
    fi
  done
  if [[ "$has_local" -eq 1 ]]; then
    OPTIONS+=("local")
  fi
  for s in "${SUFFIXES[@]}"; do
    if [[ "$s" != "local" ]]; then
      OPTIONS+=("$s")
    fi
  done
  return 0
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

run_backend() {
  local suffix="$1"
  echo "Selected: $suffix"

  OPTIONS=("Skip build (run existing image)" "Build the docker image")
  pick_option "Build the docker image?"
  local run_task="run-backend"
  [[ "$PICK_RESULT" == "Build the docker image" ]] && run_task="run-backend-build"

  # Unconditional: a build pulls its base images from ECR, and the compose
  # stack wants CODEARTIFACT_AUTH_TOKEN either way. Refresh before anything is
  # torn down, so a failed login doesn't leave the stack stopped.
  "$SCRIPT_DIR/ensure-aws-session.sh"

  rename_tab "$suffix"
  cd "$APP_ROOT"
  echo "Stopping any running task (clearing orphaned anonymous volumes, keeping named ones like mailpit_data)..."
  task stop || true
  docker volume prune -f || true
  task "$run_task" DB_SUFIX="$suffix"
}

# Sanitize a branch name into a folder-friendly suffix
sanitize_suffix() {
  printf '%s' "$1" | tr '/' '-' | tr -cd '[:alnum:]._-'
}

# Returns the current branch of $APP_ROOT (sanitized) on stdout, or empty
current_branch_suffix() {
  local b=""
  b=$(git -C "$APP_ROOT" branch --show-current 2>/dev/null || true)
  [[ -z "$b" ]] && b=$(git branch --show-current 2>/dev/null || true)
  sanitize_suffix "$b"
}

# Reads SUFFIXES, writes OPTIONS with current-branch-match first (when present),
# then "local" (when present), then the rest in original order.
build_options_branch_first() {
  OPTIONS=()
  local branch_suffix
  branch_suffix=$(current_branch_suffix)

  local has_branch=0
  local has_local=0
  local s
  for s in "${SUFFIXES[@]}"; do
    [[ -n "$branch_suffix" && "$s" == "$branch_suffix" ]] && has_branch=1
    [[ "$s" == "local" ]] && has_local=1
  done

  if [[ "$has_branch" -eq 1 ]]; then
    OPTIONS+=("$branch_suffix")
  fi
  if [[ "$has_local" -eq 1 && "$branch_suffix" != "local" ]]; then
    OPTIONS+=("local")
  fi
  for s in "${SUFFIXES[@]}"; do
    if [[ "$s" != "local" ]] && [[ -z "$branch_suffix" || "$s" != "$branch_suffix" ]]; then
      OPTIONS+=("$s")
    fi
  done
  return 0
}

create_new_volume() {
  collect_suffixes
  if [[ ${#SUFFIXES[@]} -eq 0 ]]; then
    echo "No data-* folders found in $DB_DIR to copy from."
    exit 1
  fi

  build_options_local_first
  pick_option "Copy from which existing volume?"
  local source="$PICK_RESULT"

  # Default suffix from current branch (app repo, then cwd)
  local default_suffix
  default_suffix=$(current_branch_suffix)

  local prompt="New suffix"
  [[ -n "$default_suffix" ]] && prompt+=" [default: $default_suffix]"
  prompt+=": "

  local new_suffix=""
  while true; do
    read -rp "$prompt" new_suffix
    if [[ -z "$new_suffix" ]]; then
      new_suffix="$default_suffix"
    fi
    new_suffix=$(sanitize_suffix "$new_suffix")
    if [[ -z "$new_suffix" ]]; then
      echo "Suffix cannot be empty."
      continue
    fi
    if [[ "$new_suffix" == "$source" ]]; then
      echo "New suffix must differ from source ($source)."
      continue
    fi
    break
  done

  local db_src="$DB_DIR/data-$source"
  local db_dst="$DB_DIR/data-$new_suffix"
  local infrastructure_src="$INFRASTRUCTURE_DIR/data-$source"
  local infrastructure_dst="$INFRASTRUCTURE_DIR/data-$new_suffix"

  if [[ -e "$db_dst" ]]; then
    echo "Target $db_dst already exists. Aborting."
    exit 1
  fi
  if [[ -e "$infrastructure_dst" ]]; then
    echo "Target $infrastructure_dst already exists. Aborting."
    exit 1
  fi

  echo "Copying $db_src -> $db_dst"
  cp -a "$db_src" "$db_dst"

  if [[ -d "$infrastructure_src" ]]; then
    echo "Copying $infrastructure_src -> $infrastructure_dst"
    cp -a "$infrastructure_src" "$infrastructure_dst"
  else
    echo "Note: $infrastructure_src does not exist; skipping infrastructure copy."
  fi

  run_backend "$new_suffix"
}

delete_volume() {
  collect_suffixes
  if [[ ${#SUFFIXES[@]} -eq 0 ]]; then
    echo "No data-* folders found in $DB_DIR to delete."
    exit 1
  fi

  build_options_local_first
  pick_option "Delete which volume? (DESTRUCTIVE)"
  local target="$PICK_RESULT"

  local db_target="$DB_DIR/data-$target"
  local infrastructure_target="$INFRASTRUCTURE_DIR/data-$target"

  if ! command -v trash &>/dev/null; then
    echo "'trash' command not found. Install with: brew install trash" >&2
    exit 1
  fi

  echo
  echo "About to move to Trash:"
  [[ -d "$db_target" ]] && echo "  - $db_target"
  [[ -d "$infrastructure_target" ]] && echo "  - $infrastructure_target"
  echo
  local confirm=""
  read -rp "Proceed? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi

  if [[ -d "$db_target" ]]; then
    echo "Trashing $db_target..."
    trash "$db_target"
  fi
  if [[ -d "$infrastructure_target" ]]; then
    echo "Trashing $infrastructure_target..."
    trash "$infrastructure_target"
  fi
  echo "Done."
}

use_existing_volume() {
  collect_suffixes
  if [[ ${#SUFFIXES[@]} -eq 0 ]]; then
    echo "No data-* folders found in $DB_DIR"
    exit 1
  fi

  local selected
  if [[ ${#SUFFIXES[@]} -eq 1 ]]; then
    selected="${SUFFIXES[0]}"
  else
    build_options_branch_first
    pick_option "Pick existing volume"
    selected="$PICK_RESULT"
  fi

  run_backend "$selected"
}

# Show existing volumes first so the user knows what they can pick from
collect_suffixes
if [[ ${#SUFFIXES[@]} -eq 0 ]]; then
  echo "No existing volumes found in $DB_DIR"
else
  echo "Existing volumes in $DB_DIR:"
  for s in "${SUFFIXES[@]}"; do
    echo "  - $s"
  done
fi
echo

# Top-level: create new, use existing, or delete
OPTIONS=("Use existing volume" "Create new volume (copy from existing)" "Delete existing volume")
pick_option "What do you want to do?"

case "$PICK_RESULT" in
  "Create new volume (copy from existing)") create_new_volume ;;
  "Use existing volume") use_existing_volume ;;
  "Delete existing volume") delete_volume ;;
  *) echo "Unknown mode: $PICK_RESULT" >&2; exit 1 ;;
esac
