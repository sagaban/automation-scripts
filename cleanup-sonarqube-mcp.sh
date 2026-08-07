#!/usr/bin/env bash
# Clean up leaked mcp/sonarqube containers.
#
# Two-pass cleanup:
#   1. Remove exited/dead/created containers (safe, no risk).
#   2. Force-stop running containers older than MAX_AGE_SECONDS (default 3600 = 1h).
#      Zombie containers from crashed Claude Code sessions keep running forever
#      because `docker run -i --rm` never gets EOF. Active MCP sessions rarely
#      live past an hour, so age is a reliable proxy for "orphaned".
#
# Override threshold:  MAX_AGE_SECONDS=1800 cleanup-sonarqube-mcp.sh   # 30 min

set -u
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

MAX_AGE_SECONDS="${MAX_AGE_SECONDS:-3600}"
IMAGE="mcp/sonarqube"

# Pass 1: remove non-running containers (always safe).
non_running="$(docker ps -a \
  --filter ancestor="$IMAGE" \
  --filter status=exited \
  --filter status=dead \
  --filter status=created \
  -q 2>/dev/null)"
if [ -n "$non_running" ]; then
  echo "$non_running" | xargs docker rm -f >/dev/null 2>&1 || true
fi

# Pass 2: kill running containers older than the threshold.
now_epoch="$(date -u +%s)"
docker ps --filter ancestor="$IMAGE" --format '{{.ID}} {{.CreatedAt}}' 2>/dev/null \
  | while read -r cid created_at; do
      [ -z "$cid" ] && continue
      # CreatedAt format: "2026-05-22 16:15:30 +0200 CEST" — keep first 3 fields.
      ts="$(echo "$created_at" | awk '{print $1, $2, $3}')"
      created_epoch="$(date -j -f '%Y-%m-%d %H:%M:%S %z' "$ts" +%s 2>/dev/null || echo 0)"
      [ "$created_epoch" -eq 0 ] && continue
      age=$(( now_epoch - created_epoch ))
      if [ "$age" -gt "$MAX_AGE_SECONDS" ]; then
        docker rm -f "$cid" >/dev/null 2>&1 || true
      fi
    done
