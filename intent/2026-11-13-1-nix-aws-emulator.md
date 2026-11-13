---
status: approved
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
NixOS user has no maintained way to install it declaratively, run it as a
service or keep a pinned version buildable.

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
- The bundled `THIRD_PARTY_LICENSES` lists about 1,500 crates. Most are
  MIT/Apache/BSD, but 4 are `LGPL-3.0-only` and 4 have "no declared
  license". The binary is statically linked Rust.
- The arm64 `.deb` and the `.sig` files exist (HTTP 200); arm64 contents not
  yet inspected.
- Because the flake must pin a hash, the `latest` URL breaks every fresh
  build of `main` as soon as upstream publishes a new release, until the pin
  is updated.

## Proposed outcome

- A public repo `olafkfreund/nix-aws-emulator` (created, issue #1) with a flake that exposes
  `packages.<system>.aws-emulator` (x86_64-linux and aarch64-linux),
  `overlays.default`, and `nixosModules.default`.
- `nix run github:olafkfreund/nix-aws-emulator` starts the emulator, with
  the same telemetry choice as the module (see open question 1).
- `main` always pins the current upstream release, kept fresh by CI, with
  evidence linking each file to its signature. Whether older pins stay
  buildable depends on open question 3.
- `services.aws-emulator.enable = true;` runs it as a hardened systemd
  service with options for bind address, port, telemetry, auth, idle timeout,
  extra arguments and opening the firewall.
- A README that explains install (flake input, NixOS module, Home Manager or
  `nix profile`), configuration, pointing the AWS CLI/SDK at it, and
  troubleshooting.
- GitHub workflows that check for a new upstream release on a schedule, update
  the pinned version and hashes, build the package, run a NixOS VM test that
  starts the service and gets 200 from `/__admin/health`, build and smoke-test
  aarch64 on a native arm runner, and open a PR when everything passes.

## Affected users and systems

- New repo only. No change to `~/.config/nixos` or any host.
- Users of NixOS on x86_64 and aarch64 who want a local AWS API endpoint.
- GitHub Actions on the new repo (free public-repo runners).

## Constraints

- Must repackage the upstream signed `.deb`, not build from source (disk and
  time on CI). Must keep the upstream licence (CC0) and ship
  `THIRD_PARTY_LICENSES`.
- Must verify the AWS GPG signature in the update workflow before taking a
  new hash, against a key fingerprint pinned in the repo, failing closed. The
  hashed (and any cached) bytes must be the same bytes that were verified.
- Must not enable telemetry silently, on any entry point (`nix run`,
  package, module).
- Must not open the firewall or bind to non-loopback by default.
- Linux only (upstream binaries are Linux only).
- No secrets in the repo. Note: a PR opened with `GITHUB_TOKEN` does not
  trigger `pull_request` workflows, so the update workflow must test before
  opening the PR (or a PAT/App token is needed).
- Package metadata must declare `sourceProvenance = binaryNativeCode`.

## Open questions

1. Telemetry: default `off` for both the module and `nix run` (wrapper passes
   `-t off`), with an option to turn it on? (Proposal: yes.)
2. Service model: a hardened system service cannot easily share its per-run
   auth keys (written under its own home, regenerated each restart) with
   normal users. Options: (a) system service with auth `off` on loopback by
   default; (b) system service with a group-readable state dir; (c) a Home
   Manager user service where keys land in the user's own
   `~/.aws/emulator/<port>/`. (Proposal: ship the NixOS module with (b) and a
   `users`/group option, plus a Home Manager module with (c).)
3. Licence and redistribution: is it acceptable to re-host the `.deb` files
   as GitHub release assets in this repo, given the LGPL-3.0-only and
   undeclared-licence crates and unknown `downloads.aws.com` terms? If not,
   old pins become unbuildable once `latest` moves. (Proposal: do not re-host
   by default; fetch from `latest`, let the update workflow keep `main`
   current, and document that only the current version is guaranteed.
   Revisit after a licence check.)
4. `meta.license`: mark as `cc0` plus `unfreeRedistributable`-free licences
   as listed, or mark `unfree` to be safe? (Proposal: list `cc0`, `mit`,
   `asl20`, `lgpl3Only` and others found; not `unfree`.)
5. aarch64: native build plus binary health smoke test on `ubuntu-24.04-arm`,
   VM test on x86_64 only? (Proposal: yes.)
6. Auto-merge: open the PR and wait for you? (Proposal: wait.)

## Decisions (approved 2026-11-13)

The owner approved every proposal above: telemetry off by default everywhere;
NixOS system service with a group-readable state dir plus a Home Manager user
service; no re-hosting of `.deb` files, `main` tracks the latest release;
`meta.license` lists the real licences, not `unfree`; native arm64 build and
smoke test, VM test on x86_64; update PRs wait for owner review.
