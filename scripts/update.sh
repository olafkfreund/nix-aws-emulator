#!/usr/bin/env bash
set -euo pipefail

# Run from the repo root with: nix shell nixpkgs#curl nixpkgs#jq nixpkgs#gnupg nixpkgs#dpkg -c bash scripts/update.sh

PINNED_FPR=98BCF336A3BE53B734E967C52E5BF49BD940F624
SRC=pkgs/aws-emulator/sources.json

out() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
  fi
}

curl_args=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  curl_args=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi
tag=$(curl -fsSL "${curl_args[@]}" https://api.github.com/repos/aws/aws-emulator/releases/latest | jq -r .tag_name)
new=${tag#v}
old=$(jq -r .version "$SRC")

if [[ "$new" == "$old" ]]; then
  out changed=false
  out "version=$old"
  echo "up to date: $old"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -m 700 "$tmp/gnupg"
gpg --batch --homedir "$tmp/gnupg" --dearmor < keys/aws-publishing.asc > "$tmp/aws.gpg"

declare -A hashes sigHashes
for pair in amd64:x86_64-linux arm64:aarch64-linux; do
  arch=${pair%%:*}
  sys=${pair#*:}
  url=$(jq -r ".\"$sys\".url" "$SRC")
  deb="$tmp/aws-emulator_$arch.deb"
  sig="$deb.sig"
  curl -fsSL "$url" -o "$deb"
  curl -fsSL "$url.sig" -o "$sig"

  if ! gpgv --homedir "$tmp/gnupg" --keyring "$tmp/aws.gpg" --status-fd 3 "$sig" "$deb" 3>"$tmp/status-$arch" 2>/dev/null; then
    echo "BAD signature for $arch" >&2
    exit 1
  fi
  if ! awk -v f="$PINNED_FPR" '$1=="[GNUPG:]" && $2=="VALIDSIG" && NF>=12 && $NF==f {ok=1} END{exit !ok}' "$tmp/status-$arch"; then
    echo "Unexpected signer for $arch" >&2
    exit 1
  fi

  v=$(dpkg-deb -f "$deb" Version)
  if [[ "$v" != "$new" && ! "$v" =~ ^"$new"-[0-9]+$ ]]; then
    echo "Unexpected package version for $arch: $v" >&2
    exit 1
  fi

  hashes[$sys]=$(nix hash file --sri "$deb")
  sigHashes[$sys]=$(nix hash file --sri "$sig")
  nix store add-file "$deb" >/dev/null
done

jq --arg version "$new" --arg signer "$PINNED_FPR" \
  --arg xhash "${hashes[x86_64-linux]}" --arg xsig "${sigHashes[x86_64-linux]}" \
  --arg ahash "${hashes[aarch64-linux]}" --arg asig "${sigHashes[aarch64-linux]}" \
  '.version = $version | .signer = $signer | ."x86_64-linux".hash = $xhash | ."x86_64-linux".sigHash = $xsig | ."aarch64-linux".hash = $ahash | ."aarch64-linux".sigHash = $asig' \
  "$SRC" > "$SRC.tmp"
mv "$SRC.tmp" "$SRC"

echo "updated: $old -> $new"
out changed=true
out "old_version=$old"
out "version=$new"
