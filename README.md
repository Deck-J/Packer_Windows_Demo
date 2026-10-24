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

## What this repository will not do

- Run Windows on the runner, or hold a cloud credential: authentication is OIDC → WIF, always.
- Push a package version twice: versions are immutable, so a rebuild bumps the version.
- Claim "everything is down" from a state file alone: the audit job asks GCP.
