# Design brief — Windows build → GitHub Packages → two-node GCP deploy → full teardown

A GitHub repository must build a Windows application and prove it runs behind a load balancer on GCP,
then leave the project costing nothing. Every step is automated; a human only merges and watches.

## Required outcome

1. **Build.** Google Cloud Build builds a **Windows Server VM image** containing Visual Studio (Community
   edition as specified), the Windows build libraries needed to compile the app, and a sample
   application.
2. **Publish.** The application artifact is published to **GitHub Packages**.
3. **Trigger.** The whole thing is kicked off by a **GitHub Actions** workflow.
4. **Deploy.** Once the artifact exists in GitHub Packages, it is deployed to **two nodes** on GCP.
5. **Verify.** Each node is tested to confirm the app is reachable **through the load balancer** (not
   just on the node's own IP).
6. **Teardown.** After the tests, everything in the GCP project is spun down to save cost — and it must
   also be spun down when a step fails, or the project leaks money.

"Sample application" is a placeholder — assume a .NET 8 ASP.NET Core service with a health endpoint and
a version endpoint, but the design must not depend on that choice.

## Constraints and context

- Single GCP project, small budget; cost control is a first-class requirement, not an afterthought.
- Automation must be unattended: no interactive logins, no long-lived service-account keys if avoidable.
- Windows licensing: Visual Studio Community on a build agent has licence terms that differ from
  Build Tools; name the risk and the compliant alternative.
- The artifact registry choice matters: GitHub Packages supports NuGet, npm, Maven, RubyGems and
  containers — not arbitrary binaries. Pick one and justify it.
- Teardown must be verifiable: "we deleted the instances" is not the same as "the project bills
  nothing". Say how that is proven.

## Questions the plan must answer concretely

1. **How does Cloud Build produce a Windows image?** Cloud Build's own workers are Linux. Compare:
   (a) Cloud Build step running Packer with the googlecompute builder against a Windows VM over WinRM,
   (b) Cloud Build orchestrating `gcloud compute instances create` + startup-script/metadata handshake,
   (c) Cloud Build native Windows workers / private pool with Windows nodes, if that is actually
   supported and how. State which is chosen and why, with the failure modes of each.
2. **Where does the sample app's source come from** — baked into the image at build time, or built on a
   node after deployment? Which is testable and which is reproducible?
3. **What exactly is published to GitHub Packages**, what is its version scheme, and how does the
   deployment step authenticate to pull it (GITHUB_TOKEN vs a PAT vs a deploy key, and why)?
4. **Load balancer shape** for two Windows nodes: regional external Application LB with instance group
   and health check, or a Network LB with passthrough? Which health-check path, and how do you prove
   traffic went through the LB rather than hitting a node directly?
5. **Teardown design**: Terraform destroy vs gcloud scripts; how the teardown runs on failure
   (`if: always()`), how orphans are caught (labels + a janitor), how you *prove* zero spend afterwards.
6. **Identity**: GitHub Actions → GCP with Workload Identity Federation; the minimum IAM roles for the
   deployer, the Cloud Build service account, and the VM service account.
7. **Failure and cost traps** you would expect: image build duration and cost, Windows activation on
   non-public images, boot time before health checks pass, LB warm-up, GitHub Packages retention,
   concurrent runs colliding on resource names, and a stuck build leaving a VM running overnight.
8. **Repository layout and the CI/CD graph** — files, workflows, what runs where, and what a developer
   sees when it breaks.

## What to return

A critique first (what in this requirement is wrong, risky or underspecified), then a concrete plan:
stages with entry/exit criteria, the file layout, the exact GCP services, the IAM model, the cost
envelope with real unit prices if you know them, and the ordered checklist to build it. Be specific and
sceptical; prefer naming a failure mode over a reassuring generality. If something in the requirement
cannot be done as stated, say so plainly and give the nearest workable alternative.
