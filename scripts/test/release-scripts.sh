#!/usr/bin/env bash
# Tests of scripts/release-kind.sh and scripts/homebrew-formula.sh.
# Run: bash scripts/test/release-scripts.sh
set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
failures=0
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

kind() {
	local got
	got=$(sh "$here/release-kind.sh" "$1")
	[ "$got" = "$2" ] || fail "release-kind $1: got '$got', want '$2'"
}
kind v2.4.0 stable
kind v2.4.0-pf.1 stable
kind v2.4.0-pf.12 stable
kind v2.4.0-rc.1 prerelease
kind v2.4.0-pf.1-rc.1 prerelease
kind v2.4.0-pf. prerelease

assets=$(mktemp -d)
for f in cribelo_Darwin_arm64 cribelo_Darwin_x86_64 cribelo_Linux_arm64 cribelo_Linux_x86_64; do
	echo "$f" >"$assets/$f"
done
formula=$(sh "$here/homebrew-formula.sh" v2.4.0-pf.1 "$assets")
expect() { grep -qF -- "$1" <<<"$formula" || fail "formula: '$1' missing"; }
expect 'homepage "https://github.com/payfacto/cribelo"'
expect 'version "2.4.0-pf.1"'
expect 'url "https://github.com/payfacto/cribelo/releases/download/v2.4.0-pf.1/cribelo_Darwin_arm64"'
expect "sha256 \"$(sha256sum "$assets/cribelo_Darwin_arm64" | cut -d' ' -f1)\""
grep -q 'github.com/cribelo/' <<<"$formula" && fail "formula still points at upstream"

if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "ok"
