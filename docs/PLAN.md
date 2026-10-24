# Project plan — Windows build pipeline → GitHub Packages → two-node GCP deploy → teardown

**Status:** draft, pending merge of the Codex and Qwen design reviews (`PLAN-CODEX.md`, `PLAN-QWEN.md`).
**Owner:** John Decker. **Target:** one repository, one GCP project, everything driven from a standard
GitHub-hosted `ubuntu-latest` runner.

---

## 1. The outcome in one paragraph

A merge to `main` starts a GitHub Actions workflow on a standard hosted runner. The workflow
authenticates to GCP with Workload Identity Federation (no keys), asks Cloud Build to build a **Windows
Server image** containing Visual Studio Build Tools, the Windows build libraries and the sample
application, and publishes the application as a versioned **NuGet package in GitHub Packages**. The same
workflow then creates **two Windows nodes** behind a **load balancer** from that image, installs the exact
package it just published, proves the application answers **through the load balancer** on both nodes,
and then **destroys every billable resource** — including when a step fails. The image is kept; nothing
else is.

## 2. Requirement critique — what is risky or underspecified

These are the points where the requirement as written would fail in practice, and what this plan does
about each.

| # | Problem in the requirement | Consequence if ignored | Decision |
|---|---|---|---|
| 1 | **Cloud Build does not have Windows workers.** Its workers are Linux containers; there is no `windows` machine type. | A design that says "Cloud Build runs MSBuild" is unimplementable. | Cloud Build *orchestrates* a temporary Windows VM; the VM does the Windows work (see §4.1). |
| 2 | **"Visual Studio Community edition" on a build agent.** Community's licence is for individuals and small organisations and is not the natural licence for shared build infrastructure. | Licence non-compliance on a corporate image. | Build with **Visual Studio Build Tools 2022** (free, purpose-built, no IDE). A Community-equipped variant stays available as an option for interactive/dev images only, with the licence question recorded as an ADR and answered by whoever owns licensing. |
| 3 | **"Artifact placed in GitHub Packages"** — Packages supports NuGet, npm, Maven, RubyGems and containers, not arbitrary binaries. | An `app.zip` cannot be "in Packages"; a Release asset is a different feature. | Publish a **NuGet package** (`WinBuild.SampleApp`, semver from git) with symbols; that is the system of record. |
| 4 | **Two nodes + "reachable through the load balancer"** is not a test unless direct access is impossible. | A test that hits the LB IP but is served by one node proves nothing, and a test that hits nodes directly proves less. | Firewall admits port 80 **only** from Google's LB ranges; nodes return `X-Served-By: <instance>`; the test asserts the LB IP returns 200 **and** that both instance names appear. |
| 5 | **"Spin everything down"** — an image cannot be spun down, and a failed run must tear down too. | Overnight Windows VMs, orphaned disks, LB forwarding rules billing while idle. | `scripts/destroy.sh` under `if: always()`, plus an inventory assertion, a delayed billing reconciliation, and a janitor as defence in depth (§4.6). |
| 6 | **Image containing "the sample application"** conflicts with deploying the *published* artifact — which version is running? | Nodes silently run the baked copy instead of the package under test. | Both, deliberately: the image bakes a smoke-testable copy from the same commit, and nodes are deployed by **installing the published package version**, which `/version` then proves. The baked copy is never what the test asserts on. |
| 7 | **A standard hosted runner cannot run Windows or hold credentials.** | Any design needing a Windows runner or a service-account JSON key is out of scope. | Everything Windows happens in GCP; auth is WIF; the runner only holds an OIDC token. |

## 3. Architecture

```
GitHub (push to main / workflow_dispatch)
        │  ubuntu-latest runner, OIDC token
        ▼
┌─────────────────────────────────────────────────────────────────────┐
│ GitHub Actions workflow  .github/workflows/pipeline.yml             │
│  job build   → auth (WIF) → gcloud builds submit cloudbuild.image.yaml
│  job publish → dotnet pack → GitHub Packages (nuget.pkg.github.com) │
│  job deploy  → scripts/deploy.sh (2 nodes + LB + firewall, gcloud)  │
│  job verify  → curl LB IP /healthz /version, backend health, 2 nodes │
│  job destroy → scripts/destroy.sh  [if: always()]                   │
│  job audit   → scripts/assert-empty-project.sh + billing check      │
└─────────────────────────────────────────────────────────────────────┘
        │                                   ▲
        ▼                                   │ artifact transport
   Cloud Build (Linux workers)               │ (exact .nupkg bytes)
   ├─ step: create builder VM  ──► Windows Server 2022 VM
   │        startup-script installs Build Tools + SDK + .NET,
   │        builds the sample app, stages C:\app, writes status to GCS
   ├─ step: poll status         ──► gs://<bucket>/image-build/<run>/status.json
   ├─ step: gcloud compute images create winbuild-app-<version>
   └─ step: delete builder VM (also on failure)
                                             │
                              gs://<bucket>/artifacts/<version>/*.nupkg
                                             │
                    ┌────────────────────────┴────────────────────────┐
                    ▼                                                 ▼
            Windows node 1 (us-central1-a)                  Windows node 2 (us-central1-b)
            192.168.x.x — no public ingress except LB ranges
                    └────────────► regional external Application LB ◄───┘
                                   static IP, health check /healthz
```

