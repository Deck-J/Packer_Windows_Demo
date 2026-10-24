# Windows build, GitHub Packages, two-node GCP demonstration: critique and plan

Prepared 2026-10-23. The requested `BRIEF.md` is absent; `docs-brief.md` is the design brief used here. This document proposes implementation; it does not provision infrastructure. Prices are USD, on demand, before tax, with us-central1 as the reference region.

## 1. Critique of the requirement

1. **Cloud Build is the controller, not a Windows compiler host.** Its supported worker model runs Linux build steps. A private pool does not turn those workers into Windows hosts. A Compute Engine Windows VM must perform Windows installation and compilation. The resulting GCE custom boot image is different from a container image or an application package. Shipping a GCE image to GitHub Packages is neither required nor a suitable artifact contract. See [Cloud Build worker versions](https://docs.cloud.google.com/build/docs/release-channels) and [private pools](https://docs.cloud.google.com/build/docs/private-pools/private-pools-overview).
2. **Visual Studio Community cannot be assumed permissible for this organization or unattended build use.** Eligibility depends on the actual license, organization, users, and use case; “free build agent” is not a licensing argument. Establish the exact edition/version and eligibility before installation. Preferred amendment: use the standalone .NET SDK for this sample, or licensed Visual Studio Build Tools for workloads that require it, under applicable terms. Build Tools is not universally license-free either. If Community is mandatory and eligibility cannot be established, the requirement is blocked; do not silently substitute another edition. Do not distribute Microsoft tools in the application package. See [Microsoft licensing guidance](https://www.microsoft.com/licensing/guidance/Visual-Studio) and the [edition-specific terms](https://visualstudio.microsoft.com/license-terms/).
3. **Building an IDE image for every application change is slow and expensive relative to the sample.** Expect installer downloads, reboots, servicing failures, and Sysprep failures. This demonstration deliberately rebuilds each time to leave no stored image behind. A production system would separate infrequent toolchain-image builds from application builds and explicitly budget retained images.
4. **The source and deployment contract are missing.** Building again on deployment nodes cannot demonstrate that the published artifact ran. Pin one source commit; build once; publish once; retrieve the package; verify hashes; deploy those exact bytes. A .NET 8 HTTP service is a convenient adapter, not the architecture. Its support lifecycle also needs a review before long-term adoption.
5. **GitHub Packages is not arbitrary file storage.** Choose a real registry format. This plan uses a NuGet package as a versioned Windows deployment bundle, including a manifest and published application files. It is installed by an explicit deployment adapter, not treated as a normal library dependency. A container registry would add a Windows container runtime and host compatibility requirements without satisfying the VM-image requirement by itself.
6. **“Two nodes tested through an LB” needs an observable identity and deterministic coverage.** Two successful HTTP responses might come from the same node. Version responses must include instance identity and artifact hash. Tests must prove both nodes through the frontend, with direct application ingress blocked.
7. **“Everything spun down” does not mean zero ongoing charges.** Stopped VMs retain disks; images, reserved addresses, buckets, old object generations, logs, and load balancer forwarding rules can continue costing money. Always-running janitors and billing-export datasets also conflict with literal zero spend. Define the reusable baseline separately and delete all chargeable run resources. GitHub package storage is outside GCP and has its own retention/cost policy.
8. **Absolute cleanup despite all failures is impossible.** `if: always()` does not survive every runner loss, forced cancellation, revoked identity, or GCP outage. Use independent recovery and TTLs, but document the residual interval of exposure. A budget alert is not a spending cap. Immediate deletion evidence cannot prove future invoices; provider billing arrives later. This plan promises an empty chargeable-resource inventory and later billing reconciliation, not a mathematically guaranteed zero-dollar invoice.
9. **Unattended operation has a bootstrap boundary.** An administrator must initially establish billing, APIs, WIF trust, IAM, GitHub settings, and license decisions. After that, merging a trusted change starts everything without a login or approval prompt. Organization policies prohibiting external VM addresses would require a different egress design and budget.

## 2. Chosen design and the Windows image decision

### Alternatives

| Approach | Actual Windows execution | Benefits | Failure modes and decision |
|---|---|---|---|
| Packer `googlecompute` from a Linux Cloud Build step | Temporary GCE Windows VM, provisioned over WinRM | Established image manifest, provisioning/restart helpers, image creation and normal cleanup | WinRM bootstrapping, certificate validation, ephemeral administrator credentials, reboots, firewall reachability, controller termination leaving resources. Default Cloud Build cannot simply reach a private VM address. An IAP tunnel or private-pool connectivity needs a tested configuration. Feasible runner-up; pin plugin and Packer versions. Never expose 5986 to the internet. |
| Cloud Build orchestrates GCE and startup scripts | Temporary GCE Windows VM executes a reboot-safe PowerShell state machine | No incoming management port or WinRM password; simple public Google API control and Cloud Storage rendezvous | More code for checkpointing, timeout, reboots, stale status, image capture and orphan handling. **Chosen** because the workflow is small and no remote interactive provisioning is needed. |
| Native Windows Cloud Build workers or Windows private-pool nodes | No supported native Windows worker configuration identified | Would simplify execution if it existed | Do not plan against an unsupported worker OS. Community Windows builders orchestrate external infrastructure; they do not establish native Windows worker support. GKE Windows workers add a cluster, container workflow and cost, and still do not directly produce this VM image. Recheck product documentation if support changes. |

Packer supports the GCE builder and Windows WinRM provisioning; its example is not a security baseline. See [googlecompute builder](https://developer.hashicorp.com/packer/integrations/hashicorp/googlecompute/latest/components/builder/googlecompute) and [WinRM communicator](https://developer.hashicorp.com/packer/docs/communicators/winrm).

### Build and capture sequence

1. GitHub checks out the exact merge commit and creates a sanitized source archive: no `.git`, WIF credentials, GitHub token, local caches or untracked files. Include a dependency lock, SDK pin, installer/version manifest, and source SHA-256. Run ID is `r<github.run_id>-a<github.run_attempt>`; use this in every run resource name, object prefix, image name and manifest. Put `managed_by=winbuild`, `run_id`, and an expiry timestamp label where supported; use a resource ledger for unlabeled resources.
2. Actions submits the checked-in Linux `cloudbuild.yaml` with an explicit user-managed build SA. Cloud Build runs in us-central1 on the default e2-standard-2 pool. It creates the run's builder VM in us-central1-a: e2-standard-4, 100 GiB pd-balanced boot disk, auto-delete enabled, no additional disks, no reservations or Spot instances. Select a specific Google `windows-cloud` Windows Server 2022 image, not a floating family at execution time; record its full resource ID and license metadata.
3. The VM has an ephemeral external IPv4 address for Microsoft/NuGet downloads and activation. Its VPC has no inbound RDP, WinRM, or app rule for the builder. Permit required outbound HTTPS, DNS and Google Windows activation traffic; retain Google guest agents and normal metadata connectivity. Test activation using the documented GCE Windows path; do not strip license information or assume a private/custom image avoids Windows license charges.
4. Startup metadata carries only a small launcher, run ID and a GCS script URI plus expected hash. The builder SA fetches immutable scripts/source from the run input bucket with its metadata-issued access token. PowerShell uses a local checkpoint journal and an execution lock. Each phase writes create-only status objects, tagged with run ID, commit and attempt; Cloud Build rejects mismatches or stale checkpoints. Handle installer success-with-reboot codes explicitly, resume after reboot, and upload sanitized failure logs in a `finally` handler. Never infer success merely from a running VM or a shutdown.
5. Install the approved toolchain silently with pinned workload IDs, SDK versions and installer hashes. Use a versioned installer layout when upstream feeds cannot reproduce old versions. Build and test from the supplied source under `C:\build\src`. For the sample: locked restore, unit tests, `dotnet publish -c Release -r win-x64 --self-contained true`, then a local HTTP smoke test. Configure the service executable for Windows Service operation. Enforce compiler/test exit codes.
6. Produce `Org.WinDemo.Deploy.<version>.nupkg` via a `.nuspec`: application files under `payload/win-x64`, deployment manifest, file hashes, source commit, SDK/toolchain inventory, SBOM and test summary. No package install hooks. The manifest defines entrypoint, port, health/version paths, install/uninstall commands and payload hashes. Sign or attest the package digest from trusted CI identity; retain provenance with the GitHub run.
7. Leave a diagnostic copy of the compiled application and source manifest in the image to meet the brief's “containing ... sample application” requirement, but disable its service. Upload package and pre-Sysprep logs to GCS before generalization. Delete caches, credentials and temporary source/tool downloads; verify no credential files were included. Do not create additional local administrator accounts. Run `GCESysprep`; Cloud Build waits for the expected completion markers **and** VM `TERMINATED`, then creates a uniquely named custom image from the stopped disk and waits for image `READY`. Capture serial/Sysprep failures when there is no completion. See [Google's Windows custom-image procedure](https://docs.cloud.google.com/compute/docs/instances/windows/creating-windows-os-image).
8. Cloud Build creates a build-result manifest tying package hash to image resource ID, source commit and test result. Delete the builder VM and disk after successful capture. On failure, cancel capture/build operations and delete partial images too. Timeout: 90 minutes for all Windows work, within a 100-minute Cloud Build limit. Cloud Build polling is billed while it waits.

Fresh-boot deployment is the image acceptance test. A template derived from the image must still execute Windows startup scripts, activate Windows and pass service tests. Sysprep can change guest configuration; “image READY” alone is insufficient. Never rebuild the application on either deployment node. Record pinned inputs and verified output hashes; this improves reproducibility but does not claim bit-for-bit identical Sysprep disk images or mutable upstream installer feeds.

## 3. GitHub Packages publication and authenticated deployment

Registry: `https://nuget.pkg.github.com/<OWNER>/index.json`; package ID `Org.WinDemo.Deploy`. Version: `0.1.0-ci.<run_id>.<run_attempt>`, with the full source SHA in the manifest. This is a unique SemVer prerelease per attempt; never overwrite or deploy `latest`. Configure package repository metadata/access to the workflow repository. Keep a stable package ID and immutable versions.

The publish Actions job downloads the Cloud Build package from GCS, verifies the build-result hash, inspects its manifest, and pushes with `dotnet nuget push ... --source <feed> --api-key "$GITHUB_TOKEN"`. Give that job `contents: read`, `packages: write`, `id-token: write`; give the deployment retrieval job only `packages: read` and the GCP permissions it needs. Keep authentication in a temporary config/environment outside checkout and remove it after use. Never pass the GitHub token as Cloud Build substitution, source content, instance metadata or GCE image input.

**Deployment retrieval happens in GitHub Actions.** A fresh retrieval step downloads that exact version from the NuGet feed using its job's `GITHUB_TOKEN`; verify the feed round-trip package hash against the build manifest. Implement authenticated NuGet service-index discovery/download or a pinned NuGet client, not an invented raw-binary endpoint. Stage the downloaded package and a deployment manifest in a separate GCS delivery bucket. Nodes fetch it with their GCE service-account tokens. This intentionally treats GCS as transient delivery transport: the authoritative published artifact was retrieved from GitHub Packages, not copied directly from build output into deployment.

This avoids giving Windows nodes GitHub credentials. `GITHUB_TOKEN` is repository/job scoped; WIF tokens authenticate to GCP, not GitHub Packages. If direct private-feed downloads from nodes become mandatory, a scoped, expiring PAT classic with `read:packages` and appropriate package access is the documented fallback and introduces a managed secret. A Git SSH deploy key does not authenticate to NuGet. Public NuGet packages still require registry authentication. GitHub documents Actions token support and package access in [the NuGet registry guide](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-nuget-registry).

Each node's startup script deletes the diagnostic baked app, validates the retrieved package manifest and hashes, safely extracts it (reject path traversal), and installs a fresh service from that payload. It cannot report healthy before package verification and service startup complete. Use a non-admin service account locally; startup installation itself runs as SYSTEM. This proves the deploy uses the published package despite the required app copy in the image. A corrupted package must stop deployment, not fall back to the baked copy.

Keep the last 10 successful package versions for at most 7 days for this demonstration. Implement package-version pruning separately with the required GitHub package admin/delete rights; do not give those rights to nodes. Keep compact proof bundles for 30 days in GitHub Actions artifacts, subject to account quota. GitHub storage/runner charges are separate from the GCP envelope.

## 4. Exact GCP footprint and network

Use one dedicated project with no unrelated workloads. Default region us-central1, node zones us-central1-a and us-central1-b. Terraform owns run networking/deployment; the image-build script owns its temporary VM/disk/image and records them in the ledger. Never let two tools manage the same object.

| Service/API | Use and concrete resources |
|---|---|
| Cloud Build `cloudbuild.googleapis.com` | Explicit build SA, regional build execution, source staging and custom GCS log destination; no repository connection or GCP trigger needed |
| Compute Engine `compute.googleapis.com` | One builder VM; one custom image; two e2-standard-2 Windows runtime VMs, each with 100 GiB auto-delete pd-balanced boot disk; one instance template; two zonal unmanaged instance groups with one VM each and named port `http:8080` |
| VPC through Compute API | Custom-mode VPC, normal regional subnet, `REGIONAL_MANAGED_PROXY` proxy-only subnet /23, default internet route, explicit backend and health-check firewall rules |
| Cloud Load Balancing through Compute API | Regional external Application LB: regional IPv4 address, `EXTERNAL_MANAGED` forwarding rule TCP/80, regional target HTTP proxy, URL map, regional HTTP backend service and regional HTTP health check `/healthz` port 8080 |
| Cloud Storage `storage.googleapis.com` | Separate run input, build-output, delivery, log and Terraform-state buckets, uniform access and public-access prevention; regional Standard storage, no retention lock, versioning or soft-delete retention for disposable buckets |
| IAM, STS, IAM Credentials | `iam.googleapis.com`, `sts.googleapis.com`, `iamcredentials.googleapis.com`; GitHub OIDC federation, user-managed SAs and narrowly scoped bindings |
| Cloud Asset Inventory `cloudasset.googleapis.com` | Independent discovery evidence, supplemented by authoritative per-service list APIs |
| Cloud Billing/Budgets | Project linkage, small monthly alert budget; administrator configures detailed billing export to the observation dataset; no automatic billing-detach assumed |
| BigQuery `bigquery.googleapis.com` | A small billing-observation dataset retained through reconciliation, then exported to GitHub and deleted; explicit temporary exception to immediate zero storage |

No GKE, Cloud SQL, Artifact Registry, Secret Manager, Cloud NAT, Cloud Scheduler or persistent Cloud Run janitor is required. BigQuery is used only during the explicitly costed billing-observation window below. Use a pinned public builder image; do not accidentally create an Artifact Registry repository through an implementation shortcut. Google-managed service agents remain enabled under their normal service-agent roles.

Runtime nodes also have ephemeral external IPv4 for activation/egress, but ingress to application port 8080 is allowed **only** from the proxy-only subnet and Google's documented health-check ranges (currently 35.191.0.0/16 and 130.211.0.0/22; confirm at implementation). Apply equivalent Windows Firewall restrictions after Sysprep. No public RDP/WinRM rule. External addresses do not make the app directly accessible. If external addresses are prohibited, replace them with explicitly costed Cloud NAT and revise the checklist; a private pool alone would not provide VM internet egress.

HTTP is an explicit choice for a short-lived, non-sensitive demonstration, avoiding DNS and certificate lifecycle. Do not put secrets in responses. A production requirement needs HTTPS, a domain and certificate plan. The selected regional LB structure follows [Google's instance-group setup](https://docs.cloud.google.com/load-balancing/docs/https/setting-up-reg-ext-https-lb). An external passthrough Network LB could test TCP reachability but lacks the useful HTTP routing used below; it is not chosen.

### Proving both nodes through the frontend

Health: `/healthz` returns 200 only when the installed service and expected manifest are ready. `/version` returns source SHA, package version, payload hash, run ID and the instance ID/name obtained locally from metadata; never bake node identity into the image.

Attach the two singleton instance groups to the normal backend service, with session affinity disabled. Also create two regional diagnostic backend services, each referencing just one singleton group. Add URL-map routes `/probe/a/*` and `/probe/b/*`, rewriting away the prefix so `/probe/a/version` reaches node A's `/version`, and likewise B. Health checks and firewall policy remain identical. This is deterministic and does not depend on random load balancing.

Tests from GitHub Actions send all positive requests to the LB frontend IPv4:80, with the intended Host header, unique nonce, no caching and bounded retries. Require correct version/hash and distinct expected instance IDs through both diagnostic routes; also verify ordinary `/version` succeeds and both normal backends report healthy. Negative tests to each VM external address:8080 must fail. Save request/response evidence and URL-map/backend configuration; a header such as `X-Forwarded-For` alone is not proof. Allow up to 20 minutes for node startup and 10 minutes for LB health/config propagation; retain health-check status and node startup logs on timeout.

## 5. Identity and IAM

### GitHub to GCP WIF

Bootstrap a project-level workload identity pool and OIDC provider for `https://token.actions.githubusercontent.com`. Use the provider resource as the expected audience. Map `google.subject=assertion.sub`, `attribute.repository_id=assertion.repository_id`, and `attribute.repository_owner_id=assertion.repository_owner_id`. Restrict the provider with numeric owner and repository IDs, `assertion.ref == 'refs/heads/main'`, and the exact permitted `assertion.workflow_ref` values for the deployment, cleanup, and janitor workflow files. Do not trust repository names alone; do not allow fork PRs or `pull_request_target` to execute untrusted code with these identities.

Bind `roles/iam.workloadIdentityUser` on each impersonated SA to `principalSet://iam.googleapis.com/projects/<NUMBER>/locations/global/workloadIdentityPools/<POOL>/attribute.repository_id/<REPO_ID>`. Use separate provider conditions or finer mappings to ensure each workflow can impersonate only its intended SA, especially the janitor. Jobs declare `id-token: write`; use pinned `google-github-actions/auth` to obtain short-lived SA credentials, then pinned setup-gcloud. Authenticate again in every cleanup/retrieval job; never rely on credentials surviving a long Windows build. Do not create JSON SA keys or grant project-wide Token Creator. See [Google's pipeline WIF guidance](https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines).

### Role boundaries

The following are target minimum capabilities, not a proposal to assign Owner/Editor. Check exact API permission requirements against the pinned Terraform provider in stage 1. Commit explicit custom-role definitions and an exercised permission matrix; do not wildcard `compute.*` or automatically add permissions on 403.

| Principal | Scope and required capabilities | Explicit exclusions |
|---|---|---|
| Bootstrap administrator | Initially enable APIs, create SAs/WIF/custom roles/bindings and billing budget; supply approved project/billing IDs | No bootstrap IAM or billing mutation rights in routine CI |
| `gha-submit` | Custom `cloudbuild.builds.create/get/list/update` (including cancellation); Service Account User (`iam.serviceAccounts.actAs`) only on `cb-windows`; Storage Object Admin on run source/result/log buckets as needed to stage/read/purge | No infrastructure IAM editing, no VM impersonation or SA keys |
| `cb-windows` | Custom builder role: instances create/get/list/delete/setMetadata/setLabels/stop; disks create/get/list/delete/use; images create/get/list/delete/setLabels; machineTypes/zones/regions/zoneOperations/globalOperations get/list; networks/subnetworks get and subnetworks.use/useExternalIp. Service Account User only on `vm-builder`; input object viewer, build-output object admin, log object creator | No GitHub token, no IAM editing, no broad runtime deployment rights |
| `gha-deploy` | Custom Terraform role covering create/get/list/update/delete for VPC/subnets/routes/firewalls, instances/disks/templates/groups, regional addresses/forwarding rules/HTTP proxies/URL maps/backend services/health checks, including group add/remove/setNamedPorts, network/subnet/image/disk use and operation polling; SA User only on `vm-runtime`. Storage bucket create/get/list/update/delete for ephemeral run storage and object admin there; state object admin | No project IAM policy changes, no API disabling, no SA creation, no builder-SA impersonation |
| `vm-builder` | Storage Object Viewer on its input bucket; Storage Object Creator on build-output bucket (unique objects, no overwrite/delete) | No Compute API administration, no GitHub authentication |
| `vm-runtime` | Storage Object Viewer on delivery bucket only; metadata-issued tokens with cloud-platform scope constrained by IAM | No source/output/state access, package publish, VM creation or SA impersonation |
| `gha-cleanup` | Union of necessary run-resource read/delete/update capabilities to cancel builds, remove group dependencies and destroy run infra; storage bucket/object purge; asset inventory read. No create except recovery operations strictly needed by destroy | No arbitrary IAM changes or project/billing deletion |
| `gha-janitor` | Same resource cleanup capabilities plus read-only run-ledger/build discovery; separate workflow trust; asset inventory read | No package write, IAM grant, or ability to alter its own trust |

`compute.instances.setServiceAccount` is needed only if implementation changes an existing attachment; prefer setting the approved SA at creation. Add image-use permissions to deployer and the service agents where actually required, not image-admin. Audit the permission list for Windows password-reset APIs: none are needed by the chosen transport. Use bucket IAM rather than project-wide storage roles; scripts can bootstrap each bucket's bindings through a narrowly scoped bucket IAM permission on the dedicated project's run buckets. This remains a meaningful privilege: deploying arbitrary trusted code on a VM can exercise that VM's SA. Isolate source, output, delivery and state accordingly.

IAM cannot generally confine all create/delete operations to arbitrary run labels. Project-level network mutation and janitor deletion authority remain powerful. The real boundary is a dedicated project plus protected main/workflow files and least-privilege SA attachments. For this small project, serialize runs; use run-specific bucket IAM bindings and revoke/delete buckets at cleanup. Do not claim labels provide authorization.

## 6. Stages, gates and workflow graph

| Stage | Entry criteria | Work / owner | Exit criteria |
|---|---|---|---|
| 0. Resolve contract | Brief available | Record license decision, region, project, repo IDs, budget, HTTP demo scope and artifact schema | Community eligibility documented or explicit toolchain amendment; no ambiguous artifact/image contract |
| 1. Bootstrap and feasibility | Stage 0 accepted | Administrator creates trust/IAM/APIs; Actions validates allowed/denied WIF cases; minimal Windows image probe and NuGet push/pull | No keys; exact image supported; activation, script reboot/resume, Sysprep/fresh boot and package round trip proven; cost rates captured |
| 2. Cleanup before full build | Bootstrap complete | Implement Terraform skeleton, ledger, janitor and per-service inventory; create inexpensive fixtures | Destroy twice succeeds; out-of-state orphan removed; evidence saved; permission-denied discovery fails closed |
| 3. Image/application build | Cleanup tested; pinned inputs present | Cloud Build/Windows VM builds/tests/packages/generalizes/captures | Package, hashes, logs and image READY; build VM/disk gone; fresh image boot tested in next stage |
| 4. Publish and retrieve | Trusted build manifest complete | Actions publishes and independently retrieves exact NuGet version | Download hash equals build hash; manifest staged; publishing error prevents deployment |
| 5. Deploy and verify | Image READY and package retrieved | Terraform creates two nodes and regional LB; startup installs retrieved payload; frontend tests | Both expected node IDs and hashes proven through LB; direct ingress negative tests pass; startup/activation accepted |
| 6. Destroy and attest | Any prior result, including failure | Independent cleanup identity cancels builds, destroys infra, sweeps orphans and exports evidence | Empty run resources; inventory contains only the declared billing-observation exception; deletion evidence complete; original test failure retained |
| 7. Reconcile | Teardown timestamp and evidence retained | Scheduled GitHub billing/inventory review | No unexplained post-cutoff workload usage; observation costs recorded; dataset/export removed and final inventory empty; anomalies reopen incident |

Workflow graph:

```text
push main -> validate -> prepare -> submit/poll Cloud Build -> publish -> retrieve -> deploy -> verify
                    \______________________________________________________________/
                                 cleanup (needs all, if: always()) -> inventory proof
workflow_run completed -> independent cleanup recovery (trusted default-branch code)
schedule every 15 minutes + workflow_dispatch -> janitor -> orphan inventory/proof
next-day and later review -> billing reconciliation
```

Set concurrency group to the fixed project ID, `cancel-in-progress: false`; use the same exclusion group for mutation workflows, and avoid holding it during long sleeps. A run exceeding its deadline must not prevent janitor indefinitely: allow janitor to cancel the stale run/build, then sweep after controllers stop. Every operation has a bounded poll. Keep the normal lifecycle under 150 minutes; cleanup gets a separate 30-minute job. GitHub scheduling is best effort and cannot guarantee a 15-minute recovery SLA. Add `workflow_run` recovery for failures before cleanup starts; read only the ledger/run identifiers from the failed run, and execute cleanup code from protected main, never downloaded PR code.

The developer sees separate image-build, package round-trip, node-A, node-B, normal-LB and cleanup conclusions in the Actions summary, with Cloud Build IDs/log links, version/digests and a teardown report. A failed cleanup leaves the overall run failed even when functional tests passed. Capture sanitized logs before deletion, but a log upload failure must not block destruction. Keep functional failure and cleanup failure as separate statuses.

## 7. Teardown and what “proven” means

**Ownership:** Terraform owns deployment resources and the run buckets/state infrastructure; bootstrap handles creation of the state bucket before backend initialization. Image scripts own build VM/disk/image. Record resource names in GitHub evidence and labels *before* launching operations. Include resources not yet written to Terraform state. After final closeout, a reusable project keeps only APIs, SAs, IAM/WIF and other non-metered configuration; no stored baseline images or state buckets. During financial observation, the billing dataset is a declared temporary exception, never hidden in an empty-inventory claim.

Cleanup order:

1. Mark the run closed so controllers cannot create more resources. Cancel and poll active Cloud Builds to terminal state, stop outstanding builder operations, and ensure VM startup cannot race another image creation. Check the ledger against build substitutions and API operations, not only job-local files.
2. Disable/delete the LB forwarding rule first; delete proxies, URL maps, backend services and health checks, then groups, instances/templates, custom images, leftover disks/snapshots, addresses, firewall rules, subnets and VPC in dependency order. Use `terraform destroy` for tracked resources and narrowly targeted API deletion for build/orphan resources. Retry in-use and eventual-consistency errors; confirm operation completion. Never accept “request submitted” as deleted.
3. Fetch proof/logs/state for evidence. Empty all run bucket objects, including generations and incomplete uploads where applicable, then delete input/output/delivery/log buckets. Disable soft delete at creation, not after deletion. No retention locks. State bucket is last: complete destroy using it, copy final state/evidence to the GitHub runner, reinitialize locally if necessary, and explicitly purge/delete the backend bucket. Do not destroy a state backend midway through ordinary Terraform operations.
4. Run an independent authoritative inventory across **all zones/regions**, including stopped VMs, disks, snapshots, images/machine images, forwarding rules, addresses, reservations, commitments, NAT routers, worker pools, storage buckets/soft-deleted storage, Artifact Registry repositories, Cloud Run services, Scheduler jobs, BigQuery datasets, log buckets/sinks and any other enabled metered service. During observation, explicitly enumerate the billing dataset as an exception; remove it for final closeout. Compare with an empty-project baseline, not just `run_id` matches. Use Cloud Asset Inventory as a cross-check because its freshness/coverage is not sufficient alone. Unrecognized resources are a failed proof, not automatic deletion outside this project's ownership contract.
5. Repeat inventory after a short consistency interval; save timestamped JSON, completed deletion operation IDs, remaining non-metered baseline resources and failed API queries. Inability to list a service is **unknown**, not empty. Cleanup is idempotent: 404 is success, 403 is failure. Janitor detects expired `expires_at` labels and name/ledger entries; it also lists unlabeled resources in this dedicated project and flags ownership anomalies.
6. Upload a small `teardown-proof.json` and sanitized evidence bundle to GitHub before losing runner context. Report `resources_deleted`, `inventory_verified_at`, and `billing_reconciliation_pending` separately. Verify no Cloud Build is still accruing minutes.

**Financial evidence:** Save a cutoff timestamp T after the final deletion completes. On the next day and again after at least 72 hours, inspect project/SKU usage for `usage_start_time >= T`, rather than the arrival time of a billing record. Investigate positive gross usage/cost even if credits make net cost zero. Delayed pre-T charges are expected and do not imply a leak. Billing corrections can arrive later; 72 hours is an operational review interval, not a provider finality guarantee. Reconcile against the monthly invoice. [Google documents variable billing reporting delays](https://docs.cloud.google.com/billing/docs/how-to/export-data-bigquery-tables/detailed-usage).

For unattended financial review, configure detailed Cloud Billing export to a small BigQuery dataset in this same project during bootstrap. There is no general Cloud Billing API that substitutes for detailed usage export. Give a separate `gha-billing-review` SA BigQuery Job User on the project and Data Viewer on only this dataset, with separately restricted WIF workflow trust; give the final cleanup SA dataset/table deletion rights. Query with maximum-bytes-billed limits, export the relevant records to GitHub, then remove the export configuration and delete the dataset after the observation window. The billing export writer uses its documented Google-managed identity. This dataset incurs storage/query costs and is an explicit temporary exception: report runtime teardown first and final chargeable-storage teardown only after reconciliation. For recurring merges, retaining this dataset is a costed baseline, not zero spend; deleting and recreating it also loses continuous billing history. If immediate project-wide zero retained storage is non-negotiable, unattended detailed financial reconciliation needs an existing external billing-data facility, or must be relaxed to manual billing-account review. Literal immediate zero spend, including audit/log retention and all future adjustments, cannot honestly be certified. Deleting the entire project or detaching billing is an optional one-shot administrative closeout, not the routine design; it also destroys the reusable WIF/bootstrap and still does not erase accrued charges.

Fault-injection acceptance tests: fail compiler; interrupt installer/reboot; kill polling controller; force package auth failure; corrupt payload; block health check; cancel workflow; revoke deploy rights while retaining cleanup rights; create an unlabeled/out-of-state disk; simulate inventory 403. For each, prove eventual sweep or explicit failed/unknown cleanup status. Revoking **all** cleanup access or a prolonged control-plane outage is a documented external recovery dependency; it cannot be solved by another script using the same broken authority.

## 8. Cost envelope and controls

Reference successful run: builder 90 minutes maximum; two runtime nodes for 45 minutes; Linux controller up to 100 minutes. Rates below are planning inputs, not a fixed quote. Refresh the Compute SKU estimate during stage 1; do not assume free tiers or credits.

| Item | Unit price / planning assumption | Example allowance |
|---|---|---|
| Builder e2-standard-4 | Approximately $0.134/hour base in Iowa (estimate to verify) + **$0.184/hour Windows** = ~$0.318/hour | 1.5 hours: ~$0.48 |
| Two e2-standard-2 runtime VMs | Approximately $0.067/hour base each (estimate to verify) + **$0.092/hour Windows** each | 2 × 0.75 hours: ~$0.24 |
| Default-pool Cloud Build e2-standard-2 | **$0.006/minute**; polling counts | 100 minutes: $0.60 |
| Boot disks | Budget ~$0.10/GiB-month for pd-balanced, confirm regional SKU | 100 GiB × 3 aggregate VM-hours / 730: ~$0.041 |
| Custom image | Budget ~$0.05/GiB-month, billed stored size; verify SKU | 50 GiB for 2 hours: ~$0.007 |
| External VM IPv4 | **$0.005/address-hour** | 3 aggregate address-hours: $0.015 |
| Regional external Application LB | **$0.025/hour** first forwarding-rule tier; ~$0.008/GiB regional data processing | 0.75 hours: ~$0.019 plus bytes |
| Storage, requests, logs, egress | Allow up to $0.50/run for bounded small artifacts/logs; measure actuals | $0.50 allowance, revise if downloads/exports grow |

The Windows premium is $0.046 per visible vCPU-hour, in addition to VM compute. Sources: [Compute pricing and Windows license rates](https://cloud.google.com/products/compute/pricing/general-purpose), [Cloud Build pricing](https://cloud.google.com/build/pricing), [LB pricing](https://cloud.google.com/load-balancing/pricing), [IPv4 pricing](https://cloud.google.com/vpc/network-pricing), and [disk/image prices](https://cloud.google.com/compute/disks-image-pricing). The minimum proxy-instance charge described for **internal** Application LBs must not be incorrectly added to this regional **external** LB estimate.

Expected GCP total: approximately **$1.50–$3 per successful run** with the stated bounds; reserve **$5 per attempt** during development. Twenty attempts: plan $30–$60, with a $100 monthly alert budget. Reserve an additional $1/month for the small, query-capped billing observation dataset until measured; this is an estimate, not a BigQuery unit price. This excludes paid Microsoft licenses, GitHub minutes/storage and tax. Full IDE installation can exceed the time/disk estimates: fail at deadline and revise the envelope from measured results rather than letting it run unattended all night.

A stuck builder costs about $7.63/day in VM compute/Windows alone; both runtime nodes roughly another $7.63/day, before disks, IPs, LB and controller. The cheap-looking hourly numbers still justify cleanup-first implementation. Do not buy commitments or reservations. Set build/job timeouts, VM `maxRunDuration` with termination action DELETE where supported, and 3-hour run expiry. Deleting a VM does not delete its image or non-attached resources; janitor still matters. Limit peak concurrency to one builder and two runtime VMs, limit CPUs/disks through project quotas, and alert at $10/$25/$50/$100. Quotas constrain exposure; budget notifications do not stop it. Successful teardown targets $0 ongoing infrastructure run-rate, subject to the financial caveats above.

## 9. Proposed repository layout

```text
.github/workflows/
  pipeline.yml                 # merge -> build -> publish -> retrieve -> deploy -> verify -> cleanup
  cleanup-recovery.yml         # workflow_run recovery using trusted main
  janitor.yml                  # schedule/manual sweep, serialized with normal mutations
  billing-review.yml           # delayed export queries and dataset closeout
app/                           # sample service, Windows Service host, identity/version endpoints
  src/  tests/  global.json  packages.lock.json
contracts/
  deployment.schema.json       # app-independent install/run/health/hash contract
build/
  cloudbuild.yaml              # pinned Linux orchestrator steps, explicit SA/log bucket/timeouts
  toolchain.lock.json          # OS image, SDK/installers/workloads/hashes/license decision
  package.nuspec
scripts/
  build-image.sh               # launch/poll/capture/delete Windows builder
  windows/bootstrap.ps1        # checkpointed installer/source/build/pack state machine
  windows/generalize.ps1       # sanitization and GCESysprep
  windows/install-service.ps1  # package validation, service install, readiness
  publish-package.sh           # GitHub NuGet push
  retrieve-package.sh          # authenticated registry round trip and staging
  verify-lb.py                 # deterministic node routes, hashes, negative ingress tests
  cleanup.sh                   # cancellation, destroy, orphan sweep, state backend last
  inventory.py                 # API-specific inventory and baseline comparison
  janitor.py                   # expiry/ownership checks and cleanup invocation
  billing-review.py            # bounded BigQuery queries, export evidence, dataset closeout
infra/
  bootstrap/                   # separately applied WIF/SAs/APIs/custom roles, no daily destroy
  run/                         # VPC, VMs, groups, regional LB and disposable buckets
  iam/                         # custom role permission lists and exercised permission matrix
  .terraform.lock.hcl
policies/
  baseline.json                # allowed retained non-metered resources
  deadlines.json               # deadlines, expiry, retry limits
  retention.json               # package and GitHub evidence retention
  source-excludes.txt
tests/                         # contract, permission and failure-injection integration checks
 docs/
  bootstrap.md                 # once-only admin actions and licensing record
  recovery.md                  # cleanup failure and externally blocked recovery
  cost-model.md                # dated SKU evidence and measured run costs
PLAN-CODEX.md
```

Pin Actions to commit SHAs, Terraform providers through the lockfile, and builder tools/images to immutable versions/digests. Store generated plans, credentials, packages, state and proof bundles outside tracked source; never commit them. Avoid vendoring tools or implementing general-purpose packaging infrastructure beyond this contract.

## 10. Ordered build checklist

1. Confirm the actual brief filename and record scope amendments: license/toolchain, HTTP demonstration, package format, zero-resource versus billing proof, bootstrap boundary.
2. Select dedicated project/repo IDs, region/zones, quotas, budget alerts and immutable run-name convention. Check external-address and Windows-image organization policies.
3. Bootstrap APIs, WIF provider conditions, separate SAs/custom roles and GitHub workflow/package settings. Test allowed main identity and denied fork/wrong-repo/wrong-workflow identities.
4. Implement inventory and recovery first; create and destroy a small fixture, then an out-of-state disk. Prove inventory query failure cannot report green.
5. Implement run bucket creation, explicit disabled soft-delete/retention, per-SA access separation and state-backend finalization. Exercise purge of old object generations.
6. Probe the pinned Windows base image: activation, outbound installer access, startup metadata, checkpoint/reboot and GCESysprep. Capture and fresh-boot an image without IDE installation first.
7. Implement the minimal sample and application-independent deployment schema. Add local build tests, manifest validation and version/node identity responses.
8. Add the approved Windows toolchain, locked dependencies, Windows build/test/publish, NuGet packaging, SBOM, pre-generalization log export and secret scan. Measure duration/disk usage.
9. Wire the Linux Cloud Build controller, explicit build SA, async submission/status/cancellation, timeouts, image manifest and builder cleanup. Kill the controller and demonstrate janitor recovery.
10. Publish a throwaway NuGet version with `GITHUB_TOKEN`, retrieve it through the feed in a fresh step, verify its digest and test package access denial. Wire transient GCS delivery; ensure no GitHub token reaches Windows.
11. Implement Terraform runtime VMs, image pin, groups, regional ALB/proxy subnet, health checks/firewalls and deterministic diagnostic routes. Confirm fresh-image startup installs only the retrieved package.
12. Run node-A/node-B/normal-route frontend tests plus direct-ingress rejection. Save expected IDs, package digests and response evidence.
13. Wire unconditional cleanup and independent workflow recovery. Test every failure case in section 7, repeat destruction, and scan all project regions/services for leftovers.
14. Implement package/evidence pruning and delayed billing review. Measure actual SKU costs against the envelope; update rate assumptions with dated evidence.
15. Demonstrate two consecutive clean merge-driven runs, one failed build, one cancelled run and one orphan sweep. Accept the project only with separate functional, teardown-inventory and pending/reconciled billing statuses visible to a reviewer.
