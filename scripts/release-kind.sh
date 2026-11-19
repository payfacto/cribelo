#!/bin/sh
# Prints "stable" or "prerelease" for a release tag. A tag with a dash is a
# pre-release, except the releases of the PayFacto fork: v2.4.0-pf.1 is
# stable, v2.4.0-pf.1-rc.1 is not.
#   scripts/release-kind.sh v2.4.0-pf.1
set -eu

case "$1" in
	*-pf.*-*) echo prerelease ;;
	*-pf.[0-9]*)
		suffix="${1##*-pf.}"
		case "$suffix" in *[!0-9]*) echo prerelease ;; *) echo stable ;; esac
		;;
	*-*) echo prerelease ;;
	*) echo stable ;;
esac
