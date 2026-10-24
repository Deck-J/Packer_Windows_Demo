#!/usr/bin/env bash
# Delete everything this run created, in dependency order, then prove the project is empty.
# Safe to run when nothing exists: every step tolerates absence.
set -uo pipefail
cd "$(dirname "$0")"
. lib/common.sh

: "${RUN_ID:?RUN_ID is required}"
say "destroy run $RUN_ID"
fail=0
try() { "$@" --quiet >/dev/null 2>&1 || { warn "not deleted (may not exist): $*"; }; }

# Order matters: front end, then back end, then the machines it describes.
try gcloud compute forwarding-rules delete "wb-${RUN_ID}-fr" --region="$REGION"
try gcloud compute target-http-proxies delete "wb-${RUN_ID}-px" --region="$REGION"
try gcloud compute url-maps delete "wb-${RUN_ID}-um" --region="$REGION"
try gcloud compute backend-services delete "wb-${RUN_ID}-bs" --region="$REGION"
try gcloud compute health-checks delete "wb-${RUN_ID}-hc" --region="$REGION"
try gcloud compute addresses delete "wb-${RUN_ID}-ip" --region="$REGION"
try gcloud compute instance-groups unmanaged delete "wb-${RUN_ID}-ig" --zone="$ZONE_A"

# Machines: delete by label, so a node created outside this script is still caught.
for name in $(gcloud compute instances list --filter="labels.run=$RUN_ID" --format='value(name,zone.basename())' | awk '{print $1":"$2}'); do
  n="${name%%:*}"; z="${name##*:}"
  try gcloud compute instances delete "$n" --zone="$z"
done
# Disks left behind by a deleted instance (boot disks are auto-delete, but a manual disk may linger).
for d in $(gcloud compute disks list --filter="labels.run=$RUN_ID" --format='value(name,zone.basename())' | awk '{print $1":"$2}'); do
  n="${d%%:*}"; z="${d##*:}"
  try gcloud compute disks delete "$n" --zone="$z"
done

say "verifying the project is empty of this run"
./assert-empty-project.sh || fail=1
[ "$fail" -eq 0 ] || die "teardown incomplete - see the inventory above"
say "destroyed (image and shared network deliberately kept)"
