#!/bin/bash
# Poll-driven droplet-per-job controller for the omarchy-builder runner pool.
#
# Run from cron every minute on a small always-on droplet. No inbound
# endpoint: it polls GitHub for queued jobs wanting our label, creates one
# ephemeral droplet per job (up to MAX_DROPLETS), and deletes droplets that
# have powered off or exceeded MAX_AGE_MINUTES. The reaper does not trust its
# own bookkeeping: it lists by tag and acts on what DigitalOcean reports.
#
# Needs: gh (token with actions:read + administration:write on the repo),
#        doctl (DigitalOcean token), jq.
set -euo pipefail

REPO=${REPO:?owner/name}
LABEL=${LABEL:-omarchy-builder}
TAG=${TAG:-omarchy-builder}
REGION=${REGION:-nyc3}
SIZE=${SIZE:-c-32}
IMAGE=${IMAGE:-ubuntu-24-04-x64}
MAX_DROPLETS=${MAX_DROPLETS:-4}
MAX_AGE_MINUTES=${MAX_AGE_MINUTES:-200}
RUNNER_VERSION=${RUNNER_VERSION:-2.337.0}
CLOUD_INIT=${CLOUD_INIT:-$(dirname "$0")/runner-cloud-init.yaml}
LOCK=/tmp/omarchy-controller.lock

exec 9>"$LOCK"; flock -n 9 || exit 0

log() { echo "$(date '+%F %T') $*"; }

# --- reap ------------------------------------------------------------------
now=$(date +%s)
# JSON, not --format: the Created column renders as <nil> in table output.
doctl compute droplet list --tag-name "$TAG" -o json |
  jq -r '.[] | "\(.id) \(.status) \(.created_at)"' |
while read -r id status created; do
  age=$(( (now - $(date -d "$created" +%s)) / 60 ))
  if [[ $status == off ]] || (( age > MAX_AGE_MINUTES )); then
    log "deleting droplet $id (status=$status age=${age}m)"
    doctl compute droplet delete -f "$id"
  fi
done

# --- demand ----------------------------------------------------------------
queued=$(gh api "repos/$REPO/actions/runs?status=queued&per_page=50" --jq '.workflow_runs[].id' |
  while read -r run; do
    gh api "repos/$REPO/actions/runs/$run/jobs" \
      --jq ".jobs[] | select(.status==\"queued\") | select(.labels | index(\"$LABEL\")) | .id"
  done | wc -l)

# Droplets that are still booting/idle count against demand; we cannot see
# which job they will take, so treat every live droplet as covering one.
live=$(doctl compute droplet list --tag-name "$TAG" -o json | jq '[.[] | select(.status != "off")] | length')
need=$(( queued - live ))
(( need > 0 )) || exit 0
room=$(( MAX_DROPLETS - live ))
(( need > room )) && need=$room
(( need > 0 )) || { log "at cap ($live/$MAX_DROPLETS) with $queued queued"; exit 0; }

# --- create ----------------------------------------------------------------
for _ in $(seq "$need"); do
  token=$(gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token)
  userdata=$(sed -e "s|__REPO__|$REPO|" -e "s|__RUNNER_TOKEN__|$token|" \
                 -e "s|__RUNNER_LABELS__|$LABEL|" -e "s|__RUNNER_VERSION__|$RUNNER_VERSION|g" "$CLOUD_INIT")
  name="$TAG-$(date +%s)-$RANDOM"
  log "creating $name ($SIZE) for $queued queued job(s)"
  doctl compute droplet create "$name" --region "$REGION" --size "$SIZE" --image "$IMAGE" \
    --tag-name "$TAG" --user-data "$userdata" --wait --format ID,Name --no-header
done
