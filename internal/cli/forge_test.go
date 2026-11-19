package cli

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestParseRemote(t *testing.T) {
	for address, want := range map[string][2]string{
		"git@github.com:cribelo/cribelo.git":                {"github.com", "cribelo/cribelo"},
		"https://gitlab.com/group/sub/project.git":          {"gitlab.com", "group/sub/project"},
		"https://oauth2:secret@gitlab.com/group/project":    {"gitlab.com", "group/project"},
		"ssh://git@git.example.org:2222/group/project.git":  {"git.example.org", "group/project"},
		"git@gitlab.example.org:group/sub/project.git":      {"gitlab.example.org", "group/sub/project"},
		"git@bitbucket.org:payfactopay/cribelo.git":         {"bitbucket.org", "payfactopay/cribelo"},
		"git@ssh.bitbucket.org:payfactopay/cribelo.git":     {"ssh.bitbucket.org", "payfactopay/cribelo"},
		"https://jay@bitbucket.org/payfactopay/cribelo.git": {"bitbucket.org", "payfactopay/cribelo"},
		"/srv/git/project.git":                              {"", ""},
		"../project":                                        {"", ""},
	} {
		host, path := parseRemote(address)
		assert.Equal(t, want, [2]string{host, path}, address)
	}
}

// remotes is a repository with the given remotes, name then address.
func remotes(t *testing.T, pairs ...string) string {
	t.Helper()
	root := t.TempDir()
	run := func(args ...string) {
		cmd := exec.Command("git", args...)
		cmd.Dir = root
		out, err := cmd.CombinedOutput()
		require.NoError(t, err, string(out))
	}
	run("init", "-q")
	for i := 0; i+1 < len(pairs); i += 2 {
		run("remote", "add", pairs[i], pairs[i+1])
	}
	return root
}

