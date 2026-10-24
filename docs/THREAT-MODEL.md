# Threat model (short, and honest about scope)

**Assets:** the GCP project, the image and its toolchain, the published package, and the credentials that
reach them.

| Threat | Control | Residual risk |
|---|---|---|
| Credential theft from CI | No long-lived cloud credential exists. OIDC → WIF, bound to this repository by attribute condition; tokens last minutes | A malicious workflow in this repo could impersonate the deployer — hence PR-only, CODEOWNERS, and no `pull_request_target` |
| Compromised dependency in the image | Installers fetched over HTTPS from vendor URLs during build; versions pinned; SBOM of the app produced | Installer hashes are not yet pinned for Build Tools (vendors rotate URLs) — the gap to close first |
| Node compromise | No external IP; ingress only from LB ranges; node SA can read one bucket and write logs | An attacker inside the VPC could reach nodes on 80 |
| Data exfiltration via the app | Sample app holds no data; no secrets in the image or environment | — |
| Runaway cost / crypto-mining | CPU quota 16, budget alerts, 2h TTL janitor, destroy under `if: always()` | A resource created outside Terraform with no labels would be caught only by the billing reconciliation |
| Supply-chain tampering of the package | Package immutable per version, sha256 recorded at publish, re-verified before staging and again on the node | NuGet author signing not yet configured (needs a certificate) |

## The troubleshooting path (opt-in, bounded)

`debug_keep_vm=true` deliberately leaves a machine alive with an administrator account. It is bounded on
four axes: **network** (RDP admits only the IAP range, so there is no public listener), **credential** (a
per-build 32-character password in Secret Manager, not in a log or the repo), **time** (`ttl=debug-<n>h`
label plus the scheduled reaper) and **authority** (the deployer service account is the only thing that can
read the secret). It is a flag a human sets for one run, not a default.

## Deliberate accepted risks

- **The builder VM has an external IP.** Needed for Microsoft/NuGet downloads and Windows activation; no
  inbound management port is open, and SSH is reached through IAP with a keypair that exists only for the
  life of the build.
- **`checkov` skips CKV_GCP_2 and CKV_GCP_62.** CKV_GCP_2 wants VPC flow logs on every subnet (cost, and
  this network lives for 20 minutes); CKV_GCP_62 wants log buckets with retention (Cloud Logging defaults
  apply here). Both are recorded rather than silently disabled.