## 4. Component decisions

Each decision gets an ADR in `docs/adr/` at implementation time; the reasoning is here first.

### 4.1 How Cloud Build produces a Windows image

Three options were weighed:

1. **Packer with the `googlecompute` builder** — standard, declarative, idempotent, but needs inbound
   WinRM/SSH to the builder VM and a baked password, i.e. a management plane exposed for the duration of
   the build.
2. **Cloud Build orchestrating a temporary VM** — `gcloud compute instances create` with
   `windows-startup-script-ps1` metadata; the script installs, builds and writes a status object to GCS;
   a Cloud Build step polls that object; `gcloud compute images create` snapshots the boot disk; the VM
   is deleted. No inbound management port, credentials never leave the instance's own service account.
3. **Native Windows workers in Cloud Build** — not available for public pools. Rejected as
   unimplementable today; revisit if Google ships it.

**Chosen: option 2.** The reasons are security-shaped, not preference: no WinRM listener, no password in
a template, and the only control channel is an outbound HTTPS write to a bucket. Packer remains the
documented alternative (ADR-0002) if the image later needs multi-cloud parity.

**Consequence to accept:** the startup script is now production code that must be versioned, tested and
idempotent, and its logs are the build's primary evidence. It is treated as such (unit-tested PowerShell
modules, `-ErrorAction Stop`, structured status JSON, retry-wrapped installers).

### 4.2 What the image contains

Windows Server 2022 Datacenter (public image, licence included in the GCE Windows premium), Visual
Studio Build Tools 2022 with the `Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools` and
`NativeDesktopBuildTools` workloads, Windows 10/11 SDK, .NET 8 SDK, IIS + ASP.NET Core Hosting Bundle,
and the built sample app at `C:\app` with its service registered. The image is versioned
`winbuild-app-<semver>-<gitshort>` and published to a family `winbuild-app` so the deploy script can pin *either* a
version (reproducibility) or the family (rolling).

### 4.3 Artifact and its transport

- **Build**: `dotnet pack -p:Version=<semver>` → `WinBuild.SampleApp.<semver>.nupkg` + `.snupkg`.
- **Publish**: `dotnet nuget push` to `https://nuget.pkg.github.com/<owner>/index.json` with the
  workflow's `GITHUB_TOKEN` (`packages: write`); the package is immutable per version, so a rebuild must
  bump the version, never overwrite.
- **Transport to nodes**: the deploy job downloads the exact `.nupkg` it published, records its sha256,
  uploads it to a versioned bucket, and nodes install from there with their own service account. Nodes
  therefore need **no** GitHub credential — the alternative (a PAT on every node) is the classic
  credential-sprawl finding.
- **Version scheme**: `MinVer`/`GitVersion` from tags; pre-release suffix on `main` builds
  (`1.4.0-beta.7`), release on tag. The `/version` endpoint returns the assembly version so the test can
  assert *the deployed version equals the published version*.

### 4.4 Load balancer and the proof of path

Regional external **Application Load Balancer**: static regional IP, backend service over a zonal
network endpoint group per node (or a regional managed instance group of size 2), HTTP health check
`GET /healthz` expecting `200` with body `ok`, session affinity `NONE` so both nodes get traffic. Firewall:
ingress 80/443 **from `130.211.0.0/22` and `35.191.0.0/16` only** (LB health checks and proxy), egress
allow; SSH/RDP only via IAP (`35.235.240.0/20`) and only while a debug flag is set.

Proof that traffic went through the balancer, in order of strength:
1. The nodes have **no** external IP; the firewall denies everything but LB ranges, so a direct hit from
   the runner is impossible by construction.
2. `gcloud compute backend-services get-health` shows **2 healthy** endpoints at test time.
3. Twenty sequential requests to the LB IP must return **both** distinct `X-Served-By` values, proving
   the LB is distributing rather than pinning.
