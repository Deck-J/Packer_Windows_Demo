# Security

## Reporting

Open a **private** security advisory on this repository (Security → Advisories → New draft advisory) rather than
a public issue. If that is unavailable, contact the maintainer directly.

## What this repository does by design

- **No long-lived cloud credentials.** GitHub Actions authenticates to GCP with Workload Identity Federation,
  scoped to this repository by an attribute condition. The one short-lived exception is the bootstrap workflow,
  which takes a user access token that expires within the hour and should be deleted immediately after use.
- **No management port open to the internet.** Windows management is SSH over an IAP tunnel with a per-build
  ed25519 keypair; RDP, when explicitly enabled for troubleshooting, is admitted only from Google's IAP range.
- **No secrets in the image.** The Dynatrace token is fetched from Secret Manager by the node at boot; the Telemetry
  endpoint is configuration, not a credential.
- **Least privilege per identity.** Four service accounts (deployer, cloud build, builder, node) with narrow roles,
  documented in `docs/PLAN.md` §4.5.

## What is out of scope here

Image contents (Visual Studio, its installers) are downloaded from vendor URLs at build time and pinned only by
version, not by hash. If you need hash pinning, that is a change to `packer/scripts/install-toolchain.ps1` and a
welcome one.
