#!/bin/sh
# Installs the latest cribelo release of the PayFacto fork into /usr/local/bin,
# or ~/.local/bin when /usr/local/bin is not writable. CRIBELO_VERSION=2.4.0-pf.4
# pins a version, CRIBELO_INSTALL_DIR=/some/dir chooses the destination. The
# binary is installed only when it matches the SHA256SUMS of its release.
set -eu

repo="payfacto/cribelo"
os=$(uname -s)
case "$os" in
  Linux) os=Linux ;;
  Darwin) os=Darwin ;;
  MINGW*|MSYS*|CYGWIN*) os=Windows ;;
  *) echo "cribelo: unsupported OS $os" >&2; exit 1 ;;
esac
arch=$(uname -m)
case "$arch" in
  x86_64|amd64) arch=x86_64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "cribelo: unsupported architecture $arch" >&2; exit 1 ;;
esac

name="cribelo_${os}_${arch}"
[ "$os" = Windows ] && name="$name.exe"
if [ -n "${CRIBELO_VERSION:-}" ]; then
  base="https://github.com/$repo/releases/download/v${CRIBELO_VERSION#v}"
else
  base="https://github.com/$repo/releases/latest/download"
fi

dir="${CRIBELO_INSTALL_DIR:-}"
if [ -z "$dir" ]; then
  if [ -w /usr/local/bin ]; then dir=/usr/local/bin; else dir="$HOME/.local/bin"; fi
fi
mkdir -p "$dir"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Downloading $base/$name"
curl -fsSL "$base/$name" -o "$tmp/$name"
if ! curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"; then
  echo "cribelo: this release has no SHA256SUMS (releases before 2.4.0-pf.3 have none): set CRIBELO_VERSION to a newer one" >&2
  exit 1
fi
want=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1; exit }' "$tmp/SHA256SUMS")
got=$(sha256 "$tmp/$name")
if [ -z "$want" ] || [ "$got" != "$want" ]; then
  echo "cribelo: $name does not match the SHA256SUMS of its release, not installed" >&2
  exit 1
fi
chmod +x "$tmp/$name"
mv "$tmp/$name" "$dir/cribelo"

echo "Installed $("$dir/cribelo" --version) in $dir"
cmd=cribelo
case ":$PATH:" in
  *":$dir:"*) ;;
  *) cmd="$dir/cribelo"; echo "$dir is not in your PATH: add it, or use the full path below." ;;
esac

cat <<EOF

Now go to a repository, check out the branch you want reviewed, and run:

  $cmd

Short on time? $cmd --budget 30m
EOF
