#!/usr/bin/env bash
# Assert that nothing billable from this run survives. Exits non-zero if it finds any.
set -uo pipefail
cd "$(dirname "$0")"
. lib/common.sh

filters="labels.owner=${LABEL_OWNER}"
found=0
check() {
  local what="$1"; shift
  local out
  out="$("$@" 2>/dev/null | grep -v '^NAME' || true)"
  if [ -n "$out" ]; then printf '\033[31mLEFTOVER\033[0m %s:\n%s\n' "$what" "$out"; found=$((found+1)); fi
}

check instances   gcloud compute instances list --filter="$filters" --format='value(name,zone.basename())'
check disks       gcloud compute disks list --filter="$filters" --format='value(name,zone.basename())'
check addresses   gcloud compute addresses list --filter="$filters" --format='value(name,region.basename())'
check forwarding  gcloud compute forwarding-rules list --filter="$filters" --format='value(name,region.basename())'
check backends    gcloud compute backend-services list --filter="$filters" --format='value(name)'
check healthchk   gcloud compute health-checks list --filter="$filters" --format='value(name)'
check proxys      gcloud compute target-http-proxies list --filter="$filters" --format='value(name)'
check urlmaps     gcloud compute url-maps list --filter="$filters" --format='value(name)'
check groups      gcloud compute instance-groups list --filter="$filters" --format='value(name,zone.basename())'

if [ "$found" -gt 0 ]; then
  die "$found resource group(s) from run $RUN_ID still exist"
fi
echo "PASS: no resource labelled owner=${LABEL_OWNER},run=${RUN_ID} remains (image and network are kept by design)"
