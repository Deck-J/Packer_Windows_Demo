# winbuild — Windows build, GitHub Packages, two nodes, proven and then destroyed

One green run of `.github/workflows/pipeline.yml` does this, on a standard `ubuntu-latest` runner:

1. **Cloud Build + Packer** build a Windows Server 2022 image with Visual Studio Build Tools, the Windows
   SDK, .NET 8, IIS and a smoke-test copy of the sample app.
2. **GitHub Packages** receives the application as a versioned NuGet package, with an SBOM and a
   provenance attestation.
3. **Terraform** creates two Windows nodes (no external IPs) behind a regional external Application LB.
4. **The nodes install the exact published package** (staged in GCS, sha256 verified) — not the baked copy.
5. **`scripts/verify-through-lb.sh`** proves `/healthz` 200, `/version` equal to the published version, and
   two distinct `X-Served-By` values across N requests.
6. **`terraform destroy`** runs whatever happened before, followed by **`scripts/assert-empty-project.sh`**,
   which asks GCP what exists instead of trusting state.

A tag (`v1.4.0`) produces a release instead: release-named image and package, a `release-manifest.json`
attached to the GitHub Release, and a separate **`promote.yml`** that deploys those exact digests to the
persistent environment behind the `gcp-prod` approval gate — no rebuild, no teardown.

The design and its trade-offs: [`docs/PLAN.md`](docs/PLAN.md). Decisions: [`docs/adr/`](docs/adr/).

## Layout

```
bootstrap/00-bootstrap.sh     one-time: APIs, buckets, service accounts, WIF, budget, quota
cloudbuild/image.yaml         Cloud Build → Packer → image, with a per-build WinRM password over IAP
packer/                       windows.pkr.hcl + provisioning scripts (toolchain, bake, smoke test, sysprep)
infra/                        Terraform: network, 2-node MIG, LB, firewall, health check, outputs
src/WinBuild.SampleApp        the app: /healthz, /version, X-Served-By
scripts/                      verify-through-lb.sh, assert-empty-project.sh, policy-check.sh
docs/                         PLAN, RUNBOOK, ROLLBACK, COST, THREAT-MODEL, adr/
.github/workflows/            bootstrap.yml (once), pipeline.yml (the run), pr-checks.yml (gates)
```

## First-time setup

Follow [`docs/RUNBOOK.md`](docs/RUNBOOK.md) §1: it is one workflow dispatch (the bootstrap), then eight
repository variables, then a merge to `main`.

## Two things you can change without touching the pipeline

**Your own build.** `custom/` is the contract: `custom/run.ps1` executes the steps listed in
`custom/build.config.json` (command, working directory, env, timeout per step), and any non-zero exit fails
the image build. The shipped config is a real one — NuGet config, build and publish, IIS site and app pool
configuration, then a `/healthz` check — so it doubles as the worked example. Scripts, config files and NuGet configs live beside it and are copied to the builder
verbatim. Every file used is hashed into `C:\packer\custom-manifest.json`, so the image records exactly
which build recipe produced it. Start from `custom/build.config.example.json`.

**A machine to debug on.** Dispatch the pipeline with `debug_keep_vm=true`: teardown is skipped, a failed
Packer build leaves its machine running (`-on-error=abort`), a troubleshooting account is created with a
password in Secret Manager, and RDP is enabled **only from the IAP range** — you reach it with
`gcloud compute start-iap-tunnel <vm> 3389 --local-host-port=localhost:13389`. The machine carries a
`ttl=debug-<n>h` label and `scripts/reap-leftovers.sh` (scheduled every two hours) deletes it whether or not
anyone remembers.

## What this repository will not do

- Run Windows on the runner, or hold a cloud credential: authentication is OIDC → WIF, always.
- Push a package version twice: versions are immutable, so a rebuild bumps the version.
- Claim "everything is down" from a state file alone: the audit job asks GCP.
