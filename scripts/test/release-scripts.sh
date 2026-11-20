#!/usr/bin/env bash
# Tests of scripts/release-kind.sh, scripts/homebrew-formula.sh,
# scripts/release-checksums.sh and scripts/publish-release.sh (with a fake gh).
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

# release-checksums.sh: one line per asset, in sha256sum -c format, not itself.
sums_dir=$(mktemp -d)
printf 'linux' >"$sums_dir/cribelo_Linux_x86_64"
printf 'windows' >"$sums_dir/cribelo_Windows_x86_64.exe"
sh "$here/release-checksums.sh" "$sums_dir" || fail "release-checksums: exit $?"
[ "$(wc -l <"$sums_dir/SHA256SUMS")" -eq 2 ] || fail "SHA256SUMS: want 2 lines, got $(cat "$sums_dir/SHA256SUMS")"
(cd "$sums_dir" && sha256sum -c --quiet SHA256SUMS) || fail "SHA256SUMS does not verify"
grep -q 'SHA256SUMS$' "$sums_dir/SHA256SUMS" && fail "SHA256SUMS lists itself"
sh "$here/release-checksums.sh" "$sums_dir" && [ "$(wc -l <"$sums_dir/SHA256SUMS")" -eq 2 ] \
	|| fail "a second run lists SHA256SUMS"

# publish-release.sh with a fake gh. FAKE_RELEASE is the state of the
# release: empty (none), true (a draft) or false (published).
fake=$(mktemp -d)
cat >"$fake/gh" <<'FAKE'
#!/usr/bin/env bash
echo "gh $*" >>"$FAKE_CALLS"
case "$*" in
  "release view"*) [ -n "${FAKE_RELEASE:-}" ] || exit 1; echo "$FAKE_RELEASE" ;;
esac
FAKE
chmod +x "$fake/gh"
publish() {
	FAKE_CALLS="$fake/calls"; : >"$FAKE_CALLS"
	out_dir=$(mktemp -d)
	printf 'bin' >"$out_dir/cribelo_Linux_x86_64"
	PATH="$fake:$PATH" FAKE_CALLS="$FAKE_CALLS" FAKE_RELEASE="$1" \
		sh "$here/publish-release.sh" "$2" "$out_dir" >"$fake/out" 2>&1
}
calls() { cat "$fake/calls"; }

publish "" v2.4.0-pf.3 || fail "publish new: exit $?, $(cat "$fake/out")"
grep -q -- "release create v2.4.0-pf.3 --draft --verify-tag" "$fake/calls" || fail "not created as a draft: $(calls)"
grep -q -- "cribelo_Linux_x86_64" "$fake/calls" || fail "asset not attached: $(calls)"
grep -q -- "SHA256SUMS" "$fake/calls" || fail "SHA256SUMS not attached: $(calls)"
grep -q -- "--prerelease" "$fake/calls" && fail "a stable tag is a pre-release"
[ "$(tail -n1 "$fake/calls")" = "gh release edit v2.4.0-pf.3 --draft=false" ] || fail "not published last: $(calls)"
grep -q -- "--clobber\|release upload" "$fake/calls" && fail "assets uploaded to an existing release"

publish "" v2.4.0-rc.1 || fail "publish rc: exit $?"
grep -q -- "--prerelease" "$fake/calls" || fail "an rc tag is not a pre-release: $(calls)"

publish false v2.4.0-pf.3 && fail "a published release is replaced"
grep -q "release create\|release edit\|release delete" "$fake/calls" && fail "a published release was changed: $(calls)"

publish true v2.4.0-pf.3 || fail "draft left by a failed run: exit $?"
grep -q "release delete v2.4.0-pf.3 --yes" "$fake/calls" || fail "the old draft is not removed: $(calls)"

if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "ok"
