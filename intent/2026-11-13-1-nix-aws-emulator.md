---
status: draft
issue: 1
author: olafkfreund
---

# Intent: Install and configure AWS Emulator on NixOS

## Problem

AWS Emulator (https://github.com/aws/aws-emulator, CC0-1.0, Rust) is a local
emulator of the AWS APIs. Upstream supports Linux only through RPM and Debian
packages (`downloads.aws.com/.../LTS/latest/aws-emulator_{amd64,arm64}.deb`,
signed with a `.sig` next to each file) or a Docker image built from a short
Dockerfile. There is no Nix package, no NixOS module and no nixpkgs entry, so a
NixOS user can't install it declaratively, run it as a service or pin a
version.

Facts from the review (release v1.0.342, 2026-11-13):

- The `.deb` holds one stripped, dynamically linked x86_64 binary
  (`/opt/aws-emulator/bin/aws-emulator`, glibc only) plus
  `THIRD_PARTY_LICENSES`. About 177 MB.
- The GitHub release carries only `scores.json.gz`; binaries are on
  `downloads.aws.com`. Only the `latest` URL is known to work; versioned paths
  return 403, so an old pin can't be re-fetched once `latest` moves.
- Building from source needs about 100 GB of `target/` and a long multi-core
  build (437 service crates), which is beyond a standard GitHub runner.
- CLI: `-b/--bind` (`EMULATOR_BIND_ADDRESS`), `-p/--port` (default 9297,
  `EMULATOR_DATA_PORT`), `-t/--telemetry on|off`, `-a/--auth on|off`,
  `--idle-timeout`. Health check `GET /__admin/health` over self-signed HTTPS.
  State is in memory; per-port files go in `~/.aws/emulator/<port>/`.
  Telemetry is on by default.

## Proposed outcome

- A public repo `olafkfreund/nix-aws-emulator` with a flake that exposes
  `packages.<system>.aws-emulator` (x86_64-linux and aarch64-linux),
  an overlay, and `nixosModules.default`.
- `nix run github:olafkfreund/nix-aws-emulator` starts the emulator.
- `services.aws-emulator.enable = true;` runs it as a hardened systemd
  service with options for bind address, port, telemetry, auth, idle timeout,
  extra arguments and opening the firewall.
- A README that explains install (flake input, NixOS module, Home Manager or
  `nix profile`), configuration, pointing the AWS CLI/SDK at it, and
  troubleshooting.
- GitHub workflows that check for a new upstream release on a schedule, update
  the pinned version and hashes, build the package, run a NixOS VM test that
  starts the service and gets 200 from `/__admin/health`, and open a PR when
  everything passes.

## Affected users and systems

- New repo only. No change to `~/.config/nixos` or any host.
- Users of NixOS on x86_64 and aarch64 who want a local AWS API endpoint.
- GitHub Actions on the new repo (free public-repo runners).

## Constraints

- Must repackage the upstream signed `.deb`, not build from source (disk and
  time on CI). Must keep the upstream licence (CC0) and ship
  `THIRD_PARTY_LICENSES`.
- Must verify the AWS GPG signature in the update workflow before taking a
  new hash.
- Must not enable telemetry silently: the module should expose it and the
  README must say the upstream default is on.
- Must not open the firewall or bind to non-loopback by default.
- Linux only (upstream binaries are Linux only).
- No secrets in the repo; workflows use only `GITHUB_TOKEN`.

## Open questions

1. Telemetry default in the module: keep upstream `on`, or default to `off`?
   (Proposal: `off`, documented.)
2. Auth default: upstream `on` writes per-run keys to the service's home.
   Keep `on`? (Proposal: keep `on`, document where the keys land.)
3. Because only `latest` is downloadable, should the workflow also cache each
   pinned `.deb` (for example as a GitHub release asset in this repo) so old
   pins stay buildable? (Proposal: yes, attach the `.deb` files to a release
   per version.)
4. Is aarch64-linux in scope for the CI VM test, or only for the package
   build? (Proposal: build-check the aarch64 hash only; VM test on x86_64.)
5. Should the update workflow auto-merge a green PR, or wait for you?
   (Proposal: open the PR and wait.)
