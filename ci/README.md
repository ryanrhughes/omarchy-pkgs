# CI spike: build PRs on ephemeral DigitalOcean droplets

Status: spike. Nothing here publishes. The repository host keeps building and
signing on merge exactly as before.

## Pieces

- `.github/workflows/build-pr.yml` — on a PR touching `pkgbuilds/**`, one job
  per changed package on runners labelled `omarchy-builder`. Uploads the
  unsigned `.pkg.tar.zst` as a workflow artifact (7 days).
- `runner-cloud-init.yaml` — Ubuntu 24.04 user-data: docker + buildx, the
  GitHub runner registered `--ephemeral`, runs one job, powers off.
- `controller.sh` — cron every minute on a small always-on droplet. Polls for
  queued jobs with our label, creates one c-32 droplet per job up to
  `MAX_DROPLETS`, deletes droplets that are powered off or older than
  `MAX_AGE_MINUTES`. No inbound endpoint. Needs `gh` (repo admin, for
  registration tokens), `doctl`, `jq`.

## What the spike proved (2026-09-17, fork ryanrhughes/omarchy-pkgs)

- `bin/build` works from a bare clone: with no local published tree it
  plans against and resolves from `https://pkgs.omarchy.org/<mirror>/<arch>`.
- Droplet create → runner registered: ~70 s. omarchy-fish PR job: 2 min
  including the builder image build. Droplet powers off after the job.
- linux-omarchy on a c-32 droplet: 30 min wall clock for the build job
  (23:39 → 00:09), 254 MB artifact. Cold start ~90 s before the job began.
- A PR whose PKGBUILD fails to build turns the required check red and GitHub
  refuses the merge (`mergeStateStatus=BLOCKED`, `gh pr merge` refuses
  without `--admin`).
- Controller: one queued job + one busy droplet ⇒ creates exactly one more;
  reaps powered-off droplets on the next tick.

## Not done (required before this touches the real repo)

- Tooling from base: check out master's `bin/ helpers/ build/` and overlay
  only the PR's `pkgbuilds/<name>`; today a PR can edit the build script.
- "Require approval for all outside collaborators" on the repository.
- DigitalOcean cloud firewall on the `omarchy-builder` tag: no inbound, no
  egress to private ranges or the metadata address.
- Controller as a systemd timer with its own credentials on a dedicated
  droplet; concurrency cap tuned; reaper as a separate cron.
- Multi-channel matrix for fast-ring packages, aarch64 (no DO arm64; QEMU or
  an external arm box), and artifact reuse on merge.

## Cleanup

    doctl compute droplet list --tag-name omarchy-builder
    doctl compute droplet delete -f <id>
