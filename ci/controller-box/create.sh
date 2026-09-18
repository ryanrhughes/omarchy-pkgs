#!/bin/bash
# Create the controller droplet with plain curl. Run from a laptop, once.
#
#   DIGITALOCEAN_TOKEN=... GITHUB_TOKEN=... ci/controller-box/create.sh [branch]
#
# The DO token given here is baked into the box's env file, so it must be the
# token for the account that should pay for builder droplets.
set -euo pipefail
here=$(dirname "$0")
: "${DIGITALOCEAN_TOKEN:?}" "${GITHUB_TOKEN:?}"
REPO=${REPO:-omacom/omarchy-pkgs}
BRANCH=${1:-master}
REGION=${REGION:-nyc3}
NAME=${NAME:-omarchy-controller}

env_file=$(sed -e "s|^DIGITALOCEAN_TOKEN=.*|DIGITALOCEAN_TOKEN=$DIGITALOCEAN_TOKEN|" \
               -e "s|^GITHUB_TOKEN=.*|GITHUB_TOKEN=$GITHUB_TOKEN|" \
               -e "s|^REPO=.*|REPO=$REPO|" "$here/controller.env.example")
userdata=$(sed -e "s|__REPO_URL__|https://github.com/$REPO.git|" -e "s|__BRANCH__|$BRANCH|" \
               -e "s|__ENV_B64__|$(printf '%s\n' "$env_file" | base64 -w0)|" "$here/cloud-init.yaml")
body=$(jq -n --arg name "$NAME" --arg region "$REGION" --arg ud "$userdata" \
  '{name:$name, region:$region, size:"s-1vcpu-1gb", image:"ubuntu-24-04-x64", tags:["omarchy-controller"], user_data:$ud}')

# Refuse to create a second one.
existing=$(curl -fsS -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
  "https://api.digitalocean.com/v2/droplets?tag_name=omarchy-controller" | jq '.droplets | length')
if (( existing > 0 )); then echo "a controller droplet already exists" >&2; exit 1; fi

curl -fsS -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" -H "Content-Type: application/json" \
  -X POST -d "$body" https://api.digitalocean.com/v2/droplets | jq -r '"created \(.droplet.name) id=\(.droplet.id)"'
