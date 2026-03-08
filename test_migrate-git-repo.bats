#!/usr/bin/env bats

# Tests for migrate-git-repo.sh
#
# Mocks git and gh by prepending a stubs directory to PATH so the real
# binaries are never called. Each test can customise stub behaviour via
# environment variables (see stub helpers below).

SCRIPT="$BATS_TEST_DIRNAME/migrate-git-repo.sh"
STUBS_DIR="$BATS_TEST_TMPDIR/stubs"

SOURCE_URL="git@bitbucket.org:org/repo.git"
DEST_URL="git@github.com:org/repo.git"
GITHUB_SOURCE_URL="git@bitbucket.org:org/repo.git"

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  mkdir -p "$STUBS_DIR"
  export PATH="$STUBS_DIR:$PATH"
  export BATS_TEST_TMPDIR

  # Default git stub: ls-remote returns empty (destination is empty),
  # clone and push succeed silently.
  create_git_stub \
    ls_remote_exit=0 \
    ls_remote_output="" \
    clone_exit=0 \
    push_exit=0

  # Default gh stub: repo create and repo view succeed.
  create_gh_stub \
    installed=true \
    create_exit=0 \
    view_output="https://github.com/org/repo"
}

teardown() {
  # Clean up any .git mirror dirs created in the working directory
  rm -rf "$BATS_TEST_TMPDIR"/stubs
  rm -rf repo.git 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Stub helpers
# ---------------------------------------------------------------------------

# create_git_stub ls_remote_exit=N ls_remote_output="..." clone_exit=N push_exit=N
create_git_stub() {
  local ls_remote_exit=0
  local ls_remote_output=""
  local clone_exit=0
  local push_exit=0

  for arg in "$@"; do
    case "$arg" in
      ls_remote_exit=*)   ls_remote_exit="${arg#*=}" ;;
      ls_remote_output=*) ls_remote_output="${arg#*=}" ;;
      clone_exit=*)       clone_exit="${arg#*=}" ;;
      push_exit=*)        push_exit="${arg#*=}" ;;
    esac
  done

  cat > "$STUBS_DIR/git" << STUB
#!/usr/bin/env bash
case "\$1" in
  ls-remote)
    echo "$ls_remote_output"
    exit $ls_remote_exit
    ;;
  clone)
    # Create the expected bare repo dir so the script's cd succeeds
    REPO_DIR=\$(basename "\${@: -1}" .git).git
    mkdir -p "\$REPO_DIR"
    # Stub out the remote add that happens inside the dir
    exit $clone_exit
    ;;
  remote)
    exit 0
    ;;
  push)
    exit $push_exit
    ;;
  *)
    exit 0
    ;;
esac
STUB
  chmod +x "$STUBS_DIR/git"
}

# create_gh_stub installed=true|false create_exit=N view_output="..." view_exit=N
create_gh_stub() {
  local installed=true
  local create_exit=0
  local view_output="https://github.com/org/repo"
  local view_exit=0

  for arg in "$@"; do
    case "$arg" in
      installed=*)   installed="${arg#*=}" ;;
      create_exit=*) create_exit="${arg#*=}" ;;
      view_output=*) view_output="${arg#*=}" ;;
      view_exit=*)   view_exit="${arg#*=}" ;;
    esac
  done

  if [ "$installed" = false ]; then
    # Shadow real gh with a stub that fails, so the script's `gh --version` check fails
    printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS_DIR/gh"
    chmod +x "$STUBS_DIR/gh"
    return
  fi

  cat > "$STUBS_DIR/gh" << STUB
#!/usr/bin/env bash
if [ "\$1" = "repo" ] && [ "\$2" = "create" ]; then
  exit $create_exit
fi
if [ "\$1" = "repo" ] && [ "\$2" = "view" ]; then
  echo "$view_output"
  exit $view_exit
fi
exit 0
STUB
  chmod +x "$STUBS_DIR/gh"
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "no arguments: exits 1 and prints usage" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "source URL only, no dest, no --create-github-repo: exits 1" {
  run "$SCRIPT" "$SOURCE_URL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"destination clone URL is required"* ]]
}

