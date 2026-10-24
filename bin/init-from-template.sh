#!/usr/bin/env bash
# Turn a copy of this repository into a starting point for one application.
#
#   bin/init-from-template.sh my-service --port 8080
#
# Copies the starter app to src/<name>, writes projects/<name>.yaml, and checks the pair with the doctor. It
# does not touch the demo application or the sample project definition — delete those when you are confident.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:?usage: init-from-template.sh <name> [--port 8080]}"; shift
PORT=80
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:?}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -d "src/$NAME" ] && { echo "src/$NAME already exists" >&2; exit 2; }

mkdir -p "src/$NAME"
cp templates/starter/App.csproj "src/$NAME/$NAME.csproj"
cp templates/starter/Program.cs "src/$NAME/Program.cs"
cp templates/starter/App.Tests.csproj "src/$NAME/$NAME.Tests.csproj"
cp templates/starter/ContractTests.cs "src/$NAME/ContractTests.cs"

# The starter's test project references App.csproj; rename the reference to the new project.
python3 - "$NAME" <<'PY'
import pathlib, sys
name = sys.argv[1]
p = pathlib.Path(f"src/{name}/{name}.Tests.csproj")
p.write_text(p.read_text().replace("../App.csproj", f"../{name}.csproj"))
PY

cat > "projects/$NAME.yaml" <<YAML
name: $NAME
description: ""
profile: windows-iis
solution: src/$NAME/$NAME.csproj
tests: src/$NAME/$NAME.Tests.csproj
target_framework: net8.0

artifact:
  type: nuget
  id: $NAME

deploy:
  targets: [iis]
  iis:
    site: $NAME
    app_pool: $NAME
    port: $PORT
    physical_path: C:\\\\app\\\\custom
    health_path: /healthz
    version_path: /version

build:
  vs_edition: enterprise
  dotnet_channel: "8.0"

validation:
  expect_otel: false
  smoke_paths: [/healthz, /version]
YAML

python3 bin/validate-projects.py >/dev/null && echo "projects/$NAME.yaml validates"
bin/framework-doctor "projects/$NAME.yaml" || { echo "the doctor found a mismatch - see above" >&2; exit 1; }

cat <<TXT

Created:
  src/$NAME/            starter application + contract tests
  projects/$NAME.yaml   build/deploy definition

Next:
  1. git rm -r src/WinBuild.SampleApp src/WinBuild.SampleApp.Tests projects/sample-app.yaml   # when ready
  2. dotnet sln add src/$NAME/$NAME.csproj src/$NAME/$NAME.Tests.csproj
  3. Set the repository variables (see docs/GETTING-STARTED.md) and push to main.
TXT
