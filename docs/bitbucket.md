# Cribelo on Bitbucket Cloud (PayFacto fork)

This fork of [cribelo](https://github.com/cribelo/cribelo) adds Bitbucket Cloud: a plan comment on each pull request, links that open the files on Bitbucket, and `cribelo inbox` / `cribelo pr` through `bb`. Bitbucket Data Center is not supported.

## On a pull request

1. Once per workspace, a workspace admin creates a repository access token on `payfactopay/cribelo` with the `repository` (read) scope and stores it as the secured workspace variable `CRIBELO_DOWNLOAD_TOKEN`.
2. In your repository, create a repository access token with the `pullrequest:write` scope and store it as the secured repository variable `CRIBELO_TOKEN`. Without it, the plan is only in the step log and the `cribelo-plan.md` artifact.
3. Copy the `cribelo` step of [`ci/bitbucket-pipelines.yml`](../ci/bitbucket-pipelines.yml) into your `bitbucket-pipelines.yml`, under `pull-requests`.

The step plans the commit you pushed, not the merge Bitbucket makes in the runner, so the links open. It posts one comment and edits it on each push. Set `CRIBELO_BOT_ACCOUNT_ID` to the account id of the token (shown as the author of the first comment) so that only that account's comment is edited: a repository access token cannot read its own account, and without the id the marker alone is trusted.

Options are variables: `CRIBELO_BUDGET`, `CRIBELO_TOP`, `CRIBELO_FAIL_ON`, `CRIBELO_FAIL_OVER` (as for the GitHub Action), `CRIBELO_VERSION` (a release such as `2.4.0-pf.1`, `latest` by default). Pin it: with `latest`, the step runs the script of the `main` branch of `payfactopay/cribelo` with the secrets of your pipeline. The step fails only when the gate fails, and the gate is off unless you set `CRIBELO_FAIL_ON` or `CRIBELO_FAIL_OVER`. A Bitbucket API error, a git checkout or fetch error, a missing `CRIBELO_DOWNLOAD_TOKEN` or a failed download never fails it: cribelo is skipped with a line in the log.

Bitbucket does not render HTML, so the folded sections of the plan come as plain Markdown.

## On your machine

`cribelo inbox` and `cribelo pr 12` read the pull requests with `bb` (the PayFacto Bitbucket Cloud CLI), which must be set up (`bb setup`). The workspace and the repository come from the `origin` remote (`bitbucket.org` or `ssh.bitbucket.org`). The list of Bitbucket does not carry the reviewers, so the inbox reads each open pull request once to know whether it asks for your review: one API call per open pull request (`--all` skips them).

Bitbucket Cloud keeps no ref per pull request: the head is fetched from its branch on `origin`. A pull request from a fork cannot be planned. When its branch moved on since Bitbucket answered, the commit Bitbucket named is planned. `--viewed` works on GitHub only.

Build the binary on macOS: `go build -o ~/bin/cribelo .` from a clone (needs a C compiler, cgo).

## Releases

A tag `v<upstream version>-pf.<n>` (`v2.4.0-pf.1`) runs the tests, then publishes `cribelo_<version>_Linux_x86_64` and `cribelo_Linux_x86_64` (the latest) to the Downloads of this repository. It needs the secured repository variable `CRIBELO_RELEASE_TOKEN`, a repository access token of `payfactopay/cribelo` with the `repository:write` scope.

## Upstream

`upstream` is the GitHub repository. Bring its changes in with `git fetch upstream && git merge upstream/main` on a branch, then a pull request.
