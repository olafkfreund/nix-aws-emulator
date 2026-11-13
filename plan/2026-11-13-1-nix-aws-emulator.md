---
status: draft
issue: 1
spec: spec/2026-11-13-1-nix-aws-emulator.md
coders:
  1: coder   # package + sources + key: moderate, needs nix builds to iterate
  2: coder   # flake wiring depends on step 1's file shapes
  3: coder   # small runCommand test, same agent keeps cache warm
  4: codex   # updater: small but tricky (gpg status parsing, races, fail-closed)
  5: codex   # NixOS module: tricky probe-address mapping, group logic, ExecStartPost
  6: coder   # Home Manager module mirrors step 5's options
  7: coder   # VM test, iterates with nix build
  8: agy     # two workflow files: large, mostly mechanical YAML
  9: agy     # README: large prose doc from the spec
reviewers:
  - codex    # independent read of the final diff against this plan
  - agy      # second independent read; disagreement is the signal
---

# Plan: Install and configure AWS Emulator on NixOS

## Summary of approved decisions (self-contained)

Repo `olafkfreund/nix-aws-emulator`, branch `feat/1-nix-package-module`,
issue #1. Repackage AWS's signed `.deb` (no source build). Telemetry off by
default everywhere. NixOS system service (group-readable key files) plus Home
Manager user service. No re-hosting of `.deb` files; `main` pins the current
upstream release via the mutable `latest` URL plus SRI hash. Real licences
in `meta.license`, not `unfree`. arm64 tested natively; VM test on x86_64.
Update PRs wait for the owner. Repo code is MIT.

Upstream facts (v1.0.342):

- URLs: `https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/latest/aws-emulator_amd64.deb`
  and `..._arm64.deb`; signature at the same URL plus `.sig`.
- amd64 `.deb` sha256 (hex) `9d7238ca2505c010e6c1a9abad6bc5d8e88c56bf63b73da05dd6c0d83a4dcff8`.
- `.deb` content: `opt/aws-emulator/bin/aws-emulator` (stripped PIE, needs
  libc/libm/libpthread/libdl only) and `opt/aws-emulator/THIRD_PARTY_LICENSES`.
- Signing key: `https://downloads.aws.com/keys/gpg/current.asc`, primary
  fingerprint `98BCF336A3BE53B734E967C52E5BF49BD940F624`, signs with primary
  key. Control `Version: 1.0.342-1`.
- CLI: `-b <ip>` (default 127.0.0.1), `-p <port>` (default 9297), `-t on|off`
  (disable-only), `-a on|off` (default on), `--idle-timeout <s>`, `-v`.
- Health: `GET https://<addr>:<port>/__admin/health` -> 200 in ~2 s.
- Writes to `$HOME/.aws/emulator/<port>/`: `config`, `ca.pem`,
  `truststore.p12`, and `emulator_credentials` only when auth is on. Files
  `0600`, dir `0700`, regardless of umask. No private keys in them. Deleted
  on clean stop.
- `EMULATOR_TELEMETRY`: `off|false|0` disables and wins over everything;
  `on|true|1` enables; other values fail safe to disabled. Startup log says
  `telemetry: disabled` when off.
- Idle RSS ~290 MB. Embeds RustPython (so no `MemoryDenyWriteExecute`).

## Execution waves

Steps in one wave touch different files and run in parallel.

- **Wave 1:** step 1 (coder), step 4 (codex), step 9 (agy).
- **Wave 2:** step 2, then 3, 6, 7 (coder, same agent in sequence); step 5
  (codex); step 8 (agy).
- **Wave 3:** step 10 (Claude: integrate, run checks, fix, commit, push, PR).

Implementers never stage, commit, push, or switch branches. Claude commits
each step as it lands, citing the step.

## Steps

