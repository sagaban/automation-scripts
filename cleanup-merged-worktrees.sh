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
#             PR. Reported; --force removes anyway.
#   KEEP    unmerged work.
#
# Removal is delegated to `task remove-worktree -- <dir>` in REPO, which stops docker
# stacks bind-mounted onto the worktree, removes the tree and deletes the branch. The
# argument is the worktree DIRECTORY relative to WT_BASE, not the branch: the task
# derives its target path as $WT_BASE/<arg>/app, and the two are not always the same
# (branch hotfix/CPE-1/foo can live in a directory named CPE-1-foo). When they differ
# the task cannot delete the branch, so this script deletes it afterwards.
#
# Finally, empty leftover directories under WT_BASE are pruned — the namespace dirs that
# `rm -rf $WT_BASE/<dir>` leaves behind for slash-named branches (fix/, hotfix/,
# story/CPE-1234/, dependabot/). Pruning STOPS at checkout boundaries: inside a worktree
# an empty directory is meaningful content — postgres requires pg_notify/, pg_tblspc/,
# pg_snapshots/ ... to exist and be empty — so a blanket `find -type d -empty -delete`
# would corrupt every data-stack database under WT_BASE.
#
# Usage:
#   cleanup-merged-worktrees.sh [-n|--dry-run] [-y|--yes] [--force]
#                               [--include-empty] [--keep-empty-dirs] [--no-fetch]
#
#   -n, --dry-run          Classify everything, delete nothing.
#   -y, --yes              Skip the confirmation prompt.
#       --force            Also remove merged worktrees flagged as dirty / ahead of the
#                          merged PR. Destructive: that uncommitted or unpushed work is lost.
#       --include-empty    Also remove the warned "no commits beyond main" worktrees.
#       --keep-empty-dirs  Skip the empty-directory prune.
#       --no-fetch         Skip `git fetch --prune` (use cached remote state).
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
PRUNE_DIRS=1
DO_FETCH=1

# Parallel arrays (bash 3.2 has no associative arrays). *_DIRS holds the WT_BASE-relative
# worktree directory — the argument `task remove-worktree` actually needs.
MERGED_BRANCHES=(); MERGED_DIRS=(); MERGED_REASONS=()   # merged with real work
EMPTY_BRANCHES=();  EMPTY_DIRS=();  EMPTY_REASONS=()    # no commits beyond main: warn
BLOCKED_BRANCHES=(); BLOCKED_DIRS=(); BLOCKED_REASONS=() # merged but unsaved work
KEEP_LINES=()        # unmerged, reported for context
ORPHAN_DIRS=()       # directories that are not registered worktrees

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)      DRY_RUN=1 ;;
    -y|--yes)          ASSUME_YES=1 ;;
    --force)           FORCE=1 ;;
    --include-empty)   INCLUDE_EMPTY=1 ;;
    --keep-empty-dirs) PRUNE_DIRS=0 ;;
    --no-fetch)        DO_FETCH=0 ;;
    -h|--help)         sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# Looks up the merged PR for branch $1, setting PR_NUM and PR_HEAD (both empty when
# there is no merged PR).
PR_NUM=""; PR_HEAD=""
find_merged_pr() {
  PR_NUM=""; PR_HEAD=""
  [[ $HAVE_GH -eq 1 ]] || return 0
  local out
  out="$(gh pr list --head "$1" --state merged --limit 1 \
        --json number,headRefOid --jq '.[0] | "\(.number) \(.headRefOid)"' 2>/dev/null || true)"
  [[ -z "$out" || "$out" == "null null" ]] && return 0
  PR_NUM="${out%% *}"
  PR_HEAD="${out##* }"
}

# True when commit $2 is one of the commits of PR $1, asked of GitHub rather than of the
# local object store. Needed because a merged PR's head is often absent locally: the
# remote branch is deleted on merge, so its final commit was never fetched.
pr_contains_commit() {
  [[ $HAVE_GH -eq 1 && -n "$1" ]] || return 1
  gh pr view "$1" --json commits --jq '.commits[].oid' 2>/dev/null | grep -qx "$2"
}

