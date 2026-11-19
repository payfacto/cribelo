package cli

import (
	"os/exec"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// gitRun runs git in a directory and returns what it prints.
func gitRun(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@example.org", "-c", "commit.gpgsign=false"}, args...)...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	require.NoError(t, err, string(out))
	return strings.TrimSpace(string(out))
}

// bitbucketRemote is a clone of a repository with a main branch and a
// pull request branch feat/one two commits ahead, as on Bitbucket Cloud:
// no ref per pull request.
func bitbucketRemote(t *testing.T) (clone, first, tip string) {
	t.Helper()
	server := t.TempDir()
	gitRun(t, server, "init", "-q", "-b", "main")
	gitRun(t, server, "commit", "-q", "--allow-empty", "-m", "base")
	gitRun(t, server, "checkout", "-q", "-b", "feat/one")
	gitRun(t, server, "commit", "-q", "--allow-empty", "-m", "one")
	first = gitRun(t, server, "rev-parse", "HEAD")
	gitRun(t, server, "commit", "-q", "--allow-empty", "-m", "two")
	tip = gitRun(t, server, "rev-parse", "HEAD")
	gitRun(t, server, "checkout", "-q", "main")
	clone = t.TempDir()
	gitRun(t, clone, "clone", "-q", "--no-local", "--single-branch", "-b", "main", server, ".")
	return clone, first, tip
}

func TestFetchPullsReadsBitbucketHeadsFromTheirBranch(t *testing.T) {
	clone, first, tip := bitbucketRemote(t)
	site := forge{Kind: bitbucket, Remote: "origin"}
	pulls := []pullRequest{
		{Number: 1, HeadRefOid: tip[:12], HeadRefName: "feat/one", BaseRefName: "main"},
		{Number: 2, HeadRefOid: first[:12], HeadRefName: "feat/one", BaseRefName: "main"},
		{Number: 3, HeadRefOid: "0123456789ab", HeadRefName: "feat/one", BaseRefName: "main"},
	}

	unfetched := fetchPulls(clone, site, pulls)

	assert.Equal(t, map[int]string{3: "its commit is no longer on its branch"}, unfetched)
	assert.Equal(t, tip, pulls[0].HeadRefOid, "the short hash of Bitbucket is read as the full one")
	assert.Equal(t, first, pulls[1].HeadRefOid, "the branch moved on: the commit the API named is planned")
	assert.Equal(t, tip, gitRun(t, clone, "rev-parse", "refs/cribelo/pull/1"))
}

func TestFetchPullsTellsABitbucketBranchThatIsGone(t *testing.T) {
	clone, _, tip := bitbucketRemote(t)
	site := forge{Kind: bitbucket, Remote: "origin"}
	pulls := []pullRequest{
		{Number: 1, HeadRefOid: tip[:12], HeadRefName: "feat/one", BaseRefName: "main"},
		{Number: 4, HeadRefOid: "0123456789ab", HeadRefName: "feat/deleted", BaseRefName: "main"},
	}

	unfetched := fetchPulls(clone, site, pulls)

	assert.Equal(t, map[int]string{4: "its branch is gone from origin"}, unfetched)
	assert.Equal(t, tip, pulls[0].HeadRefOid)
}
