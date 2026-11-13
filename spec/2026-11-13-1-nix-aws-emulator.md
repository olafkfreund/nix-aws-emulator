---
status: draft
issue: 1
intent: intent/2026-11-13-1-nix-aws-emulator.md
---

# Spec: Install and configure AWS Emulator on NixOS

## Facts this design rests on (checked 2026-11-13, v1.0.342)

- `HOME` decides where the emulator writes: `$HOME/.aws/emulator/<port>/`
  (`vendor/emulator-paths/src/lib.rs`). It writes `config`,
  `emulator_credentials`, `ca.pem` and `truststore.p12`, all mode `0600` in a
  `0700` port directory, whatever the umask. It deletes them on clean stop.
- `-t off` prints "telemetry: disabled" at startup. `EMULATOR_TELEMETRY` and a
  config file are also read; `-t off` always wins.
- Health: `GET https://<bind>:<port>/__admin/health` returns 200 within about
  2 s of start. Idle RSS is about 290 MB.
- The amd64 and arm64 `.deb` packages have the same layout
  (`opt/aws-emulator/bin/aws-emulator`, `opt/aws-emulator/THIRD_PARTY_LICENSES`).
  The binary needs only glibc (`libc`, `libm`, `libpthread`, `libdl`).
- `.sig` verifies against the AWS key at
  `https://downloads.aws.com/keys/gpg/current.asc`, fingerprint
  `98BC F336 A3BE 53B7 34E9 67C5 2E5B F49B D940 F624`, which matches the AWS
  Linux install guide.

## Design

### Repository layout

```
flake.nix  flake.lock
pkgs/aws-emulator/package.nix
pkgs/aws-emulator/sources.json      # version + url + SRI hash per system
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
only by the VM test, consumers can drop it with `follows`).

Outputs, for `x86_64-linux` and `aarch64-linux`:

- `packages.<sys>.{aws-emulator,default}`, `apps.<sys>.default`
- `overlays.default` adds `aws-emulator`
- `nixosModules.{aws-emulator,default}`, `homeManagerModules.{aws-emulator,default}`.
  Both modules default `package` to this flake's package for the host system,
  so the overlay is not required.
- `checks.<sys>.smoke`; `checks.x86_64-linux.nixos` (VM test)
- `formatter.<sys>` = `nixfmt-rfc-style`

### Package (`pkgs/aws-emulator/package.nix`)

- `stdenv.mkDerivation`, `src = fetchurl` from `sources.json` for the host
  system; `throw` on other systems.
- Unpack with `dpkg-deb -x` (`dpkg` in `nativeBuildInputs`), then
  `autoPatchelfHook` and `makeWrapper`.
- Install the real binary to `$out/libexec/aws-emulator/aws-emulator` and
  `THIRD_PARTY_LICENSES` to `$out/share/doc/aws-emulator/`.
- `$out/bin/aws-emulator` is a wrapper with
  `--set-default EMULATOR_TELEMETRY off`. That covers `nix run`, `nix profile`
  and the overlay. A user who exports `EMULATOR_TELEMETRY=on` opts in. (The
  accepted values are checked in the plan's first step; if the variable can't
  express "off", the wrapper adds `-t off` unless `-t`/`--telemetry` is
  already in the arguments.)
- `meta`: `description`, `homepage`, `changelog` (GitHub release URL),
  `mainProgram = "aws-emulator"`, `platforms = [ x86_64-linux aarch64-linux ]`,
  `sourceProvenance = [ binaryNativeCode ]`, `license` = list of the licences
  found in `THIRD_PARTY_LICENSES` (`cc0`, `mit`, `asl20`, `bsd2`, `bsd3`,
  `isc`, `zlib`, `unicode-30`, `boost`, `lgpl3Only`, and any others present).
  Not `unfree`. The README notes the 4 crates with no declared licence.
- `passthru.updateScript = ../../scripts/update.sh`.

### `sources.json`

```json
{ "version": "1.0.342",
  "x86_64-linux":  { "url": "https://downloads.aws.com/.../LTS/latest/aws-emulator_amd64.deb", "hash": "sha256-..." },
  "aarch64-linux": { "url": "https://downloads.aws.com/.../LTS/latest/aws-emulator_arm64.deb", "hash": "sha256-..." } }
