# nix-aws-emulator

[![CI](https://github.com/olafkfreund/nix-aws-emulator/actions/workflows/ci.yml/badge.svg)](https://github.com/olafkfreund/nix-aws-emulator/actions/workflows/ci.yml)
[![Update](https://github.com/olafkfreund/nix-aws-emulator/actions/workflows/update.yml/badge.svg)](https://github.com/olafkfreund/nix-aws-emulator/actions/workflows/update.yml)

## What it is

`nix-aws-emulator` packages [AWS Emulator](https://github.com/aws/aws-emulator) (`aws-emulator`) for Nix (`x86_64-linux` and `aarch64-linux`) and provides NixOS and Home Manager service modules. AWS Emulator is an upstream local emulator of AWS APIs (see the [AWS Emulator User Guide](https://docs.aws.amazon.com/emulator/latest/userguide/what-is-service.html)) intended for development and testing, not production. The package repackages the signed upstream `.deb` release, disables telemetry by default across all entry points, and keeps emulated resources in memory only; per-run connection and TLS files are generated at startup.

## Quick try

Run the emulator directly on default `127.0.0.1:9297` (HTTPS-only):

```bash
nix run github:olafkfreund/nix-aws-emulator
```

Pass CLI flags after `--` (for example, to check the version or change the port):

```bash
nix run github:olafkfreund/nix-aws-emulator -- -v
nix run github:olafkfreund/nix-aws-emulator -- -b 127.0.0.1 -p 9297
```

## Add as a flake input

Add `nix-aws-emulator` to your `flake.nix` inputs and import `nixosModules.default` (and optionally `overlays.default` and `homeManagerModules.default`). If you already use `home-manager` in your flake, point `inputs.aws-emulator.inputs.home-manager.follows` at it to avoid duplicate inputs in `flake.lock`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    aws-emulator = {
      url = "github:olafkfreund/nix-aws-emulator";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      aws-emulator,
      ...
    }:
    {
      nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          aws-emulator.nixosModules.default
          {
            # Optional: exposes pkgs.aws-emulator
            nixpkgs.overlays = [ aws-emulator.overlays.default ];
          }
          ./configuration.nix
        ];
      };
    };
}
```

Flake outputs provided by `github:olafkfreund/nix-aws-emulator`:

- `packages.<system>.default` (`packages.<system>.aws-emulator`)
- `apps.<system>.default`
- `overlays.default`
- `nixosModules.default` (`nixosModules.aws-emulator`)
- `homeManagerModules.default` (`homeManagerModules.aws-emulator`)

## NixOS module

Enable the hardened system service in your NixOS configuration and add your user to the `aws-emulator` group so you can read the generated credentials and CA bundle under `/run/aws-emulator/.aws/emulator/<port>/`:

```nix
{
  services.aws-emulator = {
    enable = true;
    bindAddress = "127.0.0.1";
    port = 9297;
    telemetry = false;
    auth = true;
    idleTimeout = null;
    extraArgs = [ ];
    openFirewall = false;
    group = "aws-emulator";
  };

  users.users.alice.extraGroups = [ "aws-emulator" ];
}
```

### Options (`services.aws-emulator`)

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `services.aws-emulator.enable` | `bool` | `false` | Whether to enable AWS Emulator, a local emulator of the AWS APIs. |
| `services.aws-emulator.package` | `package` | `pkgs.aws-emulator` | AWS Emulator package to run. |
| `services.aws-emulator.bindAddress` | `str` | `"127.0.0.1"` | Address on which AWS Emulator listens. |
| `services.aws-emulator.port` | `ints.between 1024 65535` | `9297` | Port on which AWS Emulator listens. |
| `services.aws-emulator.telemetry` | `bool` | `false` | Whether to enable AWS Emulator telemetry. |
| `services.aws-emulator.auth` | `bool` | `true` | Whether to require authentication. |
| `services.aws-emulator.idleTimeout` | `nullOr ints.positive` | `null` | Exit successfully after this many idle seconds and stay stopped. |
| `services.aws-emulator.extraArgs` | `listOf str` | `[ ]` | Extra command line arguments for AWS Emulator. |
| `services.aws-emulator.openFirewall` | `bool` | `false` | Open the listening port in the firewall. |
| `services.aws-emulator.group` | `str` | `"aws-emulator"` | Group allowed to read AWS Emulator connection files. |

## Using it from the AWS CLI and SDKs

1. Join the service group in your NixOS configuration and re-login so the group membership takes effect:

```nix
{
  users.users.<you>.extraGroups = [ "aws-emulator" ];
}
```

2. Wait for `aws-emulator.service` to reach the `active` state (its `ExecStartPost` script waits for the health check and `config` file before running `chmod -R g+rX /run/aws-emulator/.aws`):

```bash
systemctl is-active aws-emulator.service
```

3. Point the AWS CLI or SDKs at the generated `config` (which configures `endpoint_url` and `ca_bundle`) and `emulator_credentials` files:

```bash
export AWS_CONFIG_FILE=/run/aws-emulator/.aws/emulator/9297/config
export AWS_SHARED_CREDENTIALS_FILE=/run/aws-emulator/.aws/emulator/9297/emulator_credentials
aws s3 mb s3://emulator-test
aws s3 ls
```

4. To avoid redirecting every `aws` invocation in your shell to the emulator, define a shell helper function `awsemu`:

```bash
awsemu() {
  local port="${AWS_EMULATOR_PORT:-9297}"
  local dir="/run/aws-emulator/.aws/emulator/${port}"
  AWS_CONFIG_FILE="${dir}/config" \
  AWS_SHARED_CREDENTIALS_FILE="${dir}/emulator_credentials" \
    aws "$@"
}
```

5. The emulator is HTTPS-only and generates a per-run self-signed CA certificate at `/run/aws-emulator/.aws/emulator/<port>/ca.pem` (already referenced by `ca_bundle` in `config`) and a PKCS#12 truststore for Java SDK clients at `/run/aws-emulator/.aws/emulator/<port>/truststore.p12`:

```bash
java \
  -Djavax.net.ssl.trustStore=/run/aws-emulator/.aws/emulator/9297/truststore.p12 \
  -Djavax.net.ssl.trustStoreType=PKCS12 \
  -jar app.jar
```

## Home Manager module

Import `homeManagerModules.default` in your Home Manager configuration to run `aws-emulator` as a systemd user service (`systemd.user.services.aws-emulator`) and install `aws-emulator` into `home.packages`. The Home Manager module supports `enable`, `package`, `bindAddress`, `port`, `telemetry`, `auth`, `idleTimeout`, and `extraArgs` with the same types, defaults, and descriptions as the NixOS module:

```nix
{
  imports = [ aws-emulator.homeManagerModules.default ];

  services.aws-emulator = {
    enable = true;
    bindAddress = "127.0.0.1";
    port = 9297;
    telemetry = false;
    auth = true;
    idleTimeout = null;
    extraArgs = [ ];
  };
}
```

When running under Home Manager (or directly as your user), connection and TLS files are written under `~/.aws/emulator/<port>/`:

```bash
export AWS_CONFIG_FILE="$HOME/.aws/emulator/9297/config"
export AWS_SHARED_CREDENTIALS_FILE="$HOME/.aws/emulator/9297/emulator_credentials"
aws s3 ls
```

The Home Manager module does not set `AWS_CONFIG_FILE` globally in session variables so normal AWS CLI calls are not routed to the emulator unexpectedly; use an `awsemu` shell function pointed at `$HOME/.aws/emulator/${port}`:

```bash
awsemu() {
  local port="${AWS_EMULATOR_PORT:-9297}"
  local dir="${HOME}/.aws/emulator/${port}"
  AWS_CONFIG_FILE="${dir}/config" \
  AWS_SHARED_CREDENTIALS_FILE="${dir}/emulator_credentials" \
    aws "$@"
}
```

## `nix profile install`

Install the `aws-emulator` binary into your user profile:

```bash
nix profile install github:olafkfreund/nix-aws-emulator
aws-emulator -v
```

## Telemetry

Upstream AWS Emulator enables telemetry by default. In this repository, telemetry is disabled by default across every entry point:

- The package wrapper sets `--set-default EMULATOR_TELEMETRY off`.
- Both the NixOS and Home Manager modules default `services.aws-emulator.telemetry` to `false` (setting `EMULATOR_TELEMETRY=off`).

To opt in to telemetry on NixOS or Home Manager:

```nix
{
  services.aws-emulator.telemetry = true;
}
```

To opt in when running the binary directly from the command line:

```bash
EMULATOR_TELEMETRY=on nix run github:olafkfreund/nix-aws-emulator
```

## Auth and keys

Authentication (`services.aws-emulator.auth = true`, passing `-a on`) is enabled by default. On every start, the emulator generates fresh per-run files and deletes them on clean stop:

- System service (`services.aws-emulator` on NixOS): `/run/aws-emulator/.aws/emulator/<port>/` (`config`, `ca.pem`, `truststore.p12`, and `emulator_credentials` when `auth = true`).
- User service (Home Manager or direct CLI run): `~/.aws/emulator/<port>/` (`config`, `ca.pem`, `truststore.p12`, and `emulator_credentials` when `auth = true`).

Keys and certificates are regenerated on every start. For the NixOS service they live in `/run/aws-emulator` (tmpfs), so nothing persists across restarts or reboots. For Home Manager or a direct CLI run they are written to `~/.aws/emulator/<port>/` on disk and removed on clean stop (an empty port directory remains).

The `group` option makes its members able to read these files. Use a dedicated group: if you set it to a shared group such as `users`, every member of that group can read the emulator credentials.

## Network

`bindAddress` must be an IP address; the emulator rejects host names such as `localhost` (the modules fail evaluation with an assertion). By default, `services.aws-emulator.bindAddress` is `"127.0.0.1"` and `services.aws-emulator.openFirewall` is `false`.

If you change `bindAddress` or `openFirewall`, the NixOS module emits evaluation warnings for unsafe or ineffective combinations:

- Non-loopback `bindAddress` with `auth = true`:
  `AWS Emulator listens on <bindAddress>; anyone who can reach it and has the keys can use it`
- Non-loopback `bindAddress` with `auth = false`:
  `AWS Emulator listens on <bindAddress> WITHOUT authentication; anyone who can reach the port can use it and exhaust memory`
- `openFirewall = true` while `bindAddress` is loopback (`"127.0.0.1"` or `"::1"`):
  `AWS Emulator openFirewall has no effect while bindAddress is loopback`

Never add `ca.pem` to your system-wide trust store (`security.pki.certificateFiles`). Point only the AWS CLI or SDK at `/run/aws-emulator/.aws/emulator/<port>/config` (or `ca.pem` / `truststore.p12`) for emulator sessions.

## Relaxing hardening

The NixOS system service runs with strict systemd sandboxing (`ProtectSystem = "strict"`, `ProtectHome = true`, `PrivateTmp = true`, `PrivateDevices = true`, `NoNewPrivileges = true`, `CapabilityBoundingSet = ""`, and kernel/namespace restrictions). `MemoryDenyWriteExecute` is intentionally omitted because the binary embeds RustPython.

If an emulated AWS service API requires loosening a systemd unit setting, override `systemd.services.aws-emulator.serviceConfig` in your NixOS configuration:

```nix
{ lib, ... }:
{
  systemd.services.aws-emulator.serviceConfig = {
    # Example: allow device access and drop the address-family filter.
    PrivateDevices = lib.mkForce false;
    RestrictAddressFamilies = lib.mkForce [ ];
  };
}
```

## Updates

`.github/workflows/update.yml` runs weekly (Mondays 06:17 UTC, `17 6 * * 1`) and on demand via `workflow_dispatch`:

1. `scripts/update.sh` downloads the `amd64` and `arm64` `.deb` archives and their `.deb.sig` detached signatures from the `LTS/latest` URLs on `downloads.aws.com`.
2. Each `.deb` is verified with `gpgv` against the pinned AWS key in `keys/aws-publishing.asc`, requiring a `VALIDSIG` status line whose primary-key fingerprint equals `98BCF336A3BE53B734E967C52E5BF49BD940F624`, and checking the Debian `Architecture:` field.
3. The version comes from the verified packages' `Version:` field, not from GitHub: upstream tags GitHub releases several times a day, but the `LTS/latest` packages move less often. The workflow continues only when that version (or the bytes) differ from `pkgs/aws-emulator/sources.json`, both architectures agree, the version is not older than the pin, and no open PR on `update/aws-emulator` already targets it.
4. `pkgs/aws-emulator/sources.json` records `version`, `signer`, and per-system `url`, `hash`, and `sigHash` as committed verification evidence.
5. The workflow runs `nix flake check -L` (format, smoke test, and NixOS VM test) on `x86_64-linux` and `.#checks.aarch64-linux.smoke` on `aarch64-linux`. Only when both pass does it open a pull request and merge it into `main` straight away. A failing check leaves `main` untouched and the run red.

**Mutable `latest` URL and hash-mismatch window:** Upstream only serves `.deb` packages at the mutable `.../LTS/latest/aws-emulator_{amd64,arm64}.deb` URLs (versioned paths return HTTP 403), and this repository does not re-host the binaries. When upstream publishes a new release at `latest`, fresh builds without the previous `.deb` already in `/nix/store` will fail with a fixed-output derivation hash mismatch until the next weekly update lands. Upstream moves `latest` often (twice on 2026-11-13), so expect this between weekly runs. To fix it sooner, run the workflow by hand: **Actions → Update → Run workflow**, or `gh workflow run update.yml -R olafkfreund/nix-aws-emulator`.

**Why no required status checks are configured on `main`:** Update pull requests are opened using the repository's `GITHUB_TOKEN`, and GitHub Actions does not trigger `pull_request` workflows (`ci.yml`) on events created by `GITHUB_TOKEN`. Because `update.yml` already runs both the `x86_64-linux` flake check (including the VM test) and the `aarch64-linux` smoke check before creating the PR, `main` does not configure required status checks that would otherwise block merging update PRs.

## Licences

- **This repository (`nix-aws-emulator`):** [MIT](LICENSE) (covers the Nix expressions, modules, scripts, tests, and workflows in this repository only).
- **AWS Emulator binary:** Upstream `aws-emulator` is released under `CC0-1.0` and bundles third-party crates whose notices are installed at `$out/share/doc/aws-emulator/THIRD_PARTY_LICENSES`.
  - These include permissive licences (`MIT`, `Apache-2.0`, `0BSD`, `BSD-2-Clause`, `BSD-3-Clause`, `ISC`, `Zlib`, `Unicode-3.0`, `BSL-1.0`, `Unlicense`, `MIT-0`, `CC0-1.0`, `PSF-2.0`, `bzip2-1.0.6`, `BlueOak-1.0.0`), `LGPL-3.0-only` (`malachite-*` crates), `CDLA-Permissive-2.0` (which has no matching entry in `nixpkgs` `lib.licenses`), and 4 crates with no declared licence in `THIRD_PARTY_LICENSES` (`mt19937`, `rustpython-doc`, `rustpython-pylib`, `syn-ext`).
  - `meta.license` in `pkgs/aws-emulator/package.nix` is static and is not recomputed automatically by `scripts/update.sh`.

## Troubleshooting

- **Port already in use:** Change `services.aws-emulator.port` (or pass `-p <port>` on the CLI) and inspect what is bound to the port:

```bash
ss -tlnp | grep 9297
```

- **Inspect service logs:** Check the systemd journal for startup errors or verify that `telemetry: disabled` is logged:

```bash
journalctl -u aws-emulator -e
```

- **Health check via `curl`:** The emulator speaks HTTPS with its self-signed certificate; probe `/__admin/health` with `-k` (or `--cacert`):

```bash
curl -sfk https://127.0.0.1:9297/__admin/health
```

- **Permission denied on `/run/aws-emulator/.aws/emulator/<port>/...`:**
  1. Ensure your user is in `services.aws-emulator.group` (`aws-emulator` by default) and that your current login session has that group (`id -nG`).
  2. Wait until `aws-emulator.service` is `active`; the binary creates files with mode `0600` in a `0700` directory, and `ExecStartPost` applies `chmod -R g+rX /run/aws-emulator/.aws` only after `/__admin/health` returns `200` and `config` exists:

```bash
systemctl is-active aws-emulator.service
id -nG
```

- **Hash mismatch when building `aws-emulator`:** Upstream updated the file at the mutable `latest` URL after the commit you are building. (The updater also catches upstream republishing the same version with new bytes.) Update your flake input to the latest `main` commit (or trigger the update workflow by hand, or run `scripts/update.sh` locally):

```bash
nix flake update aws-emulator
```

## Development

Run the full flake check suite (formatting check, sandbox smoke test, and on `x86_64-linux` the NixOS + Home Manager VM test):

```bash
nix flake check -L
```

Format all `.nix` files with `nixfmt`:

```bash
nix fmt
```

Run the updater script locally from the repository root:

```bash
nix shell nixpkgs#curl nixpkgs#jq nixpkgs#gnupg nixpkgs#dpkg -c bash scripts/update.sh
```
