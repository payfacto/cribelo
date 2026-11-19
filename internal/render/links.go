package render

import (
	"crypto/sha256"
	"fmt"
	"net/url"
	"regexp"
	"strings"
)

// Links gives the address of a changed file in the pull request, or of a
// span of its lines when start is positive.
type Links func(file string, start, end int) string

var (
	githubPull    = regexp.MustCompile(`^(https?://[^/]+/[^/]+/[^/]+)/pull/(\d+)`)
	gitlabMerge   = regexp.MustCompile(`^(https?://.+)/-/merge_requests/\d+`)
	bitbucketPull = regexp.MustCompile(`^(https?://bitbucket\.org/[^/]+/[^/]+)/pull-requests/\d+`)
)

// PullRequestLinks builds the links of a pull request from its address. On
// GitHub they open the diff of the pull request on the lines. On GitLab,
// whose diff anchors need the line numbers of both sides, and on Bitbucket
// Cloud, they open the file at the head commit.
func PullRequestLinks(address, headSha string) (Links, error) {
	if m := githubPull.FindStringSubmatch(address); m != nil {
		files := m[1] + "/pull/" + m[2] + "/files"
		return func(file string, start, end int) string {
			anchor := fmt.Sprintf("%s#diff-%x", files, sha256.Sum256([]byte(file)))
			switch {
			case start <= 0:
				return anchor
			case end <= start:
				return fmt.Sprintf("%sR%d", anchor, start)
			}
			return fmt.Sprintf("%sR%d-R%d", anchor, start, end)
		}, nil
	}
	if m := gitlabMerge.FindStringSubmatch(address); m != nil {
		return fileLinks(m[1]+"/-/blob/"+headSha+"/", "#L%d", "#L%d-%d"), nil
	}
	if m := bitbucketPull.FindStringSubmatch(address); m != nil {
		return fileLinks(m[1]+"/src/"+headSha+"/", "#lines-%d", "#lines-%d:%d"), nil
	}
	return nil, fmt.Errorf("%s is not the address of a GitHub pull request, a GitLab merge request or a Bitbucket pull request", address)
}

// fileLinks opens a file at the head commit, under the blob address, with
// the anchor formats of the forge for one line and for a span.
func fileLinks(blob, oneLine, span string) Links {
	return func(file string, start, end int) string {
		segments := strings.Split(file, "/")
		for i, s := range segments {
			segments[i] = url.PathEscape(s)
		}
		address := blob + strings.Join(segments, "/")
		switch {
		case start <= 0:
			return address
		case end <= start:
			return address + fmt.Sprintf(oneLine, start)
		}
		return address + fmt.Sprintf(span, start, end)
	}
}
