#!/usr/bin/env bash
set -euo pipefail

# migrate-git-repo.sh - Mirror a git repository from one host to another
# Can be used to migrate between any git hosting providers e.g. Bitbucket, GitHub, GitLab, Gitea, etc.
#
# For automated GitHub repo creation, install gh CLI: brew install gh (or see https://github.com/cli/cli#installation) then run gh auth login

usage() {
  local script_name
  script_name=$(basename "$0")
  cat << USAGE
Usage: $script_name <from-url> [to-url] [options]

Mirror a git repository from one host to another, preserving all branches,
tags, and refs. Can be used to migrate between any git hosting providers
such as Bitbucket, GitHub, GitLab, Gitea, etc.

Arguments:
  from-url   SSH or HTTPS clone URL of the source repository
  to-url     SSH or HTTPS clone URL of the destination repository.
             Optional when using --create-github-repo, in which
             case it is generated automatically using the same
             name as the source repository. To use a different
             name, provide a destination clone URL instead.

Options:
  --create-github-repo   Create the destination repository on GitHub using
                         the gh CLI before pushing. Defaults to private.
                         Requires gh to be installed and authenticated.
                         See: https://cli.github.com
                         Ignored if destination is not a GitHub URL.
  --create-public        Make the created GitHub repository public.
                         Only valid with --create-github-repo.
                         Ignored if destination is not a GitHub URL.
  --https                Use HTTPS for the auto-generated destination URL.
                         Only applies when --create-github-repo is used
                         without a destination URL. Defaults to SSH.
  --cleanup              Remove the local mirror clone after pushing.
                         Default: off.

Notes:
  - Unless --create-github-repo is used, the destination repository must
    already exist and must be empty.
  - This is a one-shot migration, not ongoing sync.
  - For automated GitHub repo creation, install gh CLI: brew install gh 
    (or see https://github.com/cli/cli#installation) then run gh auth login

Examples:
  $script_name git@bitbucket.org:org/repo.git git@github.com:org/repo.git
  $script_name git@bitbucket.org:org/repo.git --create-github-repo
  $script_name git@bitbucket.org:org/repo.git --create-github-repo --https
  $script_name git@bitbucket.org:org/repo.git --create-github-repo --create-public
  $script_name git@github.com:org/repo.git git@gitlab.com:org/repo.git --cleanup
USAGE
  exit 1
}

if [ $# -lt 1 ]; then
  usage
fi

POSITIONAL=()
CLEANUP=false
CREATE_GITHUB_REPO=false
VISIBILITY="--private"
USE_HTTPS=false

for arg in "$@"; do
  case "$arg" in
    --create-github-repo) CREATE_GITHUB_REPO=true ;;
    --create-public)      VISIBILITY="--public" ;;
    --https)              USE_HTTPS=true ;;
    --cleanup)            CLEANUP=true ;;
    --*) echo "Unknown option: $arg"; usage ;;
    *)   POSITIONAL+=("$arg") ;;
  esac
done

SOURCE_URL="${POSITIONAL[0]:-}"
DESTINATION_URL="${POSITIONAL[1]:-}"

if [ -z "$SOURCE_URL" ]; then
  echo "Error: source clone URL is required."
  usage
fi

if [ -z "$DESTINATION_URL" ] && [ "$CREATE_GITHUB_REPO" = false ]; then
  echo "Error: destination clone URL is required unless --create-github-repo is specified."
  exit 1
fi

if [ "$USE_HTTPS" = true ] && [ "$CREATE_GITHUB_REPO" = false ]; then
  echo "Error: --https is only applicable when --create-github-repo is used without a destination URL."
  exit 1
fi

if [ "$USE_HTTPS" = true ] && [ -n "$DESTINATION_URL" ]; then
  echo "Error: --https is only applicable when --create-github-repo is used without a destination URL."
  exit 1
fi

# Detect whether destination is GitHub
IS_GITHUB=false
if [ -n "$DESTINATION_URL" ] && echo "$DESTINATION_URL" | grep -qi "github.com"; then
  IS_GITHUB=true
elif [ "$CREATE_GITHUB_REPO" = true ] && [ -z "$DESTINATION_URL" ]; then
  IS_GITHUB=true
fi

# Ignore GitHub-specific flags if destination is not GitHub
if [ "$IS_GITHUB" = false ]; then
  if [ "$CREATE_GITHUB_REPO" = true ] || [ "$VISIBILITY" = "--public" ]; then
    echo "Note: destination is not a GitHub URL - ignoring --create-github-repo and --create-public."
  fi
  CREATE_GITHUB_REPO=false
  VISIBILITY="--private"
fi

if [ "$VISIBILITY" = "--public" ] && [ "$CREATE_GITHUB_REPO" = false ]; then
  echo "Error: --create-public is only valid with --create-github-repo."
  exit 1
fi

REPO_DIR=$(basename "$SOURCE_URL" .git).git

if [ -d "$REPO_DIR" ]; then
  echo "Error: local directory '$REPO_DIR' already exists. Remove it and retry."
  exit 1
fi

section() {
  echo ""
  echo "==> $1"
}

if [ "$CREATE_GITHUB_REPO" = true ]; then
  if ! gh --version &> /dev/null; then
    echo "Error: gh CLI is not installed."
    echo "Install it with: brew install gh  (or see https://github.com/cli/cli#installation)"
    echo "Then authenticate with: gh auth login"
    exit 1
  fi
  SOURCE_REPO_NAME=$(basename "$SOURCE_URL" .git)
  section "Creating GitHub repository"
  echo "    Name:       $SOURCE_REPO_NAME"
  echo "    Visibility: ${VISIBILITY#--}"
  echo "    Running:    gh repo create \"$SOURCE_REPO_NAME\" \"$VISIBILITY\""
  if ! gh repo create "$SOURCE_REPO_NAME" "$VISIBILITY"; then
    echo "Error: failed to create GitHub repository '$SOURCE_REPO_NAME'. Aborting."
    exit 1
  fi
  HTTPS_URL=$(gh repo view "$SOURCE_REPO_NAME" --json url --jq .url)
  if [ "$USE_HTTPS" = true ]; then
    DESTINATION_URL="$HTTPS_URL"
  else
    # Convert HTTPS URL to SSH format:
    # https://github.com/owner/repo.git -> git@github.com:owner/repo.git
    DESTINATION_URL=$(echo "$HTTPS_URL" | sed -E 's|https://github.com/([^/]+/[^/]+)(\.git)?$|git@github.com:\1.git|')
  fi
  echo "    URL:        $DESTINATION_URL"
else
  section "Checking destination"
  if ! REMOTE_REFS=$(git ls-remote "$DESTINATION_URL" 2>&1); then
    echo "Error: could not connect to destination repository: $REMOTE_REFS"
    exit 1
  fi
  if echo "$REMOTE_REFS" | grep -q .; then
    echo "Error: destination repository is not empty. Aborting to avoid overwrite."
    exit 1
  fi
  echo "    Destination is empty, proceeding."
fi

section "Cloning source"
echo "    $SOURCE_URL"
git clone --mirror --origin source "$SOURCE_URL"

cd "$REPO_DIR"
git remote add origin "$DESTINATION_URL"

section "Pushing to destination"
echo "    $DESTINATION_URL"
git push --mirror origin

if [ "$CLEANUP" = true ]; then
  section "Cleaning up"
  cd ..
  rm -rf "$REPO_DIR"
  echo "    Removed $REPO_DIR"
fi

echo ""
echo "Done."