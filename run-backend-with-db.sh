#!/usr/bin/env bash
set -euo pipefail

DB_DIR="/Users/santiago/repos/app/db"
APP_ROOT="/Users/santiago/repos/app"

# Find data-* directories and extract suffixes
suffixes=()
for dir in "$DB_DIR"/data-*; do
  [[ -d "$dir" ]] || continue
  suffix="${dir##*/data-}"
  [[ -z "$suffix" ]] && continue
  suffixes+=("$suffix")
done

# Handle cases: none, one, or multiple
if [[ ${#suffixes[@]} -eq 0 ]]; then
  echo "No data-* folders found in $DB_DIR"
  exit 1
fi

if [[ ${#suffixes[@]} -eq 1 ]]; then
  selected="${suffixes[0]}"
elif [[ -n "${1:-}" ]]; then
  # Validate user-provided suffix exists
  if [[ " ${suffixes[*]} " =~ " $1 " ]]; then
    selected="$1"
  else
    echo "Unknown suffix: $1. Available: ${suffixes[*]}"
    exit 1
  fi
else
  # Put local first as default when it exists
  options=()
  [[ " ${suffixes[*]} " =~ " local " ]] && options=("local")
  for s in "${suffixes[@]}"; do
    [[ "$s" != "local" ]] && options+=("$s")
  done

  if command -v fzf &>/dev/null; then
    selected=$(printf '%s\n' "${options[@]}" | fzf --height=20 --reverse --header="↑↓ to navigate, Enter to select")
    [[ -z "$selected" ]] && exit 1
  else
    echo "Available database options:"
    for i in "${!options[@]}"; do
      default_marker=""
      [[ "${options[$i]}" == "local" ]] && default_marker=" (default)"
      echo "  $((i + 1))) ${options[$i]}${default_marker}"
    done
    echo ""
    default_prompt=""
    [[ " ${suffixes[*]} " =~ " local " ]] && default_prompt=" [Enter=local]"
    while true; do
      read -rp "Choose option (1-${#options[@]})${default_prompt}: " choice
      if [[ -z "$choice" ]] && [[ " ${suffixes[*]} " =~ " local " ]]; then
        selected="local"
        break
      fi
      if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#options[@]})); then
        selected="${options[$((choice - 1))]}"
        break
      fi
      echo "Invalid choice. Please enter a number between 1 and ${#options[@]}."
    done
  fi
fi

echo "Selected: $selected"
cmux rename-tab --tab $(echo $CMUX_SURFACE_ID) --title $selected
cd "$APP_ROOT"
task run-backend-build DB_SUFIX="$selected"
