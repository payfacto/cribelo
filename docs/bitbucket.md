# Cribelo on Bitbucket Cloud (PayFacto fork)

This fork of [cribelo](https://github.com/cribelo/cribelo) adds Bitbucket Cloud: a plan comment on each pull request, links that open the files on Bitbucket, and `cribelo inbox` / `cribelo pr` through `bb`. Bitbucket Data Center is not supported.

## On a pull request

1. In your repository, create a repository access token with the `pullrequest:write` scope and store it as the secured repository variable `CRIBELO_TOKEN`. Without it, the plan is only in the step log and the `cribelo-plan.md` artifact.
2. Copy the `cribelo` step of [`ci/bitbucket-pipelines.yml`](../ci/bitbucket-pipelines.yml) into your `bitbucket-pipelines.yml`, under `pull-requests`. It downloads the binary and the script from the public mirror `github.com/payfacto/cribelo`, with no token.

The step plans the commit you pushed, not the merge Bitbucket makes in the runner, so the links open. It posts one comment and edits it on each push. Set `CRIBELO_BOT_ACCOUNT_ID` to the account id of the token (shown as the author of the first comment) so that only that account's comment is edited: a repository access token cannot read its own account, and without the id the marker alone is trusted.

Options are variables: `CRIBELO_BUDGET`, `CRIBELO_TOP`, `CRIBELO_FAIL_ON`, `CRIBELO_FAIL_OVER` (as for the GitHub Action), `CRIBELO_VERSION` (a release such as `2.4.0-pf.1`, `latest` by default). Pin it: with `latest`, the step runs the script of the `main` branch of `payfacto/cribelo` with the secrets of your pipeline. The step fails only when the gate fails, and the gate is off unless you set `CRIBELO_FAIL_ON` or `CRIBELO_FAIL_OVER`. A Bitbucket API error, a git checkout or fetch error, a failed package install or a failed download never fails it: cribelo is skipped with a line in the log.

Bitbucket does not render HTML, so the folded sections of the plan come as plain Markdown.

## On your machine

`cribelo inbox` and `cribelo pr 12` read the pull requests with `bb` (the PayFacto Bitbucket Cloud CLI) v0.20.0 or later, which must be set up (`bb setup`); an older `bb` stops with "cribelo needs bb v0.20.0 or later", and `brew upgrade bb` fixes it. The workspace and the repository come from the `origin` remote (`bitbucket.org` or `ssh.bitbucket.org`). The inbox lists the pull requests where you are a formal reviewer (`bb pr list --reviewer me`, one API call); a comment alone does not make you a reviewer. `--all` lists every open pull request.

Bitbucket Cloud keeps no ref per pull request: the head is fetched from its branch on `origin`. A pull request from a fork cannot be planned. When its branch moved on since Bitbucket answered, the commit Bitbucket named is planned. `--viewed` works on GitHub only.

Install:

- macOS (Apple silicon or Intel): `brew install payfacto/tap/cribelo`
- Windows: download `cribelo_Windows_x86_64.exe` from the [releases of payfacto/cribelo](https://github.com/payfacto/cribelo/releases/latest) and put it on your `PATH` as `cribelo.exe`.
- Linux: `brew install payfacto/tap/cribelo`, or `cribelo_Linux_x86_64` / `cribelo_Linux_arm64` from the same releases.

## Releases

Bitbucket `payfactopay/cribelo` is the source of truth. After the tests, its pipeline strips `.context/` from the history and pushes `main` and each `v*` tag to the public mirror `github.com/payfacto/cribelo` (`scripts/mirror-to-github.sh`). On a tag, the mirror's `.github/workflows/release.yml` builds on native runners (cgo rules out cross-compiling): Linux x86_64 and arm64, macOS arm64 and x86_64, Windows x86_64. A last job (`scripts/publish-release.sh`) creates the GitHub release as a draft with every binary, `bitbucket-pr-comment.sh` and `SHA256SUMS` (`scripts/release-checksums.sh`), then publishes it; it never replaces the assets of a published release. Then it updates `Formula/cribelo.rb` in `payfacto/homebrew-tap`. A failed release is fixed by a new tag.

Tags are `v<upstream version>-pf.<n>` (`v2.4.0-pf.1`): stable releases (`scripts/release-kind.sh`). A tag such as `v2.4.0-pf.1-rc.1` is a pre-release and skips Homebrew.

One-time setup:

1. Create the public GitHub repository `payfacto/cribelo`, empty.
2. Add a deploy key with write access to it; put the private key in Repository settings -> Pipelines -> SSH keys of `payfactopay/cribelo`, with `github.com` as a known host.
3. Add the secret `HOMEBREW_TAP_TOKEN` (contents: write on `payfacto/homebrew-tap`) to `payfacto/cribelo`.
4. Set the repository variable `GITHUB_MIRROR_ENABLED` to `true` on `payfactopay/cribelo`. Until then the mirror step pushes nothing and passes.
5. After the first mirror push, disable upstream's review workflows there: `gh workflow disable cribelo.yml -R payfacto/cribelo` and `gh workflow disable cribelo-comment.yml -R payfacto/cribelo`.
6. Once a release was built by the draft-then-publish `release.yml`, turn on release immutability in the settings of `payfacto/cribelo` (Settings -> General -> Releases). Published assets and their tag can then no longer be changed.

## Upstream

`upstream` is the GitHub repository. Bring its changes in with `git fetch upstream && git merge upstream/main` on a branch, then a pull request.
