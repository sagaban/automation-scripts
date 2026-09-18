#!/usr/bin/env bash
# Make sure AWS is usable for a docker build before one starts.
#
# The Dockerfiles pull their base images from
# 705137920128.dkr.ecr.us-west-2.amazonaws.com, and the Taskfile resolves
# AWS_REGISTRY with `aws ecr describe-registry`, so a build needs BOTH:
#   * a live SSO session (the token expires, typically daily), and
#   * a fresh docker login against ECR (that token lasts 12h).
# Either one stale and the build dies on the first FROM. This refreshes
# whatever is missing and is a no-op when both are good.
#
# Usage: ensure-aws-session.sh
# Exit status is non-zero if the session could not be refreshed, so callers
# under `set -e` stop before starting a build that would fail anyway.
set -euo pipefail

APP_ROOT="${APP_ROOT:-/Users/santiago/repos/app}"

# ECR auth tokens are valid for 12h; treat them as stale a bit earlier so a
# slow build can't outlive the token it started with.
ECR_LOGIN_TTL_MIN=$((11 * 60))
STAMP_FILE="$HOME/.cache/ensure-aws-session/ecr-login"

# The cheapest call that actually exercises the SSO credentials.
sso_session_active() {
  aws sts get-caller-identity >/dev/null 2>&1
}

# There is nothing to query docker for (a stored ECR auth entry carries no
# expiry), so freshness is tracked by the mtime of our own stamp file.
ecr_login_fresh() {
  [[ -n $(find "$STAMP_FILE" -mmin "-$ECR_LOGIN_TTL_MIN" 2>/dev/null) ]]
}

# Always run from the main checkout: worktrees have no .env of their own, and
# the registry is the same one for every checkout anyway.
login_to_ecr() {
  (cd "$APP_ROOT" && task login-to-aws-ecs)
  mkdir -p "$(dirname "$STAMP_FILE")"
  touch "$STAMP_FILE"
}

if sso_session_active; then
  if ecr_login_fresh; then
    echo "AWS session OK and ECR login still fresh."
    exit 0
  fi
  echo "AWS session OK; refreshing the docker/ECR login..."
  login_to_ecr
  exit 0
fi

echo "No active AWS session — running 'aws sso login'..."
aws sso login
login_to_ecr
