# Extending this framework

Three extension points, in increasing order of effort. Almost everything you want is the first one.

## 1. Add an application (`projects/`)

One YAML file per application. The pipeline reads these instead of hard-coding a single solution.

```bash
bin/new-project.sh my-api --profile windows-iis --solution src/MyApi/MyApi.csproj
$EDITOR projects/my-api.yaml        # site name, app pool, artifact id, tests
python3 bin/validate-projects.py    # shape *and* truth: do the paths exist?
```

`bin/validate-projects.py` checks two different things, and both matter:

- **shape** — required keys, allowed values, `name` matching the filename (the schema in `projects/schema/`)
- **truth** — the solution, test project and any `build.extra_steps` files actually exist in the repo

It runs in `pr-checks`, so a project file that points at a path which does not exist fails the pull request
rather than the build.

## 2. Add or change a profile (`profiles/`)

A profile is the *shape* of a build: which steps run, what the deploy does, what the image must provide.

| profile | for |
|---|---|
| `windows-iis` | ASP.NET Core app served by IIS, verified through the load balancer |
| `windows-service` | background Windows service, verified by service state + local health check |
| `installer-vdproj` | Visual Studio Installer project → MSI, needs the IDE and the out-of-proc switch |
| `library` | build and publish only, nothing deployed |

A profile lists `build_steps`, `deploy_scripts`, `validate_scripts` and `requires`. Adding one is a YAML file
plus the scripts it names — no workflow change.

## 3. Add a step (`custom/`)

`custom/build.config.json` is the execution list: ordered steps, each a PowerShell command with a working
directory, environment and timeout. `custom/tests/*.Tests.ps1` are the validation suite, run in both the build
phase and against the load balancer. Both are documented in [`../custom/README.md`](../custom/README.md).

## What is deliberately not abstracted

- **The Windows toolchain**. `packer/scripts/install-toolchain.ps1` installs a specific set, because "which
  Visual Studio" is a licensing and support decision, not a configuration value.
- **The deployment topologies**. Two nodes behind a regional external LB is the demo's shape; changing it means
  changing `infra/`, which is the right place for that decision.
- **Secrets**. Nothing here has a "put your secret here" convenience, because that convenience is how secrets end
  up in repository variables. Secret Manager, referenced by the node, is the path.

## Versioning the framework

- Tag releases (`v1.4.0`); `CHANGELOG.md` records what changed and what breaks.
- A project file's `build.vs_edition`, `dotnet_channel` and workload list are part of its contract: changing them
  changes the image, so they belong in a reviewed PR, not a variable.
- Reusable-workflow packaging (a `workflow_call` entry point another repo can `uses:`) is the natural next step
  and is not done yet — today the framework is copied, not consumed.
