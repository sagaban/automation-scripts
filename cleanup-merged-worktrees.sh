#!/usr/bin/env bash
# Remove worktrees under WT_BASE whose branch carried real work that has landed on main.
# Branches with no commits of their own are only warned about, never removed.
#
# Each registered worktree under WT_BASE lands in one of four buckets:
#
#   REMOVE  branch has commits of its own AND they are on main. Detected by either:
#             - GitHub reports a merged PR for the branch (squash merges, whose commits
#               never appear on main, so no git-only check can see them), or
#             - the tip is an ancestor of origin/main but NOT on main's first-parent
#               chain, i.e. it was pulled in as the second parent of a merge commit.
#   WARN    branch has no commits beyond origin/main — its tip sits on main's own
#             first-parent history. Nothing was merged; the branch either never got a
#             commit, or was reset onto main. Reported, never removed (--include-empty
#             opts in).
#   SKIP    merged, but the tree has uncommitted changes or commits not in the merged
#             PR head. Reported; --force removes anyway.
#   KEEP    unmerged work.
#
# Deletion is delegated to `task remove-worktree -- <branch>` in REPO, which stops
# docker stacks bind-mounted onto the worktree, removes the tree and deletes the branch.
#
# Usage:
#   cleanup-merged-worktrees.sh [-n|--dry-run] [-y|--yes] [--force]
#                               [--include-empty] [--no-fetch]
#
#   -n, --dry-run        Classify everything, delete nothing.
#   -y, --yes            Skip the confirmation prompt.
#       --force          Also remove merged worktrees flagged as dirty / ahead of the
#                        merged PR. Destructive: that uncommitted or unpushed work is lost.
#       --include-empty  Also remove the warned "no commits beyond main" worktrees.
#       --no-fetch       Skip `git fetch --prune` (use cached remote state).
#
# Env overrides: REPO, WT_BASE, MAIN_BRANCH

set -euo pipefail

REPO="${REPO:-/Users/santiago/repos/app}"
WT_BASE="${WT_BASE:-/Users/santiago/working-trees}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"

DRY_RUN=0
ASSUME_YES=0
FORCE=0
INCLUDE_EMPTY=0
DO_FETCH=1

# Parallel arrays (bash 3.2 has no associative arrays).
MERGED_BRANCHES=()   # merged, carried real work, safe to remove
MERGED_REASONS=()
EMPTY_BRANCHES=()    # no commits beyond main — warn only
EMPTY_REASONS=()
BLOCKED_BRANCHES=()  # merged but dirty / ahead of the merged PR
BLOCKED_REASONS=()
KEEP_LINES=()        # unmerged, reported for context
ORPHAN_DIRS=()       # directories that are not registered worktrees

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)     DRY_RUN=1 ;;
    -y|--yes)         ASSUME_YES=1 ;;
    --force)          FORCE=1 ;;
    --include-empty)  INCLUDE_EMPTY=1 ;;
    --no-fetch)       DO_FETCH=0 ;;
    -h|--help)        sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ -d "$REPO/.git" || -f "$REPO/.git" ]] || { echo "Not a git repo: $REPO" >&2; exit 1; }
[[ -d "$WT_BASE" ]] || { echo "No worktree base directory: $WT_BASE" >&2; exit 1; }
command -v task >/dev/null || { echo "'task' not found in PATH." >&2; exit 1; }

HAVE_GH=0
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  HAVE_GH=1
else
  echo "Warning: gh unavailable or not authenticated — squash-merged branches cannot be" >&2
  echo "         detected and will be reported as unmerged." >&2
fi

cd "$REPO"

if [[ $DO_FETCH -eq 1 ]]; then
  echo "==> Fetching origin..."
  git fetch --prune origin >/dev/null 2>&1 || echo "    Fetch failed, continuing with cached refs."
fi

REMOTE_MAIN="origin/$MAIN_BRANCH"
git rev-parse --verify --quiet "$REMOTE_MAIN" >/dev/null || REMOTE_MAIN="$MAIN_BRANCH"

