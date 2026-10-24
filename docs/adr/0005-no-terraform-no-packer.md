# ADR-0005 — no Terraform, no Packer, for now

**Status:** accepted (owner's direction, 2026-10-23). **Revisit when:** a second environment exists, or
more than one person changes infrastructure.

## Context

The pipeline needs a Windows image, two nodes, a load balancer and a provable teardown. The conventional
toolkit is Terraform for the infrastructure and Packer for the image. The owner has asked for neither, for
now: fewer moving parts locally, nothing to install on the runner beyond `gcloud`, and no state to lose.

## Decision

- **Infrastructure**: `scripts/*.sh`, idempotent `ensure_*` helpers over `gcloud`, with every resource
  labelled `owner=winbuild-ci,run=<run>,ttl=2h`. Creation is create-if-absent; destruction is by label.
- **Image**: Cloud Build orchestrates a temporary Windows VM running a PowerShell state machine that
  writes status to GCS (§4.1 of the plan). No Packer, no inbound WinRM.

## Consequences

**Accepted losses**
- No plan/diff of desired vs actual. Mitigation: `deploy.sh --dry-run` prints the exact calls it would make,
  and `assert-empty-project.sh` proves the inverse (nothing left behind).
- No state file, so there is no resource-level dependency graph: deletion order is hand-coded in
  `destroy.sh` and must stay correct.
- No import path for resources made by hand, and no drift detection between runs.

**What this buys**
- The runner needs only `gcloud`; no Terraform version pinning, no plugin downloads, no state bucket ACLs
  to get wrong, no `.tfstate` in a backup.
- The teardown proof is stronger than a state file's: it asks GCP what exists, by label, rather than
  trusting what Terraform wrote down.
- The image path has no inbound management port and no password anywhere.

## Migration note

The scripts are structured as one function per resource group (`ensure_network`, `ensure_node`,
`ensure_lb`) precisely so a later Terraform module can call the same names and the same labels. Nothing
here blocks the switch; the switch just is not now.
