#!/usr/bin/env bash
# Prove the application is reachable THROUGH the load balancer, on both nodes, at the published version.
#
# Three independent assertions:
#   1. the LB IP answers /healthz with 200
#   2. /version equals the package version that was published (not the image's baked copy)
#   3. across N requests, both node identities appear in X-Served-By
set -uo pipefail
cd "$(dirname "$0")"
. lib/common.sh

: "${VERSION:?VERSION is required}"
IP="${1:-$(cat lb-ip.txt 2>/dev/null || true)}"
[ -n "$IP" ] || die "no LB IP: pass one as \$1 or run deploy.sh first"
N="${REQUESTS:-20}"
say "verifying http://$IP (expecting version $VERSION)"

for i in $(seq 1 40); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$IP/healthz" || true)"
  [ "$code" = "200" ] && break
  printf '  attempt %02d: /healthz -> %s\n' "$i" "${code:-no response}"
  sleep 10
  [ "$i" = "40" ] && die "LB never returned 200 on /healthz"
done
echo "healthz: 200"

seen_version="$(curl -s --max-time 10 "http://$IP/version")"
echo "version endpoint says: ${seen_version:-<empty>}"
case "$seen_version" in
  *"$VERSION"*) echo "version matches the published package" ;;
  *) die "LB serves version '${seen_version}', expected '${VERSION}' - nodes are not running the published artifact" ;;
esac

serve="$(for i in $(seq 1 "$N"); do curl -s -D - -o /dev/null --max-time 5 "http://$IP/healthz" \
          | tr -d '\r' | awk -F': ' 'tolower($1)=="x-served-by"{print $2}'; done | sort | uniq -c | tee /tmp/served.txt)"
echo "served by:"; sed 's/^/  /' /tmp/served.txt
distinct="$(awk '{print $2}' /tmp/served.txt | sort -u | wc -l)"
[ "$distinct" -ge 2 ] || die "only $distinct node answered in $N requests: traffic is not being distributed"

gcloud compute backend-services get-health "wb-${RUN_ID}-bs" --region="$REGION" \
  --format='table(status[].healthStatus[].instance.basename(), status[].healthStatus[].healthState)' | sed 's/^/  /'
echo "PASS: reachable through the LB, version $VERSION, $distinct nodes serving"
