#!/usr/bin/env bash
# Drop the anonymous volumes left orphaned by a `docker compose down`.
#
# The backend/frontend services mount anonymous volumes over /app/.venv and
# /app/node_modules. `compose down` removes the containers but keeps those
# volumes, and compose never reattaches them — a later `up` always creates new
# ones — so they pile up as dead weight. Once no container (running OR stopped)
# references one it is unrecoverable garbage, which is exactly what
# `docker volume prune` removes: dangling ANONYMOUS volumes only. Named volumes
# (app_mailpit_data, stack-N_mailpit_data, the db/infrastructure data) need -a
# to be touched, so they are safe.
#
# Call AFTER the teardown (`task stop`, `task stack-down -- N`), so the volumes
# that teardown just orphaned are included in the sweep.
#
# Usage: prune-orphan-volumes.sh
# Never fails the caller: this is cleanup, not a precondition.

# No `set -e` on purpose — see above.
set -uo pipefail

if ! command -v docker &>/dev/null; then
  echo "docker not found; skipping volume cleanup." >&2
  exit 0
fi

orphans=$(docker volume ls --filter dangling=true --filter label=com.docker.volume.anonymous -q 2>/dev/null | wc -l | tr -d '[:space:]')

if [[ "${orphans:-0}" == "0" ]]; then
  echo "No orphaned anonymous volumes to clear."
  exit 0
fi

echo "Clearing $orphans orphaned anonymous volume(s) (named ones like mailpit_data are kept)..."
docker volume prune -f || true
exit 0