1. **`pkgs/aws-emulator/package.nix`, `pkgs/aws-emulator/sources.json`,
   `keys/aws-publishing.asc`** (new).
   - `keys/aws-publishing.asc`: download `current.asc`; check its primary
     fingerprint equals the constant above before saving.
   - `sources.json`: `{ version, signer, "x86_64-linux": {url, hash, sigHash},
     "aarch64-linux": {url, hash, sigHash} }`; SRI hashes from
     `nix hash file --sri` of `.deb` files you verified with `gpgv` against
     the pinned key.
   - `package.nix`: `{ lib, stdenv, fetchurl, dpkg, autoPatchelfHook,
     makeWrapper }`; read `sources.json` with `lib.importJSON`; `src =
     fetchurl { inherit (sources.${system}) url hash; }`, `throw` on other
     systems; `nativeBuildInputs = [ dpkg autoPatchelfHook makeWrapper ]`;
     `runtimeDependencies = [ stdenv.cc.cc.lib ]`; `dontStrip = true`;
     `dontConfigure`/`dontBuild`; install binary to
     `$out/libexec/aws-emulator/aws-emulator`, licences to
     `$out/share/doc/aws-emulator/THIRD_PARTY_LICENSES`; `makeWrapper ...
     $out/bin/aws-emulator --set-default EMULATOR_TELEMETRY off`.
   - `meta`: description, homepage, changelog
     (`https://github.com/aws/aws-emulator/releases/tag/v${version}`),
     `mainProgram`, platforms `[ "x86_64-linux" "aarch64-linux" ]`,
     `sourceProvenance = [ lib.sourceTypes.binaryNativeCode ]`,
     `license = with lib.licenses; [ cc0 mit asl20 bsd0 bsd2 bsd3 isc zlib
     unicode-30 boost unlicense mit0 lgpl3Only ]`.
   - Verify: `nix build --impure --expr 'with import <nixpkgs> {};
     callPackage ./pkgs/aws-emulator/package.nix {}'` then
     `./result/bin/aws-emulator -v` prints `1.0.342`.
   - Traps: `unicode-30` is the correct attr name (`unicode30` doesn't
     exist). The dpkg setup hook unpacks `.deb` into the source root: set
     `sourceRoot = "."` or check where it lands. Don't strip. Don't hash
     anything you didn't verify.

2. **`flake.nix`, `flake.lock`, `LICENSE`** (new).
   - Inputs: `nixpkgs` = `github:NixOS/nixpkgs/nixos-unstable`;
     `home-manager` = `github:nix-community/home-manager` with
     `inputs.nixpkgs.follows = "nixpkgs"`.
   - `systems = [ "x86_64-linux" "aarch64-linux" ]`, `forAllSystems` with
     `nixpkgs.lib.genAttrs`; no flake-utils.
   - Outputs: `overlays.default = final: prev: { aws-emulator =
     final.callPackage ./pkgs/aws-emulator/package.nix { }; }`;
     `packages.<sys>.{aws-emulator,default}`; `apps.<sys>.default` (type
     app, program `${pkg}/bin/aws-emulator`, `meta.description`);
     `nixosModules.{aws-emulator,default} = ./modules/nixos.nix`;
     `homeManagerModules.{aws-emulator,default} = ./modules/home-manager.nix`;
     `formatter.<sys> = pkgs.nixfmt-rfc-style`;
     `checks.<sys>.smoke = import ./tests/smoke.nix { ... }`,
     `checks.<sys>.format` = `runCommand` running `nixfmt --check` on every
     `.nix` file under `self`; `checks.x86_64-linux.nixos = import
     ./tests/nixos.nix { inherit pkgs self home-manager; }`.
   - `LICENSE`: MIT, "Copyright (c) 2026 olafkfreund", covering this repo's
     code only.
   - Verify: `nix flake show` and `nix flake check --no-build` succeed
     (create stub files for 5-7 only if needed to evaluate, and say so).
   - Traps: `formatter` alone doesn't check formatting. Modules must not
     need `self` for their package default (step 5 uses `pkgs.aws-emulator
     or callPackage`).

