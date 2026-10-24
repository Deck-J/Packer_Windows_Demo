# ADR-0006 — adopt Terraform and Packer (supersedes ADR-0005)

**Status:** accepted, supersedes [ADR-0005](0005-no-terraform-no-packer.md).

## Context

ADR-0005 chose reviewed shell over `gcloud` and a hand-rolled Packer-free image build, to keep the
toolchain small. Two things changed the balance: the owner reviewed the trade-off and asked for Terraform
and Packer; and the script version needed hand-coded deletion ordering plus a bespoke PowerShell state
machine for the Windows build — both of which are exactly what those two tools already do better.

## Decision

- **Terraform** owns every GCP resource: `infra/` with remote state in the bootstrap-created GCS bucket
  (versioned, native locking), separate workspaces per environment, `plan` reviewed on the PR.
- **Packer** owns the image: `packer/windows.pkr.hcl` + provisioning scripts, driven by Cloud Build,
  captured as `winbuild-app-<version>` in the family `winbuild-app`.

## What is gained

`plan` (the only review that reliably catches an untagged or off-region resource), computed dependency
order, drift detection, import, module/workspace separation, and a Windows provisioning lifecycle —
autounattend, reboots, WinRM readiness, sysprep, capture, cleanup — that is tested by many people instead
of by us.

## What is given up, and what replaces it

- **State is now a dependency.** A lost or corrupt state file makes `terraform destroy` forget resources.
  The label sweep (`scripts/assert-empty-project.sh`) is kept precisely for that: it asks GCP what exists.
- **The toolchain grows.** `terraform` and `packer` binaries on the runner, plus a provider and a plugin
  download per run. Versions are pinned in CI.
- **A management credential exists during the build.** A per-build ed25519 keypair is generated inside
  Cloud Build, injected through instance metadata, destroyed at the end of the step, and usable only over
  an IAP tunnel. There is no password, and nothing listens on 5985.

## Consequences for the proofs

Unchanged. The reachability proof, the two-node assertion, the version assertion, the billing
reconciliation and the janitor all stay — Terraform makes creation and destruction better, not verification.
