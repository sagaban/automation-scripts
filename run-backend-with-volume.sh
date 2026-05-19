#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="/Users/santiago/repos/app"
DB_DIR="$APP_ROOT/db"
STORAGE_DIR="$APP_ROOT/storage"

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
    PICK_RESULT=$(printf '%s\n' "${OPTIONS[@]}" | fzf --height=~50% --reverse --header="$prompt") || true
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

run_backend() {
  local suffix="$1"
  echo "Selected: $suffix"
  if [[ -n "${CMUX_SURFACE_ID:-}" ]] && command -v cmux &>/dev/null; then
    cmux rename-tab --tab "$CMUX_SURFACE_ID" --title "$suffix"
  fi
  cd "$APP_ROOT"
  task run-backend-build DB_SUFIX="$suffix"
}

# Sanitize a branch name into a folder-friendly suffix
sanitize_suffix() {
  printf '%s' "$1" | tr '/' '-' | tr -cd '[:alnum:]._-'
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
  local default_suffix=""
  default_suffix=$(git -C "$APP_ROOT" branch --show-current 2>/dev/null || true)
  [[ -z "$default_suffix" ]] && default_suffix=$(git branch --show-current 2>/dev/null || true)
  default_suffix=$(sanitize_suffix "$default_suffix")

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
  local storage_src="$STORAGE_DIR/data-$source"
  local storage_dst="$STORAGE_DIR/data-$new_suffix"

  if [[ -e "$db_dst" ]]; then
    echo "Target $db_dst already exists. Aborting."
    exit 1
  fi
  if [[ -e "$storage_dst" ]]; then
    echo "Target $storage_dst already exists. Aborting."
    exit 1
  fi

  echo "Copying $db_src -> $db_dst"
  cp -a "$db_src" "$db_dst"

  if [[ -d "$storage_src" ]]; then
    echo "Copying $storage_src -> $storage_dst"
    cp -a "$storage_src" "$storage_dst"
  else
    echo "Note: $storage_src does not exist; skipping storage copy."
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
  local storage_target="$STORAGE_DIR/data-$target"

  if ! command -v trash &>/dev/null; then
    echo "'trash' command not found. Install with: brew install trash" >&2
    exit 1
  fi

  echo
  echo "About to move to Trash:"
  [[ -d "$db_target" ]] && echo "  - $db_target"
  [[ -d "$storage_target" ]] && echo "  - $storage_target"
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
  if [[ -d "$storage_target" ]]; then
    echo "Trashing $storage_target..."
    trash "$storage_target"
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
    build_options_local_first
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
