#!/bin/sh
# Writes DIR/SHA256SUMS: the SHA-256 of every other file of DIR, in the format
# of sha256sum -c. Every download of a release (install.sh, action.yml, the CI
# templates) checks the file it got against this list.
# Usage: release-checksums.sh DIR
set -eu

cd "$1"
rm -f SHA256SUMS
sums=$(mktemp)
for f in *; do
  [ -f "$f" ] || continue
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$f"; else shasum -a 256 -- "$f"; fi
done >"$sums"
mv "$sums" SHA256SUMS