func TestDetectForge(t *testing.T) {
	site, err := detectForge(remotes(t, "origin", "git@gitlab.com:group/sub/project.git"), "")
	require.NoError(t, err)
	assert.Equal(t, forge{Kind: gitlab, Remote: "origin", Host: "gitlab.com", Project: "group/sub/project"}, site)
	assert.Equal(t, "refs/merge-requests/7/head", site.headRef(pullRequest{Number: 7}))
	assert.Equal(t, "projects/group%2Fsub%2Fproject/merge_requests", site.endpoint("merge_requests"))

	site, err = detectForge(remotes(t, "origin", "git@github.com:cribelo/cribelo.git"), "")
	require.NoError(t, err)
	assert.Equal(t, github, site.Kind)
	assert.Equal(t, "refs/pull/7/head", site.headRef(pullRequest{Number: 7}))

	for _, address := range []string{"git@bitbucket.org:payfactopay/cribelo.git", "git@ssh.bitbucket.org:payfactopay/cribelo.git", "https://bitbucket.org/payfactopay/cribelo.git"} {
		site, err = detectForge(remotes(t, "origin", address), "")
		require.NoError(t, err, address)
		assert.Equal(t, bitbucket, site.Kind, address)
		assert.Equal(t, "payfactopay/cribelo", site.Project, address)
	}
	assert.Equal(t, "refs/heads/feat/one", site.headRef(pullRequest{Number: 7, HeadRefName: "feat/one"}), "Bitbucket Cloud has no ref per pull request")
	assert.Equal(t, "pull request", site.noun())
	assert.Equal(t, "#", site.sign())

	// A fork on a host that says nothing, the project on GitLab.
	site, err = detectForge(remotes(t, "origin", "/srv/git/fork.git", "upstream", "https://gitlab.com/group/project.git"), "")
	require.NoError(t, err)
	assert.Equal(t, "upstream", site.Remote)
	assert.Equal(t, gitlab, site.Kind)

	// A self-hosted instance under a name of its own.
	tools := map[string]bool{}
	previous := loggedIn
	loggedIn = func(tool, host string) bool { return tools[tool] }
	t.Cleanup(func() { loggedIn = previous })
	t.Setenv("GITLAB_HOST", "")
	t.Setenv("GL_HOST", "")
	selfHostedGitLab := forge{Kind: gitlab, Remote: "origin", Host: "git.example.org", Project: "group/project"}
	root := remotes(t, "origin", "git@git.example.org:group/project.git")

	_, err = detectForge(root, "")
	assert.ErrorContains(t, err, "cannot tell whether git.example.org is a GitHub or a GitLab")

	// A Bitbucket Data Center is not Bitbucket Cloud: its name alone says nothing.
	_, err = detectForge(remotes(t, "origin", "git@bitbucket.example.org:group/project.git"), "")
	assert.ErrorContains(t, err, "cannot tell whether bitbucket.example.org")

	tools["glab"] = true
	site, err = detectForge(root, "")
	require.NoError(t, err)
	assert.Equal(t, selfHostedGitLab, site, "glab is the one installed")

	tools["gh"] = true
	site, err = detectForge(root, "")
	require.NoError(t, err)
	assert.Equal(t, github, site.Kind, "gh is logged in to that host")

	t.Setenv("GITLAB_HOST", "https://git.example.org")
	site, err = detectForge(root, "")
	require.NoError(t, err)
	assert.Equal(t, selfHostedGitLab, site, "the host glab is pointed at")
	t.Setenv("GITLAB_HOST", "")

	site, err = detectForge(root, "gitlab")
	require.NoError(t, err)
	assert.Equal(t, selfHostedGitLab, site)

	cmd := exec.Command("git", "config", "cribelo.forge", "gitlab")
	cmd.Dir = root
	require.NoError(t, cmd.Run())
	site, err = detectForge(root, "")
	require.NoError(t, err)
	assert.Equal(t, selfHostedGitLab, site, "the setting of the repository")
	site, err = detectForge(root, "github")
	require.NoError(t, err)
	assert.Equal(t, github, site.Kind, "the option wins over the setting")

	_, err = detectForge(root, "gitea")
	assert.ErrorContains(t, err, "unknown forge \"gitea\" (github, gitlab or bitbucket)")

	site, err = detectForge(root, "bitbucket")
	require.NoError(t, err)
	assert.Equal(t, bitbucket, site.Kind, "the option names Bitbucket")

	site, err = detectForge(remotes(t), "")
	require.NoError(t, err)
	assert.Equal(t, forge{Kind: github, Remote: "origin"}, site)
}

// fakeGlab puts on the PATH a glab that logs its arguments and answers
// what the REST API of GitLab answers.
func fakeGlab(t *testing.T) (log string) {
	t.Helper()
	bin := t.TempDir()
	log = filepath.Join(bin, "calls")
	script := `#!/bin/sh
echo "$*" >> "` + log + `"
case "$*" in
  *" user"*) echo '{"id":1,"username":"ada"}' ;;
  *merge_requests/9*) echo '{"message":"404 Not found"}'; exit 1 ;;
  *merge_requests/*) echo '{"iid":4400,"title":"fix: one","web_url":"https://gitlab.com/group/project/-/merge_requests/4400","sha":"5eccbb9373f4e9c30f0eca591551e3961ce8f6ec","target_branch":"main","draft":false,"updated_at":"2026-11-12T03:08:50.583Z","author":{"username":"grace"}}' ;;
  *merge_requests*) echo '[{"iid":4401,"title":"Draft: two","web_url":"https://gitlab.com/group/project/-/merge_requests/4401","sha":null,"target_branch":"main","draft":true,"updated_at":"2026-11-12T08:43:49.087Z","author":{"username":"linus"}},{"iid":4400,"title":"fix: one","web_url":"https://gitlab.com/group/project/-/merge_requests/4400","sha":"5eccbb9373f4e9c30f0eca591551e3961ce8f6ec","target_branch":"main","draft":false,"updated_at":"2026-11-12T03:08:50.583Z","author":{"username":"grace"}}]' ;;
esac
`
	require.NoError(t, os.WriteFile(filepath.Join(bin, "glab"), []byte(script), 0o755))
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	return log
}