3. **`tests/smoke.nix`** (new). `{ pkgs, package }: pkgs.runCommand
   "aws-emulator-smoke" { nativeBuildInputs = [ package pkgs.curl ]; } ''...''`:
   `aws-emulator -v | grep -F "${package.version}"`; `export HOME=$TMPDIR`;
   start `aws-emulator -b 127.0.0.1 -p 19297 > log 2>&1 &`; `trap 'kill $pid'
   EXIT`; poll `curl -sk -o /dev/null -w '%{http_code}'
   https://127.0.0.1:19297/__admin/health` up to 30 s for 200; `grep -q
   'telemetry: disabled' log`; `touch $out`.
   - Verify: `nix build -L .#checks.x86_64-linux.smoke`.
   - Traps: use `127.0.0.1`, not `localhost`; the trap must kill the child or
     the build hangs.

4. **`scripts/update.sh`** (new, executable, `#!/usr/bin/env bash`,
   `set -euo pipefail`). Needs `curl jq gpg gpgv dpkg-deb nix`.
   - Latest tag: `curl -fsSL https://api.github.com/repos/aws/aws-emulator/releases/latest | jq -r .tag_name`
     (use `Authorization: Bearer $GITHUB_TOKEN` when set); strip `v`.
   - If equal to `jq -r .version pkgs/aws-emulator/sources.json`: print
     `up to date: <v>`, exit 0.
   - `tmp=$(mktemp -d)`, `trap 'rm -rf "$tmp"' EXIT`. For `amd64` ->
     `x86_64-linux`, `arm64` -> `aarch64-linux`: download `.deb` and `.sig`.
   - `gpg --homedir "$tmp/gnupg" --dearmor < keys/aws-publishing.asc >
     "$tmp/aws.gpg"`; `gpgv --homedir "$tmp/gnupg" --keyring "$tmp/aws.gpg"
     --status-fd 3 <sig> <deb> 3>"$tmp/status"`; require a `[GNUPG:]
     VALIDSIG` line whose **last field** (primary-key fingerprint) equals
     `PINNED_FPR`. Any failure: message and exit 1.
   - `dpkg-deb -f <deb> Version` must match `^${tag}(-[0-9]+)?$`.
   - `nix hash file --sri` for `.deb` and `.sig`; `nix store add-file <deb>`;
     write new `sources.json` atomically with `jq` (keep `url`s, update
     `version`, `signer`, `hash`, `sigHash`).
   - Print `updated: <old> -> <new>`; if `$GITHUB_OUTPUT` is set, append
     `changed=true`, `old_version=`, `version=`.
   - Verify: `bash scripts/update.sh` prints `up to date: 1.0.342`; then set
     `version` to `0.0.0` in a scratch copy and run it: hashes written equal
     step 1's. `shellcheck scripts/update.sh` clean.
   - Traps: `VALIDSIG`'s first field is the signing (sub)key; use the last
     field. Never use the host keyring. Download each file once; hash those
     exact bytes. `nix store add-file` stores by name: name the file
     `aws-emulator_<arch>.deb` so `fetchurl` hits the same store path (check;
     if it doesn't, drop that step and accept the re-download).

5. **`modules/nixos.nix`** (new). `{ config, lib, pkgs, ... }`.
   - Options under `services.aws-emulator` as in the summary:
     `enable` (`mkEnableOption`), `package` (default
     `pkgs.aws-emulator or (pkgs.callPackage ../pkgs/aws-emulator/package.nix { })`,
     `defaultText`), `bindAddress` (str, `"127.0.0.1"`), `port`
     (`types.ints.between 1024 65535`, 9297), `telemetry` (bool, false),
     `auth` (bool, true), `idleTimeout` (`nullOr ints.positive`, null; doc:
     service exits 0 when idle and stays stopped), `extraArgs` (listOf str),
     `openFirewall` (bool, false), `group` (str, `"aws-emulator"`).
   - Config (`mkIf cfg.enable`): `users.users.aws-emulator = { isSystemUser =
     true; group = cfg.group; }`; `users.groups = mkIf (cfg.group ==
     "aws-emulator") { aws-emulator = { }; }`.
   - `probeHost`: `"0.0.0.0"` -> `"127.0.0.1"`; `"::"` -> `"[::1]"`; contains
     `:` -> `"[${addr}]"`; else as is.
   - `systemd.services.aws-emulator`: `wantedBy = [ "multi-user.target" ]`,
     `after = [ "network.target" ]`; `environment = { HOME =
     "/run/aws-emulator"; EMULATOR_TELEMETRY = if cfg.telemetry then "on"
     else "off"; }`; `serviceConfig`: `Type = "exec"`, `User =
     "aws-emulator"`, `Group = cfg.group`, `ExecStart` = escaped args
     (`lib.escapeShellArgs`), `ExecStartPost` = a `writeShellScript` (uses
     `${pkgs.curl}`) that loops 30 s for health 200 **and**
     `/run/aws-emulator/.aws/emulator/${port}/config` to exist, then `chmod
     -R g+rX /run/aws-emulator/.aws`; exit 1 on timeout. `Restart =
     "on-failure"`, `RuntimeDirectory = "aws-emulator"`,
     `RuntimeDirectoryMode = "0750"`, `UMask = "0027"`, and the hardening
     list: `NoNewPrivileges ProtectSystem=strict ProtectHome PrivateTmp
     PrivateDevices ProtectKernelTunables ProtectKernelModules
     ProtectKernelLogs ProtectControlGroups ProtectClock ProtectHostname
     RestrictAddressFamilies=[AF_INET AF_INET6 AF_UNIX AF_NETLINK]
     RestrictNamespaces RestrictRealtime RestrictSUIDSGID LockPersonality
     SystemCallArchitectures=native CapabilityBoundingSet=""`.
   - `networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ]`.
   - `warnings`: non-loopback bind (`!(elem bindAddress ["127.0.0.1" "::1"
     "localhost"])`); non-loopback with `auth = false`; `openFirewall` with
     loopback bind.
   - No `environment.systemPackages`.
   - Verify: `nix eval` of a minimal `nixosSystem` with the module enabled
     builds `config.systemd.units."aws-emulator.service".unit`; full test in
     step 7.
   - Traps: `ExecStartPost` must not use the `+` prefix. Not `DynamicUser`.
     No `MemoryDenyWriteExecute`. Bracket IPv6 in the probe URL.

6. **`modules/home-manager.nix`** (new). Same options as step 5 minus
   `openFirewall` and `group`. `config = mkIf cfg.enable`:
   `assertions` Linux only (`pkgs.stdenv.hostPlatform.isLinux`);
   `home.packages = [ cfg.package ]`;
   `systemd.user.services.aws-emulator = { Unit.Description = ...;
   Service = { ExecStart = ...; Environment = [ "EMULATOR_TELEMETRY=on|off" ];
   Restart = "on-failure"; }; Install.WantedBy = [ "default.target" ]; }`.
   No `AWS_CONFIG_FILE` session variables.
   - Verify: evaluated by step 7's VM test.
   - Traps: HM `Environment` is a list of `"K=V"` strings; without
     `WantedBy` the unit never starts under lingering.

7. **`tests/nixos.nix`** (new). `{ pkgs, self, home-manager }:
   pkgs.testers.runNixOSTest { name = "aws-emulator"; nodes.machine = ...;
   testScript = ...; }`.
   - Node: `imports = [ self.nixosModules.default
     home-manager.nixosModules.home-manager ]`;
     `nixpkgs.overlays = [ self.overlays.default ]`;
     `virtualisation.memorySize = 2048`;
     `services.aws-emulator.enable = true`; users `alice` (normal,
     `extraGroups = [ "aws-emulator" ]`), `carol` (normal), `bob` (normal,
     `linger = true`); `home-manager.users.bob = { imports = [
     self.homeManagerModules.default ]; services.aws-emulator = { enable =
     true; port = 9298; }; home.stateVersion = "25.11"; }`;
     `environment.systemPackages = [ pkgs.awscli2 pkgs.curl ]`.
   - Script: `machine.wait_for_unit("aws-emulator.service")`; health 200 on
     9297 via curl -sk; as alice (`su - alice -c ...`) with
     `AWS_CONFIG_FILE=/run/aws-emulator/.aws/emulator/9297/config` and
     `AWS_SHARED_CREDENTIALS_FILE=.../emulator_credentials`: `aws s3 mb
     s3://emulator-test` and `aws s3 ls | grep emulator-test`;
     `machine.fail("su - carol -c 'cat .../emulator_credentials'")`;
     `machine.succeed("journalctl -u aws-emulator | grep -q 'telemetry:
     disabled'")`; `machine.wait_for_unit("user@<bob uid>.service")` (look
     up uid with `id -u bob`); `machine.wait_until_succeeds("systemctl
     --machine=bob@ --user is-active aws-emulator")`; health 200 on 9298;
     `systemctl --machine=bob@ --user stop aws-emulator`, then
     `machine.fail("test -e /home/bob/.aws/emulator/9298")`.
   - Verify: `nix build -L .#checks.x86_64-linux.nixos` passes.
   - Traps: needs KVM locally (it's available on this host). If S3 calls
     fail on TLS, set `AWS_CA_BUNDLE` to `ca.pem` explicitly; the `config`
     file already sets `ca_bundle`.

8. **`.github/workflows/ci.yml`, `.github/workflows/update.yml`** (new).
   Pin every action by full commit SHA with the tag as a comment:
   `actions/checkout` v7.0.1, `cachix/install-nix-action` v31.11.5,
   `actions/upload-artifact` v7.0.2, `actions/download-artifact` v8.0.2,
   `peter-evans/create-pull-request` v8.1.3 (look up SHAs with
   `gh api repos/<o>/<r>/git/ref/tags/<tag>`, dereferencing annotated tags).
   - KVM block (before install-nix): `echo 'KERNEL=="kvm", GROUP="kvm",
     MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee
     /etc/udev/rules.d/99-kvm4all.rules`, `sudo udevadm control
     --reload-rules`, `sudo udevadm trigger --name-match=kvm`, then `test -r
     /dev/kvm -a -w /dev/kvm`.
   - install-nix `extra_nix_config: system-features = nixos-test benchmark
     big-parallel kvm`.
   - `ci.yml`: on `push` (main), `pull_request`, `workflow_dispatch`;
     `permissions: contents: read`; `concurrency` per ref, cancel in
     progress. Job `x86_64` (`ubuntu-latest`): checkout, KVM, nix, `nix flake
     check -L`. Job `aarch64` (`ubuntu-24.04-arm`): checkout, nix, `nix
     build -L .#checks.aarch64-linux.smoke .#checks.aarch64-linux.format`.
   - `update.yml`: `schedule: cron "17 6 * * *"`, `workflow_dispatch`;
     workflow `permissions: contents: read`. Job `update` (ubuntu-latest):
     checkout; nix; get latest tag; if `gh pr list --head
     update/aws-emulator --state open --json title` already contains it,
     stop with `changed=false`; else run `scripts/update.sh` (passes
     `GITHUB_TOKEN`), and if changed: KVM, `nix flake check -L`, upload
     `pkgs/aws-emulator/sources.json` artifact. Outputs `changed`,
     `old_version`, `version`. Job `arm` (needs update, if changed,
     `ubuntu-24.04-arm`): checkout, download artifact into
     `pkgs/aws-emulator/`, nix, `nix build -L .#checks.aarch64-linux.smoke`.
     Job `pr` (needs both, if changed; `permissions: contents: write,
     pull-requests: write`): checkout, download artifact, create-pull-request
     with `branch: update/aws-emulator`, `title: "aws-emulator: <old> ->
     <new>"`, `commit-message` same, body linking
     `https://github.com/aws/aws-emulator/releases/tag/v<new>` and the run
     URL, `delete-branch: true`.
   - Verify: `nix run nixpkgs#actionlint` clean on both files.
   - Traps: KVM rule before Nix is installed. `pull-requests: read` is
     needed in the `update` job for `gh pr list` (add it there, still no
     write). Artifacts must be downloaded into the right path in both later
     jobs.

9. **`README.md`** (new). Sections in this order, with copy-paste blocks:
   title + CI badges (`ci.yml`, `update.yml`); what it is (one paragraph,
   link upstream and AWS docs, "not for production"); quick try (`nix run
   github:olafkfreund/nix-aws-emulator`); add as flake input (`inputs` +
   `nixosModules.default`, optional `overlays.default`, `home-manager.follows`
   note); NixOS module example and option table (from step 5); using it from
   the AWS CLI and SDKs (`users.users.<you>.extraGroups`, env vars
   `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE`, a shell function
   `awsemu() { AWS_CONFIG_FILE=... AWS_SHARED_CREDENTIALS_FILE=... aws "$@"; }`,
   Java truststore path); Home Manager module example (keys under
   `~/.aws/emulator/<port>/`); `nix profile install`; telemetry (off here,
   upstream default on, `EMULATOR_TELEMETRY=on` / `telemetry = true` to opt
   in); auth and where keys live, regenerated every start; network binding,
   firewall, warnings, never add `ca.pem` to system trust; relaxing
   hardening via `systemd.services.aws-emulator.serviceConfig`; updates (daily
   workflow, signature check with fingerprint, the hash-mismatch window when
   upstream moves `latest`); licences (repo MIT; binary CC0 + third-party,
   LGPL-3.0-only `malachite-*`, undeclared `mt19937`, `rustpython-doc`,
   `rustpython-pylib`, `syn-ext`; `THIRD_PARTY_LICENSES` path in the
   package); troubleshooting (port in use, `journalctl -u aws-emulator`,
   health curl, permission denied before unit active); development (`nix
   flake check`, `nix fmt`, `scripts/update.sh`).
   - Verify: every command block is checked in step 10.
   - Traps: don't promise features not in steps 1-8; the option table must
     match step 5 exactly.

10. **Integrate and ship** (Claude).
    - Commit each step as it lands (`feat: <step> (#1)`), citing the step.
    - `nix fmt`; `nix flake check -L` locally (x86_64, KVM); fix and record
      any deviation in this plan in the same commit.
    - `bash scripts/update.sh` prints up to date.
    - Repo setting: `gh api -X PUT
      repos/olafkfreund/nix-aws-emulator/actions/permissions/workflow -f
      default_workflow_permissions=read -F
      can_approve_pull_request_reviews=true`.
    - Push; open PR to `main` linking intent, spec and plan, listing which
      steps each coder did; wait for `ci.yml` green on both jobs.
    - Opus review (fresh agent, plan path + `git diff main`), plus Codex and
      agy read-only reviews; fix confirmed findings.
    - After merge: run `update.yml` with `workflow_dispatch`; it must end
      "up to date".

## Tests

| Command | Expected |
|---|---|
| `nix flake check -L` (x86_64) | format, smoke, VM test pass |
| `nix build -L .#checks.aarch64-linux.smoke` (arm runner) | pass |
| `nix run . -- -v` | prints `Version: 1.0.342` |
| `bash scripts/update.sh` | `up to date: 1.0.342` |
| `nix run nixpkgs#actionlint` | no findings |
| CI on the PR | both jobs green |
| `update.yml` dispatch on `main` | "up to date", no PR |

## Rollback

All changes are in the new repo. Before merge: close the PR and delete the
branch. After merge: `git revert` the merge commit, or archive the repo with
`gh repo archive olafkfreund/nix-aws-emulator`. No host or `~/.config/nixos`
change to undo.
