# Runbook

## 1. First-time setup (once)

1. **Project** — create the GCP project, link billing, note the project ID and billing account ID.
2. **Bootstrap workflow** — in Cloud Shell run `gcloud auth print-access-token`, save it as the repository
   secret `GCP_BOOTSTRAP_TOKEN`, then dispatch **bootstrap** with the project ID, billing account, region and
   `BOOTSTRAP` as the confirmation. It runs behind the `bootstrap` environment (required reviewers).
3. **Delete the secret** — the token is valid for ≤60 minutes anyway.
4. **Repository variables** (Settings → Secrets and variables → Actions → *Variables*):
   `GCP_PROJECT`, `GCP_REGION`, `GCP_ZONE`, `WIF_PROVIDER`, `DEPLOYER_SA`, `NODE_SA`, `BUILDER_SA`,
   `STATE_BUCKET`, `ARTIFACT_BUCKET`, `BUILD_BUCKET`.
5. **Verify** — the bootstrap workflow's `verify` job authenticates the pipeline's way (impersonation, no
   key) and must print the deployer service account.
6. **Branch protection** — require PR, require review, require the `pr-checks` jobs, linear history.

## 2. A normal run, and what you see while it runs

Every phase announces itself: a banner, a collapsible log group, and a verdict row appended to the run summary.
The numbering is fixed across workflows so a log reads as a sequence rather than a pile of jobs:

| phase | where | what it is |
|---|---|---|
| 1 | `bootstrap` workflow (once) | project, buckets, service accounts, WIF, budget |
| 2 | `pipeline` / build-image | **build builder — building application** |
| 3 | `pipeline` / build-image | **build succeeded** (milestone: the image exists) |
| 4 | `pipeline` / publish | **upload to GitHub Packages** |
| 5 | `pipeline` / publish | **upload succeeded** (milestone: the package is there) |
| 6 | `pipeline` / deploy | **deploy nodes** |
| 7 | `pipeline` / verify | **testing deployment** |
| 8 | `pipeline` / destroy | teardown |
| 9 | `pipeline` / audit | cost audit — nothing left billing |

Phases 3 and 5 are milestones inside 2 and 4 rather than jobs of their own: they mark the moment the artefact
exists, which is what stops "the build job passed" from being confused with "the image was produced".

The `build-image` job does not fire-and-wait: `scripts/stream-cloud-build.sh` submits the build asynchronously
and streams its log into the Actions log as it happens, annotating the lines that matter.

- a collapsible **group per Cloud Build step**
- `::notice::` milestones: build submitted (with the console URL and elapsed time), image creation, build result
- `::notice::` lines for the demo builds, so `msbuild-demo` and `devenv-build` are visible as they run
- `::warning::` on lines containing errors, and on stream failures
- a final verdict from `gcloud builds describe` — the stream ending is not the same as the build succeeding, so it
  polls the build status and fails the job on `FAILURE`, `TIMEOUT`, `CANCELLED` or a stuck build

The Windows-side progress comes through the same stream: Packer prints each provisioner's output, and our
scripts log `msbuild: <path>`, `devenv: <path>`, `[step] starting/failed` lines, which the streamer highlights.
Clicking the console URL gives the same log with Cloud Build's own grouping if you prefer that view.

## 2b. A normal run

Merge to `main` (or dispatch `pipeline`). Expect ~55–75 minutes end to end, most of it the Build Tools
install inside the image build. The run summary carries: image name, package version + sha256, LB IP,
teardown result.

## 3. When it fails

| Symptom | Where to look | Likely cause |
|---|---|---|
| Cloud Build fails at `packer-build` | Cloud Build log, then `gs://<build bucket>/image-builds/<version>/` | WinRM never came up (IAP/firewall), installer download blocked (no egress), Build Tools exit code |
| `verify` fails with one node | `gcloud compute backend-services get-health <run>-bs --region=…` | node startup script failed: read `C:\app\status.json` over IAP RDP, or the serial console |
| `verify` fails with wrong version | `/version` output in the log | node installed a stale object, or the image's baked copy answered because the package install failed |
| `audit` finds leftovers | the printed inventory | `terraform destroy` was skipped (check the `deploy` result) or a resource was made outside Terraform |
| Run dies mid-flight | `gh run list`, then the label sweep by hand | runner lost: teardown must be done manually — `terraform destroy` with the same vars, then the sweep |

## 3a. Build Tools or the full IDE

The image installs **Visual Studio Build Tools** by default: MSBuild, the C++ compiler, the Windows SDK and
the .NET SDK — everything a build agent needs, and the edition Microsoft licenses for unattended agents.

Some project types only build with the **full IDE** installed, because their MSBuild tasks or workloads ship
with Visual Studio itself or with a VSIX extension:

