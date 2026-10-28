#!/usr/bin/env bash
# Sets up the Connectivity workspace: clones every component repo next to
# connectivity-platform and creates a go.work so you can change shared
# modules and services together without releasing first.
#
#   workspace/
#   ├── go.work                          (local only, never committed)
#   ├── connectivity-platform/           (this repo)
#   ├── connectivity-contracts/
#   ├── connectivity-go-kit/
#   ├── connectivity-edge-agent/
#   ├── connectivity-ingest-api/
#   └── connectivity-telemetry-processor/
set -euo pipefail

OWNER="${OWNER:-spr732}"
REPOS=(
  connectivity-contracts
  connectivity-go-kit
  connectivity-edge-agent
  connectivity-ingest-api
  connectivity-telemetry-processor
)

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$WORKSPACE"

for repo in "${REPOS[@]}"; do
  if [[ -d "$repo/.git" ]]; then
    echo "updating $repo"
    git -C "$repo" pull --ff-only --quiet
  else
    echo "cloning  $repo"
    git clone --quiet "https://github.com/$OWNER/$repo.git"
  fi
done

if [[ ! -f go.work ]]; then
  go work init "${REPOS[@]/#/./}"
  echo "created go.work"
fi

echo
echo "Workspace ready: $WORKSPACE"
echo "Next: cd connectivity-platform && make tidy && make test && make up"
