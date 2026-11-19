#!/usr/bin/env bash
# Cribelo on a Bitbucket Cloud pull request pipeline. Run it from the root of
# the checkout, with cribelo, git, curl and jq on the PATH:
# ci/bitbucket-pipelines.yml shows the step that installs them.
#
# The plan lands in the step log and in cribelo-plan.md (an artifact). With
# CRIBELO_TOKEN (a repository access token with the pullrequest:write scope)
# it is also posted as one comment, edited on each push.
#
# Variables: CRIBELO_BUDGET, CRIBELO_TOP, CRIBELO_FAIL_ON, CRIBELO_FAIL_OVER
# mean what the GitHub Action inputs mean. CRIBELO_BOT_ACCOUNT_ID is the
# account of the token, to find the comment again: a repository access token
# cannot read its own account, and without it the marker alone is trusted.
#
# Exit status: 0, or 1 when the gate fails (only with CRIBELO_FAIL_ON or
# CRIBELO_FAIL_OVER), or the status of cribelo when it crashes. A failure of
# the Bitbucket API never fails the step.

set +e -uo pipefail

readonly marker='[//]: # (cribelo-plan)'
readonly max_comment_bytes=30000

# Bitbucket Pipelines runs a pull request on a merge of the destination into
# the source, made in the runner and never pushed: its links would not open.
# The pushed commit is the one planned.
git checkout -q --detach "$BITBUCKET_COMMIT" || exit 1
destination="$BITBUCKET_PR_DESTINATION_BRANCH"
git fetch --no-tags origin "+refs/heads/$destination:refs/remotes/origin/$destination" || exit 1

args=(--base "origin/$destination" --no-color)
[ -n "${CRIBELO_FAIL_ON:-}" ] && args+=(--fail-on "$CRIBELO_FAIL_ON")
[ -n "${CRIBELO_FAIL_OVER:-}" ] && args+=(--fail-over "$CRIBELO_FAIL_OVER")
if [ -n "${CRIBELO_BUDGET:-}" ]; then
	args+=(--budget "$CRIBELO_BUDGET")
elif [ -n "${CRIBELO_TOP:-}" ]; then
	args+=(--top "$CRIBELO_TOP")
fi

# Written outside the checkout, or cribelo would count it as a changed file.
plan=$(mktemp)
cribelo "${args[@]}" --format markdown >"$plan"
status=$?
cat "$plan"
[ "$status" -le 1 ] || exit "$status"
reasons=""
if [ "$status" -eq 1 ]; then
	reasons=$(cribelo "${args[@]}" --format json 2>/dev/null | jq -r '(.gate_reasons // []) | join("; ")')
fi
cp "$plan" cribelo-plan.md

# plain_markdown turns the HTML of the plan, which Bitbucket does not render,
# into Markdown: folded sections become their title in bold.
plain_markdown() {
	sed -E \
		-e 's#<details[^>]*><summary>(.*)</summary>#\1#' \
		-e 's#</?details[^>]*>##g' \
		-e 's#</?b>#**#g' \
		-e 's#<br>#  -  #g' \
		-e 's#</?sub>##g' \
		-e '/^<!--.*-->$/d'
}

# bot_account is the author of the comment to edit, empty when unknown.
bot_account() {
	if [ -n "${CRIBELO_BOT_ACCOUNT_ID:-}" ]; then
		echo "$CRIBELO_BOT_ACCOUNT_ID"
		return
	fi
	curl -fsS -H "$auth" "https://api.bitbucket.org/2.0/user" 2>/dev/null | jq -r '.account_id // empty'
}

# existing_comment finds the comment of an earlier run: its marker, and its
# author when known (anyone can write the marker).
existing_comment() {
	local me=$1 page="$api?pagelen=100&fields=values.id,values.user.account_id,values.content.raw,values.deleted,values.inline,next"
	local comments found
	for _ in $(seq 1 50); do
		comments=$(curl -fsS -H "$auth" "$page") || return
		found=$(jq -r --arg me "$me" --arg m "$marker" \
			'[.values[] | select((.deleted | not) and .inline == null and (.content.raw | startswith($m)) and ($me == "" or .user.account_id == $me))][0].id // empty' <<<"$comments")
		if [ -n "$found" ]; then
			echo "$found"
			return
		fi
		page=$(jq -r '.next // empty' <<<"$comments")
		[ -n "$page" ] || return
	done
}

post_comment() {
	auth="Authorization: Bearer $CRIBELO_TOKEN"
	api="https://api.bitbucket.org/2.0/repositories/$BITBUCKET_WORKSPACE/$BITBUCKET_REPO_SLUG/pullrequests/$BITBUCKET_PR_ID/comments"
	local me existing body
	me=$(bot_account)
	[ -n "$me" ] || echo "cribelo: the account of CRIBELO_TOKEN is unknown, trusting the marker alone (set CRIBELO_BOT_ACCOUNT_ID)"
	existing=$(existing_comment "$me")
	body=$(mktemp)
	plain_markdown <"$plan" | head -c "$max_comment_bytes" | jq -Rs --arg m "$marker" '{content: {raw: ($m + "\n" + .)}}' >"$body"
	if [ -n "$existing" ]; then
		curl -fsS -X PUT -H "$auth" -H 'Content-Type: application/json' --data @"$body" "$api/$existing" >/dev/null
	else
		curl -fsS -X POST -H "$auth" -H 'Content-Type: application/json' --data @"$body" "$api" >/dev/null
	fi || echo "cribelo: could not post the comment (does CRIBELO_TOKEN have the pullrequest:write scope?)"
}

if [ -n "${CRIBELO_TOKEN:-}" ]; then
	post_comment
else
	echo "cribelo: CRIBELO_TOKEN is not set, the plan is in the cribelo-plan.md artifact"
fi

if [ "$status" -eq 1 ]; then
	echo "cribelo: gate failed: ${reasons:-see the plan}"
	exit 1
fi
exit 0