func TestGitLabMergeRequestsAreReadAsPullRequests(t *testing.T) {
	log := fakeGlab(t)
	site := forge{Kind: gitlab, Remote: "origin", Host: "gitlab.com", Project: "group/project"}

	pulls, err := site.list(".", 500, false)
	require.NoError(t, err)
	require.Len(t, pulls, 2)
	assert.Equal(t, 4401, pulls[0].Number)
	assert.True(t, pulls[0].IsDraft)
	assert.Empty(t, pulls[0].HeadRefOid, "a merge request without a commit")
	want := pullRequest{Number: 4400, Title: "fix: one", URL: "https://gitlab.com/group/project/-/merge_requests/4400",
		HeadRefOid: "5eccbb9373f4e9c30f0eca591551e3961ce8f6ec", BaseRefName: "main", UpdatedAt: "2026-11-12T03:08:50.583Z"}
	want.Author.Login = "grace"
	assert.Equal(t, want, pulls[1])

	pull, id, err := site.view(".", 4400)
	require.NoError(t, err)
	assert.Equal(t, want, pull)
	assert.Empty(t, id)

	_, _, err = site.view(".", 9)
	assert.ErrorContains(t, err, "404 Not found")

	_, err = site.list(".", 20, true)
	require.NoError(t, err)

	calls, err := os.ReadFile(log)
	require.NoError(t, err)
	assert.Equal(t, []string{
		"api --hostname gitlab.com --method GET user",
		"api --hostname gitlab.com --method GET projects/group%2Fproject/merge_requests --raw-field state=opened --raw-field per_page=100 --raw-field reviewer_username=ada",
		"api --hostname gitlab.com --method GET projects/group%2Fproject/merge_requests/4400",
		"api --hostname gitlab.com --method GET projects/group%2Fproject/merge_requests/9",
		"api --hostname gitlab.com --method GET projects/group%2Fproject/merge_requests --raw-field state=opened --raw-field per_page=20",
	}, strings.Split(strings.TrimSpace(string(calls)), "\n"))
}

func TestForgeToolMissing(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	_, err := forge{Kind: gitlab}.list(".", 20, true)
	assert.ErrorContains(t, err, "inbox reads the merge requests with the GitLab command line: install glab")
	_, err = forge{Kind: bitbucket}.list(".", 20, true)
	assert.ErrorContains(t, err, "inbox reads the pull requests with the Bitbucket command line: install bb")
	_, _, err = forge{Kind: github}.view(".", 1)
	assert.ErrorContains(t, err, "pr reads the pull requests with the GitHub command line: install gh")
}

// fakeBb puts on the PATH a bb that logs its arguments and answers what
// bb answers on Bitbucket Cloud: JSON, and a JSON error object on failure.
func fakeBb(t *testing.T) (log string) {
	t.Helper()
	bin := t.TempDir()
	log = filepath.Join(bin, "calls")
	pull := func(id int, title, branch, hash string, draft bool, reviewer string) string {
		reviewers := "[]"
		if reviewer != "" {
			reviewers = `[{"account_id":"` + reviewer + `","nickname":"someone"}]`
		}
		return `{"id":` + strconv.Itoa(id) + `,"title":"` + title + `","draft":` + strconv.FormatBool(draft) +
			`,"updated_on":"2026-11-19T16:38:26.190323+00:00","author":{"account_id":"a1","nickname":"Ada"}` +
			`,"source":{"branch":{"name":"` + branch + `"},"commit":{"hash":"` + hash + `"}}` +
			`,"destination":{"branch":{"name":"main"},"commit":{"hash":"0123456789ab"}}` +
			`,"reviewers":` + reviewers +
			`,"links":{"html":{"href":"https://bitbucket.org/payfactopay/cribelo/pull-requests/` + strconv.Itoa(id) + `"}}}`
	}
	script := `#!/bin/sh
echo "$*" >> "` + log + `"
case "$*" in
  "user me"*) echo '{"account_id":"me-1","nickname":"Jay"}' ;;
  "pr list"*) echo '[` + pull(12, "feat: two", "feat/two", "e7026f3d39e9", true, "") + `,` + pull(11, "fix: one", "fix/one", "5eccbb9373f4", false, "") + `]' ;;
  "pr get --pr-id 12 "*) echo '` + pull(12, "feat: two", "feat/two", "e7026f3d39e9", true, "me-1") + `' ;;
  "pr get --pr-id 11 "*) echo '` + pull(11, "fix: one", "fix/one", "5eccbb9373f4", false, "other") + `' ;;
  "pr get"*) echo '{"error":{"code":"not_found","message":"HTTP 404: no such pull request"}}'; exit 1 ;;
esac
`
	require.NoError(t, os.WriteFile(filepath.Join(bin, "bb"), []byte(script), 0o755))
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	return log
}

