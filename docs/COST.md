# Cost model (us-central1, indicative list prices)

| Item | Rate | Per run (~60 min) | Idle months |
|---|---|---|---|
| Builder VM, e2-standard-4 (Windows), ~50 min | ~$0.19/h | ~$0.16 | $0 |
| Two nodes, e2-standard-2 (Windows), ~20 min | ~$0.11/h each | ~$0.07 | $0 |
| LB forwarding rule + proxy, ~20 min | ~$0.025/h | ~$0.01 | $0 |
| Cloud Build worker time (Linux steps) | first 120 min/day free | ~$0 | $0 |
| Image storage, ~15 GB (Build Tools) | $0.05/GB-month | — | **~$0.75** |
| Image storage if `vs_edition` is the full IDE, ~40 GB | $0.05/GB-month | — | **~$2.00** |
| Egress for the test (a few MB) | $0.12/GB | <$0.01 | $0 |
| **Total** | | **≈ $0.25 per run** | **≈ $0.75** |

A Dynatrace **free trial** (no card, 15 days) covers a test tenant; the **Playground** is free but shared and
cannot accept an agent install. `DYNATRACE_DRY_RUN=true` exercises the wiring with no tenant at all.

Monitoring adds no GCP cost. Dynatrace licensing is per host (host units), and ephemeral test nodes each
register as a host even for 20 minutes: if you enable the agent on the test pipeline, expect a handful of
short-lived hosts per day, which is why the host group is `winbuild-test` and separate from production.

Two numbers matter more than the table:

- A leaked Windows VM over a weekend is about **$27**. That is why there is a janitor, a CPU quota and a
  destroy job that runs under `if: always()`.
- The image is the only intentionally persistent cost. Deleting old versions (`gcloud compute images
  delete`) is the lever if it grows.

Budget alert at $25/month with 50/90/100% thresholds is created by the bootstrap.
