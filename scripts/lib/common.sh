#!/usr/bin/env bash
# Shared helpers for the winbuild scripts. No Terraform, no Packer: everything here is gcloud, and every
# function is idempotent — "ensure" means create-if-absent, never create-and-hope.
#
# Required env (set by the workflow from repository variables):
#   PROJECT_ID  REGION  ZONE_A  ZONE_B  RUN_ID  VERSION  NODE_SA
set -euo pipefail

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${REGION:=us-central1}"
: "${ZONE_A:=us-central1-a}"
: "${ZONE_B:=us-central1-b}"
: "${RUN_ID:?RUN_ID is required (short unique id for this run)}"
: "${LABEL_OWNER:=winbuild-ci}"

gcloud config set project "$PROJECT_ID" --quiet >/dev/null
gcloud config set compute/region "$REGION" --quiet >/dev/null

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

# Every resource this project creates carries these labels, which is how destroy and the janitor find
# them without a state file.
labels() { printf 'owner=%s,run=%s,ttl=2h' "$LABEL_OWNER" "$RUN_ID"; }

exists() { "$@" >/dev/null 2>&1; }

# --- network (shared, created once, never destroyed per run) -----------------
ensure_network() {
  say "network"
  exists gcloud compute networks describe wb-net || \
    gcloud compute networks create wb-net --subnet-mode=custom --quiet
  exists gcloud compute subnets describe wb-subnet --region="$REGION" || \
    gcloud compute subnets create wb-subnet --network=wb-net --region="$REGION" \
      --range=10.42.0.0/24 --quiet
  # Only Google's load-balancer ranges may reach the app port. This is what makes the LB test meaningful.
  exists gcloud compute firewall-rules describe wb-fw-lb || \
    gcloud compute firewall-rules create wb-fw-lb --network=wb-net --direction=INGRESS \
      --action=ALLOW --rules=tcp:80 --source-ranges=130.211.0.0/22,35.191.0.0/16 \
      --target-tags=wb-node --quiet
  # Admin access only through IAP, and only for RDP.
  exists gcloud compute firewall-rules describe wb-fw-iap || \
    gcloud compute firewall-rules create wb-fw-iap --network=wb-net --direction=INGRESS \
      --action=ALLOW --rules=tcp:3389 --source-ranges=35.235.240.0/20 \
      --target-tags=wb-node --quiet
  echo "network ready (nodes have no external IP; only LB ranges reach port 80)"
}

# --- one Windows node ---------------------------------------------------------
ensure_node() {
  local name="$1" zone="$2" startup="image/node-startup.ps1"
  if exists gcloud compute instances describe "$name" --zone="$zone"; then
    echo "node $name already exists"
    return 0
  fi
  say "node $name ($zone)"
  gcloud compute instances create "$name" \
    --zone="$zone" \
    --machine-type="${NODE_MACHINE_TYPE:-e2-standard-2}" \
    --image-family="${IMAGE_FAMILY:-winbuild-app}" \
    --image-project="$PROJECT_ID" \
    --boot-disk-size="${NODE_DISK_GB:-50}GB" \
    --boot-disk-type=pd-balanced \
    --network-interface="subnet=wb-subnet,no-address" \
    --service-account="$NODE_SA" \
    --scopes=cloud-platform \
    --tags=wb-node \
    --labels="$(labels)" \
    --metadata-from-file="windows-startup-script-ps1=$startup" \
    --metadata="package-url=${PACKAGE_URL:?},package-sha256=${PACKAGE_SHA256:?},app-version=${VERSION:?}" \
    --quiet
}

# --- load balancer (regional external Application LB) ------------------------
ensure_lb() {
  local ig="wb-${RUN_ID}-ig" hc="wb-${RUN_ID}-hc" bs="wb-${RUN_ID}-bs"
  local um="wb-${RUN_ID}-um" px="wb-${RUN_ID}-px" fr="wb-${RUN_ID}-fr" ip="wb-${RUN_ID}-ip"

  say "load balancer"
  exists gcloud compute instance-groups unmanaged describe "$ig" --zone="$ZONE_A" || \
    gcloud compute instance-groups unmanaged create "$ig" --zone="$ZONE_A" --quiet
  gcloud compute instance-groups unmanaged add-instances "$ig" --zone="$ZONE_A" \
    --instances="${NODE_NAMES:-${INST_A:-},${INST_B:-}}" --quiet

  exists gcloud compute health-checks describe "$hc" --region="$REGION" || \
    gcloud compute health-checks create http "$hc" --region="$REGION" --port=80 \
      --request-path=/healthz --check-interval=10s --timeout=5s \
      --healthy-threshold=2 --unhealthy-threshold=3 --quiet

  exists gcloud compute backend-services describe "$bs" --region="$REGION" || \
    gcloud compute backend-services create "$bs" --region="$REGION" \
      --load-balancing-scheme=EXTERNAL_MANAGED --protocol=HTTP --health-checks="$hc" \
      --health-checks-region="$REGION" --timeout=30s --quiet
  if ! gcloud compute backend-services describe "$bs" --region="$REGION" \
        --format='value(backends[].group)' | grep -q "$ig"; then
    gcloud compute backend-services add-backend "$bs" --region="$REGION" \
      --instance-group="$ig" --instance-group-region="$REGION" --quiet
  fi

  exists gcloud compute url-maps describe "$um" --region="$REGION" || \
    gcloud compute url-maps create "$um" --region="$REGION" --default-service="$bs" --quiet
  exists gcloud compute target-http-proxies describe "$px" --region="$REGION" || \
    gcloud compute target-http-proxies create "$px" --region="$REGION" --url-map="$um" --quiet
  exists gcloud compute addresses describe "$ip" --region="$REGION" || \
    gcloud compute addresses create "$ip" --region="$REGION" --network-tier=PREMIUM --quiet
  local addr
  addr="$(gcloud compute addresses describe "$ip" --region="$REGION" --format='value(address)')"
  if ! exists gcloud compute forwarding-rules describe "$fr" --region="$REGION"; then
    gcloud compute forwarding-rules create "$fr" --region="$REGION" \
      --load-balancing-scheme=EXTERNAL_MANAGED --network-tier=PREMIUM \
      --address="$addr" --target-http-proxy="$px" --target-http-proxy-region="$REGION" \
      --ports=80 --quiet
  fi
  echo "$addr" > lb-ip.txt
  echo "LB IP: $addr (labels $(labels))"
}

# --- readiness ---------------------------------------------------------------
wait_backends_healthy() {
  local bs="wb-${RUN_ID}-bs" tries="${1:-40}"
  say "waiting for both backends to report healthy"
  for i in $(seq 1 "$tries"); do
    local healthy
    healthy="$(gcloud compute backend-services get-health "$bs" --region="$REGION" \
      --format='value(status[].healthStatus[].healthState)' 2>/dev/null | tr ',' '\n' | grep -c HEALTHY || true)"
    printf '  attempt %02d: %s healthy\n' "$i" "${healthy:-0}"
    if [ "${healthy:-0}" -ge 2 ]; then echo "both backends healthy"; return 0; fi
    sleep 15
  done
  die "backends did not both become healthy in $((tries*15))s"
}
