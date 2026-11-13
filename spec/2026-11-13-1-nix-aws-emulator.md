---
status: approved
issue: 1
intent: intent/2026-11-13-1-nix-aws-emulator.md
---

# Spec: Install and configure AWS Emulator on NixOS

## Facts this design rests on (checked 2026-11-13, v1.0.342)

- `HOME` decides where the emulator writes: `$HOME/.aws/emulator/<port>/`
  (`vendor/emulator-paths/src/lib.rs`). It writes `config`, `ca.pem`,
  `truststore.p12` and, with auth on, `emulator_credentials`; all `0600` in a
  `0700` port directory, whatever the umask. It deletes them on clean stop.
  `ca.pem` and `truststore.p12` hold certificates only, no private key.
- Telemetry (`vendor/emulator-telemetry/src/policy.rs`): `EMULATOR_TELEMETRY`
  `off|false|0` disables it "no matter what the config file or the embedding
  API say"; `on|true|1` enables; any other value (including empty) fails safe
  to disabled. `-t off` is disable-only and also wins.
- Health: `GET https://<addr>:<port>/__admin/health` returns 200 within about
  2 s of start. Idle RSS is about 290 MB.
- The amd64 and arm64 `.deb` packages have the same layout
  (`opt/aws-emulator/bin/aws-emulator`, `opt/aws-emulator/THIRD_PARTY_LICENSES`).
  The binary needs only glibc (`libc`, `libm`, `libpthread`, `libdl`). It
  embeds RustPython (`rustpython-*` crates).
- `.sig` is made by the primary key of the AWS key at
  `https://downloads.aws.com/keys/gpg/current.asc`, fingerprint
  `98BC F336 A3BE 53B7 34E9 67C5 2E5B F49B D940 F624`, which matches the AWS
  Linux install guide. Control `Version:` is `1.0.342-1`.
- Licences in `THIRD_PARTY_LICENSES`: mostly MIT/Apache-2.0; also BSD-2/3,
  ISC, Zlib, Unicode-3.0, BSL-1.0, 0BSD, Unlicense, MIT-0, CC0, PSF-2.0,
  bzip2, CDLA-Permissive-2.0, BlueOak-1.0.0, LGPL-3.0-only (`malachite-*`, 4
  crates) and 4 with no declared licence (`mt19937`, `rustpython-doc`,
  `rustpython-pylib`, `syn-ext`). In nixpkgs `lib.licenses`: `unicode-30`
  exists, `unicode30` does not.

## Design

### Repository layout

```
flake.nix  flake.lock
pkgs/aws-emulator/package.nix
pkgs/aws-emulator/sources.json      # version, url, hash, sig evidence per system
modules/nixos.nix                   # services.aws-emulator (system)
modules/home-manager.nix            # services.aws-emulator (user)
tests/nixos.nix                     # NixOS VM test (x86_64)
tests/smoke.nix                     # sandbox start + health (both arches)
keys/aws-publishing.asc             # pinned AWS signing key
scripts/update.sh                   # verify-then-pin updater
.github/workflows/ci.yml
.github/workflows/update.yml
README.md  LICENSE (MIT, for this repo's Nix code only)
```

### Flake

Inputs: `nixpkgs` (nixos-unstable) and `home-manager` (follows nixpkgs; used
only by the VM test). It still appears in consumers' `flake.lock`; they can
point it at their own with `inputs.aws-emulator.inputs.home-manager.follows`.

Outputs, for `x86_64-linux` and `aarch64-linux`:

- `packages.<sys>.{aws-emulator,default}`, `apps.<sys>.default`
- `overlays.default` adds `aws-emulator` via `callPackage`
- `nixosModules.{aws-emulator,default}`, `homeManagerModules.{aws-emulator,default}`.
  Each module's `package` default is
  `pkgs.aws-emulator or (pkgs.callPackage ../pkgs/aws-emulator/package.nix { })`,
  with a `defaultText`. It respects the overlay, works without it, and is
  only evaluated when the service is enabled.
- `checks.<sys>.smoke` and `checks.<sys>.format` (`nixfmt --check` over all
  `.nix` files); `checks.x86_64-linux.nixos` (VM test)
- `formatter.<sys>` = `nixfmt-rfc-style` (for `nix fmt`)

`sources.json` is read with `builtins.fromJSON`; no IFD.

### Package (`pkgs/aws-emulator/package.nix`)

- `stdenv.mkDerivation`, `src = fetchurl` from `sources.json` for the host
  system; `throw` with a clear message on other systems.