4. Cloud Logging shows the requests arriving at the backend service with the LB's proxy marker.

### 4.5 Identity and least privilege

- **GitHub Actions → GCP**: Workload Identity Federation, provider restricted by
  `attribute.repository == '<owner>/<repo>'` and `assertion.ref` for `refs/heads/main`; the runner
  receives a short-lived token, never a key file.
- **Deployer service account** (`sa-winbuild-ci`): `roles/cloudbuild.builds.editor`,
  `roles/storage.objectAdmin` on the two buckets only, `roles/compute.admin` (scoped by a deny policy to
  the `winbuild-*` naming prefix), `roles/iam.serviceAccountUser` on the VM service account,
  `roles/logging.viewer`. No `roles/owner`, no `roles/editor`.
- **Cloud Build SA**: `compute.instanceAdmin.v1`, `iam.serviceAccountUser` on the builder SA,
  `storage.objectAdmin` on the build bucket.
- **Builder VM SA** (`sa-winbuild-builder`): `roles/storage.objectCreator` on the status prefix only,
  `roles/logging.logWriter`. Cannot create VMs or read secrets.
- **Node SA** (`sa-winbuild-node`): `roles/storage.objectViewer` on the artifact bucket,
  `roles/logging.logWriter`, `roles/monitoring.metricWriter`. Nothing else.
- **Secrets**: none in the repo, none in the image. Secret Manager is used only if a future step needs
  one, with accessor bindings per service account.

### 4.6 Teardown, and proving it

Teardown is a job, not a habit:

1. **`scripts/destroy.sh`** in a `destroy` job with `if: always()` and its own
   `concurrency` group so it cannot be skipped by a cancelled sibling.
2. **Inventory assertion**: `gcloud asset search-all-resources --project=<p>` filtered to
   `labels.owner=winbuild-ci` must return **nothing**; `compute instances|disks|addresses|
   forwarding-rules|target-pools list` must be empty; the only surviving resource is the image.
3. **Delayed billing reconciliation**: a scheduled job (`schedule: cron` weekly) reads the Cloud Billing
   BigQuery export for the project and fails if any cost appears for the CI label after the run window —
   this is the only way to catch a resource type the inventory check does not know about.
4. **Janitor as defence in depth**: Cloud Scheduler → Cloud Function every 2 hours deletes any instance,
   disk or forwarding rule labelled `owner=winbuild-ci` older than 2 hours. It exists because a cancelled
   workflow, a runner death or a hung Cloud Build can all leave the destroy job unrun.
5. **Budget**: a $25/month budget with alerts at 50/90/100%; a quota on `CPUS` in the project sized to the
   test (16) so a runaway loop cannot create forty Windows VMs.

### 4.7 Enterprise standards the build must satisfy

| Standard | Mechanism in this repo | Evidence produced |
|---|---|---|
| IaC, no click-ops | Every GCP resource created by reviewed shell in `scripts/` and `image/`; no console changes | The scripts are the record; `--dry-run` prints the intended calls |
| Change control | PR-only to `main`, required review, CODEOWNERS, conventional commits, linear history | Branch protection + PR template |
| Least privilege | WIF, four narrowly-scoped service accounts (§4.5), no JSON keys | IAM policy doc + `gcloud projects get-iam-policy` snapshot in the run |
| Secrets hygiene | No secrets in repo or image; `GITHUB_TOKEN` only; Secret Manager for anything else; push protection on | Secret-scanning alerts = 0 |
| Policy as code | `shellcheck` on every script, `bash -n`, a `scripts/policy-check.sh` that refuses untagged resources, off-region zones, public IPs on nodes and non-`EXTERNAL_MANAGED` LB schemes | CI job that fails the PR |
| Supply chain | SBOM (`syft` → SPDX), build provenance (`attest-build-provenance`), signed package, pinned action SHAs | Attestation attached to the package/release |
| Code quality | `dotnet format --verify-no-changes`, analyzers as errors, unit + integration tests, `dotnet list package --vulnerable` | CI gates |
| Dependency governance | Dependabot for NuGet and Actions; dependency review on PRs | Blocked PR on high severity |
| Observability | Health endpoint, `/version`, structured logs to Cloud Logging, LB request logs, uptime check during the test window | Log links per run, retained 30 days |
| Documentation | README, this plan, ADRs, runbook (`docs/RUNBOOK.md`), rollback (`docs/ROLLBACK.md`), cost model | Docs in-repo, reviewed with the code |
| Environment separation | Separate projects or resource prefixes per environment; the workflow takes `env` as an input, and `prod` needs a reviewer and never auto-destroys | Environment protection rules |
| Naming and tagging | `<project>-<env>-<component>-<n>`; every resource labelled `owner`, `env`, `cost-centre`, `ttl` | `conftest` policy denies untagged resources |
| Resilience | Two nodes in two zones, health-checked, LB retries; the app is stateless in test | Backend health shows 2/2 during the test |
| Rollback | Redeploy the previous package version; pin the image by name instead of family; re-run `deploy.sh` at the previous tag | Runbook step with exact commands |

