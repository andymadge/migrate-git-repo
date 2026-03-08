# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Running tests

Tests use [bats-core](https://github.com/bats-core/bats-core). Install with `brew install bats-core`.

```bash
bats test_migrate-git-repo.bats
```

## Architecture

This repo is a single script (`migrate-git-repo.sh`) with a test file (`test_migrate-git-repo.bats`).

The script flow:
1. Parse all flags/args (flags accepted in any position via a loop into `POSITIONAL`)
2. Validate argument combinations
3. Detect if destination is GitHub; ignore GitHub-specific flags if not
4. Either create the GitHub repo via `gh` CLI, or verify the destination is empty via `git ls-remote`
5. `git clone --mirror --origin source <source>`, then `git push --mirror origin`
6. Optionally `rm -rf` the local mirror dir

### Testing approach

The test suite stubs `git` and `gh` by prepending a `$BATS_TEST_TMPDIR/stubs/` directory to `PATH` — no real network calls are made. Two helper functions (`create_git_stub`, `create_gh_stub`) accept named `key=value` arguments to configure per-test stub behaviour (exit codes, output). Defaults are set in `setup()`.

When `create_gh_stub installed=false` is used, a failing stub is written (rather than removing the file) so it shadows any real `gh` binary on `PATH`. The script uses `gh --version` (not `command -v gh`) for the installed check so this works correctly.

## Conventions

- Bash style: lowercase snake_case for local variables, `set -euo pipefail`
- Use `local variable_name` declaration separate from assignment for command substitution (so `set -e` catches failures)
