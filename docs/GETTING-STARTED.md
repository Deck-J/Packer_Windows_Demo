# Getting started

For a developer who has been handed this framework and needs to ship an application with it. Two paths; most
teams want the first.

## Path A — start from this repository as a template (30 minutes)

1. **Use it as a template.** GitHub → *Use this template* → *Create a new repository*. (On the template repo:
   Settings → tick **Template repository**, so nobody has to fork by hand.)
2. **Create your application definition and a working app skeleton:**
   ```bash
   git clone <your-new-repo> && cd <your-new-repo>
   bin/init-from-template.sh my-service --port 8080
   ```
   That writes `src/my-service/` (a runnable ASP.NET Core app plus the contract tests) and
   `projects/my-service.yaml`, then validates both.
3. **Check it against the image before you build anything:**
   ```bash
   bin/framework-doctor
   ```
   It compares what your project asks for (Visual Studio edition, workloads, .NET version, devenv, out-of-proc)
   with what the image in `image/profile.yaml` provides, and prints the exact setting to change. This is the
   difference between a two-second answer and a 45-minute image build that ends in *"the task X was not found"*.
4. **Remove the demo when you are ready:** `git rm -r src/WinBuild.SampleApp src/WinBuild.SampleApp.Tests projects/sample-app.yaml`,
   then add your projects to a solution.
5. **Bootstrap once**, following [`RUNBOOK.md`](RUNBOOK.md) §1: create a GCP project, run the `bootstrap`
   workflow with a 60-minute access token, delete the token, set the repository variables.
6. **Push to `main`.** The pipeline builds an image containing your app, publishes it to GitHub Packages, deploys
   two nodes behind a load balancer, proves the app answers through it, and tears everything down.

## Path B — bring this framework to an existing repository

Not supported yet, and that is deliberate: the framework is currently *copied*, not *consumed*. Publishing the
pipeline as a reusable workflow (`workflow_call`) plus composite actions is the next step; until then, copying is
the honest instruction, and the docs say so rather than implying a one-line `uses:`.

## What you inherit, and what you have to decide

| you inherit | you decide |
|---|---|
| the image build (Visual Studio, SDKs, IIS, utilities) | which Visual Studio edition and workloads your project needs |
| the pipeline: build → publish → deploy → verify → teardown | your project definition: solution, tests, artifact id, site name, port |
| the validation suite and phases | your own checks in `custom/tests/*.Tests.ps1` |
| secret handling, IAM shape, teardown proofs | your secrets, in Secret Manager |
| the cost model and budget guards | your budget ceiling |

## The contract your application must satisfy

Any app built by this framework must, at the very least:

- answer `GET /healthz` with `200` and the body `ok` — the load balancer's health check
- answer `GET /version` with the version that was published — so "deployed" and "tested" cannot diverge
- set an `X-Served-By` header identifying the instance — so a two-node test can prove both nodes answered

Everything else is yours. `templates/starter/` is a working example of exactly that contract.

## Where to look when something breaks

| symptom | look at |
|---|---|
| the doctor reports a mismatch | the fix line it prints; then `docs/RUNBOOK.md` §3a |
| the image build fails | `docs/RUNBOOK.md` §3, then the streamed Cloud Build log |
| the app builds but `/healthz` fails | `C:\app\status.json` on the node, and `docs/RUNBOOK.md` §3c |
| the deploy is slow | the MIG takes ~6 minutes to boot Windows; check backend health rather than guessing |