## 5. Stage plan

Each stage has an exit criterion that is a command, not an opinion.

| Stage | What is built | Exit criterion |
|---|---|---|
| **S0 Bootstrap** (half day) | GCP project, billing, APIs enabled (`compute`, `cloudbuild`, `storage`, `iam`, `logging`, `secretmanager`, `billingbudgets`), state bucket, WIF pool + provider, four service accounts, budgets and CPU quota | `gcloud builds list` works from a locally-authenticated shell; WIF token exchange succeeds from a test workflow |
| **S1 Repo skeleton** (half day) | Repo layout (§6), branch protection, CODEOWNERS, PR template, ADR-0001..0005, `shellcheck` + `bash -n` + policy check in CI | PR with the skeleton passes all CI jobs; `scripts/deploy.sh --dry-run` prints a clean intended action list against an empty project |
| **S2 Image build** (2–3 days) | `cloudbuild.image.yaml`, `image/startup.ps1` + modules, status handshake, image naming, failure cleanup | A run produces `winbuild-app-<version>` and `C:\app` answers `GET /healthz` on the builder VM before imaging; a deliberately broken script leaves **no** VM behind |
| **S3 Publish** (1 day) | `dotnet pack`, versioning, push to GitHub Packages, SBOM + attestation, sha256 recorded as a run output | Package visible in Packages with the SBOM; `dotnet nuget push` of the same version fails (immutability proven) |
| **S4 Deploy** (2 days) | `scripts/deploy.sh`: network, firewall, image pinning, 2 nodes, LB, health check; readiness poll on backend health | `scripts/deploy.sh` yields an LB IP that returns `200 ok` from the runner, with both backends healthy inside 10 minutes |
| **S5 Verify** (1 day) | The reachability test: retries, version assertion, `X-Served-By` both-nodes assertion, backend health | Test fails when one node is stopped (negative test) and passes with two — both runs recorded |
| **S6 Teardown** (1 day) | `scripts/destroy.sh`, `scripts/assert-empty-project.sh`, billing reconciliation, janitor | After a green run and after a deliberately failed run, the inventory is empty and the janitor has nothing to delete |
| **S7 Hardening** (2 days) | Policy-as-code, vulnerability gates, runbook, ADRs completed, cost review, `prod` environment gates | A PR that adds an untagged resource is refused by `conftest`; a PR with a high-severity package is refused by dependency review |

Realistic total: **8–10 working days** for one engineer who knows GCP and Windows, with the image build and the
Windows startup script the two places that overrun.

## 6. Repository layout

```
.github/
  workflows/pipeline.yml          build → publish → deploy → verify → destroy → audit
  workflows/pr-checks.yml         fmt, validate, checkov, conftest, dotnet test, CodeQL
  workflows/schedule-janitor.yml  weekly billing reconciliation
  CODEOWNERS  pull_request_template.md  dependabot.yml
cloudbuild/
  image.yaml                      Cloud Build: create VM → poll → create image → delete VM
  deploy.yaml                     (optional) Cloud Build path for environments without Actions
image/
  startup.ps1                     orchestration entry point (idempotent, structured status)
  modules/Install-BuildTools.ps1  modules/Publish-App.ps1  modules/Write-Status.ps1
  autounattend.xml                only if a custom ISO path is ever needed
src/
  WinBuild.SampleApp/             the sample .NET 8 service (/healthz, /version, X-Served-By)
  WinBuild.SampleApp.Tests/
bootstrap/
  00-bootstrap.sh                 one-time: APIs, buckets, SAs, WIF, budget, quota
scripts/
  lib/common.sh                   idempotent ensure_* helpers (network, node, LB, readiness)
  deploy.sh  destroy.sh           the run
  verify-through-lb.sh            the reachability proof
  assert-empty-project.sh         the teardown proof
  policy-check.sh                 refuses untagged/off-region/public-IP resources
image/
  node-startup.ps1                what a deployed node runs (pull package, install, serve)
docs/
  PLAN.md  RUNBOOK.md  ROLLBACK.md  COST.md  THREAT-MODEL.md
  adr/0001-cloud-build-windows-strategy.md
  adr/0002-packer-alternative.md
  adr/0003-nuget-as-the-artifact.md
  adr/0004-teardown-and-cost-control.md
scripts/
  verify-through-lb.sh            the reachability proof
  assert-empty-project.sh         the teardown proof
```