| project type | what is missing in Build Tools |
|---|---|
| UWP / WinUI, Windows Application Packaging (MSIX) | `Microsoft.VisualStudio.Workload.UniversalBuildTools` plus packaging targets |
| .NET MAUI, Android, iOS | mobile workloads and their SDKs |
| Office / VSTO add-ins | Office developer tools |
| SSDT (SSIS/SSRS/SSAS) | SQL Server Data Tools workload |
| Windows drivers | WDK integration that expects an IDE install |
| anything using a third-party VSIX that ships MSBuild tasks | the extension itself |

Switch edition with two Packer variables (both validate; nothing else changes):

```bash
-var "vs_edition=enterprise" \
-var "vs_workloads=Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools,Microsoft.VisualStudio.Workload.UniversalBuildTools"
```

- `vs_edition`: `buildtools` (default) | `community` | `professional` | `enterprise`
- `vs_workloads`: comma-separated workload/component IDs; empty means desktop .NET + C++ build tools + Windows 11 SDK

Costs of switching: the image grows from ~15 GB to 30-45 GB, the bake takes 15-30 minutes longer, and
**licensing is yours to confirm** — Community on a shared build server is not the intended use, and
Professional/Enterprise need a subscription. That is why the default is Build Tools and the switch is explicit.

### The demo builds both ways, in one image

`custom/build.config.json` runs, in order: `dotnet` build+publish (the app), **`msbuild-demo`** (legacy .NET
Framework project via MSBuild.exe), **`devenv-build`** (the same project via the IDE), then IIS configuration,
site verification and the validation suite.

Both demo steps write `C:\packer\demo-manifest.json`, and `custom/tests/15-build-demo.Tests.ps1` fails if either
kind is missing or a recorded artefact hash no longer matches. The image defaults to `vs_edition=enterprise`
via the pipeline; set the `VS_EDITION` repository variable to `buildtools` for the smaller agent-licensed image
(the devenv step then reports a skip instead of a build).

### Demonstrating a devenv build

`custom/scripts/25-devenv-build.ps1` is a step in the build: it finds `devenv.com` with `vswhere`, builds
`WinBuild.sln` as `Release|x64`, prints the tail of the IDE's own build log, and asserts the assembly exists
(failing on a missing artefact even when the exit code is zero).

- On a **Build Tools** image it logs that `devenv` is absent and skips. It does not pretend.
- On an **IDE** image (`vs_edition=community|professional|enterprise`) it builds for real.

Evidence, inspectable on the machine (use `debug_keep_vm=true` or `scripts/debug-vm.sh`):

| file | what it proves |
|---|---|
| `C:\packer\devenv.log` | that `devenv.com` was located, which path, the command line, exit code, artefact sha256 |
| `C:\packer\devenv-build.log` | the IDE's own build log for the solution |
| the assembly in `bin\...\Release` | that something was actually produced |

For a `.vdproj` (installer MSI) rather than a plain solution build, see
[`demo/README.md`](../demo/README.md): it needs the Installer Projects VSIX (`vs_extra_vsix_urls`) and usually
`vs_disable_out_of_proc_build=true`.

### Disabling out-of-process builds

A related switch, and the one people hit with older projects: `.vdproj` installer projects, SSDT/SSRS report
projects, VSTO and Office add-ins often fail from a command line because `devenv` builds them **out of
process**. Visual Studio ships `DisableOutOfProcBuild.exe` (under
`Common7\IDE\CommonExtensions\Microsoft\VSI\DisableOutOfProcBuild`) which turns that off.

Set it per image:

```bash
-var "vs_edition=enterprise" -var "vs_disable_out_of_proc_build=true"
```

Two honest caveats:

- It writes a **per-user** registry value (HKCU). Provisioning runs it as the account that builds the image, so
  builds that run as *that* account are covered. If your build runs as a different user, the value must be set
  for that user too — the provisioning log prints what it found under
  `HKCU:\Software\Microsoft\VisualStudio`, so you can see whether it was applied rather than assuming.
- It needs **devenv**, i.e. the full IDE. With `vs_edition=buildtools` the flag is ignored with a warning.

Also worth setting for stubborn projects (COM-heavy, or parallel builds that deadlock): `MSBUILDDISABLENODEREUSE=1`
(already in `custom/build.config.json`) and `-m:1` on the build command.

The `dotnet` CLI is present throughout (`dotnet build`, `dotnet test`, `dotnet publish`, `dotnet pack`), so a
project that builds with the SDK alone never needs the IDE at all.

## 3b. Custom build steps

The build does not hard-code how the application is compiled. `custom/build.config.json` lists steps; each
runs in PowerShell from `workingDirectory` with the configured environment, and the first non-zero exit
fails the image build.

