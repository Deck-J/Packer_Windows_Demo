# `custom/` — the build contract

Everything about *how your application is built* lives here. The pipeline copies this folder to
`C:\packer\custom` on the builder and runs `run.ps1`; the image build fails if any step fails.

```
run.ps1                    the entrypoint: reads build.config.json, runs the steps, writes the logs
build.config.json          what to run, in what order, with what environment and timeout
build.config.example.json  a minimal starting point
scripts/                   the steps themselves, one file each
```

## What a step is

```json
{ "name": "build-and-publish",
  "command": "& 'C:\\packer\\custom\\scripts\\20-build.ps1'",
  "timeoutSeconds": 2400,
  "enabled": true }
```

- `command` runs in PowerShell from `workingDirectory` (default `C:\packer\custom`).
- A non-zero exit fails the image build immediately; nothing is swallowed.
- `timeoutSeconds` defaults to 3600 and kills the step rather than hanging the build.
- `enabled: false` parks a step without deleting it.

## What the shipped example actually does

| step | file | what it configures |
|---|---|---|
| `nuget-config` | `scripts/10-nuget-config.ps1` | writes `NuGet.Config`: public feed, plus GitHub Packages when `GITHUB_REPOSITORY_OWNER` is set, and a build-local package cache |
| `build-and-publish` | `scripts/20-build.ps1` | restore → build with `-warnaserror` → publish to `C:\app\custom`, versioned from `APP_VERSION` |
| `configure-iis` | `scripts/30-configure-iis.ps1` | app pool (`No Managed Code`, ApplicationPoolIdentity, no periodic recycle), site on port 80, `web.config` with out-of-process hosting, app environment, stdout logging to `logs\` |
| `verify-site` | `scripts/40-verify.ps1` | waits for `/healthz` to return `ok`, then prints `/version` and `X-Served-By`; fails the build if it never comes up |
| `optional-static-analysis` | — | `dotnet format --verify-no-changes`, shipped **disabled** because it is slow and opinionated |

That last point is the shape of the thing: the image carries the *capability* (a toolchain, IIS, git,
7-Zip, jq, NuGet, gcloud); `custom/` carries the *decisions* (which app, which pool, which environment,
which checks).

## Adding your own

1. Write a script in `scripts/`, take no arguments, throw on failure, and print what it did.
2. Add a step to `build.config.json`. Give it a timeout you would be happy to wait out.
3. If it needs a secret, take it from instance metadata or Secret Manager inside the script — not from
   this file, which is committed.
4. Run the build. `C:\packer\custom.log` is the transcript and `C:\packer\custom-manifest.json` records
   the sha256 of every file used, so the image knows exactly which recipe produced it.

## Rules that keep it honest

- **Idempotent.** The same folder may run twice on the same machine while you iterate.
- **No absolute build-machine paths** beyond `C:\packer\...` and `C:\app\...`; those are the contract.
- **Fail loudly.** A step that swallows an error produces an image that fails mysteriously later.
- **Nothing here runs at boot.** Node startup is `image/node-startup.ps1`'s job; this folder only shapes
  the image.