## 7. Cost envelope (us-central1, indicative)

| Item | Rate | Per run (~45 min) | Monthly if idle |
|---|---|---|---|
| Windows VM, e2-standard-4 (builder, ~60 min) | ~$0.19/h | ~$0.19 | $0 |
| Two Windows nodes, e2-standard-2, 20 min | ~$0.11/h each | ~$0.07 | $0 |
| LB forwarding rule + proxy (20 min) | ~$0.025/h | ~$0.01 | $0 |
| Cloud Build (Linux steps, e2-medium) | included minutes | ~$0.01 | $0 |
| Image storage (~12 GB) | $0.05/GB-month | — | **~$0.60** |
| Egress to runner (tests) | $0.12/GB | <$0.01 | $0 |
| **Total** | | **≈ $0.30 per run** | **≈ $0.60** |

The number that matters: an idle project costs **cents**, and a leaked Windows VM for a weekend costs
~$27. Hence the janitor and the CPU quota.

## 8. Risks, ranked

1. **Startup-script fragility** — installer downloads, VS Build Tools requiring a reboot, transient
   network errors. Mitigation: idempotent modules, retry with backoff, every step writing structured
   status, and a 90-minute Cloud Build timeout with a hard failure that still cleans up.
2. **Windows boot + install time** — 35–55 minutes for Build Tools. Mitigation: bake the toolchain into
   the image (done once), keep the per-run work to app build + deploy; cache installers in the bucket.
3. **Leftover cost after a cancelled run** — mitigated by janitor, quota, budget, and `if: always()`.
4. **LB warm-up and health-check timing** — nodes need IIS started before health checks pass; mitigation
   is a readiness poll on `backend-services get-health` (`wait_backends_healthy`) rather than a fixed sleep.
5. **NuGet package immutability vs rebuilds** — a re-run of the same commit cannot re-push the same
   version; mitigation: pre-release suffix per run, or `--skip-duplicate` with a content-hash check.
6. **Cloud Build concurrency** — two runs colliding on VM/image names; mitigation: names suffixed with the
   run id and a `concurrency` group in Actions.
7. **Licensing** — Build Tools vs Community (§2.2) needs a written decision from whoever owns Microsoft
   licensing, not an engineering default.

## 9. Why not Terraform or Packer (for now)

Deliberate, recorded in `docs/adr/0005-no-terraform-no-packer.md`:

- **No Terraform** means no state file, so nothing can drift silently — every script is an
  "ensure-or-create" call, and destruction works from labels rather than state. What is lost: a plan that
  diffs desired against actual, resource-level dependency ordering, and cheap import of hand-made
  resources. What replaces it: idempotent `ensure_*` helpers, `--dry-run` printing the exact gcloud calls,
  and `assert-empty-project.sh` proving nothing survives. The scripts are written so a later Terraform
  migration can wrap them rather than rewrite them.
- **No Packer** means the image is built by Cloud Build orchestrating a Windows VM with a PowerShell
  state machine. What is lost: Packer's provisioner ecosystem and multi-cloud parity. What replaces it: no
  inbound WinRM port, no password in a template, and a script that can be run by hand on a scratch VM
  while it is being developed.

Both are reversible decisions, and both are revisited if the project grows past one environment.

## 10. Definition of done

- A PR to `main` runs the whole pipeline green from a clean project, twice in a row, with no manual step.
- The package is in GitHub Packages with an SBOM and a provenance attestation; its sha256 equals the
  bytes deployed to both nodes.
- The reachability test proves traffic through the LB to **both** nodes, and fails when one node is down.
- After the run — and after a deliberately failed run — the project inventory is empty except the image,
  and the billing reconciliation for that window is zero.
- The repo contains: plan, runbook, rollback, cost model, threat model, four ADRs, and a policy check that
  refuses untagged or off-region resources.

## 11. Build order (first two days, concretely)

1. `bootstrap/00-bootstrap.sh` run once through the `bootstrap` workflow, recorded in `docs/RUNBOOK.md`.
2. Repo skeleton with CI passing (shellcheck, `bash -n`, policy check) and a "hello" sample app.
3. `image/startup.ps1` against a manually created VM until `Get-Content C:\app\status.json` says
   `{"stage":"done"}` — the script is proven before Cloud Build touches it.
4. Only then wire Cloud Build, then publish, then deploy, then verify, then destroy.