# Classifies one worktree. Args: <worktree path> <branch> <WT_BASE-relative dir>
classify() {
  local path="$1" branch="$2" dir="$3"
  local tip ahead reason

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
    EMPTY_BRANCHES+=("$branch"); EMPTY_DIRS+=("$dir"); EMPTY_REASONS+=("$reason")
    return
  fi

  find_merged_pr "$branch"
  if [[ -n "$PR_HEAD" ]]; then
    reason="merged PR #$PR_NUM (head ${PR_HEAD:0:9})"
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

  # With a squash merge the branch commits are absent from main by design, so "ahead"
  # is only meaningful against what was actually merged.
  if [[ -n "$PR_HEAD" && "$tip" != "$PR_HEAD" ]]; then
    if git cat-file -e "$PR_HEAD^{commit}" 2>/dev/null; then
      if ! git merge-base --is-ancestor "$tip" "$PR_HEAD" 2>/dev/null; then
        blockers+=("$(git rev-list --count "$PR_HEAD..$branch") local commit(s) not in PR #$PR_NUM")
      fi
    elif ! pr_contains_commit "$PR_NUM" "$tip"; then
      # Merged head not fetched and the tip is not a commit GitHub knows for this PR,
      # so the tip may hold work that never reached the PR.
      blockers+=("tip ${tip:0:9} is not a commit of PR #$PR_NUM (merged head not fetched)")
    fi
  fi

  if [[ ${#blockers[@]} -gt 0 ]]; then
    local joined
    joined="$(printf '%s, ' "${blockers[@]}")"
    BLOCKED_BRANCHES+=("$branch"); BLOCKED_DIRS+=("$dir")
    BLOCKED_REASONS+=("${joined%, } (${reason})")
  else
    MERGED_BRANCHES+=("$branch"); MERGED_DIRS+=("$dir"); MERGED_REASONS+=("$reason")
  fi
}

# True when $1 sits inside a checkout, where an empty directory is real content rather
# than leftover scaffolding. A container dir is recognised by holding an `app` child
# (the worktree layout is <root>/app, <root>/etl) or a `.git` entry. `etl/` has neither
# a .git nor an app child, so the `app`-sibling test is what protects `etl/data`.
inside_checkout() {
  local d="$1"
  while :; do
    d="$(dirname "$d")"
    [[ "$d" == "$WT_BASE" || "$d" == "/" ]] && return 1
    [[ -d "$d/app" || -e "$d/.git" ]] && return 0
  done
}

# Echoes prunable empty dirs (one pass, deepest first). WT_BASE itself is never a
# candidate, and anything under a checkout is filtered out by inside_checkout.
prunable_empty_dirs() {
  local d
  while IFS= read -r d; do
    [[ "$d" == "$WT_BASE" ]] && continue
    inside_checkout "$d" && continue
    printf '%s\n' "$d"
  done < <(find "$WT_BASE" -mindepth 1 -depth -type d -empty 2>/dev/null)
}

# Removes prunable empty dirs, repeating until a pass removes nothing, so a parent that
# only became empty because its last child was pruned (fix/CPE-1 -> fix/) also goes.
PRUNED_COUNT=0
prune_empty_dirs() {
  local d pass_removed
  while :; do
    pass_removed=0
    while IFS= read -r d; do
      # rmdir, not rm -rf: it refuses to touch a directory that is not actually empty.
      if rmdir "$d" 2>/dev/null; then
        echo "  - $d"
        PRUNED_COUNT=$((PRUNED_COUNT + 1))
        pass_removed=$((pass_removed + 1))
      fi
    done < <(prunable_empty_dirs)
    [[ $pass_removed -eq 0 ]] && break
  done
}

# Walk registered worktrees. Both the branch and the directory come from git, since a
# worktree's directory name does not have to match the branch checked out in it.
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
      # Worktrees live at <root>/app; <root> is what remove-worktree deletes.
      root="${wt_path%/app}"
      REGISTERED_ROOTS+=("$root")
      classify "$wt_path" "$branch" "${root#$WT_BASE/}"
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

# Renders one bucket. Args: <label> <count> then branches/dirs/reasons via name refs is
# not available in bash 3.2, so each caller loops itself.
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
    MERGED_DIRS+=("${EMPTY_DIRS[@]}")
    MERGED_REASONS+=("${EMPTY_REASONS[@]}")
  else
    echo "    Nothing was merged for these — they may be worktrees you just created."
    echo "    Remove with --include-empty, or by hand:  cd $REPO && task remove-worktree -- <dir>"
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
    MERGED_DIRS+=("${BLOCKED_DIRS[@]}")
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

if [[ ${#MERGED_BRANCHES[@]} -gt 0 ]]; then
  echo "To remove (${#MERGED_BRANCHES[@]}):"
  i=0
  while [[ $i -lt ${#MERGED_BRANCHES[@]} ]]; do
    echo "  - dir ${MERGED_DIRS[$i]}"
    echo "      branch ${MERGED_BRANCHES[$i]} — ${MERGED_REASONS[$i]}"
    i=$((i + 1))
  done
  echo ""
fi

if [[ $DRY_RUN -eq 1 ]]; then
  if [[ $PRUNE_DIRS -eq 1 ]]; then
    EMPTY_DIRS_NOW="$(prunable_empty_dirs || true)"
    if [[ -n "$EMPTY_DIRS_NOW" ]]; then
      echo "Empty directories to prune:"
      printf '%s\n' "$EMPTY_DIRS_NOW" | sed 's|^|  - |'
      echo "    Parents left empty by these (and by the removals above) are pruned too."
      echo ""
    fi
  fi
  echo "Dry run — nothing removed."
  exit 0
fi

if [[ ${#MERGED_BRANCHES[@]} -eq 0 ]]; then
  if [[ $PRUNE_DIRS -eq 1 ]]; then
    echo "No worktrees to remove; pruning empty directories..."
    prune_empty_dirs
    echo "Pruned $PRUNED_COUNT empty director$([[ $PRUNED_COUNT -eq 1 ]] && echo y || echo ies)."
  else
    echo "Nothing to remove."
  fi
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
i=0
while [[ $i -lt ${#MERGED_BRANCHES[@]} ]]; do
  dir="${MERGED_DIRS[$i]}"
  branch="${MERGED_BRANCHES[$i]}"
  i=$((i + 1))
  echo ""
  echo "=============================================================="
  echo "==> task remove-worktree -- $dir"
  echo "=============================================================="
  if ! (cd "$REPO" && task remove-worktree -- "$dir"); then
    echo "    FAILED for $dir" >&2
    FAILED+=("$dir")
    continue
  fi
  # The task deletes the branch only when it is named like the directory. When they
  # differ its `git branch -D <dir>` is a no-op, so finish the job here.
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    echo "==> Deleting branch $branch..."
    git branch -D "$branch" || { echo "    Could not delete branch $branch" >&2; FAILED+=("$branch (branch)"); }
  fi
done

if [[ $PRUNE_DIRS -eq 1 ]]; then
  echo ""
  echo "==> Pruning empty directories under $WT_BASE..."
  prune_empty_dirs
  [[ $PRUNED_COUNT -eq 0 ]] && echo "  (none)"
fi

echo ""
removed=$(( ${#MERGED_BRANCHES[@]} - ${#FAILED[@]} ))
echo "Removed $removed of ${#MERGED_BRANCHES[@]} worktree(s), pruned $PRUNED_COUNT empty director$([[ $PRUNED_COUNT -eq 1 ]] && echo y || echo ies)."
if [[ ${#FAILED[@]} -gt 0 ]]; then
  printf 'Failed: %s\n' "${FAILED[*]}" >&2
  exit 1
fi