# Main's own first-parent history, computed once. A commit on this list is part of
# mainline itself; a merged feature tip is not (it enters as a merge's second parent).
FP_LIST="$(mktemp -t merged-wt-fp)"
trap 'rm -f "$FP_LIST"' EXIT
git rev-list --first-parent "$REMOTE_MAIN" > "$FP_LIST"

# True when commit $1 is part of main's own first-parent history.
on_mainline() {
  grep -qx "$1" "$FP_LIST"
}

# Echoes the merged-PR head SHA for branch $1, or nothing when there is no merged PR.
merged_pr_head() {
  local branch="$1"
  [[ $HAVE_GH -eq 1 ]] || return 0
  gh pr list --head "$branch" --state merged --limit 1 \
    --json headRefOid --jq '.[0].headRefOid // empty' 2>/dev/null || true
}

# Classifies one worktree. Args: <worktree path> <branch>
classify() {
  local path="$1" branch="$2"
  local tip ahead pr_head reason

  tip="$(git rev-parse "$branch")"
  ahead="$(git rev-list --count "$REMOTE_MAIN..$branch")"

  # No commits beyond main AND the tip is mainline itself => the branch never
  # contributed anything. Warn instead of deleting; a fresh worktree the user just
  # created is indistinguishable from an abandoned one, and only they know which.
  if [[ "$ahead" -eq 0 ]] && on_mainline "$tip"; then
    reason="no commits beyond $REMOTE_MAIN (tip ${tip:0:9} is mainline)"
    if [[ -d "$path" ]] && [[ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]]; then
      reason="$reason, uncommitted changes present"
    fi
    EMPTY_BRANCHES+=("$branch")
    EMPTY_REASONS+=("$reason")
    return
  fi

  pr_head="$(merged_pr_head "$branch")"
  if [[ -n "$pr_head" ]]; then
    reason="merged PR (head ${pr_head:0:9})"
  elif [[ "$ahead" -eq 0 ]]; then
    # Ancestor of main but off the first-parent chain: pulled in by a merge commit.
    reason="merged into $REMOTE_MAIN via merge commit"
  else
    KEEP_LINES+=("$branch — unmerged ($ahead commit(s) not on $REMOTE_MAIN)")
    return
  fi

  local blockers=()

  if [[ -d "$path" ]] && [[ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]]; then
    blockers+=("uncommitted changes")
  fi

  # With a squash merge the branch commits are absent from main by design, so
  # "ahead" is only meaningful against the SHA that was actually merged.
  if [[ -n "$pr_head" && "$tip" != "$pr_head" ]]; then
    if ! git merge-base --is-ancestor "$tip" "$pr_head" 2>/dev/null; then
      local n
      n="$(git rev-list --count "$pr_head..$branch" 2>/dev/null || echo '?')"
      blockers+=("$n local commit(s) not in the merged PR")
    fi
  fi

  if [[ ${#blockers[@]} -gt 0 ]]; then
    local joined
    joined="$(printf '%s, ' "${blockers[@]}")"
    BLOCKED_BRANCHES+=("$branch")
    BLOCKED_REASONS+=("${joined%, } (${reason})")
  else
    MERGED_BRANCHES+=("$branch")
    MERGED_REASONS+=("$reason")
  fi
}

# Walk registered worktrees; branch names come from git, so nested layouts such as
# story/CPE-1234/foo (a directory tree, not a single directory) map correctly.
echo "==> Inspecting worktrees under $WT_BASE..."
REGISTERED_ROOTS=()
wt_path=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*) wt_path="${line#worktree }" ;;
    "branch refs/heads/"*)
      branch="${line#branch refs/heads/}"
      case "$wt_path" in "$WT_BASE"/*) ;; *) continue ;; esac
      [[ "$branch" == "$MAIN_BRANCH" || "$branch" == "master" ]] && continue
      # Worktrees live at <root>/app; the root is what remove-worktree deletes.
      REGISTERED_ROOTS+=("${wt_path%/app}")
      classify "$wt_path" "$branch"
      ;;
    "detached") [[ -n "$wt_path" ]] && KEEP_LINES+=("$wt_path — detached HEAD, skipped") ;;
  esac
done < <(git worktree list --porcelain)

# Leftover directories that git no longer tracks as worktrees.
while IFS= read -r app_dir; do
  root="${app_dir%/app}"
  known=0
  for r in ${REGISTERED_ROOTS[@]+"${REGISTERED_ROOTS[@]}"}; do
    [[ "$r" == "$root" ]] && { known=1; break; }
  done
  [[ $known -eq 0 ]] && ORPHAN_DIRS+=("$root")
done < <(find "$WT_BASE" -mindepth 2 -maxdepth 5 -type d -name app -prune 2>/dev/null)

echo ""
if [[ ${#KEEP_LINES[@]} -gt 0 ]]; then
  echo "Keeping (unmerged):"
  printf '  - %s\n' "${KEEP_LINES[@]}"
  echo ""
fi

if [[ ${#EMPTY_BRANCHES[@]} -gt 0 ]]; then
  echo "!! WARNING — no commits beyond $REMOTE_MAIN, $([[ $INCLUDE_EMPTY -eq 1 ]] && echo 'removing (--include-empty)' || echo 'NOT removed'):"
  i=0
  while [[ $i -lt ${#EMPTY_BRANCHES[@]} ]]; do
    echo "  - ${EMPTY_BRANCHES[$i]} — ${EMPTY_REASONS[$i]}"
    i=$((i + 1))
  done
  if [[ $INCLUDE_EMPTY -eq 1 ]]; then
    MERGED_BRANCHES+=("${EMPTY_BRANCHES[@]}")
    MERGED_REASONS+=("${EMPTY_REASONS[@]}")
  else
    echo "    Nothing was merged for these — they may be worktrees you just created."
    echo "    Remove with --include-empty, or by hand:  cd $REPO && task remove-worktree -- <branch>"
  fi
  echo ""
fi

if [[ ${#BLOCKED_BRANCHES[@]} -gt 0 ]]; then
  echo "Merged but $([[ $FORCE -eq 1 ]] && echo 'FORCED' || echo 'skipped') (unsaved work):"
  i=0
  while [[ $i -lt ${#BLOCKED_BRANCHES[@]} ]]; do
    echo "  - ${BLOCKED_BRANCHES[$i]} — ${BLOCKED_REASONS[$i]}"
    i=$((i + 1))
  done
  if [[ $FORCE -eq 1 ]]; then
    MERGED_BRANCHES+=("${BLOCKED_BRANCHES[@]}")
    MERGED_REASONS+=("${BLOCKED_REASONS[@]}")
  else
    echo "    (re-run with --force to remove these too)"
  fi
  echo ""
fi

if [[ ${#ORPHAN_DIRS[@]} -gt 0 ]]; then
  echo "Unregistered directories (not touched, check manually):"
  printf '  - %s\n' "${ORPHAN_DIRS[@]}"
  echo ""
fi

if [[ ${#MERGED_BRANCHES[@]} -eq 0 ]]; then
  echo "Nothing to remove."
  exit 0
fi

echo "To remove (${#MERGED_BRANCHES[@]}):"
i=0
while [[ $i -lt ${#MERGED_BRANCHES[@]} ]]; do
  echo "  - ${MERGED_BRANCHES[$i]} — ${MERGED_REASONS[$i]}"
  i=$((i + 1))
done
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry run — nothing removed."
  exit 0
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  printf 'Remove these worktrees and delete their branches? [y/N] '
  read -r answer </dev/tty || answer=""
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

FAILED=()
for branch in "${MERGED_BRANCHES[@]}"; do
  echo ""
  echo "=============================================================="
  echo "==> task remove-worktree -- $branch"
  echo "=============================================================="
  if ! (cd "$REPO" && task remove-worktree -- "$branch"); then
    echo "    FAILED for $branch" >&2
    FAILED+=("$branch")
  fi
done

echo ""
removed=$(( ${#MERGED_BRANCHES[@]} - ${#FAILED[@]} ))
echo "Removed $removed of ${#MERGED_BRANCHES[@]} worktree(s)."
if [[ ${#FAILED[@]} -gt 0 ]]; then
  printf 'Failed: %s\n' "${FAILED[*]}" >&2
  exit 1
fi
