#!/usr/bin/env bash
# Tests of the downloads of a release: install.sh (which action.yml runs) and
# the Bitbucket CI template, with a fake curl that serves a fake release. Every
# download comes from payfacto/cribelo and is checked against its SHA256SUMS.
# Run: bash scripts/test/downloads.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
failures=0
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# setup builds a sandbox: a fake release in $release, served by a fake curl
# that logs each URL; FAKE_TAMPER names an asset served with other bytes.
setup() {
	sandbox=$(mktemp -d)
	release="$sandbox/release"
	mkdir -p "$sandbox/bin" "$release" "$sandbox/install"
	for f in cribelo_Linux_x86_64 cribelo_Linux_arm64 cribelo_Darwin_arm64 cribelo_Darwin_x86_64; do
		printf '#!/bin/sh\necho "cribelo 9.9.9"\n' >"$release/$f"
	done
	printf 'echo RAN-PR-COMMENT\n' >"$release/bitbucket-pr-comment.sh"
	sh "$root/scripts/release-checksums.sh" "$release"
	cat >"$sandbox/bin/curl" <<'FAKE'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift ;; -*) ;; *) url=$1 ;; esac
  shift
done
echo "$url" >>"$SANDBOX/urls"
name=${url##*/}
[ -f "$RELEASE/$name" ] || exit 22
if [ "$name" = "${FAKE_TAMPER:-}" ]; then echo tampered >"$out"; else cp "$RELEASE/$name" "$out"; fi
FAKE
	printf '#!/bin/sh\nexit 0\n' >"$sandbox/bin/apt-get"
	printf '#!/bin/sh\nexit 0\n' >"$sandbox/bin/git"
	chmod +x "$sandbox/bin/"*
	: >"$sandbox/urls"
	export PATH="$sandbox/bin:$PATH" SANDBOX="$sandbox" RELEASE="$release"
	unset FAKE_TAMPER CRIBELO_VERSION CRIBELO_DOWNLOAD_URL
}
urls() { cat "$sandbox/urls"; }

install() { CRIBELO_INSTALL_DIR="$sandbox/install" sh "$root/install.sh" >"$sandbox/out" 2>&1; }

setup
install || fail "install.sh: exit $?, $(cat "$sandbox/out")"
[ -x "$sandbox/install/cribelo" ] || fail "install.sh: nothing installed"
grep -q "https://github.com/payfacto/cribelo/releases/latest/download/SHA256SUMS" "$sandbox/urls" || fail "install.sh: no SHA256SUMS from payfacto/cribelo: $(urls)"
grep -q "github.com/cribelo/" "$sandbox/urls" && fail "install.sh: downloads from upstream: $(urls)"

setup
CRIBELO_VERSION=2.4.0-pf.3 install || fail "install.sh pinned: exit $?"
grep -q "releases/download/v2.4.0-pf.3/SHA256SUMS" "$sandbox/urls" || fail "install.sh pinned: $(urls)"

setup
case "$(uname -m)" in aarch64 | arm64) host_arch=arm64 ;; *) host_arch=x86_64 ;; esac
export FAKE_TAMPER="cribelo_$(uname -s)_$host_arch"
install && fail "install.sh installs a binary that does not match SHA256SUMS"
[ -e "$sandbox/install/cribelo" ] && fail "install.sh: a tampered binary is installed"

setup
rm "$release/SHA256SUMS"
install && fail "install.sh installs without SHA256SUMS"
[ -e "$sandbox/install/cribelo" ] && fail "install.sh: installed without SHA256SUMS"

setup
grep -v "cribelo_$(uname -s)_$host_arch" "$release/SHA256SUMS" >"$release/sums" && mv "$release/sums" "$release/SHA256SUMS"
install && fail "install.sh installs a binary SHA256SUMS does not list"

# The Bitbucket template: its script block, run with /usr/local/bin and the
# working directory moved into the sandbox.
bitbucket() {
	awk '/^          - \|$/ {on=1; next} /^        artifacts:/ {on=0} on' "$root/ci/bitbucket-pipelines.yml" \
		| sed -e 's/^            //' -e "s#/usr/local/bin#$sandbox/install#g" >"$sandbox/step.sh"
	BITBUCKET_CLONE_DIR="$sandbox" bash "$sandbox/step.sh" >"$sandbox/out" 2>&1
}

setup
bitbucket || fail "bitbucket: exit $?, $(cat "$sandbox/out")"
grep -q RAN-PR-COMMENT "$sandbox/out" || fail "bitbucket: the script did not run: $(cat "$sandbox/out")"
[ -x "$sandbox/install/cribelo" ] || fail "bitbucket: cribelo not installed"
grep -q "releases/latest/download/bitbucket-pr-comment.sh" "$sandbox/urls" || fail "bitbucket: script not from the release: $(urls)"
grep -q "raw.githubusercontent.com" "$sandbox/urls" && fail "bitbucket: script read from a branch: $(urls)"

setup
export FAKE_TAMPER=bitbucket-pr-comment.sh
bitbucket && fail "bitbucket: a tampered script passes"
grep -q RAN-PR-COMMENT "$sandbox/out" && fail "bitbucket: a tampered script ran"

setup
export FAKE_TAMPER=cribelo_Linux_x86_64
bitbucket && fail "bitbucket: a tampered binary passes"
grep -q RAN-PR-COMMENT "$sandbox/out" && fail "bitbucket: ran with a tampered binary"

setup
rm "$release/SHA256SUMS"
bitbucket || fail "bitbucket: a release without SHA256SUMS must skip, not fail: exit $?"
grep -q RAN-PR-COMMENT "$sandbox/out" && fail "bitbucket: ran without SHA256SUMS"

# Every download of a template comes from payfacto/cribelo and is checked.
for f in action.yml install.sh ci/gitlab-ci.yml ci/bitbucket-pipelines.yml; do
	grep -q "github.com/cribelo/cribelo/releases\|raw.githubusercontent.com/cribelo/cribelo/.*install" "$root/$f" && fail "$f downloads from upstream"
done
grep -q "SHA256SUMS" "$root/ci/gitlab-ci.yml" || fail "gitlab-ci.yml does not check SHA256SUMS"
grep -q "install.sh" "$root/action.yml" || fail "action.yml does not install with the checked install.sh"

if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "ok"