@test "unknown option: exits 1 and prints usage" {
  run "$SCRIPT" "$SOURCE_URL" "$DEST_URL" --unknown
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "--create-public without --create-github-repo: exits 1" {
  run "$SCRIPT" "$SOURCE_URL" "$DEST_URL" --create-public
  [ "$status" -eq 1 ]
  [[ "$output" == *"--create-public is only valid with --create-github-repo"* ]]
}

@test "--dest-https without --create-github-repo: exits 1" {
  run "$SCRIPT" "$SOURCE_URL" "$DEST_URL" --dest-https
  [ "$status" -eq 1 ]
  [[ "$output" == *"--dest-https is only applicable"* ]]
}

@test "destination URL with --create-github-repo: exits 1" {
  run "$SCRIPT" "$SOURCE_URL" "$DEST_URL" --create-github-repo
  [ "$status" -eq 1 ]
  [[ "$output" == *"do not provide a destination URL with --create-github-repo"* ]]
}

@test "options before arguments are accepted" {
  run "$SCRIPT" --cleanup "$SOURCE_URL" "$DEST_URL"
  [ "$status" -eq 0 ]
}

@test "options interspersed with arguments are accepted" {
  run "$SCRIPT" "$SOURCE_URL" --cleanup "$DEST_URL"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Local directory check
# ---------------------------------------------------------------------------

@test "exits if local mirror directory already exists" {
  mkdir -p repo.git
  run "$SCRIPT" "$SOURCE_URL" "$DEST_URL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
  rmdir repo.git
}

# ---------------------------------------------------------------------------
# Destination checks (non-GitHub)
# ---------------------------------------------------------------------------

@test "exits if destination repo is not empty" {
  create_git_stub ls_remote_exit=0 ls_remote_output="abc123 refs/heads/main"
  run "$SCRIPT" "$SOURCE_URL" "$DEST_URL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"destination repository is not empty"* ]]
}

@test "exits if destination repo is unreachable" {
  create_git_stub ls_remote_exit=1 ls_remote_output="fatal: repository not found"
  run "$SCRIPT" "$SOURCE_URL" "$DEST_URL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not connect to destination"* ]]
}

# ---------------------------------------------------------------------------
# --repo-name flag
# ---------------------------------------------------------------------------

@test "--repo-name without --create-github-repo: exits 1" {
  run "$SCRIPT" "$SOURCE_URL" "$DEST_URL" --repo-name custom-name
  [ "$status" -eq 1 ]
  [[ "$output" == *"--repo-name is only valid with --create-github-repo"* ]]
}

@test "--repo-name passes custom name to gh repo create" {
  cat > "$STUBS_DIR/gh" << 'STUB'
#!/usr/bin/env bash
if [ "$1" = "repo" ] && [ "$2" = "create" ]; then
  printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/gh_create_args"
  exit 0
fi
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  echo "https://github.com/org/custom-name"
  exit 0
fi
exit 0
STUB
  chmod +x "$STUBS_DIR/gh"
  run "$SCRIPT" "$GITHUB_SOURCE_URL" --create-github-repo --repo-name custom-name
  [ "$status" -eq 0 ]
  grep -q "custom-name" "$BATS_TEST_TMPDIR/gh_create_args"
}

@test "--repo-name with --dest-https: exits 0 and uses custom name" {
  create_gh_stub installed=true view_output="https://github.com/org/custom-name"
  run "$SCRIPT" "$GITHUB_SOURCE_URL" --create-github-repo --repo-name custom-name --dest-https
  [ "$status" -eq 0 ]
  [[ "$output" == *"custom-name"* ]]
  [[ "$output" == *"https://github.com/org/custom-name"* ]]
}

# ---------------------------------------------------------------------------
# GitHub repo creation
# ---------------------------------------------------------------------------