func TestBitbucketPullRequestsAreReadWithBb(t *testing.T) {
	log := fakeBb(t)
	site := forge{Kind: bitbucket, Remote: "origin", Host: "bitbucket.org", Project: "payfactopay/cribelo"}

	all, err := site.list(".", 20, true)
	require.NoError(t, err)
	require.Len(t, all, 2)
	want := pullRequest{Number: 11, Title: "fix: one", URL: "https://bitbucket.org/payfactopay/cribelo/pull-requests/11",
		HeadRefOid: "5eccbb9373f4", HeadRefName: "fix/one", BaseRefName: "main", UpdatedAt: "2026-11-19T16:38:26.190323+00:00"}
	want.Author.Login = "Ada"
	assert.Equal(t, want, all[1])
	assert.True(t, all[0].IsDraft)

	limited, err := site.list(".", 1, true)
	require.NoError(t, err)
	assert.Len(t, limited, 1, "the limit holds")

	mine, err := site.list(".", 20, false)
	require.NoError(t, err)
	require.Len(t, mine, 1, "only the pull request that asks for my review")
	assert.Equal(t, 12, mine[0].Number)

	pull, id, err := site.view(".", 11)
	require.NoError(t, err)
	assert.Equal(t, want, pull)
	assert.Empty(t, id)

	_, _, err = site.view(".", 9)
	assert.ErrorContains(t, err, "HTTP 404: no such pull request")

	calls, err := os.ReadFile(log)
	require.NoError(t, err)
	assert.Equal(t, []string{
		"pr list -w payfactopay -r cribelo -f json",
		"pr list -w payfactopay -r cribelo -f json",
		"pr list -w payfactopay -r cribelo -f json",
		"user me -f json",
		"pr get --pr-id 12 -w payfactopay -r cribelo -f json",
		"pr get --pr-id 11 -w payfactopay -r cribelo -f json",
		"pr get --pr-id 11 -w payfactopay -r cribelo -f json",
		"pr get --pr-id 9 -w payfactopay -r cribelo -f json",
	}, strings.Split(strings.TrimSpace(string(calls)), "\n"))
}

func TestBbErrorObjectIsAnError(t *testing.T) {
	bin := t.TempDir()
	script := "#!/bin/sh\necho '{\"error\":{\"code\":\"rate_limited\",\"message\":\"HTTP 429: Rate limit\"}}'\n"
	require.NoError(t, os.WriteFile(filepath.Join(bin, "bb"), []byte(script), 0o755))
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))

	_, err := forge{Kind: bitbucket, Project: "payfactopay/cribelo"}.list(".", 20, true)
	assert.ErrorContains(t, err, "HTTP 429: Rate limit", "bb exits 0 with an error object")
}

func TestBbErrorObjectOnStderrIsReadAsItsMessage(t *testing.T) {
	bin := t.TempDir()
	script := "#!/bin/sh\necho '{\"error\":{\"code\":\"rate_limited\",\"message\":\"HTTP 429: Rate limit\"}}' >&2\nexit 1\n"
	require.NoError(t, os.WriteFile(filepath.Join(bin, "bb"), []byte(script), 0o755))
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))

	_, err := forge{Kind: bitbucket, Project: "payfactopay/cribelo"}.list(".", 20, true)
	assert.EqualError(t, err, "bb pr list: HTTP 429: Rate limit")
}
