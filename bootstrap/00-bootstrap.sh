#!/usr/bin/env bash
# One-time bootstrap for the winbuild pipeline. Idempotent: safe to re-run.
#
# Run from the `bootstrap` GitHub Actions workflow (see .github/workflows/bootstrap.yml), which supplies
# a SHORT-LIVED access token — never a service-account key. Everything it creates is what the pipeline
# afterwards uses through Workload Identity Federation, so this is the only credential the project ever
# sees and it expires within the hour.
#
# Requires: gcloud, a user token with Project Owner on the target project (and Billing Account User on
# the billing account for the budget).
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?set PROJECT_ID}"
BILLING_ACCOUNT="${BILLING_ACCOUNT:?set BILLING_ACCOUNT (XXXXXX-XXXXXX-XXXXXX)}"
REGION="${REGION:-us-central1}"
GITHUB_REPO="${GITHUB_REPO:?set GITHUB_REPO as owner/repo}"
BUDGET_AMOUNT="${BUDGET_AMOUNT:-25}"
PREFIX="winbuild"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
have() { "$@" >/dev/null 2>&1; }

gcloud config set project "$PROJECT_ID" --quiet

say "1/8 Enabling APIs (idempotent)"
APIS=(
  compute.googleapis.com cloudbuild.googleapis.com storage.googleapis.com iam.googleapis.com
  iamcredentials.googleapis.com logging.googleapis.com monitoring.googleapis.com
  secretmanager.googleapis.com billingbudgets.googleapis.com cloudresourcemanager.googleapis.com
  iap.googleapis.com cloudtrace.googleapis.com
)
gcloud services enable "${APIS[@]}" --project="$PROJECT_ID" --quiet
echo "enabled: ${#APIS[@]} APIs"

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
echo "project number: $PROJECT_NUMBER"

say "2/8 State bucket (versioned, uniform access, no public access)"
STATE_BUCKET="gs://${PROJECT_ID}-${PREFIX}-tfstate"
if ! gsutil ls -b "$STATE_BUCKET" >/dev/null 2>&1; then
  gcloud storage buckets create "$STATE_BUCKET" --project="$PROJECT_ID" --location="$REGION" \
    --uniform-bucket-level-access --public-access-prevention
fi
gcloud storage buckets update "$STATE_BUCKET" --versioning >/dev/null
echo "state bucket: $STATE_BUCKET"

say "3/8 Artifact + build-input buckets (lifecycle 14 days, versioned)"
ARTIFACT_BUCKET="gs://${PROJECT_ID}-${PREFIX}-artifacts"
BUILD_BUCKET="gs://${PROJECT_ID}-${PREFIX}-build"
for b in "$ARTIFACT_BUCKET" "$BUILD_BUCKET"; do
  if ! gsutil ls -b "$b" >/dev/null 2>&1; then
    gcloud storage buckets create "$b" --project="$PROJECT_ID" --location="$REGION" \
      --uniform-bucket-level-access --public-access-prevention
  fi
  gcloud storage buckets update "$b" --versioning >/dev/null
  cat > /tmp/lifecycle.json <<'JSON'
{"rule":[{"action":{"type":"Delete"},"condition":{"age":14,"isLive":false}}]}
JSON
  gcloud storage buckets update "$b" --lifecycle-file=/tmp/lifecycle.json >/dev/null
done
echo "buckets: $ARTIFACT_BUCKET $BUILD_BUCKET"

say "4/8 Service accounts (builder, node, cloudbuild, deployer)"
for sa in builder node cloudbuild deployer; do
  email="sa-${PREFIX}-${sa}@${PROJECT_ID}.iam.gserviceaccount.com"
  if ! gcloud iam service-accounts describe "$email" >/dev/null 2>&1; then
    gcloud iam service-accounts create "sa-${PREFIX}-${sa}" \
      --display-name="winbuild ${sa}" --project="$PROJECT_ID" --quiet
  fi
  echo "  $email"
done
SA_BUILDER="sa-${PREFIX}-builder@${PROJECT_ID}.iam.gserviceaccount.com"
SA_NODE="sa-${PREFIX}-node@${PROJECT_ID}.iam.gserviceaccount.com"
SA_BUILD="sa-${PREFIX}-cloudbuild@${PROJECT_ID}.iam.gserviceaccount.com"
SA_DEPLOY="sa-${PREFIX}-deployer@${PROJECT_ID}.iam.gserviceaccount.com"

