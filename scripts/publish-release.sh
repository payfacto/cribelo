#!/bin/sh
# Publishes the release of TAG with every file of DIR and their SHA256SUMS.
# The release is created as a draft with all its assets, then published in one
# step: with release immutability on, nothing can be added or replaced after.
# A published release is never touched again; a draft left by a failed run is
# deleted and built again. Needs gh with GH_TOKEN (contents: write).
# Usage: publish-release.sh TAG DIR
set -eu

tag=$1 dir=$2
here=$(cd "$(dirname "$0")" && pwd)

if draft=$(gh release view "$tag" --json isDraft --jq .isDraft 2>/dev/null); then
  if [ "$draft" != true ]; then
    echo "release $tag is already published: its assets are not replaced, push a new tag" >&2
    exit 1
  fi
  gh release delete "$tag" --yes
fi

sh "$here/release-checksums.sh" "$dir"
set -- "$dir"/*
if [ "$(sh "$here/release-kind.sh" "$tag")" = prerelease ]; then set -- --prerelease "$@"; fi
gh release create "$tag" --draft --verify-tag --title "$tag" --generate-notes "$@"
gh release edit "$tag" --draft=false
