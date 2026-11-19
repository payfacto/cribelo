package cli

import (
	"encoding/json"
	"errors"
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
	Reviewers []bitbucketAccount `json:"reviewers"`
	Links     struct {
		HTML struct {
			Href string `json:"href"`
		} `json:"html"`
	} `json:"links"`
}

type bitbucketAccount struct {
	AccountID string `json:"account_id"`
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

// asksReviewOf tells whether the account is among the reviewers.
func (b bitbucketPull) asksReviewOf(accountID string) bool {
	return slices.ContainsFunc(b.Reviewers, func(r bitbucketAccount) bool { return r.AccountID == accountID })
}

// bitbucketList reads the open pull requests: those that ask for the review
// of the user, or all of them.
func (f forge) bitbucketList(root string, limit int, all bool) ([]pullRequest, error) {
	var listed []bitbucketPull
	if err := bb(root, &listed, f.inRepository("pr", "list")...); err != nil {
		return nil, err
	}
	if !all {
		return f.askingReviewOfMe(root, listed, limit)
	}
	pulls := make([]pullRequest, 0, min(len(listed), limit))
	for _, b := range listed[:min(len(listed), limit)] {
		pulls = append(pulls, b.pull())
	}
	return pulls, nil
}

// askingReviewOfMe keeps the pull requests whose reviewers include the
// user. The list of Bitbucket is short of the reviewers, so each pull
// request is read until the limit is reached.
func (f forge) askingReviewOfMe(root string, listed []bitbucketPull, limit int) ([]pullRequest, error) {
	var me bitbucketAccount
	if err := bb(root, &me, "user", "me"); err != nil {
		return nil, err
	}
	if me.AccountID == "" {
		return nil, errors.New("bb user me: no account in the answer, run bb setup")
	}
	var pulls []pullRequest
	for _, b := range listed {
		if len(pulls) >= limit {
			break
		}
		full, err := f.bitbucketGet(root, b.ID)
		if err != nil {
			return nil, err
		}
		if full.asksReviewOf(me.AccountID) {
			pulls = append(pulls, b.pull())
		}
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
