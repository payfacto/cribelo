#!/usr/bin/env bash
# Posts the lines to read closely as review comments on a pull request, after
# removing those this token posted on an earlier run, so that only the current
# head is marked. Usage: post-review.sh OWNER/REPO PR REVIEW_JSON [MAX_COMMENTS]
# REVIEW_JSON is the output of cribelo --format github-review. Needs GH_TOKEN
# with pull-requests write. Exits non-zero when it cannot post.
#
# REVIEW_JSON can come from the artifact of a fork's run, so it is untrusted:
# the body sent to the API is rebuilt from an allow-list. The event is always
# COMMENT (never APPROVE or REQUEST_CHANGES), at most MAX_COMMENTS comments
# (10 by default, cut to 50) on the right side of the diff, and the texts are
# cut to the lengths cribelo writes; a cut comment keeps the marker, so the
# next run still removes it.
set -euo pipefail

repo=$1 pr=$2 review=$3 max=${4:-10}
[[ "$max" =~ ^[0-9]{1,9}$ ]] || max=10
[ "$max" -le 50 ] || max=50
# The same string ends every comment cribelo writes (internal/render/review.go).
marker='<!-- cribelo-review -->'
body="${RUNNER_TEMP:-/tmp}/cribelo-review.json"

# The lines are numbered on the commit the job checked out, the merge commit
# of the pull request on a pull_request event; the review is attached to its
# head, where the diff shows the same lines unless the base also touched the
# file. A review holds at most a few dozen comments without drowning the
# diff: the plan already keeps four spans a file. The body is built before
# anything is removed, so an invalid file leaves the earlier comments.
head=$(gh api "repos/$repo/pulls/$pr" --jq .head.sha)
jq --arg head "$head" --argjson max "$max" --arg marker "$marker" '
  def line: if type == "number" and . == floor and . > 0 then . else error("line \(.) is not a line number") end;
  {
    commit_id: $head,
    event: "COMMENT",
    body: (.body // "" | tostring | .[:2000]),
    comments: [(.comments // [])[:$max][] | {
      path: (.path | tostring),
      line: (.line | line),
      side: "RIGHT",
      body: (.body | tostring | if length > 4000 then .[:3950] + "\n\n" + $marker else . end)
    } + (if .start_line then {start_line: (.start_line | line), start_side: "RIGHT"} else {} end)]
  }' "$review" > "$body"

# Only remove comments written by this token: anyone can end a comment with
# the marker. GITHUB_TOKEN cannot read /user, its login is fixed.
if ! login=$(gh api user --jq .login 2>/dev/null) || ! [[ "$login" =~ ^[A-Za-z0-9-]+(\[bot\])?$ ]]; then
  login='github-actions[bot]'
fi
gh api "repos/$repo/pulls/$pr/comments" --paginate \
  --jq ".[] | select(.user.login == \"$login\" and (.body | contains(\"$marker\"))) | .id" |
while read -r id; do
  gh api -X DELETE "repos/$repo/pulls/comments/$id" > /dev/null
done

if [ "$(jq '.comments | length' "$body")" -eq 0 ]; then
  echo "no lines to read closely, no review posted"
  exit 0
fi
gh api "repos/$repo/pulls/$pr/reviews" --input "$body" > /dev/null
