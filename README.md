# migrate-git-repo.sh

A bash script to mirror a git repository from one host to another, preserving all branches, tags, and refs.

Can be used to migrate between any git hosting providers — Bitbucket, GitHub, GitLab, Gitea, etc.

## Requirements

- `git`
- `bash` 4.0 or later
- [gh CLI](https://cli.github.com) — only required if using `--create-github-repo`

## Usage

```bash
./migrate-git-repo.sh <from-url> [to-url] [options]
```

### Arguments

| Argument                | Description                                                                                       |
| ----------------------- | ------------------------------------------------------------------------------------------------- |
| `from-url` | SSH or HTTPS clone URL of the source repository                                                   |
| `to-url`   | SSH or HTTPS clone URL of the destination repository. Optional when using `--create-github-repo`. |

### Options

| Option                 | Description                                                                                                                                       |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--create-github-repo` | Create the destination repository on GitHub using the `gh` CLI before pushing. Defaults to private. Ignored if destination is not a GitHub URL.   |
| `--create-public`      | Make the created GitHub repository public. Only valid with `--create-github-repo`.                                                                |
| `--https`              | Use an HTTPS URL for the auto-generated destination. Only applies when `--create-github-repo` is used without a destination URL. Defaults to SSH. |
| `--cleanup`            | Remove the local mirror clone after pushing. Default: off.                                                                                        |

Options can appear anywhere in the command — before, after, or interspersed with arguments.

## Examples

### Basic migration between any two hosts

The destination repository must already exist and be empty.

```bash
./migrate-git-repo.sh \
  git@bitbucket.org:org/repo.git \
  git@github.com:org/repo.git
```

### Create the GitHub destination repo automatically

Creates a private GitHub repository with the same name as the source, then pushes to it. Requires `gh` to be installed and authenticated.

```bash
./migrate-git-repo.sh \
  git@bitbucket.org:org/repo.git \
  --create-github-repo
```

### Create as public

```bash
./migrate-git-repo.sh \
  git@bitbucket.org:org/repo.git \
  --create-github-repo --create-public
```

### Use HTTPS instead of SSH for the generated URL

```bash
./migrate-git-repo.sh \
  git@bitbucket.org:org/repo.git \
  --create-github-repo --https
```

### Migrate to a different repo name on GitHub

Provide the destination URL explicitly to control the repo name.

```bash
./migrate-git-repo.sh \
  git@bitbucket.org:org/old-name.git \
  git@github.com:org/new-name.git
```

### Clean up local mirror after pushing

```bash
./migrate-git-repo.sh \
  git@bitbucket.org:org/repo.git \
  git@github.com:org/repo.git \
  --cleanup
```

## How it works

1. Validates all arguments and options
2. Checks the destination repository is empty (or creates it on GitHub)
3. Clones the source as a bare mirror (`git clone --mirror`)
4. Pushes all refs to the destination (`git push --mirror`)
5. Optionally removes the local mirror clone

The source remote is named `source` and the destination remote `origin` in the local mirror.

## Setting up the gh CLI

The `gh` CLI is only required when using `--create-github-repo`.

See https://github.com/cli/cli#installation for full installation instructions.

```bash
# Install
brew install gh

# Authenticate
gh auth login
```

## Notes

- The destination repository must already exist and be empty unless `--create-github-repo` is used.
- This is a one-shot migration, not an ongoing sync.
- Both SSH and HTTPS clone URLs are supported for source and destination.

---

## Running the tests

Tests are written using [bats-core](https://github.com/bats-core/bats-core).

### Install bats

```bash
brew install bats-core
```

### Run the tests

Both files must be in the same directory.

```bash
bats test_migrate-git-repo.bats
```

### How the tests work

The test suite mocks `git` and `gh` by prepending a stubs directory to `PATH`, so no real network calls are made. Stub behaviour (exit codes, output) can be configured per-test, allowing all code paths to be exercised quickly and reliably.

The following areas are covered:

- Argument and option validation
- Options accepted in any position
- Local directory collision detection
- Destination empty/unreachable checks
- Non-GitHub destinations ignoring GitHub-specific flags
- GitHub repo creation (success, failure, `gh` not installed)
- SSH vs HTTPS URL generation
- Private vs public visibility
- `--mirror` flag passed to `git push`
- `--cleanup` removing the local mirror directory