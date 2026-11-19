#!/bin/sh
# Strips .context/ from the history and pushes main, and the current tag, to
# the public GitHub mirror payfacto/cribelo. Run by bitbucket-pipelines.yml in
# a full clone; see the notes there (pinned filter-repo, explicit refspecs).
set -eu

apk add --no-cache git openssh-client >/dev/null
# Pinned by version and by checksum: this runs with the deploy key.
filter_repo_sha256=67447413e273fc76809289111748870b6f6072f08b17efe94863a92d810b7d94
wget -qO /usr/local/bin/git-filter-repo https://raw.githubusercontent.com/newren/git-filter-repo/v2.47.0/git-filter-repo
echo "$filter_repo_sha256  /usr/local/bin/git-filter-repo" | sha256sum -c -
chmod +x /usr/local/bin/git-filter-repo
git filter-repo --version

# Branches and tags exist locally before the rewrite: a tag build checks out
# a detached tag, so refs/heads/main may not exist yet.
git fetch --tags --force origin "+refs/heads/*:refs/remotes/origin/*"

# filter-repo removes origin and turns refs/remotes/origin/* into
# refs/heads/*: nothing below may use origin or refs/remotes/*.
git filter-repo --force --invert-paths --path .context

# Fail closed: never push a tree that still carries .context.
if [ -n "$(git log --all --oneline -- .context)" ]; then
	echo "FATAL - .context survived the rewrite"
	exit 1
fi
if git rev-list --all --objects | grep -q '\.context/'; then
	echo "FATAL - .context blob still referenced"
	exit 1
fi

mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keyscan -t rsa,ecdsa,ed25519 github.com >>~/.ssh/known_hosts 2>/dev/null
git remote add github git@github.com:payfacto/cribelo.git

# Explicit refspecs only: never --mirror (refs/replace/*), never --tags
# (upstream's tags).
git push github refs/heads/main:refs/heads/main --force
if [ -n "${BITBUCKET_TAG:-}" ]; then
	git push github "refs/tags/$BITBUCKET_TAG:refs/tags/$BITBUCKET_TAG"
fi
