#!/usr/bin/env bash
# Tests of scripts/post-review.sh with a fake gh: the review.json of the
# artifact is written by a fork, so only an allow-listed body reaches the API.
# Run: bash scripts/test/post-review.sh
set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
script="$here/post-review.sh"
failures=0
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/bin"
cat >"$sandbox/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "gh $*" >>"$SANDBOX/calls"
prev=""
for arg in "$@"; do
  [ "$prev" = --input ] && cp "$arg" "$SANDBOX/posted.json"
  prev=$arg
done
case "$*" in
  "api user"*) exit 1 ;;
  *"/comments --paginate"*) echo 11 ;;
  *"/reviews --input"*) [ -z "${FAKE_POST_FAILS:-}" ] || exit 1 ;;
  *"pulls/7 --jq .head.sha"*) echo headsha ;;
esac
FAKE
chmod +x "$sandbox/bin/gh"
export PATH="$sandbox/bin:$PATH" SANDBOX="$sandbox" RUNNER_TEMP="$sandbox"

# post REVIEW_JSON runs the script and leaves the posted body in posted.json.
post() {
	rm -f "$sandbox/posted.json" "$sandbox/calls"
	printf '%s' "$1" >"$sandbox/review.json"
	bash "$script" owner/repo 7 "$sandbox/review.json" ${2:+"$2"} >"$sandbox/out" 2>&1
}
posted() { jq -c "$1" "$sandbox/posted.json"; }

many=$(jq -nc '[range(0; 60) | {path: "a.go", line: (. + 1), side: "RIGHT", body: "x"}]')
post "{\"event\":\"APPROVE\",\"body\":\"ok\",\"commit_id\":\"evil\",\"extra\":1,\"comments\":$many}" \
	|| fail "hostile review: exit $?, $(cat "$sandbox/out")"
[ "$(posted .event)" = '"COMMENT"' ] || fail "event: got $(posted .event), want COMMENT"
[ "$(posted .commit_id)" = '"headsha"' ] || fail "commit_id: got $(posted .commit_id)"
[ "$(posted '.comments | length')" = 10 ] || fail "comments: got $(posted '.comments | length'), want 10"
[ "$(posted 'keys')" = '["body","comments","commit_id","event"]' ] || fail "top keys: $(posted keys)"

post "{\"comments\":$many}" 3 || fail "max 3: exit $?"
[ "$(posted '.comments | length')" = 3 ] || fail "max 3: got $(posted '.comments | length')"
post "{\"comments\":$many}" 999 || fail "max 999: exit $?"
[ "$(posted '.comments | length')" = 50 ] || fail "max over 50 is cut to 50: got $(posted '.comments | length')"
post "{\"comments\":$many}" 'x' || fail "max x: exit $?"
[ "$(posted '.comments | length')" = 10 ] || fail "max not a number falls back to 10: got $(posted '.comments | length')"

post '{"event":"REQUEST_CHANGES","body":"ok","comments":[{"path":"a.go","line":3,"start_line":1,"side":"LEFT","start_side":"LEFT","body":"b","in_reply_to":5,"position":2}]}' \
	|| fail "comment keys: exit $?"
[ "$(posted .event)" = '"COMMENT"' ] || fail "REQUEST_CHANGES not replaced: $(posted .event)"
[ "$(posted '.comments[0] | keys')" = '["body","line","path","side","start_line","start_side"]' ] \
	|| fail "comment keys: $(posted '.comments[0] | keys')"
[ "$(posted '.comments[0].side')" = '"RIGHT"' ] || fail "side: $(posted '.comments[0].side')"

long=$(head -c 9000 /dev/zero | tr '\0' a)
post "{\"body\":\"$long\",\"comments\":[{\"path\":\"a.go\",\"line\":1,\"body\":\"$long\"}]}" || fail "long texts: exit $?"
[ "$(posted '.body | length')" = 2000 ] || fail "review body length: $(posted '.body | length')"
[ "$(posted '.comments[0].body | length <= 4000')" = true ] || fail "comment body length: $(posted '.comments[0].body | length')"
[ "$(posted '.comments[0].body | endswith("<!-- cribelo-review -->")')" = true ] || fail "a cut comment lost the marker"

post '{"comments":[{"path":"a.go","line":"1; rm","body":"b"}]}' && fail "a line that is not a number is posted"
[ -e "$sandbox/posted.json" ] && fail "malformed line: a body was posted"
grep -q DELETE "$sandbox/calls" && fail "malformed line: the earlier comments were removed before the body was checked"

post "{\"comments\":$many}" 0 || fail "max 0: exit $?"
[ "$(posted '.comments | length')" = 10 ] || fail "max 0 is the default 10: got $(posted '.comments | length')"

post '{"comments":[{"path":"a.go","line":1,"body":"no marker"}]}' || fail "short body: exit $?"
[ "$(posted '.comments[0].body | endswith("<!-- cribelo-review -->")')" = true ] || fail "a comment without the marker is posted as is"

post '{"comments":[{"path":"a.go","line":1,"body":"b"}]}' || fail "order: exit $?"
[ "$(grep -n -m1 '/reviews --input' "$sandbox/calls" | cut -d: -f1)" -lt "$(grep -n -m1 DELETE "$sandbox/calls" | cut -d: -f1)" ] \
	|| fail "the earlier comments are removed before the new review is posted: $(cat "$sandbox/calls")"
FAKE_POST_FAILS=1 post '{"comments":[{"path":"a.go","line":99999,"body":"b"}]}' && fail "a refused review exits 0"
grep -q DELETE "$sandbox/calls" && fail "a refused review removed the earlier comments"

post '{"comments":[]}' || fail "no comments: exit $?"
grep -q DELETE "$sandbox/calls" || fail "no comments: the earlier comments are kept"
[ -e "$sandbox/posted.json" ] && fail "no comments: a review was posted"

if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "ok"