The shipped config is a working example, not a placeholder — it configures NuGet, builds and publishes the
app, configures IIS (app pool, site, `web.config` with out-of-process hosting and app environment), and
then proves `/healthz` answers before the image is captured:

| step | file |
|---|---|
| nuget-config | `custom/scripts/10-nuget-config.ps1` |
| build-and-publish | `custom/scripts/20-build.ps1` |
| configure-iis | `custom/scripts/30-configure-iis.ps1` |
| verify-site | `custom/scripts/40-verify.ps1` |
| optional-static-analysis (shipped disabled) | `dotnet format --verify-no-changes` |

- No `build.config.json` means "nothing custom" — the image still builds, it just does not compile anything
  of yours.
- `C:\packer\custom.log` is the full transcript; `C:\packer\custom-manifest.json` hashes every file used.
- Secrets do not belong in this file. Read them from metadata or Secret Manager inside a step.

## 3c. Leaving the build machine up for troubleshooting

Dispatch `pipeline` with **debug_keep_vm = true** (and optionally `debug_ttl_hours`, default 4):

- teardown is skipped;
- a Packer failure leaves the builder running (`-on-error=abort`), which is the machine that holds the
  half-installed toolchain and the build log you actually want;
- a local administrator `packer-debug` is created with a per-build password stored as the Secret Manager
  secret `winbuild-debug-<cloud-build-id>`;
- RDP is enabled but the rule only admits `35.235.240.0/20`, so the connection is:

```bash
gcloud secrets versions access latest --secret=winbuild-debug-<cloud-build-id>
gcloud compute start-iap-tunnel <instance> 3389 --local-host-port=localhost:13389 --zone=<zone>
# then RDP to localhost:13389 as packer-debug
```

If the build **succeeded** there is no surviving machine — create one from the image instead:
`PROJECT_ID=… NODE_SA=… TTL=4h scripts/debug-vm.sh`.

Cleanup is not your job: the instance is labelled `ttl=debug-<n>h` and `reaper.yml` deletes it on schedule.

## 3d. Environments, approval and promotion

Three levels, all enforced by GitHub rather than by convention:

| level | how it is triggered | guard |
|---|---|---|
| PR | `pr-checks` on every pull request | must pass before merge; branch protection requires it |
| test (ephemeral) | merge to `main` runs `pipeline` | jobs run in the **gcp-test** environment; everything is destroyed afterwards |
| production (persistent) | `promote` workflow, tag input + typed `PROMOTE` | runs in the **gcp-prod** environment, which requires reviewers in repository settings |

Set this up once, in Settings → Environments:

1. **`gcp-test`** — no reviewers, no wait timer. It exists so test deploys are labelled and auditable, and
   so a future rule (a wait timer, a branch policy) has somewhere to attach.
2. **`gcp-prod`** — **Required reviewers** (yourself, and anyone else who should be able to release),
   optionally a wait timer. Do not add a deployment branch rule: promotion runs from a tag.
3. **Settings → Actions → General** — leave "Allow GitHub Actions to create and approve pull requests"
   **off**; nothing here needs it.

Promotion deploys exactly what was tested: the image name and the package sha256 come from the
`release-manifest.json` attached to the tag, the `.nupkg` is downloaded from the same release and re-hashed
before use, and nothing is rebuilt. Resources are labelled `ttl=none`, so the reaper leaves them alone, and
`promote` has no teardown job by design.

```bash
git tag -a v1.4.0 -m "1.4.0" && git push origin v1.4.0     # builds a release-named image + package
gh workflow run promote.yml -f tag=v1.4.0 -f confirm=PROMOTE  # waits for the gcp-prod approval
```

## 3e. Dynatrace OneAgent

The agent is installed **at node startup, not into the image**. An image carrying a tenant token cannot be
shared between environments and turns every image copy into a credential; a node that reads the token from
Secret Manager can be rotated without rebuilding anything.

Set up once:

1. In Dynatrace, create a **PaaS token** with *Installer download* and *Host group* permissions.
2. Store it in Secret Manager:
   ```bash
   printf '%s' '<token>' | gcloud secrets create dynatrace-oneagent-token --data-file=- --replication-policy=automatic
   ```
3. Let the node service account read it (the bootstrap does this if `DYNATRACE_TOKEN_SECRET` is set, and it
   is idempotent):
   ```bash
   gcloud secrets add-iam-policy-binding dynatrace-oneagent-token \
     --member="serviceAccount:sa-winbuild-node@$PROJECT.iam.gserviceaccount.com" \
     --role="roles/secretmanager.secretAccessor"
   ```
4. Repository **variables** (not secrets — these are identifiers):
   `DYNATRACE_TENANT` (e.g. `abc12345`), `DYNATRACE_HOST_GROUP` (default `winbuild-test`), and
   `DYNATRACE_TOKEN_SECRET` (the secret name above).