- `nativeBuildInputs = [ dpkg autoPatchelfHook makeWrapper ]`; the `dpkg`
  setup hook unpacks the `.deb`. `runtimeDependencies` adds
  `stdenv.cc.cc.lib` so glibc can `dlopen` `libgcc_s.so.1` for thread
  unwinding. `dontStrip = true` (already stripped, 177 MB).
- Install the real binary to `$out/libexec/aws-emulator/aws-emulator` and
  `THIRD_PARTY_LICENSES` to `$out/share/doc/aws-emulator/`.
- `$out/bin/aws-emulator` is a `makeWrapper` wrapper with
  `--set-default EMULATOR_TELEMETRY off`. That covers `nix run`,
  `nix profile` and the overlay. An exported empty value also gives
  "disabled" (fails safe). A user who exports `EMULATOR_TELEMETRY=on` opts in.
- `meta`: `description`, `homepage`, `changelog` (GitHub release URL),
  `mainProgram = "aws-emulator"`, `platforms = [ x86_64-linux aarch64-linux ]`,
  `sourceProvenance = [ binaryNativeCode ]`, `license = with lib.licenses;
  [ cc0 mit asl20 bsd0 bsd2 bsd3 isc zlib unicode-30 boost unlicense mit0
  lgpl3Only ]` plus any others the plan finds by name in `lib.licenses`. Not
  `unfree`. The README lists the 4 crates with no declared licence.
- `passthru.updateScript = ../../scripts/update.sh`.

### `sources.json`

```json
{ "version": "1.0.342",
  "signer": "98BCF336A3BE53B734E967C52E5BF49BD940F624",
  "x86_64-linux":  { "url": ".../LTS/latest/aws-emulator_amd64.deb", "hash": "sha256-...", "sigHash": "sha256-..." },
  "aarch64-linux": { "url": ".../LTS/latest/aws-emulator_arm64.deb", "hash": "sha256-...", "sigHash": "sha256-..." } }
```

`sigHash` and `signer` are the committed evidence that links each pinned file
to its verified signature. The URL is the mutable `latest` (the only one that
works); the hash pins the bytes. When upstream moves, fresh builds of `main`
fail with a hash mismatch until the update PR is merged; the README says so.

### Updater (`scripts/update.sh`, bash, `set -euo pipefail`)

1. Latest tag from the GitHub API (`repos/aws/aws-emulator/releases/latest`),
   strip `v`. Exit 0 with "up to date" if it equals `sources.json.version`.
2. For each arch: download `.deb` and `.deb.sig` once into a temp dir.
3. Verify: `gpg --dearmor` `keys/aws-publishing.asc` into the temp dir, run
   `gpgv --homedir <tmp> --keyring <tmp>/aws.gpg --status-fd 1`, require a
   `VALIDSIG` line whose primary-key fingerprint field equals the pinned
   constant. Fail closed. No host keyring is consulted.
4. Read `Version:` from the `.deb` control file; it must match
   `^<tag>(-[0-9]+)?$`. This catches `latest` moving mid-run.
5. Hash the verified local `.deb` and `.sig` with `nix hash file --sri`,
   `nix store add-file` the `.deb` (so the following `nix flake check` doesn't
   download it again), and write `sources.json` with `jq`.
6. Print the old and new version.

Rotation of the AWS key is a manual change to `keys/` and the fingerprint
constant, reviewed by the owner.

### NixOS module (`services.aws-emulator`)

| Option | Type | Default |
|---|---|---|
| `enable` | bool | false |
| `package` | package | see Flake |
| `bindAddress` | str | `"127.0.0.1"` |
| `port` | port, 1024-65535 | `9297` |
| `telemetry` | bool | `false` |
| `auth` | bool | `true` |
| `idleTimeout` | null or positive int | `null` |
| `extraArgs` | list of str | `[]` |
| `openFirewall` | bool | `false` |
| `group` | str | `"aws-emulator"` |

Service:

- Static system user `aws-emulator` with `group = cfg.group`.
  `users.groups.${cfg.group}` is created only when `cfg.group` is the
  default; a custom group must already exist. `serviceConfig.User` and
  `Group = cfg.group`. Not `DynamicUser`, because its `/run/private` path is
  `0700` root and blocks group access.
- `RuntimeDirectory=aws-emulator`, `RuntimeDirectoryMode=0750`,
  `Environment=HOME=/run/aws-emulator`. Files are per-run and in memory, so a
  runtime directory fits; nothing persists across restarts, as upstream.
- `ExecStart`: the wrapper with `-b <bind> -p <port> -a on|off
  [--idle-timeout N] <extraArgs>`, and `Environment=EMULATOR_TELEMETRY=on|off`
  from `telemetry`.
