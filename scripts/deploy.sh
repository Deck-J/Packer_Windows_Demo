#!/usr/bin/env bash
# Create the two nodes and the load balancer for one run. Idempotent: re-running converges, never forks.
#
# Usage: RUN_ID=abc123 VERSION=1.4.0 PACKAGE_URL=gs://... PACKAGE_SHA256=... NODE_SA=... scripts/deploy.sh
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

INST_A="wb-${RUN_ID}-a"
INST_B="wb-${RUN_ID}-b"
export INST_A INST_B NODE_NAMES="$INST_A,$INST_B"

say "deploy run $RUN_ID (version $VERSION)"
ensure_network
ensure_node "$INST_A" "$ZONE_A"
ensure_node "$INST_B" "$ZONE_B"
ensure_lb
wait_backends_healthy 40
say "deployed"
echo "LB_IP=$(cat lb-ip.txt)" >> "${GITHUB_OUTPUT:-/dev/null}"
gcloud compute instances list --filter="labels.run=$RUN_ID" \
  --format='table(name,zone.basename(),status,networkInterfaces[0].networkIP)' | sed 's/^/  /'
