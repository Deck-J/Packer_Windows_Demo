#!/usr/bin/env bash
# Scaffold a project definition and a custom/ step set for a new application.
#
#   bin/new-project.sh my-api --profile windows-iis --solution src/MyApi/MyApi.csproj
#
# It writes projects/<name>.yaml, validates it, and prints the two things it cannot do for you: compile the
# application (that is your code) and decide the IIS site name (that is your operations decision).
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:?usage: new-project.sh <name> --profile <profile> [--solution <path>]}"; shift
PROFILE="windows-iis"; SOLUTION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:?}"; shift 2 ;;
    --solution) SOLUTION="${2:?}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -f "profiles/$PROFILE.yaml" ] || { echo "no such profile: $PROFILE (see profiles/)" >&2; exit 2; }
[ -f "projects/$NAME.yaml" ] && { echo "projects/$NAME.yaml already exists" >&2; exit 2; }
[ -n "$SOLUTION" ] || SOLUTION="src/$NAME/$NAME.csproj"

cat > "projects/$NAME.yaml" <<YAML
# Created by bin/new-project.sh — edit the paths, the site name and the artifact id for this application.
name: $NAME
description: ""
profile: $PROFILE
solution: $SOLUTION
tests: ""
target_framework: net8.0

artifact:
  type: nuget
  id: $NAME

deploy:
  targets: [iis]
  iis:
    site: $NAME
    app_pool: $NAME
    port: 80
    physical_path: C:\\\\app\\\\custom
    health_path: /healthz
    version_path: /version

build:
  vs_edition: enterprise
  dotnet_channel: "8.0"

validation:
  expect_otel: false
YAML

python3 bin/validate-projects.py >/dev/null || {
  echo "the generated definition does not validate — fix projects/$NAME.yaml" >&2
  python3 bin/validate-projects.py || true
  exit 1
}
echo "wrote projects/$NAME.yaml"
echo "next: point solution at your project, set the site/app pool names, then run bin/validate-projects.py"