- `ExecStartPost` (runs as the service user, never `+`): poll the health URL
  with `curl -sk` (max 30 s) **and** wait for `config` to exist, then
  `chmod -R g+rX /run/aws-emulator/.aws`. The probe address maps
  `0.0.0.0` to `127.0.0.1`, `::` to `[::1]`, and brackets any other IPv6
  literal. `Type=exec`, so "active" means the chmod is done; failure stops
  the unit.
- `Restart=on-failure`. With `idleTimeout` set the service exits 0 when idle
  and stays stopped; the option description says so.
- Hardening: `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=true`,
  `PrivateTmp`, `PrivateDevices`, `ProtectKernelTunables`,
  `ProtectKernelModules`, `ProtectKernelLogs`, `ProtectControlGroups`,
  `ProtectClock`, `ProtectHostname`,
  `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK`,
  `RestrictNamespaces`, `RestrictRealtime`, `RestrictSUIDSGID`,
  `LockPersonality`, `SystemCallArchitectures=native`, empty
  `CapabilityBoundingSet`, `UMask=0027`. No `MemoryDenyWriteExecute`: the
  embedded Python runtime and 437 service crates can't be shown safe with it.
- `openFirewall` opens `port` in `networking.firewall.allowedTCPPorts`.
- `warnings`: `bindAddress` not loopback; not loopback **and** `auth = false`
  (stronger wording); `openFirewall` while bound to loopback.
- The module does not add the package to `environment.systemPackages`; it is
  a daemon and clients use the AWS CLI or SDKs.

Users join the group with `users.users.<name>.extraGroups = [ "aws-emulator" ]`
and point the CLI at `/run/aws-emulator/.aws/emulator/<port>/config` and
`.../emulator_credentials`.

### Home Manager module (`services.aws-emulator`)

Same options minus `openFirewall` and `group`. A
`systemd.user.services.aws-emulator` in Home Manager's raw form
(`Unit`, `Service`, `Install`), with `Service.Environment` as a list of
`"K=V"` strings, the same `ExecStart`, `Restart=on-failure`, and
`Install.WantedBy = [ "default.target" ]`. Files land in the user's own
`~/.aws/emulator/<port>/`, so there is no chmod step. Adds the package to
`home.packages`. Does **not** set `AWS_CONFIG_FILE` globally (that would send
all AWS usage to the emulator); the README shows a shell function instead.
Assertion: Linux only.

### Tests

- `tests/smoke.nix` (both arches, `runCommand` in the build sandbox, which
  has loopback): `aws-emulator -v` reports `sources.json.version`; start it
  with `HOME=$TMPDIR -b 127.0.0.1 -p 19297`, kill it from an `EXIT` trap;
  poll `https://127.0.0.1:19297/__admin/health` with `curl -sk` up to 30 s;
  assert 200; assert the startup log says telemetry is disabled; write `$out`.
- `tests/nixos.nix` (x86_64, `pkgs.testers.runNixOSTest`,
  `virtualisation.memorySize = 2048`), one machine with
  - the NixOS module enabled, user `alice` in group `aws-emulator`, user
    `carol` not in it;
  - Home Manager for user `bob` (`isNormalUser`, `linger = true`) with the HM
    module on port `9298`.

  Script: wait for `aws-emulator.service`; health 200 on 9297; `alice` (not
  root) reads the credentials and runs `aws s3 mb s3://emulator-test` and
  `aws s3 ls` (awscli2) with `AWS_CONFIG_FILE` and
  `AWS_SHARED_CREDENTIALS_FILE` set; `carol` gets "permission denied" on the
  credentials; journal shows telemetry disabled; wait for
  `user@<bob uid>.service`, then `systemctl --machine=bob@ --user` shows
  `aws-emulator` active and health is 200 on 9298; stopping bob's unit
  removes `~bob/.aws/emulator/9298` (upstream clean-stop behaviour).

### Workflows

Actions pinned by commit SHA. Nix via `cachix/install-nix-action` with
`extra-nix-config: system-features = nixos-test benchmark big-parallel kvm`.
No secrets beyond `GITHUB_TOKEN`.

KVM setup, used in every job that runs the VM test: a udev rule giving
`/dev/kvm` mode `0666`, applied **before** installing Nix, then a step
`test -r /dev/kvm -a -w /dev/kvm` that fails the job if KVM is missing
(QEMU would otherwise fall back to slow emulation and time out).

- `ci.yml`, on push to `main`, pull requests and `workflow_dispatch`,
  `permissions: contents: read`:
  - `x86_64` (`ubuntu-latest`): KVM setup, `nix flake check -L` (format,
    smoke, VM test).
  - `aarch64` (`ubuntu-24.04-arm`):
    `nix build -L .#checks.aarch64-linux.smoke .#checks.aarch64-linux.format`.
