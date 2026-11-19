package cli

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"slices"
	"strconv"
	"strings"
)

// Bitbucket Cloud is read through bb, the command line of PayFacto that
// holds the login of the user. bb answers in JSON, and on a failure with an
// error object, sometimes with exit status 0.

// bitbucketPull is what bb says of a pull request.
type bitbucketPull struct {
	ID        int    `json:"id"`
	Title     string `json:"title"`
	Draft     bool   `json:"draft"`
	UpdatedOn string `json:"updated_on"`
	Author    struct {
		Nickname string `json:"nickname"`
	} `json:"author"`
	Source struct {
		Branch struct {
			Name string `json:"name"`
		} `json:"branch"`
		Commit struct {
			Hash string `json:"hash"`
		} `json:"commit"`
	} `json:"source"`
	Destination struct {
		Branch struct {
			Name string `json:"name"`
		} `json:"branch"`
	} `json:"destination"`
	Links struct {
		HTML struct {
			Href string `json:"href"`
		} `json:"html"`
	} `json:"links"`
}

func (b bitbucketPull) pull() pullRequest {
	p := pullRequest{
		Number:      b.ID,
		Title:       b.Title,
		URL:         b.Links.HTML.Href,
		HeadRefOid:  b.Source.Commit.Hash,
		HeadRefName: b.Source.Branch.Name,
		BaseRefName: b.Destination.Branch.Name,
		IsDraft:     b.Draft,
		UpdatedAt:   b.UpdatedOn,
	}
	p.Author.Login = b.Author.Nickname
	return p
}

// bitbucketList reads the open pull requests: those that ask for the review
// of the user, or all of them. bb filters on the reviewers with Bitbucket.
func (f forge) bitbucketList(root string, limit int, all bool) ([]pullRequest, error) {
	args := []string{"pr", "list"}
	if !all {
		args = append(args, "--reviewer", "me")
	}
	var listed []bitbucketPull
	if err := bb(root, &listed, f.inRepository(args...)...); err != nil {
		return nil, err
	}
	pulls := make([]pullRequest, 0, min(len(listed), limit))
	for _, b := range listed[:min(len(listed), limit)] {
		pulls = append(pulls, b.pull())
	}
	return pulls, nil
}

func (f forge) bitbucketView(root string, number int) (pullRequest, error) {
	b, err := f.bitbucketGet(root, number)
	return b.pull(), err
}

func (f forge) bitbucketGet(root string, number int) (bitbucketPull, error) {
	var b bitbucketPull
	err := bb(root, &b, f.inRepository("pr", "get", "--pr-id", strconv.Itoa(number))...)
	return b, err
}

// inRepository names the workspace and the repository on a bb command: bb
// does not always read them from the remote.
func (f forge) inRepository(args ...string) []string {
	workspace, repository, _ := strings.Cut(f.Project, "/")
	return append(args, "-w", workspace, "-r", repository)
}

// bb runs the command line of Bitbucket and decodes its JSON answer.
func bb(root string, answer any, args ...string) error {
	args = append(args, "-f", "json")
	cmd := exec.Command("bb", args...)
	cmd.Dir = root
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, runErr := cmd.Output()
	command := "bb " + args[0] + " " + args[1]
	if reason := bbFailure(out); reason != "" {
		return fmt.Errorf("%s: %s", command, reason)
	}
	if runErr != nil {
		reason := bbFailure([]byte(stderr.String()))
		if reason == "" {
			reason = strings.TrimSpace(stderr.String())
		}
		if reason == "" {
			reason = runErr.Error()
		}
		return fmt.Errorf("%s: %s", command, reason)
	}
	if err := json.Unmarshal(out, answer); err != nil {
		return fmt.Errorf("%s: %w", command, err)
	}
	return nil
}

// bbFailure is the message of the error object bb prints on a failure, on
// stdout or stderr; empty when the output is not one.
func bbFailure(out []byte) string {
	var failure struct {
		Error *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(out, &failure) != nil || failure.Error == nil {
		return ""
	}
	return failure.Error.Message
}

// minimumBb is the first bb that filters pull requests on their reviewers.
var minimumBb = [3]int{0, 20, 0}

// bbVersion is the error of a bb older than minimumBb, or of a bb that does
// not tell its version.
func bbVersion() error {
	out, err := exec.Command("bb", "--version").Output()
	found := "no version"
	if words := strings.Fields(strings.TrimPrefix(strings.TrimSpace(string(out)), "bb version")); len(words) > 0 {
		found = words[0]
	}
	if err == nil && atLeast(found, minimumBb) {
		return nil
	}
	return fmt.Errorf("cribelo needs bb v%d.%d.%d or later (found %s): run brew upgrade bb",
		minimumBb[0], minimumBb[1], minimumBb[2], found)
}

// atLeast tells whether a version such as v0.20.1 or 0.21.0-rc.1 is at
// least the minimum. A pre-release counts as its release.
func atLeast(version string, minimum [3]int) bool {
	core, _, _ := strings.Cut(strings.TrimPrefix(version, "v"), "-")
	parts := strings.Split(core, ".")
	if len(parts) != 3 {
		return false
	}
	var got [3]int
	for i, part := range parts {
		n, err := strconv.Atoi(part)
		if err != nil {
			return false
		}
		got[i] = n
	}
	return slices.Compare(got[:], minimum[:]) >= 0
}
