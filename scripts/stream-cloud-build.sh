#!/usr/bin/env bash
# Submit a Cloud Build and stream it into the GitHub Actions log while it runs.
#
# `gcloud builds submit` without --async does stream, but it gives you raw lines: you cannot tell a Packer
# provisioner from a Windows installer failure at a glance. This wrapper adds the things that make a live log
# readable in Actions:
#
#   ::group::  a collapsible section per Cloud Build step
#   ::notice:: milestones (build started, image created, build finished) with elapsed time
#   ::warning:: / ::error::  on failure, pointing at the step that failed
#
# and it exits non-zero if the build fails, so the workflow does not have to trust the log text.
#
# Usage: scripts/stream-cloud-build.sh <cloudbuild.yaml> <substitutions> [project]
set -uo pipefail

CONFIG="${1:?usage: stream-cloud-build.sh <cloudbuild.yaml> <substitutions> [project]}"
SUBS="${2:-}"
PROJECT="${3:-${GCP_PROJECT:-}}"

started=$(date +%s)
elapsed() { printf '%dm%02ds' $(( ($(date +%s) - started) / 60 )) $(( ($(date +%s) - started) % 60 )); }
notice() { echo "::notice title=cloud-build::$1"; echo "[$(elapsed)] $1"; }
warn()   { echo "::warning title=cloud-build::$1"; echo "[$(elapsed)] WARN $1"; }

notice "submitting $CONFIG"

submit_args=(builds submit --config "$CONFIG" --async --format='value(id)')
[ -n "$SUBS" ] && submit_args+=("--substitutions=$SUBS")
[ -n "$PROJECT" ] && submit_args+=(--project "$PROJECT")

BUILD_ID="$(gcloud "${submit_args[@]}" 2>/dev/null | tail -1)"
if [ -z "${BUILD_ID:-}" ]; then
  echo "::error title=cloud-build::could not submit the build"
  exit 1
fi
notice "build $BUILD_ID submitted; streaming logs"

LOG_URL="https://console.cloud.google.com/cloud-build/builds/${BUILD_ID}?project=${PROJECT}"
echo "::group::cloud build $BUILD_ID"
echo "live: $LOG_URL"

# Stream, annotating as we go. `gcloud builds log --stream` exits when the build finishes.
if ! gcloud builds log --stream "$BUILD_ID" --project "$PROJECT" 2>&1 | while IFS= read -r line; do
      annotated=0
      case "$line" in
        *"Step #"*"Starting Step"*|*"Step #"*"Pulling image"*)
            echo "::endgroup::"; echo "::group::$line"; annotated=1 ;;
      esac
      case "$line" in
        *"MSBuild"*|*"msbuild"*)  echo "::notice title=msbuild::$line"; annotated=1 ;;
        *"devenv"*)                echo "::notice title=devenv::$line"; annotated=1 ;;
        *"Creating image"*|*"image_name"*) echo "::notice title=image::$line"; annotated=1 ;;
        *"Traceback"*|*"ERROR"*|*"FAILED"*|*"failed"*) echo "::warning title=cloud-build::$line"; annotated=1 ;;
      esac
      # An annotated line already appears as an annotation; do not print it twice.
      if [ "$annotated" -eq 0 ]; then printf '%s\n' "$line"; fi
      # Keep the loop's exit status 0, or `if !` reads the last test as a stream failure.
      true
    done; then
  warn "log stream ended unexpectedly; falling back to status polling"
fi
echo "::endgroup::"

# Poll to a verdict: the stream ending is not the same as the build succeeding.
for _ in $(seq 1 240); do
  status="$(gcloud builds describe "$BUILD_ID" --project "$PROJECT" --format='value(status)' 2>/dev/null)"
  case "$status" in
    SUCCESS) notice "build succeeded in $(elapsed)"; exit 0 ;;
    FAILURE|INTERNAL_ERROR|TIMEOUT|CANCELLED|EXPIRED)
      echo "::error title=cloud-build::build $BUILD_ID ended $status after $(elapsed)"
      gcloud builds describe "$BUILD_ID" --project "$PROJECT" \
        --format='value(steps[].status)' 2>/dev/null | tr ';' '\n' | sed 's/^/  step: /'
      exit 1 ;;
  esac
  sleep 10
done
echo "::error title=cloud-build::build $BUILD_ID did not finish within the wait window"
exit 1