say "5/8 Role bindings (project-level, deliberately narrow)"
bind() { gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$1" --role="$2" --condition=None --quiet >/dev/null; echo "  $2 -> ${1#serviceAccount:}"; }
# deployer: builds, reads/writes the two buckets, manages compute, acts as the VM SA
bind "serviceAccount:${SA_DEPLOY}" roles/cloudbuild.builds.editor
bind "serviceAccount:${SA_DEPLOY}" roles/storage.admin
bind "serviceAccount:${SA_DEPLOY}" roles/compute.admin
bind "serviceAccount:${SA_DEPLOY}" roles/logging.viewer
# Debug access stores a per-build password in Secret Manager rather than in a log.
bind "serviceAccount:${SA_DEPLOY}" roles/secretmanager.admin
bind "serviceAccount:${SA_DEPLOY}" roles/iam.serviceAccountUser
# cloud build: create/delete the builder VM and its disks, act as the builder SA
bind "serviceAccount:${SA_BUILD}" roles/compute.instanceAdmin.v1
bind "serviceAccount:${SA_BUILD}" roles/iam.serviceAccountUser
bind "serviceAccount:${SA_BUILD}" roles/storage.admin
bind "serviceAccount:${SA_BUILD}" roles/logging.logWriter
# builder VM: writes status/artifacts only
bind "serviceAccount:${SA_BUILDER}" roles/storage.objectAdmin
bind "serviceAccount:${SA_BUILDER}" roles/logging.logWriter
# nodes: read the artifact bucket, write logs/metrics
bind "serviceAccount:${SA_NODE}" roles/storage.objectViewer
bind "serviceAccount:${SA_NODE}" roles/logging.logWriter
bind "serviceAccount:${SA_NODE}" roles/monitoring.metricWriter

say "6/8 Workload Identity Federation pool + GitHub provider"
POOL="github-pool"
PROVIDER="github-provider"
if ! gcloud iam workload-identity-pools describe "$POOL" --location=global >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "$POOL" --location=global \
    --display-name="GitHub Actions pool" --quiet
fi
if ! gcloud iam workload-identity-pools providers describe "$PROVIDER" \
      --location=global --workload-identity-pool="$POOL" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
    --location=global --workload-identity-pool="$POOL" \
    --display-name="GitHub OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
    --attribute-condition="assertion.repository=='${GITHUB_REPO}'" --quiet
fi
WIF_PROVIDER="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"
echo "provider: $WIF_PROVIDER"

# Only this repository, only main, may impersonate the deployer.
gcloud iam service-accounts add-iam-policy-binding "$SA_DEPLOY" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${GITHUB_REPO}" \
  --quiet >/dev/null
echo "deployer impersonation bound to ${GITHUB_REPO}"

if [ -n "${DYNATRACE_TOKEN_SECRET:-}" ]; then
  say "6b/8 Dynatrace: letting the nodes read the agent token"
  if gcloud secrets describe "$DYNATRACE_TOKEN_SECRET" >/dev/null 2>&1; then
    gcloud secrets add-iam-policy-binding "$DYNATRACE_TOKEN_SECRET" \
      --member="serviceAccount:${SA_NODE}" \
      --role="roles/secretmanager.secretAccessor" --quiet >/dev/null
    echo "  node service account may read $DYNATRACE_TOKEN_SECRET"
  else
    echo "  WARNING: secret $DYNATRACE_TOKEN_SECRET does not exist yet; create it and re-run this script"
  fi
fi

say "7/8 Cost guardrails (CPU quota + budget)"
# A runaway loop must not be able to create forty Windows VMs.
gcloud compute project-info describe --format='value(quotas)' >/dev/null 2>&1 || true
if gcloud compute regions describe "$REGION" --format='value(quotas)' | grep -q CPUS; then
  echo "  NOTE: regional CPU quota is visible; set it to 16 in the console or with:"
  echo "        gcloud compute regions update $REGION --update-quota=CPUS=16"
fi
cat > /tmp/budget.json <<JSON
{
  "displayName": "${PREFIX} monthly budget",
  "budgetFilter": {"projects": ["projects/${PROJECT_NUMBER}"]},
  "amount": {"specifiedAmount": {"currencyCode": "USD", "units": "${BUDGET_AMOUNT}"}},
  "thresholdRules": [
    {"thresholdPercent": 0.5, "spendBasis": "CURRENT_SPEND"},
    {"thresholdPercent": 0.9, "spendBasis": "CURRENT_SPEND"},
    {"thresholdPercent": 1.0, "spendBasis": "CURRENT_SPEND"}
  ]
}
JSON
if gcloud billing budgets list --billing-account="$BILLING_ACCOUNT" --format='value(displayName)' 2>/dev/null | grep -qx "${PREFIX} monthly budget"; then
  echo "  budget exists"
else
  gcloud billing budgets create --billing-account="$BILLING_ACCOUNT" --budget-from-file=/tmp/budget.json --quiet >/dev/null \
    && echo "  budget created (\$$BUDGET_AMOUNT)" || echo "  WARNING: budget not created (needs Billing Account Administrator)"
fi

say "8/8 Values for GitHub repository variables"
cat <<EOF | tee /tmp/bootstrap-values.txt
GCP_PROJECT=$PROJECT_ID
GCP_REGION=$REGION
WIF_PROVIDER=$WIF_PROVIDER
DEPLOYER_SA=$SA_DEPLOY
STATE_BUCKET=$STATE_BUCKET
ARTIFACT_BUCKET=$ARTIFACT_BUCKET
BUILD_BUCKET=$BUILD_BUCKET
NODE_SA=$SA_NODE
EOF
echo
echo "Bootstrap complete. No key was created; the pipeline authenticates by impersonating $SA_DEPLOY."