@test "--create-github-repo without gh installed: exits 1 with install instructions" {
  create_gh_stub installed=false
  run "$SCRIPT" "$GITHUB_SOURCE_URL" --create-github-repo
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh CLI is not installed"* ]]
  [[ "$output" == *"brew install gh"* ]]
}

@test "--create-github-repo with gh create failure: exits 1" {
  create_gh_stub installed=true create_exit=1
  run "$SCRIPT" "$GITHUB_SOURCE_URL" --create-github-repo
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to create GitHub repository"* ]]
}

@test "--create-github-repo: gh repo view failure exits non-zero" {
  create_gh_stub installed=true view_exit=1
  run "$SCRIPT" "$GITHUB_SOURCE_URL" --create-github-repo
  [ "$status" -ne 0 ]
}

@test "--create-github-repo --create-public: passes --public to gh repo create" {
  cat > "$STUBS_DIR/gh" << 'STUB'
#!/usr/bin/env bash
if [ "$1" = "repo" ] && [ "$2" = "create" ]; then
  printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/gh_create_args"
  exit 0
fi
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  echo "https://github.com/org/repo"
  exit 0
fi
exit 0
STUB
  chmod +x "$STUBS_DIR/gh"
  run "$SCRIPT" "$GITHUB_SOURCE_URL" --create-github-repo --create-public
  [ "$status" -eq 0 ]
  grep -q -- "--public" "$BATS_TEST_TMPDIR/gh_create_args"
}

@test "--create-github-repo: generates SSH destination URL by default" {
  create_gh_stub installed=true view_output="https://github.com/org/repo"
  run "$SCRIPT" "$GITHUB_SOURCE_URL" --create-github-repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"git@github.com:org/repo.git"* ]]
}

@test "--create-github-repo --dest-https: uses HTTPS destination URL" {
  create_gh_stub installed=true view_output="https://github.com/org/repo"
  run "$SCRIPT" "$GITHUB_SOURCE_URL" --create-github-repo --dest-https
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://github.com/org/repo"* ]]
}

@test "--create-github-repo: defaults to private" {
  run "$SCRIPT" "$GITHUB_SOURCE_URL" --create-github-repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"private"* ]]
}

@test "--create-github-repo --create-public: shows public visibility" {
  run "$SCRIPT" "$GITHUB_SOURCE_URL" --create-github-repo --create-public
  [ "$status" -eq 0 ]
  [[ "$output" == *"public"* ]]
}

# ---------------------------------------------------------------------------
# Git operation failures
# ---------------------------------------------------------------------------

@test "git clone failure: exits non-zero" {
  create_git_stub clone_exit=1
  run "$SCRIPT" "$SOURCE_URL" "$DEST_URL"
  [ "$status" -ne 0 ]
}

@test "git push failure: exits non-zero" {
  create_git_stub push_exit=1
  run "$SCRIPT" "$SOURCE_URL" "$DEST_URL"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Successful execution
# ---------------------------------------------------------------------------

@test "successful migration: exits 0 and prints Done" {
  run "$SCRIPT" "$SOURCE_URL" "$DEST_URL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Done."* ]]
}

@test "successful migration: passes --mirror to git push" {
  # Override git stub to record args
  cat > "$STUBS_DIR/git" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  ls-remote) exit 0 ;;
  clone)
    REPO_DIR=$(basename "${@: -1}" .git).git
    mkdir -p "$REPO_DIR"
    exit 0
    ;;
  remote) exit 0 ;;
  push)
    if [[ "$*" == *"--mirror"* ]]; then
      exit 0
    else
      echo "Error: --mirror flag missing from push" >&2
      exit 1
    fi
    ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBS_DIR/git"
  run "$SCRIPT" "$SOURCE_URL" "$DEST_URL"
  [ "$status" -eq 0 ]
}

@test "--cleanup: removes local mirror directory after push" {
  run "$SCRIPT" "$SOURCE_URL" "$DEST_URL" --cleanup
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed repo.git"* ]]
  [ ! -d "repo.git" ]
}
