#!/usr/bin/env bash
# Tests of scripts/bitbucket-pr-comment.sh with fake cribelo, git and curl.
# Run: bash scripts/test/bitbucket-pr-comment.sh
set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
script="$here/bitbucket-pr-comment.sh"
failures=0

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
expect_contains() { grep -qF -- "$2" "$1" || fail "$3: '$2' not in $(basename "$1")"; }
expect_missing() { ! grep -qF -- "$2" "$1" || fail "$3: '$2' found in $(basename "$1")"; }

# setup builds a sandbox: fake tools on the PATH, the Pipelines variables,
# and EXISTING_COMMENTS as the first page of comments the API returns.
setup() {
	sandbox=$(mktemp -d)
	mkdir -p "$sandbox/bin" "$sandbox/work"
	calls="$sandbox/calls"
	: >"$calls"
	cat >"$sandbox/bin/cribelo" <<'FAKE'
#!/usr/bin/env bash
echo "cribelo $*" >>"$CALLS"
case "$*" in
  *--format\ json*) echo '{"gate_reasons":["reading time 44 min, over the 30 min allowed"]}' ;;
  *) printf '## Plan\n<details><summary><b>Skip</b> (2 files)</summary>\n\n- a.go<br><sub>clone</sub>\n</details>\n<sub>cribelo dev</sub>\n' ;;
esac
exit "${FAKE_CRIBELO_STATUS:-0}"
FAKE
	cat >"$sandbox/bin/git" <<'FAKE'
#!/usr/bin/env bash
echo "git $*" >>"$CALLS"
case "$*" in *"${FAKE_GIT_FAILS:-no such command}"*) exit 128 ;; esac
FAKE
	cat >"$sandbox/bin/curl" <<'FAKE'
#!/usr/bin/env bash
echo "curl $*" >>"$CALLS"
for arg in "$@"; do case "$arg" in @*) cp "${arg#@}" "$SANDBOX/posted.json" ;; esac; done
case "$*" in
  *"/2.0/user"*) [ -n "${FAKE_USER_ID:-}" ] && echo "{\"account_id\":\"$FAKE_USER_ID\"}" || exit 22 ;;
  *"-X POST"*|*"-X PUT"*) echo '{}' ;;
  *"/comments?"*) echo "${EXISTING_COMMENTS:-{\"values\":[]\}}" ;;
esac
FAKE
	chmod +x "$sandbox/bin/"*
	export PATH="$sandbox/bin:$PATH" CALLS="$calls" SANDBOX="$sandbox"
	export BITBUCKET_WORKSPACE=payfactopay BITBUCKET_REPO_SLUG=demo BITBUCKET_PR_ID=9
	export BITBUCKET_COMMIT=abc123 BITBUCKET_PR_DESTINATION_BRANCH=main
	unset FAKE_GIT_FAILS CRIBELO_TOKEN CRIBELO_BOT_ACCOUNT_ID CRIBELO_BUDGET CRIBELO_TOP CRIBELO_FAIL_ON CRIBELO_FAIL_OVER FAKE_USER_ID FAKE_CRIBELO_STATUS EXISTING_COMMENTS
}

run() { (cd "$sandbox/work" && bash "$script" >"$sandbox/out" 2>&1); echo $? >"$sandbox/status"; }
status() { cat "$sandbox/status"; }

# Without a token: plan in the log and the artifact, no API call, exit 0.
setup
run
[ "$(status)" = 0 ] || fail "no token: exit $(status)"
expect_contains "$calls" "git checkout -q --detach abc123" "plans the pushed commit, not the merge of Pipelines"
expect_contains "$calls" "git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main" "fetches the destination"
expect_contains "$calls" "cribelo --base origin/main --no-color --format markdown" "runs cribelo against the destination"
expect_contains "$sandbox/work/cribelo-plan.md" "## Plan" "writes the artifact"
expect_missing "$calls" "curl" "no token, no API call"
expect_contains "$sandbox/out" "CRIBELO_TOKEN is not set" "says why there is no comment"

# A first push: no comment yet, one is posted, in plain Markdown.
setup
export CRIBELO_TOKEN=secret-token CRIBELO_BOT_ACCOUNT_ID=bot-1
run
[ "$(status)" = 0 ] || fail "post: exit $(status)"
expect_contains "$calls" "-X POST" "posts a new comment"
expect_contains "$calls" "https://api.bitbucket.org/2.0/repositories/payfactopay/demo/pullrequests/9/comments" "on the pull request"
expect_contains "$calls" "Authorization: Bearer secret-token" "with the token"
expect_contains "$sandbox/posted.json" '[//]: # (cribelo-plan)' "the marker"
expect_contains "$sandbox/posted.json" '**Skip** (2 files)' "HTML bold becomes Markdown"
expect_missing "$sandbox/posted.json" '<details>' "no HTML left"
expect_missing "$sandbox/posted.json" '<sub>' "no HTML left"
expect_missing "$sandbox/out" "secret-token" "the token is never printed"
expect_missing "$calls" "/2.0/user" "the account given is used"

# A later push: the comment of the bot is edited, one of someone else is not.
setup
export CRIBELO_TOKEN=secret-token CRIBELO_BOT_ACCOUNT_ID=bot-1
export EXISTING_COMMENTS='{"values":[{"id":5,"user":{"account_id":"human"},"content":{"raw":"[//]: # (cribelo-plan)\nfake"}},{"id":7,"user":{"account_id":"bot-1"},"content":{"raw":"[//]: # (cribelo-plan)\nold"}}]}'
run
expect_contains "$calls" "-X PUT" "edits the existing comment"
expect_contains "$calls" "/comments/7" "the one of the bot"
expect_missing "$calls" "-X POST" "never a second comment"

# No account given and /2.0/user refused: the marker alone is trusted.
setup
export CRIBELO_TOKEN=secret-token
export EXISTING_COMMENTS='{"values":[{"id":5,"user":{"account_id":"human"},"content":{"raw":"[//]: # (cribelo-plan)\nold"}}]}'
run
expect_contains "$calls" "/comments/5" "marker alone"
expect_contains "$sandbox/out" "trusting the marker alone" "says so"

# /2.0/user answers: its account is the author to match.
setup
export CRIBELO_TOKEN=secret-token FAKE_USER_ID=bot-9
export EXISTING_COMMENTS='{"values":[{"id":5,"user":{"account_id":"human"},"content":{"raw":"[//]: # (cribelo-plan)\nold"}}]}'
run
expect_contains "$calls" "-X POST" "the comment of someone else is not edited"

# Gate failed: exit 1 with the reasons.
setup
export FAKE_CRIBELO_STATUS=1 CRIBELO_FAIL_OVER=30m
run
[ "$(status)" = 1 ] || fail "gate: exit $(status)"
expect_contains "$calls" "--fail-over 30m" "passes the limit"
expect_contains "$sandbox/out" "gate failed: reading time 44 min" "tells why"

# cribelo crashes: its status is kept.
setup
export FAKE_CRIBELO_STATUS=2
run
[ "$(status)" = 2 ] || fail "crash: exit $(status)"

# git cannot check out or fetch: cribelo is skipped, the pull request is not failed.
for step in checkout fetch; do
	setup
	export FAKE_GIT_FAILS=$step CRIBELO_FAIL_OVER=30m
	run
	[ "$(status)" = 0 ] || fail "git $step fails: exit $(status)"
	expect_contains "$sandbox/out" "skipping" "git $step fails: says it skips"
	expect_missing "$calls" "cribelo --base" "git $step fails: cribelo is not run"
done

if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "ok"