```

The URL is the mutable `latest` (the only one that works). The hash pins the
bytes. When upstream moves, fresh builds of `main` fail with a hash mismatch
until the update PR is merged; the README says so.

### Updater (`scripts/update.sh`, bash, `set -euo pipefail`)

1. Latest tag from the GitHub API (`repos/aws/aws-emulator/releases/latest`),
   strip `v`.
2. Exit 0 with "up to date" if it equals `sources.json.version`.
3. For each arch: download `.deb` and `.deb.sig` once into a temp dir.
4. Verify with `gpgv` against a keyring built from `keys/aws-publishing.asc`,
   and check that the signing key fingerprint equals the pinned constant.
   Fail closed.
5. Read `Version:` from the `.deb` control file; it must equal `<tag>-1`.
   This catches `latest` moving between the API call and the download.
6. Hash the verified local file with `nix hash file --sri`; write
   `sources.json` with `jq`.

Rotation of the AWS key is a manual change to `keys/` and the fingerprint
constant, reviewed by the owner.

### NixOS module (`services.aws-emulator`)

| Option | Type | Default |
|---|---|---|
| `enable` | bool | false |
| `package` | package | this flake's package |
| `bindAddress` | str | `"127.0.0.1"` |
| `port` | port, 1024-65535 (0 refused) | `9297` |
| `telemetry` | bool | `false` |
| `auth` | bool | `true` |
| `idleTimeout` | null or positive int | `null` |
| `extraArgs` | list of str | `[]` |
| `openFirewall` | bool | `false` |
| `group` | str | `"aws-emulator"` |

Service:

- Static system user and group `aws-emulator` (not `DynamicUser`, because its
  `/run/private` and `/var/lib/private` paths are `0700` root and block
  group access).
- `RuntimeDirectory=aws-emulator`, `RuntimeDirectoryMode=0750`,
  `Environment=HOME=/run/aws-emulator`. Files are per-run and in memory, so a
  runtime directory fits; nothing persists across restarts, as upstream.
- `ExecStart`: `aws-emulator -b <bind> -p <port> -t on|off -a on|off
  [--idle-timeout N] <extraArgs>`; `Environment=EMULATOR_TELEMETRY=on|off` to
  match.
- `ExecStartPost`: a script that polls the health URL with `curl -sk` (max
  30 s), then `chmod g+rX` on `.aws`, `.aws/emulator`, `.aws/emulator/<port>`
  and `chmod g+r` on its files. Members of `group` can then read the
  credentials, config and CA without root. The unit fails if health never
  returns 200. `Type=exec`, so "active" means the chmod is done.
- `Restart=on-failure`. With `idleTimeout` set the service exits 0 when idle
  and stays stopped; the option description says so.
- Hardening: `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=true`,
  `PrivateTmp`, `PrivateDevices`, `ProtectKernelTunables`,
  `ProtectKernelModules`, `ProtectKernelLogs`, `ProtectControlGroups`,
  `ProtectClock`, `ProtectHostname`,
  `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`, `RestrictNamespaces`,
  `RestrictRealtime`, `RestrictSUIDSGID`, `LockPersonality`,
  `SystemCallArchitectures=native`, empty `CapabilityBoundingSet`,
  `UMask=0027`. `MemoryDenyWriteExecute=true` only if the VM test passes with
  it.
- `openFirewall` opens `port` in `networking.firewall.allowedTCPPorts`.
  A `warnings` entry when `bindAddress` is not loopback.
- `environment.systemPackages` gets the package.

Users join the group with `users.users.<name>.extraGroups = [ "aws-emulator" ]`
and point the CLI at `/run/aws-emulator/.aws/emulator/<port>/config` and
`.../emulator_credentials`.

### Home Manager module (`services.aws-emulator`)

Same options minus `openFirewall` and `group`. A
`systemd.user.services.aws-emulator` with the same `ExecStart` and a lighter
hardening set (user units can't use most `Protect*`). Files land in the
user's own `~/.aws/emulator/<port>/`, so there is no chmod step. Adds the
package to `home.packages`. Does **not** set `AWS_CONFIG_FILE` globally (that
would redirect all AWS usage to the emulator); the README shows a shell
function instead.

### Tests

- `tests/smoke.nix` (both arches, `runCommand` in the build sandbox): run
  `aws-emulator -v` (version equals `sources.json.version`); start it with
  `HOME=$TMPDIR` on fixed port `19297`; poll health with `curl -sk` up to
  30 s; assert 200; assert the startup log says telemetry is disabled; stop
  it.
- `tests/nixos.nix` (x86_64, `pkgs.testers.runNixOSTest`), one machine with
  - the NixOS module enabled, user `alice` in group `aws-emulator`,
    user `carol` not in it;
  - Home Manager for user `bob` with the HM module on port `9298` and
    lingering enabled.

  Asserts: unit active; health 200 on 9297; `alice` (not root) reads the
  credentials and runs `aws s3 mb s3://t` and `aws s3 ls` (awscli2) with
  `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` set; `carol` can't read
  the credentials; journal shows telemetry disabled; `bob`'s user service
  answers on 9298; stopping the unit removes the port directory.

