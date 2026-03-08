#!/usr/bin/env bash
set -euo pipefail

# migrate-git-repo.sh - Mirror a git repository from one host to another
# Can be used to migrate between any git hosting providers e.g. Bitbucket, GitHub, GitLab, Gitea, etc.
#
# For automated GitHub repo creation, install gh CLI: brew install gh (or see https://github.com/cli/cli#installation) then run gh auth login

# ==============================================================================
# Helpers
# ==============================================================================

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
             Cannot be combined with --create-github-repo. Omit
             when using --create-github-repo.

Options:
  --create-github-repo   Create the destination repository on GitHub using
                         the gh CLI before pushing. Defaults to private.
                         Requires gh to be installed and authenticated.
                         See: https://cli.github.com
  --repo-name <name>     Override the GitHub repository name when using
                         --create-github-repo. Defaults to the source
                         repository name. Only valid with --create-github-repo.
  --create-public        Make the created GitHub repository public.
                         Only valid with --create-github-repo.
  --dest-https           Use HTTPS for the auto-generated destination URL.
                         Only applies when --create-github-repo is used.
                         Defaults to SSH. Use this if you are not configured
                         for SSH push access.
  --no-cleanup           Keep the local mirror clone after pushing.
                         Default: remove it after pushing.

Notes:
  - Unless --create-github-repo is used, the destination repository must
    already exist and must be empty.
  - This is a one-shot migration, not ongoing sync.
  - For automated GitHub repo creation, install gh CLI: brew install gh
    (or see https://github.com/cli/cli#installation) then run gh auth login

Examples:
  $script_name git@bitbucket.org:org/repo.git git@github.com:org/repo.git
  $script_name git@bitbucket.org:org/repo.git --create-github-repo
  $script_name git@bitbucket.org:org/repo.git --create-github-repo --repo-name my-repo
  $script_name git@bitbucket.org:org/repo.git --create-github-repo --dest-https
  $script_name git@bitbucket.org:org/repo.git --create-github-repo --create-public
  $script_name git@github.com:org/repo.git git@gitlab.com:org/repo.git --no-cleanup
USAGE
  exit 1
}

section() {
  echo ""
  echo "==> $1"
}

# ==============================================================================
# Argument parsing
# ==============================================================================

parse_args() {
  if [ $# -lt 1 ]; then
    usage
  fi

  POSITIONAL=()
  CLEANUP=true
  # GitHub-specific flags
  CREATE_GITHUB_REPO=false
  REPO_NAME=""
  VISIBILITY="--private"
  USE_HTTPS=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --no-cleanup)         CLEANUP=false ;;
      # GitHub-specific flags
      --create-github-repo) CREATE_GITHUB_REPO=true ;;
      --repo-name)
        if [ $# -lt 2 ] || [[ "$2" == --* ]]; then
          echo "Error: --repo-name requires a value."
          usage
        fi
        REPO_NAME="$2"
        shift
        ;;
      --repo-name=*)        REPO_NAME="${1#--repo-name=}" ;;
      --create-public)      VISIBILITY="--public" ;;
      --dest-https)         USE_HTTPS=true ;;
      --*) echo "Unknown option: $1"; usage ;;
      *)   POSITIONAL+=("$1") ;;
    esac
    shift
  done

  SOURCE_URL="${POSITIONAL[0]:-}"
  DESTINATION_URL="${POSITIONAL[1]:-}"
}

validate_args() {
  if [ -z "$SOURCE_URL" ]; then
    echo "Error: source clone URL is required."
    usage
  fi

  if [ -z "$DESTINATION_URL" ] && [ "$CREATE_GITHUB_REPO" = false ]; then
    echo "Error: destination clone URL is required unless --create-github-repo is specified."
    exit 1
  fi

  if [ -n "$DESTINATION_URL" ] && [ "$CREATE_GITHUB_REPO" = true ]; then
    echo "Error: do not provide a destination URL with --create-github-repo; use --repo-name to customise the repository name."
    exit 1
  fi

  # GitHub-specific flag validation
  if [ -n "$REPO_NAME" ] && [ "$CREATE_GITHUB_REPO" = false ]; then
    echo "Error: --repo-name is only valid with --create-github-repo."
    exit 1
  fi

  if [ "$VISIBILITY" = "--public" ] && [ "$CREATE_GITHUB_REPO" = false ]; then
    echo "Error: --create-public is only valid with --create-github-repo."
    exit 1
  fi

  if [ "$USE_HTTPS" = true ] && [ "$CREATE_GITHUB_REPO" = false ]; then
    echo "Error: --dest-https is only applicable when --create-github-repo is used."
    exit 1
  fi
}

