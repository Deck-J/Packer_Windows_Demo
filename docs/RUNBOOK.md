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

## 2. A normal run

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

## 3b. Custom build steps

The build does not hard-code how the application is compiled. `custom/build.config.json` lists steps; each
runs in PowerShell from `workingDirectory` with the configured environment, and the first non-zero exit
fails the image build.

```json
{
  "workingDirectory": "C:\\packer\\custom",
  "env": { "DOTNET_CLI_TELEMETRY_OPTOUT": "1" },
  "steps": [
    { "name": "build",   "command": "dotnet build C:\\packer\\src -c Release --nologo", "timeoutSeconds": 1800 },
    { "name": "publish", "command": "dotnet publish C:\\packer\\src -c Release -o C:\\app\\custom", "timeoutSeconds": 1800 }
  ]
}
```

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
