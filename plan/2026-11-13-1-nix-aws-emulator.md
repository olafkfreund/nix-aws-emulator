---
status: approved
issue: 1
spec: spec/2026-11-13-1-nix-aws-emulator.md
coders:
  1: coder   # package + sources + key: needs nix builds to iterate
  2: coder   # flake wiring needs step 1's file shapes; same agent keeps cache warm
  3: coder   # small runCommand test, same agent
  4: codex   # updater: small but tricky (gpg status parsing, races, fail-closed)
  5: codex   # NixOS module: probe-address mapping, group logic, ExecStartPost
  6: codex   # HM module must mirror step 5's options exactly; same agent
  7: coder   # VM test, iterates with nix build once 2, 5, 6 exist
  8: agy     # two workflow files: large YAML; action SHAs are pre-pinned below
  9: agy     # README: large prose doc, written after modules and workflows exist
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
upstream release via the mutable `latest` URL plus SRI hash, with the
signature hash and signer fingerprint committed as evidence. Real licences in
`meta.license`, not `unfree`. arm64 tested natively; VM test on x86_64.
Update PRs wait for the owner. Repo code is MIT. No branch protection
required checks (Actions-opened PRs don't trigger `ci.yml`).

Upstream facts (v1.0.342):

- URLs: `https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/latest/aws-emulator_amd64.deb`
  and `..._arm64.deb`; signature at the same URL plus `.sig`.
- amd64 `.deb` sha256 (hex) `9d7238ca2505c010e6c1a9abad6bc5d8e88c56bf63b73da05dd6c0d83a4dcff8`.
- `.deb` content: `opt/aws-emulator/bin/aws-emulator` (stripped PIE, needs
  libc/libm/libpthread/libdl only) and `opt/aws-emulator/THIRD_PARTY_LICENSES`.
- Signing key: `https://downloads.aws.com/keys/gpg/current.asc`, primary
  fingerprint `98BCF336A3BE53B734E967C52E5BF49BD940F624`, signs with the
  primary key. Control `Version: 1.0.342-1`.
- CLI: `-b <ip>` (default 127.0.0.1), `-p <port>` (default 9297), `-t on|off`
  (disable-only), `-a on|off` (default on), `--idle-timeout <s>`. `-v` prints
  `Version: 1.0.342` (plus release date and commit lines).
- Health: `GET https://<addr>:<port>/__admin/health` -> 200 in ~2 s.
- Writes to `$HOME/.aws/emulator/<port>/`: `config` (has `endpoint_url` and
  `ca_bundle`), `ca.pem`, `truststore.p12`, and `emulator_credentials` only
  when auth is on. Files `0600`, dir `0700`, regardless of umask. No private
  keys in them. Deleted on clean stop.
- `EMULATOR_TELEMETRY`: `off|false|0` disables and wins over everything;
  `on|true|1` enables; other values fail safe to disabled. Startup log
  contains `telemetry: disabled` when off.
- Idle RSS ~290 MB. Embeds RustPython (so no `MemoryDenyWriteExecute`).
- nixpkgs (unstable): the `dpkg` setup hook unpacks a `.deb` into `root/` and
  that becomes the source root automatically. `pkgs.nixfmt` is the formatter
  (`nixfmt-rfc-style` is a deprecated alias). `lib.licenses` has `unicode-30`,
  `psfl`, `bzip2`, `blueOak100`; it has no CDLA-Permissive-2.0 entry.

## Execution waves

Steps in one wave touch different files and run in parallel. A step starts
only when every file it reads exists.

- **Wave 1:** step 1 (coder); steps 5 then 6 (codex); step 8 (agy).
- **Wave 2:** step 4 (codex, needs step 1); steps 2, 3, 7 in order (coder,
  needs 1, 5, 6); step 9 (agy, needs 5, 6, 8).
- **Wave 3:** step 10 (Claude: integrate, run checks, fix, commit, push, PR).

Implementers never stage, commit, push or switch branches. Claude commits
each step as it lands (`feat(<area>): ... (#1)`, citing the step).

## Steps

1. **`pkgs/aws-emulator/package.nix`, `pkgs/aws-emulator/sources.json`,
   `keys/aws-publishing.asc`** (new).
   - `keys/aws-publishing.asc`: download `current.asc`; check its primary
     fingerprint equals the constant above before saving.
   - `sources.json`:
     ```json
     { "version": "1.0.342",
       "signer": "98BCF336A3BE53B734E967C52E5BF49BD940F624",
       "x86_64-linux":  { "url": "<amd64 url>", "hash": "sha256-...", "sigHash": "sha256-..." },
       "aarch64-linux": { "url": "<arm64 url>", "hash": "sha256-...", "sigHash": "sha256-..." } }
     ```
     Hashes from `nix hash file --sri` of `.deb` and `.sig` files you first
     verified with `gpgv` against the pinned key.
   - `package.nix`:
     ```nix
     { lib, stdenv, fetchurl, dpkg, autoPatchelfHook, makeWrapper }:
     let
       sources = lib.importJSON ./sources.json;
       system = stdenv.hostPlatform.system;
       src = sources.${system} or (throw "aws-emulator: unsupported system ${system}");
     in stdenv.mkDerivation { pname = "aws-emulator"; version = sources.version; ... }
     ```
     `src = fetchurl { inherit (src) url hash; }`;
     `nativeBuildInputs = [ dpkg autoPatchelfHook makeWrapper ]`;
     `runtimeDependencies = [ stdenv.cc.cc.lib ]`; `dontStrip = true`;
     `dontConfigure = true`; `dontBuild = true`; do **not** set `sourceRoot`
     (the hook's `root/` is used). `installPhase`: `install -Dm755
     opt/aws-emulator/bin/aws-emulator $out/libexec/aws-emulator/aws-emulator`;
     `install -Dm644 opt/aws-emulator/THIRD_PARTY_LICENSES
     $out/share/doc/aws-emulator/THIRD_PARTY_LICENSES`; `makeWrapper
     $out/libexec/aws-emulator/aws-emulator $out/bin/aws-emulator
     --set-default EMULATOR_TELEMETRY off`.
   - `passthru.updateScript = ../../scripts/update.sh;`
   - `meta`: `description`, `homepage = "https://github.com/aws/aws-emulator"`,
     `changelog = ".../releases/tag/v${version}"`, `mainProgram =
     "aws-emulator"`, `platforms = [ "x86_64-linux" "aarch64-linux" ]`,
     `sourceProvenance = [ lib.sourceTypes.binaryNativeCode ]`,
     `license = with lib.licenses; [ cc0 mit asl20 bsd0 bsd2 bsd3 isc zlib
     unicode-30 boost unlicense mit0 lgpl3Only psfl bzip2 blueOak100 ]`.
   - Verify: `nix build --impure --expr '(import (builtins.getFlake
     "nixpkgs") {}).callPackage ./pkgs/aws-emulator/package.nix {}'`, then
     `./result/bin/aws-emulator -v | grep -F "Version: 1.0.342"`.
   - Traps: `unicode-30` is correct (`unicode30` doesn't exist). Don't
     strip. Don't hash anything you didn't verify. `scripts/update.sh` won't
     exist yet in wave 1; the `passthru` path is still fine (only read when
     the script is run).

2. **`flake.nix`, `flake.lock`, `LICENSE`** (new).
   - Inputs: `nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable"`;
     `home-manager = { url = "github:nix-community/home-manager";
     inputs.nixpkgs.follows = "nixpkgs"; }`.
   - `systems = [ "x86_64-linux" "aarch64-linux" ]`;
     `forAllSystems = f: lib.genAttrs systems (system: f
     nixpkgs.legacyPackages.${system})`. No flake-utils.
   - Outputs:
     - `overlays.default = final: prev: { aws-emulator =
       final.callPackage ./pkgs/aws-emulator/package.nix { }; }`
     - `packages = forAllSystems (pkgs: rec { aws-emulator =
       pkgs.callPackage ./pkgs/aws-emulator/package.nix { }; default =
       aws-emulator; })`
     - `apps = forAllSystems (pkgs: { default = { type = "app"; program =
       lib.getExe self.packages.${pkgs.system}.default; meta.description =
       "Run AWS Emulator"; }; })`
     - `nixosModules = { aws-emulator = ./modules/nixos.nix; default =
       self.nixosModules.aws-emulator; }`; same shape for
       `homeManagerModules` with `./modules/home-manager.nix`.
     - `formatter = forAllSystems (pkgs: pkgs.nixfmt)`
     - `checks = forAllSystems (pkgs: { smoke = import ./tests/smoke.nix {
       inherit pkgs; package = self.packages.${pkgs.system}.default; };
       format = pkgs.runCommand "format-check" { nativeBuildInputs = [
       pkgs.nixfmt pkgs.findutils ]; } "cd ${self} && find . -name '*.nix'
       -exec nixfmt --check {} + && touch $out"; } //
       lib.optionalAttrs (pkgs.system == "x86_64-linux") { nixos = import
       ./tests/nixos.nix { inherit pkgs self home-manager; }; })`
   - `LICENSE`: MIT, "Copyright (c) 2026 olafkfreund", stating it covers this
     repo's code, not the AWS Emulator binary.
   - Verify: `nix flake show` and `nix flake check --no-build` succeed. (Runs
     after steps 3 and 7 exist; until then, evaluate only `packages` and
     `apps`.)
   - Traps: never define `checks.x86_64-linux.nixos` beside
     `checks = forAllSystems ...` (attribute collision); use the
     `optionalAttrs` merge above. Modules must not take `self` for their
     package default.

3. **`tests/smoke.nix`** (new).
   ```nix
   { pkgs, package }:
   pkgs.runCommand "aws-emulator-smoke" { nativeBuildInputs = [ package pkgs.curl ]; } ''
     aws-emulator -v | grep -F "Version: ${package.version}"
     export HOME=$TMPDIR
     aws-emulator -b 127.0.0.1 -p 19297 > log 2>&1 &
     pid=$!
     trap 'kill "$pid" 2>/dev/null || true' EXIT
     code=000
     for _ in $(seq 1 30); do
       code=$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:19297/__admin/health || true)
       [ "$code" = 200 ] && break
       sleep 1
     done
     [ "$code" = 200 ] || { cat log; exit 1; }
     grep -q 'telemetry: disabled' log
     touch $out
   ''
   ```
   - Verify: `nix build -L .#checks.x86_64-linux.smoke`.
   - Traps: `127.0.0.1`, not `localhost`. `|| true` on curl inside the loop
     (`set -e` is on).

4. **`scripts/update.sh`** (new, `chmod +x`, `#!/usr/bin/env bash`,
   `set -euo pipefail`). Runs from the repo root. Needs `curl jq gpg gpgv
   dpkg-deb nix` (document a `nix shell nixpkgs#{curl,jq,gnupg,dpkg}` line in
   a header comment).
   - `PINNED_FPR=98BCF336A3BE53B734E967C52E5BF49BD940F624`;
     `SRC=pkgs/aws-emulator/sources.json`; `out()` appends `k=v` to
     `$GITHUB_OUTPUT` when set.
   - Latest tag: `curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer
     $GITHUB_TOKEN"} https://api.github.com/repos/aws/aws-emulator/releases/latest
     | jq -r .tag_name`; `new=${tag#v}`; `old=$(jq -r .version "$SRC")`.
   - If `new == old`: `out changed=false; out version=$old`, print
     `up to date: $old`, exit 0.
   - `tmp=$(mktemp -d)`; `trap 'rm -rf "$tmp"' EXIT`; `mkdir -m 700
     "$tmp/gnupg"`; `gpg --batch --homedir "$tmp/gnupg" --dearmor <
     keys/aws-publishing.asc > "$tmp/aws.gpg"`.
   - For each pair `amd64:x86_64-linux arm64:aarch64-linux`: `url=$(jq -r
     ".\"$sys\".url" "$SRC")`; download to `"$tmp/aws-emulator_$arch.deb"`
     (exact name; it must equal the URL's basename so `nix store add-file`
     gives the same store path as `fetchurl`) and `.sig`.
   - Verify: `if ! gpgv --homedir "$tmp/gnupg" --keyring "$tmp/aws.gpg"
     --status-fd 3 "$sig" "$deb" 3>"$tmp/status-$arch" 2>/dev/null; then
     echo "BAD signature for $arch" >&2; exit 1; fi`; then require `awk -v
     f="$PINNED_FPR" '$1=="[GNUPG:]" && $2=="VALIDSIG" && NF>=12 && $NF==f
     {ok=1} END{exit !ok}' "$tmp/status-$arch"`.
   - Version: `v=$(dpkg-deb -f "$deb" Version)`; require `[[ "$v" == "$new"
     || "$v" =~ ^"$new"-[0-9]+$ ]]` (quoted `$new` is literal inside `=~`).
   - `hash=$(nix hash file --sri "$deb")`, `sigHash=$(nix hash file --sri
     "$sig")`; `nix store add-file "$deb" >/dev/null`.
   - Write `$SRC` via `jq` to `"$SRC.tmp"` then `mv`: set `version`,
     `signer`, and each system's `hash`/`sigHash`; keep `url`s.
   - Print `updated: $old -> $new`; `out changed=true; out old_version=$old;
     out version=$new`.
   - Verify: `bash scripts/update.sh` prints `up to date: 1.0.342`. Then in a
     scratch copy of the repo set `version` to `0.0.0` and run it: hashes
     equal step 1's, and `nix build .#default` needs no download.
     `nix run nixpkgs#shellcheck -- scripts/update.sh` clean.
   - Traps: use the **last** `VALIDSIG` field (primary key), not the first
     (signing subkey). Never touch the host keyring. Download each file once
     and hash those bytes. Don't drop `nix store add-file`; if its store
     path differs from `fetchurl`'s, stop and report.

5. **`modules/nixos.nix`** (new). `{ config, lib, pkgs, ... }:`, `cfg =
   config.services.aws-emulator`.
   - Options:
     - `enable = lib.mkEnableOption "AWS Emulator, a local emulator of the AWS APIs"`
     - `package = lib.mkOption { type = types.package; default =
       pkgs.aws-emulator or (pkgs.callPackage ../pkgs/aws-emulator/package.nix
       { }); defaultText = lib.literalExpression "pkgs.aws-emulator"; }`
     - `bindAddress` (`types.str`, `"127.0.0.1"`); `port`
       (`types.ints.between 1024 65535`, `9297`); `telemetry` (`types.bool`,
       `false`); `auth` (`types.bool`, `true`); `idleTimeout`
       (`types.nullOr types.ints.positive`, `null`; description: the service
       exits 0 after this many idle seconds and stays stopped);
       `extraArgs` (`types.listOf types.str`, `[ ]`); `openFirewall`
       (`types.bool`, `false`); `group` (`types.str`, `"aws-emulator"`).
       Every option has a description.
   - `args = [ "-b" cfg.bindAddress "-p" (toString cfg.port) "-a" (if
     cfg.auth then "on" else "off") ] ++ lib.optionals (cfg.idleTimeout !=
     null) [ "--idle-timeout" (toString cfg.idleTimeout) ] ++ cfg.extraArgs`.
     `-t` is not passed; `EMULATOR_TELEMETRY` controls it.
   - `isLoopback = lib.elem cfg.bindAddress [ "127.0.0.1" "::1" "localhost" ]`.
   - `probeHost`: `"0.0.0.0"` -> `"127.0.0.1"`; `"::"` -> `"[::1]"`;
     starts with `[` -> as is; contains `:` -> `"[${addr}]"`; else as is.
   - `portDir = "/run/aws-emulator/.aws/emulator/${toString cfg.port}"`.
   - `ready = pkgs.writeShellScript "aws-emulator-ready" ''for _ in $(seq 1
     30); do code=$(${lib.getExe pkgs.curl} -sk -o /dev/null -w
     '%{http_code}' https://${probeHost}:${toString
     cfg.port}/__admin/health || true); if [ "$code" = 200 ] && [ -e
     ${portDir}/config ]; then chmod -R g+rX /run/aws-emulator/.aws; exit 0;
     fi; sleep 1; done; echo "aws-emulator not healthy after 30 s" >&2; exit
     1''` (use `${pkgs.coreutils}/bin/` for `seq`, `sleep`, `chmod`).
   - Config (`lib.mkIf cfg.enable`):
     - `users.users.aws-emulator = { isSystemUser = true; group = cfg.group; }`;
       `users.groups = lib.mkIf (cfg.group == "aws-emulator") { aws-emulator = { }; }`.
     - `systemd.services.aws-emulator`: `description`; `wantedBy = [
       "multi-user.target" ]`; `after = [ "network.target" ]`; `environment
       = { HOME = "/run/aws-emulator"; EMULATOR_TELEMETRY = if cfg.telemetry
       then "on" else "off"; }`; `serviceConfig = { Type = "exec"; User =
       "aws-emulator"; Group = cfg.group; ExecStart = "${lib.getExe
       cfg.package} ${lib.escapeShellArgs args}"; ExecStartPost = "${ready}";
       Restart = "on-failure"; RuntimeDirectory = "aws-emulator";
       RuntimeDirectoryMode = "0750"; UMask = "0027"; NoNewPrivileges = true;
       ProtectSystem = "strict"; ProtectHome = true; PrivateTmp = true;
       PrivateDevices = true; ProtectKernelTunables = true;
       ProtectKernelModules = true; ProtectKernelLogs = true;
       ProtectControlGroups = true; ProtectClock = true; ProtectHostname =
       true; RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX"
       "AF_NETLINK" ]; RestrictNamespaces = true; RestrictRealtime = true;
       RestrictSUIDSGID = true; LockPersonality = true;
       SystemCallArchitectures = "native"; CapabilityBoundingSet = ""; }`.
     - `networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ]`.
     - `warnings` (three separate entries, each via `lib.optional`):
       not loopback and auth on: "listens on <addr>; anyone who can reach
       it and has the keys can use it"; not loopback and auth off: "listens
       on <addr> WITHOUT authentication; anyone who can reach the port can
       use it and exhaust memory"; `openFirewall` and loopback: "openFirewall
       has no effect while bindAddress is loopback".
     - No `environment.systemPackages`.
   - Verify: `nix build --impure --expr` of a minimal
     `(builtins.getFlake "nixpkgs").lib.nixosSystem { system =
     "x86_64-linux"; modules = [ ./modules/nixos.nix { services.aws-emulator.enable
     = true; boot.isContainer = true; system.stateVersion = "25.11"; } ]; }`
     `.config.systemd.units."aws-emulator.service".unit` succeeds; inspect
     the unit text. Full runtime test in step 7.
   - Traps: `toString` every integer in strings. `lib.getExe pkgs.curl`, not
     `${pkgs.curl}`. No `+` prefix on `ExecStartPost`. Not `DynamicUser`. No
     `MemoryDenyWriteExecute`.

6. **`modules/home-manager.nix`** (new). Same `enable`, `package` (same
   default and `defaultText`), `bindAddress`, `port`, `telemetry`, `auth`,
   `idleTimeout`, `extraArgs` options and the same `args` list as step 5;
   no `openFirewall` or `group`. `config = lib.mkIf cfg.enable`:
   - `assertions = [ { assertion = pkgs.stdenv.hostPlatform.isLinux;
     message = "services.aws-emulator is only supported on Linux"; } ]`
   - `home.packages = [ cfg.package ]`
   - `systemd.user.services.aws-emulator = { Unit.Description = "AWS
     Emulator"; Service = { ExecStart = "${lib.getExe cfg.package}
     ${lib.escapeShellArgs args}"; Environment = [ "EMULATOR_TELEMETRY=${if
     cfg.telemetry then "on" else "off"}" ]; Restart = "on-failure"; };
     Install.WantedBy = [ "default.target" ]; }`
   - No `AWS_CONFIG_FILE` session variables.
   - Verify: runtime test in step 7.
   - Traps: HM `Environment` is a list of `"K=V"` strings; without
     `WantedBy` the unit never starts under lingering.

7. **`tests/nixos.nix`** (new). `{ pkgs, self, home-manager }:
   pkgs.testers.runNixOSTest { name = "aws-emulator"; nodes.machine = ...;
   testScript = ...; }`.
   - Node: `imports = [ self.nixosModules.default
     home-manager.nixosModules.home-manager ]`;
     `nixpkgs.overlays = [ self.overlays.default ]`;
     `virtualisation.memorySize = 2048`; `services.aws-emulator.enable =
     true`; `users.users.alice = { isNormalUser = true; extraGroups = [
     "aws-emulator" ]; }`; `carol = { isNormalUser = true; }`; `bob = {
     isNormalUser = true; linger = true; }`; `home-manager.useGlobalPkgs =
     true`; `home-manager.useUserPackages = true`; `home-manager.users.bob =
     { imports = [ self.homeManagerModules.default ];
     services.aws-emulator = { enable = true; port = 9298; };
     home.stateVersion = "25.11"; }`; `environment.systemPackages = [
     pkgs.awscli2 pkgs.curl ]`.
   - Script (Python):
     ```python
     d = "/run/aws-emulator/.aws/emulator/9297"
     env = f"AWS_CONFIG_FILE={d}/config AWS_SHARED_CREDENTIALS_FILE={d}/emulator_credentials"
     machine.wait_for_unit("aws-emulator.service")
     machine.succeed("curl -sfk https://127.0.0.1:9297/__admin/health")
     machine.succeed(f"su - alice -c 'cat {d}/emulator_credentials >/dev/null'")
     machine.succeed(f"su - alice -c '{env} aws s3 mb s3://emulator-test'")
     machine.succeed(f"su - alice -c '{env} aws s3 ls' | grep emulator-test")
     machine.fail(f"su - carol -c 'cat {d}/emulator_credentials'")
     machine.succeed("journalctl -u aws-emulator | grep -q 'telemetry: disabled'")
     uid = machine.succeed("id -u bob").strip()
     machine.wait_for_unit("home-manager-bob.service")
     machine.wait_for_unit(f"user@{uid}.service")
     bob = f"su - bob -c 'XDG_RUNTIME_DIR=/run/user/{uid} systemctl --user"
     machine.wait_until_succeeds(f"{bob} is-active aws-emulator'")
     machine.wait_until_succeeds("curl -sfk https://127.0.0.1:9298/__admin/health")
     machine.succeed(f"{bob} stop aws-emulator'")
     machine.fail("test -e /home/bob/.aws/emulator/9298")
     ```
   - Verify: `nix build -L .#checks.x86_64-linux.nixos` passes.
   - Traps: don't use `systemctl --machine=bob@` (needs machined). Bob's
     unit is `Type=simple`: poll its health with `wait_until_succeeds`. If
     S3 calls fail on TLS, add `AWS_CA_BUNDLE={d}/ca.pem` (the `config` file
     already sets `ca_bundle`). Needs KVM (available on this host).

8. **`.github/workflows/ci.yml`, `.github/workflows/update.yml`** (new).
   Pinned actions (use exactly these):
   ```
   actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
   cachix/install-nix-action@3dc140bfc76c49fbd4dd958429132e3746bcb086 # v31.11.5
   actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
   actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
   peter-evans/create-pull-request@3ffccacd46053766916f087ce41d627c0b8cf2d1 # v8.1.3
   ```
   - KVM steps (in every job that runs the VM test, **before** install-nix):
     ```bash
     echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules
     sudo udevadm control --reload-rules
     sudo udevadm trigger --name-match=/dev/kvm
     sudo udevadm settle
     test -r /dev/kvm -a -w /dev/kvm
     ```
   - install-nix `with: extra_nix_config: "system-features = nixos-test
     benchmark big-parallel kvm"`.
   - `ci.yml`: on `push` (branches `main`), `pull_request`,
     `workflow_dispatch`; `permissions: contents: read`; `concurrency: group:
     ci-${{ github.ref }}, cancel-in-progress: true`.
     - Job `x86_64` (`ubuntu-latest`): checkout, KVM steps, install-nix,
       `nix flake check -L`.
     - Job `aarch64` (`ubuntu-24.04-arm`): checkout, install-nix, `nix build
       -L .#checks.aarch64-linux.smoke .#checks.aarch64-linux.format`.
   - `update.yml`: on `schedule: - cron: "17 6 * * *"`, `workflow_dispatch`;
     workflow `permissions: contents: read`; `concurrency: update`.
     - Job `update` (`ubuntu-latest`), job permissions `contents: read`
       **and** `pull-requests: read` (job-level replaces workflow-level, so
       list both). Steps: checkout; KVM steps; install-nix; step `check`
       (id) with `GH_TOKEN: ${{ github.token }}`: get the latest tag (as in
       step 4) and run `gh pr list --head update/aws-emulator --state open
       --json title --jq '.[].title'`; if any title ends with ` -> <new>`,
       write `skip=true`. Step `run` (id, `if: steps.check.outputs.skip !=
       'true'`, env `GITHUB_TOKEN: ${{ github.token }}`): `nix shell
       nixpkgs#jq nixpkgs#gnupg nixpkgs#dpkg nixpkgs#curl -c
       scripts/update.sh`. If `steps.run.outputs.changed == 'true'`: `nix
       flake check -L`, then upload artifact `sources` with path
       `pkgs/aws-emulator/sources.json`. Job outputs: `changed`,
       `old_version`, `version` from `steps.run.outputs`.
     - Job `arm` (`needs: update`, `if: needs.update.outputs.changed ==
       'true'`, `ubuntu-24.04-arm`): checkout; download artifact `sources`
       with `path: pkgs/aws-emulator`; install-nix; `nix build -L
       .#checks.aarch64-linux.smoke`.
     - Job `pr` (`needs: [update, arm]`, same `if`, `ubuntu-latest`,
       permissions `contents: write`, `pull-requests: write`): checkout;
       download artifact `sources` with `path: pkgs/aws-emulator`;
       create-pull-request with `branch: update/aws-emulator`, `title` and
       `commit-message`: `aws-emulator: <old> -> <new>`, `body` linking
       `https://github.com/aws/aws-emulator/releases/tag/v<new>` and
       `${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}`
       and stating that x86_64 (flake check incl. VM test) and aarch64 smoke
       passed in that run; `delete-branch: true`.
   - Verify: `nix run nixpkgs#actionlint -- .github/workflows/*.yml` clean.
   - Traps: KVM before Nix. Artifact `path` on both downloads. Don't add
     write permissions anywhere except job `pr`.

9. **`README.md`** (new; written after steps 5, 6 and 8 exist, reading them
   for exact option names and workflow names). Sections in this order, with
   copy-paste fenced blocks:
   1. Title, CI badges for `ci.yml` and `update.yml`.
   2. What it is: one paragraph; link upstream and the AWS user guide; "for
      development and testing, not production".
   3. Quick try: `nix run github:olafkfreund/nix-aws-emulator`.
   4. Add as a flake input: `inputs`, `nixosModules.default`, optional
      `overlays.default`, `inputs.aws-emulator.inputs.home-manager.follows`.
   5. NixOS module: full example and an option table copied from step 5.
   6. Using it from the AWS CLI and SDKs: join the group
      (`users.users.<you>.extraGroups`), wait for the unit to be active,
      `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` paths, an `awsemu`
      shell function, the Java truststore path.
   7. Home Manager module: example; keys under `~/.aws/emulator/<port>/`.
   8. `nix profile install`.
   9. Telemetry: off here, upstream default on, opt in with
      `telemetry = true` or `EMULATOR_TELEMETRY=on`.
   10. Auth and keys: where they live, regenerated every start.
   11. Network: `bindAddress`, `openFirewall`, the warnings, and never add
       `ca.pem` to system-wide trust.
   12. Relaxing hardening: `systemd.services.aws-emulator.serviceConfig`
       override example.
   13. Updates: daily workflow, signature and fingerprint check, evidence in
       `sources.json`, the hash-mismatch window when upstream moves `latest`,
       and why no required status checks are configured on `main`.
   14. Licences: this repo MIT; the binary CC0 plus third-party licences
       listed in `share/doc/aws-emulator/THIRD_PARTY_LICENSES`, including
       LGPL-3.0-only (`malachite-*`), CDLA-Permissive-2.0 (no nixpkgs
       entry) and 4 crates with no declared licence (`mt19937`,
       `rustpython-doc`, `rustpython-pylib`, `syn-ext`); `meta.license` is
       not recomputed on update.
   15. Troubleshooting: port in use, `journalctl -u aws-emulator`, health
       `curl`, permission denied before the unit is active, hash mismatch.
   16. Development: `nix flake check`, `nix fmt`, `scripts/update.sh`.
   - Verify: every command block is exercised in step 10.
   - Traps: describe only what steps 1-8 built; the option table must match
     step 5 exactly.

10. **Integrate and ship** (Claude).
    - Commit each step as it lands, citing the step.
    - `nix fmt`; `nix flake check -L` locally (x86_64, KVM); fix and record
      any deviation in this plan in the same commit.
    - `nix run . ` starts and logs `telemetry: disabled`; `bash
      scripts/update.sh` prints up to date.
    - Repo setting: `gh api -X PUT
      repos/olafkfreund/nix-aws-emulator/actions/permissions/workflow -f
      default_workflow_permissions=read -F
      can_approve_pull_request_reviews=true`.
    - Push; open the PR to `main` linking intent, spec and plan and listing
      which steps each coder did; wait for both `ci.yml` jobs to pass.
    - Opus review (fresh agent, plan path + `git diff main`), plus Codex and
      agy read-only reviews; fix confirmed findings.
    - After the owner merges: dispatch `update.yml`; it must end "up to date".

## Tests

| Command | Expected |
|---|---|
| `nix flake check -L` (x86_64) | format, smoke, VM test pass |
| `nix build -L .#checks.aarch64-linux.smoke` (arm runner) | pass |
| `nix run .` | logs `telemetry: disabled`, health 200 on 9297 |
| `nix run . -- -v` | prints `Version: 1.0.342` |
| `bash scripts/update.sh` | `up to date: 1.0.342` |
| `nix run nixpkgs#actionlint -- .github/workflows/*.yml` | no findings |
| CI on the PR | both jobs green |
| `update.yml` dispatch on `main` | "up to date", no PR |

## Rollback

All changes are in the new repo. Before merge: close the PR and delete the
branch. After merge: `git revert` the merge commit, or archive the repo with
`gh repo archive olafkfreund/nix-aws-emulator`. No host or `~/.config/nixos`
change to undo.

## Deviations recorded during implementation

- Step 2: `pkgs.stdenv.hostPlatform.system` instead of the deprecated
  `pkgs.system`.
- Step 7: `node.pkgsReadOnly = false` in `runNixOSTest`, because the test
  driver makes `nixpkgs.overlays` read-only and the overlay must apply.
- Step 7: on clean stop the emulator deletes its files but leaves an empty
  `0700` port directory, so the last assertion checks
  `/home/bob/.aws/emulator/9298/config` is gone, not the directory.
- Step 9: the lead fixed the AWS user guide link and replaced the
  hardening example, which only re-set the defaults.
- Review fixes (Codex, Opus and agy reviews of the implementation):
  - Step 4 changed design: the version now comes from the signature-verified
    `.deb` control file, not the GitHub releases API. Upstream tags GitHub
    releases several times a day (v1.0.343 at 13:22 on 2026-11-13) while
    `LTS/latest` still served 1.0.342, so the tag-based check would fail
    every run. This also detects a same-version republish (new bytes), drops
    the API rate-limit dependency, refuses downgrades, requires both
    architectures to agree, and checks the `Architecture:` field. Cost: the
    daily run always downloads both `.deb` files (~350 MB).
  - Step 8: `update.yml` runs the updater first, then skips the checks when
    an open PR already targets that version; `persist-credentials: false` on
    every checkout; arm jobs no longer claim `kvm`/`nixos-test` features.
  - Steps 5-6: `localhost` rejected by assertion (the binary only accepts an
    IP); probe `curl` quoted, `-g`, with timeouts; `RestartSec = "5s"`.
  - Step 2: `formatter` is `nixfmt-tree`, so `nix fmt` without arguments
    formats the repo (`nixfmt` alone waits on stdin).
  - Step 9: README wording fixed (in-memory claim, shared-group warning,
    `localhost`, update flow).