# ==============================================================================
# Provider: GitHub (gh CLI)
#
# To add another provider (e.g. GitLab), follow this pattern:
#   create_<provider>_repo() - create the repo using that provider's CLI,
#                              and set DESTINATION_URL
# Then call it from main() in the provider repo creation section.
# ==============================================================================

create_github_repo() {
  if ! gh --version &> /dev/null; then
    echo "Error: gh CLI is not installed."
    echo "Install it with: brew install gh  (or see https://github.com/cli/cli#installation)"
    echo "Then authenticate with: gh auth login"
    exit 1
  fi
  local repo_name
  if [ -n "$REPO_NAME" ]; then
    repo_name="$REPO_NAME"
  else
    repo_name=$(basename "$SOURCE_URL" .git)
  fi
  section "Creating GitHub repository"
  echo "    Name:       $repo_name"
  echo "    Visibility: ${VISIBILITY#--}"
  echo "    Running:    gh repo create \"$repo_name\" \"$VISIBILITY\""
  if ! gh repo create "$repo_name" "$VISIBILITY"; then
    echo "Error: failed to create GitHub repository '$repo_name'. Aborting."
    exit 1
  fi
  local https_url
  https_url=$(gh repo view "$repo_name" --json url --jq .url)
  if [ "$USE_HTTPS" = true ]; then
    DESTINATION_URL="$https_url"
  else
    # Convert HTTPS URL to SSH format:
    # https://github.com/owner/repo.git -> git@github.com:owner/repo.git
    DESTINATION_URL=$(echo "$https_url" | sed -E 's|https://github.com/([^/]+/[^/]+)(\.git)?$|git@github.com:\1.git|')
  fi
  echo "    URL:        $DESTINATION_URL"
}

# ==============================================================================
# Git operations
# ==============================================================================

check_local_dir() {
  if [ -d "$REPO_DIR" ]; then
    echo "Error: local directory '$REPO_DIR' already exists. Remove it and retry."
    exit 1
  fi
}

check_destination_empty() {
  section "Checking destination"
  local remote_refs
  if ! remote_refs=$(git ls-remote "$DESTINATION_URL" 2>&1); then
    echo "Error: could not connect to destination repository: $remote_refs"
    exit 1
  fi
  if echo "$remote_refs" | grep -q .; then
    echo "Error: destination repository is not empty. Aborting to avoid overwrite."
    exit 1
  fi
  echo "    Destination is empty, proceeding."
}

clone_and_push() {
  section "Cloning source"
  echo "    $SOURCE_URL"
  git clone --mirror --origin source "$SOURCE_URL"

  cd "$REPO_DIR"
  git remote add origin "$DESTINATION_URL"

  section "Pushing to destination"
  echo "    $DESTINATION_URL"
  git push --mirror origin
}

do_cleanup() {
  section "Cleaning up"
  cd ..
  rm -rf "$REPO_DIR"
  echo "    Removed $REPO_DIR"
}

# ==============================================================================
# Main
# ==============================================================================

main() {
  parse_args "$@"
  validate_args

  REPO_DIR=$(basename "$SOURCE_URL" .git).git
  check_local_dir

  # Provider repo creation, or verify the destination exists and is empty
  if [ "$CREATE_GITHUB_REPO" = true ]; then
    create_github_repo
  else
    check_destination_empty
  fi

  clone_and_push

  if [ "$CLEANUP" = true ]; then
    do_cleanup
  fi

  echo ""
  echo "Done."
}

main "$@"