### Workflows

Actions pinned by commit SHA. Nix via `cachix/install-nix-action`. No secrets
beyond `GITHUB_TOKEN`.

- `ci.yml`, on push to `main`, pull requests and `workflow_dispatch`:
  - `x86_64` (`ubuntu-latest`, KVM enabled with the standard udev rule):
    `nix flake check -L` (format, smoke, VM test).
  - `aarch64` (`ubuntu-24.04-arm`):
    `nix build -L .#checks.aarch64-linux.smoke`.
- `update.yml`, daily cron and `workflow_dispatch`, `permissions:
  contents: write, pull-requests: write`:
  1. `update` job (x86_64): run `scripts/update.sh`; if `sources.json`
     changed, run the same `nix flake check -L`; upload `sources.json` as an
     artifact; output `changed` and `version`.
  2. `arm` job (needs `update`, if changed): download the artifact, run the
     aarch64 smoke check.
  3. `pr` job (needs both): `peter-evans/create-pull-request` on branch
     `update/aws-emulator`, title `aws-emulator: <old> -> <new>`, body with
     links to the upstream release and the passing run. PRs opened with
     `GITHUB_TOKEN` don't trigger `ci.yml`, so the tests run here first.
     No auto-merge; the owner merges.
  - The repo setting "Allow GitHub Actions to create pull requests" is turned
    on with `gh api` during implementation.

### README

Sections: what it is; quick try (`nix run`); flake input; NixOS module with a
full example and option table; group access and pointing the AWS CLI and SDKs
(env vars, Java truststore); Home Manager module; `nix profile`; telemetry
(off here, upstream default on, how to opt in); auth and where keys live;
binding to the network and the firewall; updates and the `latest`
hash-mismatch window; licences (repo MIT; binary CC0 plus third-party
licences, including LGPL-3.0-only and undeclared ones); troubleshooting (port
in use, health check, journal); CI badges.

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
- **Global `AWS_CONFIG_FILE` session variable**: would send every AWS call on
  the machine to the emulator.

## Risks

- **Hash-mismatch window** on `main` between an upstream release and merging
  the update PR (worst case about a day plus review). Pinning an older flake
  revision doesn't help because the URL moved. Mitigation: daily update
  workflow; the README explains it.
- **chmod race**: a group member reading files before `ExecStartPost`
  finishes gets "permission denied". `Type=exec` plus `ExecStartPost` makes
  "active" mean the chmod is done; the README says to wait for it.
- **Hardening breaks the binary** (`MemoryDenyWriteExecute`): caught by the
  VM test; drop the offending setting.
- **KVM on runners**: without `/dev/kvm` the VM test is very slow; CI fails
  loudly rather than skipping.
- **Upstream changes** paths, flags or file modes: the VM test on the update
  run catches it before a PR is opened.
- **Licence list drift**: the updater doesn't recompute `meta.license`; a new
  licence type could go unlisted. Low impact; noted in the README.
- No hosts are touched; only the new repo is affected.

## Verification

- `nix flake check -L` passes on x86_64 (formatter, smoke, VM test).
- `nix build .#checks.aarch64-linux.smoke` passes on an arm runner.
- `nix run .` starts the emulator and prints "telemetry: disabled".
- `scripts/update.sh` on a current pin prints "up to date"; with
  `sources.json.version` set to an older value it re-downloads, verifies the
  signature and fingerprint, and writes the same hashes.
- `ci.yml` green on the PR; `update.yml` run via `workflow_dispatch` ends with
  "up to date" (or opens a PR whose checks passed).
- README commands copied into a shell work as written.
