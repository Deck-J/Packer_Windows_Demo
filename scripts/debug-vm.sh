#!/usr/bin/env bash
# Create a build-toolchain machine from the newest image, with RDP reachable only through IAP, and a TTL.
#
# Use this when a build succeeded but you want to poke at the environment, or when you need a clean
# reproduction of the image without running the whole pipeline.
#
#   PROJECT_ID=p TTL=4h scripts/debug-vm.sh
set -euo pipefail
: "${PROJECT_ID:?PROJECT_ID is required}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-${REGION}-a}"
TTL="${TTL:-4h}"
NAME="${NAME:-winbuild-debug-$(date -u +%Y%m%d%H%M%S)}"
NODE_SA="${NODE_SA:?NODE_SA is required}"
USER_NAME="${USER_NAME:-packer-debug}"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "creating $NAME in $ZONE from family winbuild-app"
gcloud compute instances create "$NAME" \
  --zone="$ZONE" --machine-type="${MACHINE_TYPE:-e2-standard-4}" \
  --image-family=winbuild-app --image-project="$PROJECT_ID" \
  --boot-disk-size=60GB --boot-disk-type=pd-balanced \
  --network-interface="subnet=wb-subnet,no-address" \
  --service-account="$NODE_SA" --scopes=cloud-platform \
  --tags=wb-node --labels="owner=winbuild-ci,ttl=${TTL},source=debug" --quiet

say "waiting for SSH (the image installs OpenSSH at first boot)"
for i in $(seq 1 40); do
  if gcloud compute ssh "$NAME" --zone="$ZONE" --tunnel-through-iap --command='hostname' --quiet >/dev/null 2>&1; then
    echo "ssh is up"; break
  fi
  printf '  attempt %02d\n' "$i"; sleep 15
  [ "$i" = "40" ] && { echo "ssh never came up"; exit 1; }
done

say "enabling the troubleshooting account"
PW=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
gcloud compute ssh "$NAME" --zone="$ZONE" --tunnel-through-iap --quiet \
  --command="powershell -NoProfile -Command \"\$p=ConvertTo-SecureString '${PW}' -AsPlainText -Force; if(-not (Get-LocalUser -Name '${USER_NAME}' -ErrorAction SilentlyContinue)){ New-LocalUser -Name '${USER_NAME}' -Password \$p -PasswordNeverExpires | Out-Null }; Add-LocalGroupMember -Group Administrators -Member '${USER_NAME}' -ErrorAction SilentlyContinue; Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0; Set-NetFirewallRule -DisplayGroup 'Remote Desktop' -RemoteAddress '35.235.240.0/20' -ErrorAction SilentlyContinue\""

say "connect"
cat <<EOF
RDP through IAP (no public port):
  gcloud compute start-iap-tunnel $NAME 3389 --local-host-port=localhost:13389 --zone=$ZONE
  # then point your RDP client at localhost:13389

user:     $USER_NAME
password: $PW

auto-deleted after $TTL by scripts/reap-leftovers.sh (label ttl=${TTL})
EOF
