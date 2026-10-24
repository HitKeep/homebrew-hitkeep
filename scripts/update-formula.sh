#!/usr/bin/env bash
set -euo pipefail

tag="${1:-}"
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 vMAJOR.MINOR.PATCH" >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
formula="$root/Formula/hitkeep.rb"
url="https://github.com/HitKeep/hitkeep/archive/refs/tags/${tag}.tar.gz"
checksum="$(curl --fail --silent --show-error --location "$url" | shasum -a 256 | awk '{print $1}')"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

awk -v url="$url" -v checksum="$checksum" '
  /^  url "/ { print "  url \"" url "\""; urls++; next }
  /^  sha256 "/ { print "  sha256 \"" checksum "\""; checksums++; next }
  { print }
  END { if (urls != 1 || checksums != 1) exit 1 }
' "$formula" > "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$formula"
trap - EXIT
