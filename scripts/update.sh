#!/usr/bin/env bash
set -euo pipefail

# Run from the repo root with: nix shell nixpkgs#curl nixpkgs#jq nixpkgs#gnupg nixpkgs#dpkg -c bash scripts/update.sh
#
# The signed .deb served at the LTS "latest" URL is the source of truth for the
# version: GitHub releases are published more often than the LTS packages move,
# so the GitHub tag can't be used to decide what to pin.

PINNED_FPR=98BCF336A3BE53B734E967C52E5BF49BD940F624
SRC=pkgs/aws-emulator/sources.json

out() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
  fi
}

old=$(jq -r .version "$SRC")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -m 700 "$tmp/gnupg"
gpg --batch --homedir "$tmp/gnupg" --dearmor < keys/aws-publishing.asc > "$tmp/aws.gpg"

declare -A hashes sigHashes versions
for pair in amd64:x86_64-linux arm64:aarch64-linux; do
  arch=${pair%%:*}
  sys=${pair#*:}
  url=$(jq -r ".\"$sys\".url" "$SRC")
  # Name must equal the URL's basename so `nix store add-file` matches fetchurl's store path.
  deb="$tmp/aws-emulator_$arch.deb"
  sig="$deb.sig"
  curl -fsSL "$url" -o "$deb"
  curl -fsSL "$url.sig" -o "$sig"

  if ! gpgv --homedir "$tmp/gnupg" --keyring "$tmp/aws.gpg" --status-fd 3 "$sig" "$deb" 3>"$tmp/status-$arch" 2>/dev/null; then
    echo "BAD signature for $arch" >&2
    exit 1
  fi
  # Field 12 of VALIDSIG is the primary-key fingerprint.
  if ! awk -v f="$PINNED_FPR" '$1=="[GNUPG:]" && $2=="VALIDSIG" && NF>=12 && $12==f {ok=1} END{exit !ok}' "$tmp/status-$arch"; then
    echo "Unexpected signer for $arch" >&2
    exit 1
  fi

  a=$(dpkg-deb -f "$deb" Architecture)
  if [[ "$a" != "$arch" ]]; then
    echo "Unexpected package architecture for $arch: $a" >&2
    exit 1
  fi

  v=$(dpkg-deb -f "$deb" Version)
  if [[ ! "$v" =~ ^([0-9]+(\.[0-9]+)*)(-[0-9]+)?$ ]]; then
    echo "Unexpected package version for $arch: $v" >&2
    exit 1
  fi
  versions[$sys]=${BASH_REMATCH[1]}

  hashes[$sys]=$(nix hash file --sri "$deb")
  sigHashes[$sys]=$(nix hash file --sri "$sig")
done

new=${versions[x86_64-linux]}
if [[ "${versions[aarch64-linux]}" != "$new" ]]; then
  # Upstream is probably mid-publish; try again on the next run.
  echo "upstream versions differ (amd64 $new, arm64 ${versions[aarch64-linux]}); not updating" >&2
  out changed=false
  out "version=$old"
  exit 0
fi

same_bytes=$(jq -r --arg xh "${hashes[x86_64-linux]}" --arg ah "${hashes[aarch64-linux]}" \
  '(."x86_64-linux".hash == $xh) and (."aarch64-linux".hash == $ah)' "$SRC")

if [[ "$new" == "$old" && "$same_bytes" == "true" ]]; then
  out changed=false
  out "version=$old"
  echo "up to date: $old"
  exit 0
fi

# Refuse downgrades: only move forward (a same-version republish is allowed).
if [[ "$(printf '%s\n' "$old" "$new" | sort -V | tail -1)" != "$new" ]]; then
  echo "upstream $new is older than pinned $old; refusing to downgrade" >&2
  exit 1
fi

for arch in amd64 arm64; do
  nix store add-file "$tmp/aws-emulator_$arch.deb" >/dev/null
done

jq --arg version "$new" --arg signer "$PINNED_FPR" \
  --arg xhash "${hashes[x86_64-linux]}" --arg xsig "${sigHashes[x86_64-linux]}" \
  --arg ahash "${hashes[aarch64-linux]}" --arg asig "${sigHashes[aarch64-linux]}" \
  '.version = $version | .signer = $signer | ."x86_64-linux".hash = $xhash | ."x86_64-linux".sigHash = $xsig | ."aarch64-linux".hash = $ahash | ."aarch64-linux".sigHash = $asig' \
  "$SRC" > "$SRC.tmp"
mv "$SRC.tmp" "$SRC"

if [[ "$new" == "$old" ]]; then
  echo "republished: $new (same version, new bytes)"
else
  echo "updated: $old -> $new"
fi
out changed=true
out "old_version=$old"
out "version=$new"