- `update.yml`, daily cron and `workflow_dispatch`; workflow-level
  `permissions: contents: read`:
  1. `update` job (x86_64): skip if an open PR from `update/aws-emulator`
     already pins the latest upstream version. Otherwise run
     `scripts/update.sh`; if `sources.json` changed, KVM setup and
     `nix flake check -L`; upload `sources.json` as an artifact; outputs
     `changed`, `old_version`, `version`.
  2. `arm` job (needs `update`, if changed): checkout, download the artifact
     over `pkgs/aws-emulator/sources.json`, run the aarch64 smoke check.
  3. `pr` job (needs both), the only job with `contents: write` and
     `pull-requests: write`: checkout, download the same artifact, then
     `peter-evans/create-pull-request` on branch `update/aws-emulator`,
     title `aws-emulator: <old> -> <new>`, body with links to the upstream
     release and this run. PRs opened with `GITHUB_TOKEN` don't trigger
     `ci.yml`, so the tests run here first. No auto-merge; the owner merges.
- Repo setup during implementation:
  `gh api -X PUT repos/<owner>/nix-aws-emulator/actions/permissions/workflow`
  with `default_workflow_permissions=read` and
  `can_approve_pull_request_reviews=true` (lets Actions create PRs). The
  README notes that required status checks on `main` would block these PRs
  (no `ci.yml` run), so none are configured.

### README

Sections: what it is; quick try (`nix run`); flake input; NixOS module with a
full example and option table; group access and pointing the AWS CLI and SDKs
(env vars, Java truststore); Home Manager module; `nix profile`; telemetry
(off here, upstream default on, how to opt in); auth and where keys live;
binding to the network and the firewall, and not adding `ca.pem` to
system-wide trust; updates and the `latest` hash-mismatch window; licences
(repo MIT; binary CC0 plus third-party licences, including LGPL-3.0-only and
the 4 undeclared ones by name); troubleshooting (port in use, health check,
journal); CI badges.

## Alternatives rejected

- **Build from source** with `rustPlatform`: about 100 GB of `target/` and
  hours per build; doesn't fit GitHub runners or a quick update loop.
- **Docker image** (`virtualisation.oci-containers`): upstream publishes only
  a Dockerfile, not an image; adds a container runtime for one binary.
- **`buildFHSEnv` or `nix-ld`**: unnecessary; `autoPatchelfHook` handles a
  glibc-only binary.
- **Re-hosting `.deb` files** as release assets: declined in the intent
  (licence check pending).
- **`DynamicUser`**: blocks group access through `/run/private`.
- **Persistent `StateDirectory`**: upstream deletes these files on stop and
  regenerates keys on start, so persistence adds nothing.
- **A umask or patching the binary for group-readable files**: the binary
  forces `0600`, so a chmod after health is the only non-invasive way.
- **A shell wrapper that injects `-t off`**: needs argument parsing; the env
  variable already wins over every other source.
- **Global `AWS_CONFIG_FILE` session variable**: would send every AWS call on
  the machine to the emulator.

## Risks

- **Hash-mismatch window** on `main` between an upstream release and merging
  the update PR (worst case about a day plus review). An older flake revision
  doesn't help because the URL moved. Mitigation: daily update workflow; the
  README explains it.
- **chmod race**: a group member reading files before `ExecStartPost`
  finishes gets "permission denied". "active" means the chmod is done; the
  README says to wait for it.
- **Hardening breaks a service API** not exercised by the VM test (S3 only).
  `MemoryDenyWriteExecute` is already left out; users can relax more with
  `systemd.services.aws-emulator.serviceConfig` overrides (README example).
- **KVM on runners**: the explicit check fails the job if `/dev/kvm` is not
  usable.
- **Upstream changes** paths, flags or file modes: the VM test on the update
  run catches it before a PR is opened.
- **Licence list drift**: the updater doesn't recompute `meta.license`; a new
  licence type could go unlisted. Low impact; noted in the README.
- No hosts are touched; only the new repo is affected.

## Verification

- `nix flake check -L` passes on x86_64 (format, smoke, VM test).
- `nix build .#checks.aarch64-linux.smoke` passes on an arm runner.
- `nix run .` starts the emulator and prints that telemetry is disabled.
- `scripts/update.sh` on a current pin prints "up to date"; with
  `sources.json.version` set to an older value it re-downloads, verifies the
  signature and fingerprint, and writes the same hashes.
- `ci.yml` green on the PR; `update.yml` run via `workflow_dispatch` ends with
  "up to date".
- README commands copied into a shell work as written.
