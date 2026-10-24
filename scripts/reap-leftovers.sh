#!/usr/bin/env bash
# Reaper for machines left up on purpose or by accident.
#
# Runs from the scheduled workflow (and by hand). It deletes instances labelled owner=winbuild-ci whose
# age exceeds their own ttl label, so a troubleshooting machine disappears whether or not anyone remembers
# it. Age is measured from the instance's creationTimestamp, not from a local clock.
set -euo pipefail
: "${PROJECT_ID:?PROJECT_ID is required}"

now=$(date -u +%s)
deleted=0

gcloud compute instances list --project "$PROJECT_ID" \
  --filter="labels.owner=winbuild-ci" \
  --format="csv[no-heading](name,zone.basename(),creationTimestamp,labels.ttl)" |
while IFS=, read -r name zone created ttl; do
  [ -n "${name:-}" ] || continue
  if [ "${ttl:-}" = "none" ]; then echo "skipping $name ($zone): ttl=none (persistent environment)"; continue; fi
  case "${ttl:-}" in
    *h) hours="${ttl%h}"; hours="${hours#debug-}" ;;
    *)  hours=2 ;;
  esac
  case "$hours" in (*[!0-9]*|'') hours=2 ;; esac
  created_s=$(date -u -d "$created" +%s)
  age_h=$(( (now - created_s) / 3600 ))
  if [ "$age_h" -ge "$hours" ]; then
    echo "reaping $name ($zone): age ${age_h}h >= ttl ${hours}h"
    gcloud compute instances delete "$name" --zone "$zone" --quiet || true
    deleted=$((deleted+1))
  else
    echo "keeping $name ($zone): age ${age_h}h < ttl ${hours}h"
  fi
done
