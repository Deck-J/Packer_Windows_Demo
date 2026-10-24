#!/usr/bin/env bash
# Policy checks that cost nothing to run and catch the mistakes that cost money or exposure.
# Deliberately simple greps over the Terraform: the heavyweight rules are checkov's job (pr-checks).
set -euo pipefail
cd "$(dirname "$0")/.."
fails=0
fail() { printf '\033[31mPOLICY\033[0m %s\n' "$*"; fails=$((fails+1)); }

TF=infra/main.tf

# 1. No ingress from anywhere.
if grep -nE 'source_ranges *= *\[?"?0\.0\.0\.0/0' "$TF" >/dev/null; then
  fail "a firewall rule admits 0.0.0.0/0"
fi

# 2. The only ingress to the app is Google's LB ranges.
if ! grep -q '130\.211\.0\.0/22' "$TF"; then
  fail "the LB health-check ranges are not in the firewall (the LB test would fail for the wrong reason)"
fi

# 3. Nodes must not get an external IP.
if grep -vE '^\s*#' "$TF" | grep -nE 'access_config' >/dev/null; then
  fail "a network interface has access_config: nodes would be reachable directly, which invalidates the LB proof"
fi

# 4. Every resource that costs money or exposes a port carries the label set.
# Resources that GCP lets us label, must be labelled; the two that cannot (MIG, backend service) must
# carry the run id in their name instead, which is what the teardown sweep matches on.
for res in google_compute_instance_template google_compute_address google_compute_forwarding_rule; do
  if ! awk "/resource \"$res\"/{f=1} f&&/^}/{print; f=0} f" "$TF" | grep -qE 'labels *='; then
    fail "$res has no labels (the label sweep and the janitor cannot find it)"
  fi
done

for res in google_compute_region_instance_group_manager google_compute_region_backend_service; do
  awk "/resource \"$res\"/{f=1} f&&/^}/{print; f=0} f" "$TF" | grep -qE 'name += +"\$\{var\.run_id\}-' \
    || fail "$res is not named after the run id, so the label sweep cannot find it"
done

# 5. Region must be the one we budgeted for.
region=$(grep -E '^variable "region"' -A3 infra/variables.tf | grep default | sed -E 's/.*"(.*)".*/\1/')
[ "$region" = "us-central1" ] || fail "default region is $region, expected us-central1"

# 6. Nothing secret in the tree.
if grep -rIlE 'BEGIN [A-Z ]*PRIVATE KEY|"private_key" *:|-----BEGIN' \
     --exclude-dir=.git --exclude-dir=.terraform . | grep -v 'scripts/policy-check.sh' | grep -q .; then
  fail "something in the tree looks like a credential"
fi

[ "$fails" -eq 0 ] && echo "POLICY_OK"
exit "$fails"
