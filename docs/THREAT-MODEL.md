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

## Terraform state

State is the map of the environment, and it can contain attribute values that were never meant to be public —
some providers write generated credentials into it. It is therefore treated as a secret-bearing artefact:

| control | how |
|---|---|
| Encryption at rest | **on by default** — GCS server-side AES-256 with Google-managed keys. Nothing to enable, and nothing to lose if a key is rotated |
| Customer-managed keys (optional) | CMEK via Cloud KMS if the organisation requires key custody. Adds a key ring, a rotation policy, and a failure mode where a destroyed key makes state unreadable |
| Who can read it | IAM on the bucket, not the project: only the deployer service account holds `storage.objectAdmin`. Project-level roles are not relied on for this |
| Exposure | public access prevention + uniform bucket-level access, set at creation and re-asserted by the bootstrap |
| Recovery | object versioning, with noncurrent versions kept 90 days — enough to roll back a bad apply without keeping a year of state nobody will read |
| Concurrency | GCS backend lock: two applies cannot interleave and corrupt the map |
| Leaking through logs | no `terraform output` of sensitive values in CI; secrets live in Secret Manager and are referenced, not passed through variables that end up in state |

Residual risks, stated: anyone who compromises the deployer service account can read state and therefore every
attribute in it; and CMEK, if enabled, adds a way to lose state permanently. That is why the bucket is
versioned and why the deployer's own permissions are the smallest set that can still deploy.

## The troubleshooting path (opt-in, bounded)

`debug_keep_vm=true` deliberately leaves a machine alive with an administrator account. It is bounded on
four axes: **network** (RDP admits only the IAP range, so there is no public listener), **credential** (a
per-build 32-character password in Secret Manager, not in a log or the repo), **time** (`ttl=debug-<n>h`
label plus the scheduled reaper) and **authority** (the deployer service account is the only thing that can
read the secret). It is a flag a human sets for one run, not a default.

## Monitoring agent (Dynatrace)

The OneAgent token is a credential with download rights on the tenant, so it is treated as one: stored in
Secret Manager, readable only by the node service account, fetched at boot and never written to instance
metadata, the image, the repo or a log. The installer URL is tenant-specific and authenticated per request.
A node that cannot read the secret fails rather than continuing silently unmonitored.

Residual risk: the token is present in the node's memory during install and in the installer's arguments
for the life of the `msiexec` call. Shortening that window means installing via a drop-in package with a
pre-seeded configuration, which trades a build-time secret for a rotation burden — not obviously better.

## Deliberate accepted risks

- **The builder VM has an external IP.** Needed for Microsoft/NuGet downloads and Windows activation; no
  inbound management port is open, and SSH is reached through IAP with a keypair that exists only for the
  life of the build.
- **`checkov` skips CKV_GCP_2 and CKV_GCP_62.** CKV_GCP_2 wants VPC flow logs on every subnet (cost, and
  this network lives for 20 minutes); CKV_GCP_62 wants log buckets with retention (Cloud Logging defaults
  apply here). Both are recorded rather than silently disabled.