What the node does at boot, in `image/node-startup.ps1`: reads the tenant from metadata, fetches the token
with its own service account, downloads the OneAgent MSI for that tenant, installs it with `TENANT`,
`TENANT_TOKEN` and `HOST_GROUP`, waits for the Dynatrace services to be running, records the host tags in
`C:\app\status.json`, and deletes the MSI. If the tenant metadata is empty the step is skipped; if the
token cannot be read the node fails loudly rather than half-installing.

### Getting a tenant for a test

- **Dynatrace Playground** (`dynatrace.com/signup/playground`) — free, instant, pre-loaded with sample data.
  Good for seeing what the dashboards should look like. It is a shared demo tenant and **you cannot install
  an agent into it**, so it does not exercise this pipeline.
- **Free trial** (`dynatrace.com/signup`) — no credit card, 15 days, your own tenant (`<env>.live.dynatrace.com`)
  with a PaaS token you can create yourself. This is the one that works for testing the install.
  It expires, the tenant is deleted, and after that the pipeline fails at the agent step — which is why
  `DYNATRACE_TENANT` is unset by default rather than something you have to remember to remove.
- **No tenant at all** — `DYNATRACE_DRY_RUN=true`, **which is the default on the test pipeline today**. The
  node treats the tenant as a placeholder, records what it found, and stops before downloading anything:

  | what is configured | what the node does | `C:\app\status.json` stage |
  |---|---|---|
  | nothing | skips the step entirely | `dynatrace: not configured` |
  | dry-run only | proves metadata is wired, downloads nothing | `dry run: no token secret configured, nothing downloaded` |
  | dry-run + secret name | proves metadata **and** Secret Manager IAM | `dry run: tenant ..., secret '<name>' readable, install skipped` |
  | real tenant + secret, no dry-run | full install | `dynatrace: running; host tags: ...` |

  Promotion does **not** default to dry-run: `DYNATRACE_DRY_RUN_PROMOTE` is `false` unless set, so a real
  tenant is required before anything reaches production.

Things worth knowing before you turn it on:

- **Unset `DYNATRACE_TENANT` = no agent.** That is the default, so the pipeline costs nothing until you opt in.
- **Ephemeral nodes create host units.** A node that lives 20 minutes still registers as a host; name the
  host group per environment (`winbuild-test`, `winbuild-prod`) so test churn is visible and separable in
  the Dynatrace UI rather than polluting production.
- **The build machine is not monitored by default.** If you want build visibility, install the agent in
  `custom/` as a step (token from Secret Manager the same way) — but it will consume a host unit per build.
- **Token rotation is a secret update**, not a pipeline change: add a new secret version and the next node
  picks it up.

## 3f. OpenTelemetry (the vendor-neutral path)

The sample app is instrumented with OpenTelemetry: ASP.NET Core and HttpClient spans, runtime metrics, plus
demo instrumentation you can see working (`/demo/checkout` creates a parent span, a `pricing` child, a
`persist-order` client span, a counter and a histogram).

Where the data goes is **configuration, not code**:

| variable | meaning |
|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` (repo variable → Terraform `otel_endpoint` → instance metadata) | OTLP endpoint, e.g. `http://collector:4317` |
| `OTEL_SERVICE_NAME` | defaults to `WinBuild.SampleApp` |
| `OTEL_ENABLED` | forces export on/off; otherwise an endpoint means on, no endpoint means off |

The image bakes `__OTEL_ENDPOINT__` / `__OTEL_ENABLED__` placeholders into `web.config`; the node replaces
them at boot from metadata. So one image, any backend, no rebuild.

`/telemetry` returns what the instance decided — `enabled`, `service`, `endpoint`, `environment`, `version` —
which is how the test suite asserts that a node really is exporting (`EXPECT_OTEL=true`) rather than assuming.

To try it without any vendor: run a collector somewhere reachable (a container on the NAS is enough), set
`OTEL_EXPORTER_OTLP_ENDPOINT` to it, and call `/demo/checkout` through the load balancer. The traces land in
the collector's log — no tenant, no licence.

## 4. Cheap recovery

```bash
# what exists from this run?
gcloud compute instances list --filter="labels.owner=winbuild-ci AND labels.run=<run>"
# tear it down without Terraform (last resort)
gcloud compute instances delete $(gcloud compute instances list --filter="labels.run=<run>" --format='value(name)') --zone=<zone>
# then let the audit job tell you the truth
bash scripts/assert-empty-project.sh
```

## 5. Cost watch

`docs/COST.md`. Anything idle above ~$1/month is a bug: the image (~$0.60) is the only intended steady cost.
