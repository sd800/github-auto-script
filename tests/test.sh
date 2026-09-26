#!/usr/bin/env bash

set -uo pipefail

TEST_DIRECTORY="$({ cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P; } || exit 1)"
PROJECT_DIRECTORY="$(dirname "$TEST_DIRECTORY")"
TEST_TEMPORARY="$(mktemp -d "${TMPDIR:-/tmp}/github-auto-tests.XXXXXX")"
TEST_COUNT=0
FAILURE_COUNT=0

cleanup() {
  rm -rf "$TEST_TEMPORARY"
}
trap cleanup EXIT

export HOME="$TEST_TEMPORARY/home"
export NO_COLOR=1
export GITHUB_AUTO_TESTING=1
export GIT_AUTO_PRIVATE_DIRECTORY="$TEST_TEMPORARY/private"
export GIT_AUTO_OPTION_FILE="$TEST_TEMPORARY/option.txt"
mkdir -p "$HOME/.ssh/config.d"

# shellcheck source=../git-auto.sh
source "$PROJECT_DIRECTORY/git-auto.sh"

pass() {
  TEST_COUNT=$((TEST_COUNT + 1))
  printf 'ok %s - %s\n' "$TEST_COUNT" "$1"
}

fail_test() {
  TEST_COUNT=$((TEST_COUNT + 1))
  FAILURE_COUNT=$((FAILURE_COUNT + 1))
  printf 'not ok %s - %s\n' "$TEST_COUNT" "$1"
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail_test "$label (expected '$expected', got '$actual')"
  fi
}

assert_true() {
  local label="$1"
  shift

  if "$@"; then
    pass "$label"
  else
    fail_test "$label"
  fi
}

test_accounts() {
  assert_equal "0" "$ACCOUNT_COUNT" "new private configuration starts without accounts"
}

test_prompt_values() {
  local value=""

  value="$(prompt_value "test" "recommended" 2>/dev/null <<< "")"
  assert_equal "recommended" "$value" "Enter accepts the recommended value without prompt text contamination"

  value="$(prompt_value "test" "recommended" 2>/dev/null <<< "custom")"
  assert_equal "custom" "$value" "custom input is returned cleanly"
}

test_repository_parser() {
  local value=""
  local variants=(
    "octocat/repo"
    "octocat/repo.git"
    "github.com/octocat/repo"
    "www.github.com/octocat/repo/"
    "https://github.com/octocat/repo.git"
    "https://www.github.com/octocat/repo/tree/main"
    "https://github.com/octocat/repo/blob/main/README.md?plain=1#top"
    "git://github.com/octocat/repo.git"
    "git@github.com:octocat/repo.git"
    "ssh://git@github.com/octocat/repo.git"
    "ssh://git@ssh.github.com:443/octocat/repo.git"
    "git clone https://github.com/octocat/repo.git"
    "gh repo clone octocat/repo"
  )

  for value in "${variants[@]}"; do
    if parse_repository_input "$value"; then
      assert_equal "octocat/repo" "$REPOSITORY_OWNER/$REPOSITORY_NAME" "parses $value"
    else
      fail_test "parses $value"
    fi
  done

  if parse_repository_input "https://gitlab.com/octocat/repo"; then
    fail_test "rejects non-GitHub URL"
  else
    pass "rejects non-GitHub URL"
  fi
}

test_semver() {
  compare_semver "1.2.3" "1.2.2"
  assert_equal "1" "$SEMVER_COMPARISON" "compares patch versions"

  compare_semver "1.2.3-alpha" "1.2.3"
  assert_equal "-1" "$SEMVER_COMPARISON" "stable release beats prerelease"

  compare_semver "10.0.0" "2.0.0"
  assert_equal "1" "$SEMVER_COMPARISON" "compares multi-digit major versions"

  compare_semver "1.2.3+one" "1.2.3+two"
  assert_equal "0" "$SEMVER_COMPARISON" "ignores build metadata"

  compare_semver "1.2.3.10" "1.2.3.9"
  assert_equal "1" "$SEMVER_COMPARISON" "compares fourth numeric components"

  compare_semver "1.2.3.4.5" "1.2.3.4"
  assert_equal "1" "$SEMVER_COMPARISON" "compares version strings beyond four components"

  assert_true "accepts two-component versions" valid_release_version "1.2"
  assert_true "accepts arbitrarily long dotted versions" valid_release_version "1.2.3.4.5"
  if valid_release_version "1.2.3."; then
    fail_test "rejects an empty trailing version component"
  else
    pass "rejects an empty trailing version component"
  fi
  if extract_version_from_directory_name "project-1.2.3.4.5"; then
    assert_equal "1.2.3.4.5" "$HISTORY_DIRECTORY_VERSION" "historical folder names retain every version component"
  else
    fail_test "historical folder names retain every version component"
  fi
}

write_changelog() {
  local file="$1"
  local first="$2"
  local second="$3"

  mkdir -p "$(dirname "$file")"
  printf '## %s - 2026-08-31\n\n## %s - 2026-08-01\n' "$first" "$second" > "$file"
}

test_version_resolution() {
  local case_directory=""
  local status=0
  local saved_lookup_limit="$VERSION_LOOKUP_LIMIT_SECONDS"

  case_directory="$TEST_TEMPORARY/version-root-priority"
  mkdir -p "$case_directory"
  printf 'v1.2.3.4\n' > "$case_directory/VERSION"
  printf 'Version: 7.8.9\n' > "$case_directory/VERSION.txt"
  printf '{"version":"8.8.8"}\n' > "$case_directory/package.json"
  write_changelog "$case_directory/CHANGELOG.md" "9.9.9" "9.9.8"
  GIT_ROOT="$case_directory"
  VERSION_LOOKUP_LIMIT_SECONDS=0
  if resolve_release_version; then
    assert_equal "1.2.3.4|VERSION" "$RELEASE_VERSION|$VERSION_SOURCE" "root VERSION accepts four components and wins before other sources"
  else
    fail_test "root VERSION wins before package.json and recursive scans"
  fi
  printf 'not a release number\n' > "$case_directory/VERSION"
  if resolve_release_version; then
    assert_equal "7.8.9|VERSION.txt" "$RELEASE_VERSION|$VERSION_SOURCE" "root VERSION.txt remains an immediate fallback"
  else
    fail_test "root VERSION.txt remains an immediate fallback"
  fi
  printf 'not a release number\n' > "$case_directory/VERSION.txt"
  if resolve_release_version; then
    assert_equal "8.8.8|package.json" "$RELEASE_VERSION|$VERSION_SOURCE" "invalid root VERSION files fall through to package.json"
  else
    fail_test "invalid root VERSION files fall through to package.json"
  fi
  VERSION_LOOKUP_LIMIT_SECONDS="$saved_lookup_limit"

  case_directory="$TEST_TEMPORARY/version-root-metadata"
  mkdir -p "$case_directory"
  printf '{"name":"example","version":"2.7.1"}\n' > "$case_directory/manifest.json"
  write_changelog "$case_directory/CHANGELOG.md" "9.9.9" "9.9.8"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "2.7.1|manifest.json" "$RELEASE_VERSION|$VERSION_SOURCE" "root manifest.json version precedes root changelog"
  else
    fail_test "root manifest.json version precedes root changelog"
  fi

  case_directory="$TEST_TEMPORARY/version-root-toml"
  mkdir -p "$case_directory"
  printf '[tool.black]\nversion = "9.9.9"\n[project]\nname = "example"\nversion = "3.2.1"\n' > "$case_directory/pyproject.toml"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "3.2.1|pyproject.toml" "$RELEASE_VERSION|$VERSION_SOURCE" "pyproject.toml reads the project version, not another tool section"
  else
    fail_test "pyproject.toml reads the project version, not another tool section"
  fi

  case_directory="$TEST_TEMPORARY/version-root-cargo"
  mkdir -p "$case_directory"
  printf '[dependencies]\nversion = "9.9.9"\n[package]\nname = "example"\nversion = "3.6.1"\n' > "$case_directory/Cargo.toml"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "3.6.1|Cargo.toml" "$RELEASE_VERSION|$VERSION_SOURCE" "Cargo.toml reads the package version"
  else
    fail_test "Cargo.toml reads the package version"
  fi

  case_directory="$TEST_TEMPORARY/version-root-pubspec"
  mkdir -p "$case_directory"
  printf 'name: example\nversion: 2.9.1+3\ndependencies:\n  version: 9.9.9\n' > "$case_directory/pubspec.yaml"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "2.9.1+3|pubspec.yaml" "$RELEASE_VERSION|$VERSION_SOURCE" "pubspec.yaml reads its top-level version"
  else
    fail_test "pubspec.yaml reads its top-level version"
  fi

  case_directory="$TEST_TEMPORARY/version-package"
  mkdir -p "$case_directory"
  printf '{"version":"4.5.6"}\n' > "$case_directory/package.json"
  write_changelog "$case_directory/CHANGELOG.md" "9.0.0" "8.0.0"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "4.5.6|package.json" "$RELEASE_VERSION|$VERSION_SOURCE" "package.json precedes recursive version sources"
  else
    fail_test "package.json precedes recursive version sources"
  fi

  VERSION_LOOKUP_LIMIT_SECONDS=0
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "4.5.6|package.json" "$RELEASE_VERSION|$VERSION_SOURCE" "package.json is checked before the recursive lookup time limit"
  else
    fail_test "package.json is checked before the recursive lookup time limit"
  fi

  case_directory="$TEST_TEMPORARY/version-timeout"
  mkdir -p "$case_directory"
  write_changelog "$case_directory/CHANGELOG.md" "2.5.1" "2.5.0"
  GIT_ROOT="$case_directory"
  status=0
  resolve_release_version || status=$?
  assert_equal "124" "$status" "root changelog lookup stops at its time limit"
  VERSION_LOOKUP_LIMIT_SECONDS="$saved_lookup_limit"
  if prompt_release_version_after_timeout "Update" >/dev/null 2>&1 <<< "2.5.1.7"; then
    assert_equal "2.5.1.7|manual" "$RELEASE_VERSION|$VERSION_POSITION" "a timeout accepts a four-component manual version"
  else
    fail_test "a timeout asks for an optional release version"
  fi

  case_directory="$TEST_TEMPORARY/version-primary"
  mkdir -p "$case_directory"
  write_changelog "$case_directory/CHANGELOG.md" "2.0.0" "1.9.0"
  write_changelog "$case_directory/CHANGELOG.zh-CN.md" "8.0.0" "7.0.0"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "8.0.0|CHANGELOG.zh-CN.md" "$RELEASE_VERSION|$VERSION_SOURCE" "all changelog names participate in highest-version selection"
  else
    fail_test "all changelog names participate in highest-version selection"
  fi

  case_directory="$TEST_TEMPORARY/version-short-package"
  mkdir -p "$case_directory"
  printf '{"version":"4.5"}\n' > "$case_directory/package.json"
  write_changelog "$case_directory/CHANGELOG.md" "4.6" "4.5"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "4.5|package.json" "$RELEASE_VERSION|$VERSION_SOURCE" "a two-component package version is valid"
  else
    fail_test "a two-component package version is valid"
  fi
  printf '{"version":"4.5."}\n' > "$case_directory/package.json"
  if resolve_release_version; then
    assert_equal "4.6|CHANGELOG.md" "$RELEASE_VERSION|$VERSION_SOURCE" "an invalid package version falls through to a two-component changelog version"
  else
    fail_test "an invalid package version falls through to a two-component changelog version"
  fi

  case_directory="$TEST_TEMPORARY/version-languages"
  mkdir -p "$case_directory"
  write_changelog "$case_directory/CHANGELOG.en.md" "3.1.0.7" "3.0.0.8"
  write_changelog "$case_directory/CHANGELOG.zh-CN.md" "3.4.0.9" "3.3.0.8"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "3.4.0.9|CHANGELOG.zh-CN.md" "$RELEASE_VERSION|$VERSION_SOURCE" "language variants use the highest multi-component version"
  else
    fail_test "language variants use the highest version"
  fi
  if extract_history_date_from_changelog "$case_directory/CHANGELOG.zh-CN.md" "3.4.0.9"; then
    assert_equal "2026-08-31" "$HISTORY_CHANGELOG_DATE" "historical date lookup matches a four-component changelog version"
  else
    fail_test "historical date lookup matches a four-component changelog version"
  fi

  case_directory="$TEST_TEMPORARY/version-recursive"
  mkdir -p "$case_directory/app" "$case_directory/dist/archive" "$case_directory/node_modules/dependency"
  write_changelog "$case_directory/CHANGELOG.md" "2.0.0" "1.0.0"
  write_changelog "$case_directory/app/CHANGELOG.fr.md" "5.0.0" "4.0.0"
  write_changelog "$case_directory/dist/CHANGELOG.es.md" "5.5.0" "5.1.0"
  write_changelog "$case_directory/dist/archive/CHANGELOG_zh.md" "6.0.0" "5.0.0"
  write_changelog "$case_directory/node_modules/dependency/CHANGELOG.md" "99.0.0" "98.0.0"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "2.0.0|CHANGELOG.md" "$RELEASE_VERSION|$VERSION_SOURCE" "a valid root changelog stops before scanning nested folders"
  else
    fail_test "a valid root changelog stops before scanning nested folders"
  fi
  printf 'No release entries here\n' > "$case_directory/CHANGELOG.md"
  printf 'Version: 7.8.9\n' > "$case_directory/app/VERSION.txt"
  if resolve_release_version; then
    assert_equal "7.8.9|app/VERSION.txt" "$RELEASE_VERSION|$VERSION_SOURCE" "direct child VERSION files are used before child changelogs"
  else
    fail_test "direct child VERSION files are used before child changelogs"
  fi
  printf 'not a version\n' > "$case_directory/app/VERSION.txt"
  if resolve_release_version; then
    assert_equal "5.5.0|dist/CHANGELOG.es.md" "$RELEASE_VERSION|$VERSION_SOURCE" "all direct child changelogs compete while grandchild changelog is ignored"
  else
    fail_test "all direct child changelogs compete while grandchild changelog is ignored"
  fi
  printf 'No release entries here\n' > "$case_directory/app/CHANGELOG.fr.md"
  printf 'No release entries here\n' > "$case_directory/dist/CHANGELOG.es.md"
  if resolve_release_version; then
    fail_test "grandchild and dependency versions alone do not qualify"
  else
    pass "grandchild and dependency versions alone do not qualify"
  fi

  case_directory="$TEST_TEMPORARY/version-direct-child-metadata"
  mkdir -p "$case_directory/app" "$case_directory/dist"
  printf '{"version":"2.8.1"}\n' > "$case_directory/app/manifest.json"
  write_changelog "$case_directory/dist/CHANGELOG.md" "7.7.7" "6.6.6"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "2.8.1|app/manifest.json" "$RELEASE_VERSION|$VERSION_SOURCE" "direct child manifest version is recognized before child changelog"
  else
    fail_test "direct child manifest version is recognized before child changelog"
  fi

  case_directory="$TEST_TEMPORARY/version-recursive-tie"
  mkdir -p "$case_directory/app"
  write_changelog "$case_directory/CHANGELOG_zh.md" "7.0.0" "6.0.0"
  write_changelog "$case_directory/app/CHANGELOG.md" "7.0.0" "6.0.0"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "7.0.0|CHANGELOG_zh.md" "$RELEASE_VERSION|$VERSION_SOURCE" "an equal root version remains the preferred source"
  else
    fail_test "an equal root version remains the preferred source"
  fi

  case_directory="$TEST_TEMPORARY/version-file"
  mkdir -p "$case_directory"
  printf 'Version: v6.7.8.9.10\n' > "$case_directory/VERSION.txt"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "6.7.8.9.10|VERSION.txt" "$RELEASE_VERSION|$VERSION_SOURCE" "VERSION file retains every version component"
  else
    fail_test "VERSION file remains a fallback"
  fi

  case_directory="$TEST_TEMPORARY/version-bottom"
  mkdir -p "$case_directory"
  printf '# [1.0.0] – August 1, 2026\n\n# [1.2.0] — August 31, 2026\n' > "$case_directory/CHANGELOG.md"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "1.2.0|bottom" "$RELEASE_VERSION|$VERSION_POSITION" "detects oldest-to-newest changelog order and Unicode dashes"
  else
    fail_test "detects oldest-to-newest changelog order and Unicode dashes"
  fi
}

test_ssh_config_discovery() {
  printf 'Include %s/config.d/*\n\nHost github-main\n    HostName github.com\n    IdentityFile ~/.ssh/main\n' "$HOME/.ssh" > "$HOME/.ssh/config"
  printf 'Host github-work\n    HostName github.com\n    IdentityFile ~/.ssh/work\n' > "$HOME/.ssh/config.d/work"
  chmod 600 "$HOME/.ssh/config" "$HOME/.ssh/config.d/work"

  SSH_DIRECTORY="$HOME/.ssh"
  SSH_CONFIG_FILE="$SSH_DIRECTORY/config"
  scan_ssh_aliases
  assert_equal "3" "$DISCOVERED_SSH_ALIAS_COUNT" "discovers aliases through Include files and the effective github.com connection"
  assert_true "recognizes effective GitHub HostName" ssh_alias_is_github "github-work"
  assert_equal \
    "$HOME/.ssh/example" \
    "$(expand_home_path '~/.ssh/example')" \
    "expands SSH tilde paths without retaining a literal tilde"
}

test_alias_allocation() {
  local alias_home="$TEST_TEMPORARY/alias-home"
  local installed_key="$alias_home/.ssh/id_ed25519_github-test-user"

  mkdir -p "$alias_home/.ssh"
  printf 'Host github-johnjoe\n    HostName github.com\n    IdentityFile ~/.ssh/id_ed25519_github-johnjoe\n' > "$alias_home/.ssh/config"
  : > "$alias_home/.ssh/id_ed25519_github-johnjoe-1"

  SSH_DIRECTORY="$alias_home/.ssh"
  SSH_CONFIG_FILE="$SSH_DIRECTORY/config"
  next_available_alias "JohnJoe"
  assert_equal "github-johnjoe-2" "$NEW_SSH_ALIAS" "increments aliases across config and key collisions"

  : > "$installed_key"
  install_ssh_alias_block "test-user" "github-test-user" "$installed_key"
  if ssh_alias_is_github "github-test-user"; then
    assert_equal \
      "$installed_key" \
      "$(resolve_alias_identity_file 'github-test-user')" \
      "installs a validated SSH alias block"
  else
    fail_test "installs a validated SSH alias block"
  fi
}

test_git_binding_and_commit() {
  local repository="$TEST_TEMPORARY/git-project"
  local initial_repository="$TEST_TEMPORARY/initial-version-project"
  local dedicated_version_repository="$TEST_TEMPORARY/dedicated-version-project"
  local multi_part_package_repository="$TEST_TEMPORARY/initial-multi-part-package-project"
  local initial_template_repository="$TEST_TEMPORARY/initial-template-version-project"
  local fallback_repository="$TEST_TEMPORARY/fallback-message-project"
  local initial_no_version_repository="$TEST_TEMPORARY/initial-no-version-project"
  local bare_repository="$TEST_TEMPORARY/remote.git"
  local fake_bin="$TEST_TEMPORARY/fake-bin"
  local fake_key="$TEST_TEMPORARY/fake-key"
  local remote=""
  local push_remote=""
  local saved_name=""
  local saved_email=""
  local message=""
  local original_path_environment="$PATH"

  mkdir -p "$repository"
  git -C "$repository" init -q
  : > "$fake_key"

  GIT_ROOT="$repository"
  CURRENT_REPOSITORY_OWNER="johnjoe"
  CURRENT_REPOSITORY_NAME="example-repo"
  BOUND_USERNAME="johnjoe"
  BOUND_EMAIL="johnjoe@example.com"
  BOUND_SSH_ALIAS="github-johnjoe"
  BOUND_IDENTITY_FILE="$fake_key"

  if save_project_binding; then
    remote="$(git -C "$repository" remote get-url origin)"
    push_remote="$(git -C "$repository" remote get-url --push origin)"
    saved_name="$(git -C "$repository" config --local user.name)"
    saved_email="$(git -C "$repository" config --local user.email)"
    assert_equal "git@github-johnjoe:johnjoe/example-repo.git" "$remote" "normalizes origin to the matching owner account alias"
    assert_equal "$remote" "$push_remote" "pins the origin push address to the same account alias"
    assert_equal "johnjoe" "$saved_name" "commit display name equals GitHub username"
    assert_equal "johnjoe@example.com" "$saved_email" "stores repository-local account email"
  else
    fail_test "saves project binding"
  fi

  printf 'first\n' > "$repository/file.txt"
  printf '{"version":"1.0.0"}\n' > "$repository/package.json"
  git -C "$repository" add file.txt package.json
  git -C "$repository" commit -q -m "Initial commit"
  printf 'second\n' >> "$repository/file.txt"
  write_changelog "$repository/CHANGELOG.md" "7.8.9" "7.8.8"

  prompt_commit_message() {
    COMMIT_MESSAGE="$1"
  }

  if prepare_and_commit; then
    message="$(git -C "$repository" log -1 --pretty=%s)"
    assert_equal "Release 7.8.9" "$message" "uses resolved version for the proposed commit"
  else
    fail_test "commits staged project changes"
  fi

  mkdir -p "$initial_repository"
  git -C "$initial_repository" init -q
  git -C "$initial_repository" config user.name tester
  git -C "$initial_repository" config user.email tester@example.com
  write_changelog "$initial_repository/CHANGELOG.md" "8.9.1.2" "8.8.9.7"
  GIT_ROOT="$initial_repository"
  if prepare_and_commit; then
    message="$(git -C "$initial_repository" log -1 --pretty=%s)"
    assert_equal "Release 8.9.1.2" "$message" "a four-component changelog version takes priority over Initial commit"
  else
    fail_test "first commit uses its detected release version"
  fi

  mkdir -p "$dedicated_version_repository"
  git -C "$dedicated_version_repository" init -q
  git -C "$dedicated_version_repository" config user.name tester
  git -C "$dedicated_version_repository" config user.email tester@example.com
  printf '1.2.3.4\n' > "$dedicated_version_repository/VERSION"
  printf '{"version":"8.8.8"}\n' > "$dedicated_version_repository/package.json"
  write_changelog "$dedicated_version_repository/CHANGELOG.md" "9.9.9" "9.9.8"
  GIT_ROOT="$dedicated_version_repository"
  if prepare_and_commit; then
    message="$(git -C "$dedicated_version_repository" log -1 --pretty=%s)"
    assert_equal "Release 1.2.3.4" "$message" "a first commit uses every component of root VERSION over package and changelog"
  else
    fail_test "an actual commit uses the root VERSION over package and changelog"
  fi

  mkdir -p "$multi_part_package_repository"
  git -C "$multi_part_package_repository" init -q
  git -C "$multi_part_package_repository" config user.name tester
  git -C "$multi_part_package_repository" config user.email tester@example.com
  printf '{"version":"2.3.5.7.9"}\n' > "$multi_part_package_repository/package.json"
  GIT_ROOT="$multi_part_package_repository"
  if prepare_and_commit; then
    message="$(git -C "$multi_part_package_repository" log -1 --pretty=%s)"
    assert_equal "Release 2.3.5.7.9" "$message" "a first commit uses a five-component package version instead of Initial commit"
  else
    fail_test "a first commit uses a five-component package version instead of Initial commit"
  fi

  mkdir -p "$initial_template_repository"
  git -C "$initial_template_repository" init -q
  git -C "$initial_template_repository" config user.name tester
  git -C "$initial_template_repository" config user.email tester@example.com
  printf '{"version":"1.0.0"}\n' > "$initial_template_repository/package.json"
  GIT_ROOT="$initial_template_repository"
  if prepare_and_commit; then
    message="$(git -C "$initial_template_repository" log -1 --pretty=%s)"
    assert_equal "Release 1.0.0" "$message" "a template version included in the first commit remains eligible"
  else
    fail_test "a template version included in the first commit remains eligible"
  fi

  mkdir -p "$fallback_repository"
  git -C "$fallback_repository" init -q
  git -C "$fallback_repository" config user.name tester
  git -C "$fallback_repository" config user.email tester@example.com
  printf '{"version":"1.0.0"}\n' > "$fallback_repository/package.json"
  printf 'baseline\n' > "$fallback_repository/file.txt"
  git -C "$fallback_repository" add -A
  git -C "$fallback_repository" commit -qm baseline
  printf '{"version":"1.0.0","dependencies":{"example":"1.0.0"}}\n' > "$fallback_repository/package.json"
  printf 'changed\n' >> "$fallback_repository/file.txt"
  GIT_ROOT="$fallback_repository"
  if prepare_and_commit; then
    message="$(git -C "$fallback_repository" log -1 --pretty=%s)"
    assert_equal "Update" "$message" "an unchanged template version falls back to Update"
  else
    fail_test "an unchanged template version falls back to Update"
  fi

  printf '{"version":"2.3.1"}\n' > "$fallback_repository/package.json"
  printf 'release\n' >> "$fallback_repository/file.txt"
  if prepare_and_commit; then
    message="$(git -C "$fallback_repository" log -1 --pretty=%s)"
    assert_equal "Release 2.3.1" "$message" "a changed ordinary package version produces a release message"
  else
    fail_test "a changed ordinary package version produces a release message"
  fi
  printf 'later update\n' >> "$fallback_repository/file.txt"
  if prepare_and_commit; then
    message="$(git -C "$fallback_repository" log -1 --pretty=%s)"
    assert_equal "Release 2.3.1" "$message" "an unchanged ordinary package version remains eligible"
  else
    fail_test "an unchanged ordinary package version remains eligible"
  fi

  mkdir -p "$initial_no_version_repository"
  git -C "$initial_no_version_repository" init -q
  git -C "$initial_no_version_repository" config user.name tester
  git -C "$initial_no_version_repository" config user.email tester@example.com
  printf 'first\n' > "$initial_no_version_repository/file.txt"
  GIT_ROOT="$initial_no_version_repository"
  if prepare_and_commit; then
    message="$(git -C "$initial_no_version_repository" log -1 --pretty=%s)"
    assert_equal "Initial commit" "$message" "a first commit without a release version uses Initial commit"
  else
    fail_test "a first commit without a release version uses Initial commit"
  fi

  GIT_ROOT="$repository"

  create_pinned_ssh_wrapper
  if grep -Fq 'IdentitiesOnly=yes' "$PINNED_SSH_WRAPPER" &&
     grep -Fq 'GITHUB_AUTO_IDENTITY_FILE' "$PINNED_SSH_WRAPPER" &&
     grep -Fq 'ConnectTimeout=8' "$PINNED_SSH_WRAPPER" &&
     grep -Fq 'ServerAliveInterval=15' "$PINNED_SSH_WRAPPER" &&
     grep -Fq 'ServerAliveCountMax=2' "$PINNED_SSH_WRAPPER"; then
    pass "pinned SSH wrapper forces one identity"
  else
    fail_test "pinned SSH wrapper forces one identity"
  fi
  rm -rf "$PINNED_SSH_DIRECTORY"

  git init --bare -q "$bare_repository"
  mkdir -p "$fake_bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'for argument in "$@"; do\n'
    printf '  case "$argument" in\n'
    printf '    *git-upload-pack*) exec git-upload-pack "$FAKE_SSH_REPOSITORY" ;;\n'
    printf '    *git-receive-pack*) exec git-receive-pack "$FAKE_SSH_REPOSITORY" ;;\n'
    printf '  esac\n'
    printf 'done\n'
    printf 'exit 1\n'
  } > "$fake_bin/ssh"
  chmod 755 "$fake_bin/ssh"

  export FAKE_SSH_REPOSITORY="$bare_repository"
  PATH="$fake_bin:$PATH"
  export PATH
  if run_git_with_identity "$fake_key" push -u origin main >/dev/null 2>&1; then
    assert_equal \
      "$(git -C "$repository" rev-parse main)" \
      "$(git --git-dir="$bare_repository" rev-parse refs/heads/main)" \
      "strict identity wrapper completes an SSH Git push"
  else
    fail_test "strict identity wrapper completes an SSH Git push"
  fi
  PATH="$original_path_environment"
  export PATH
}

test_guided_updates() {
  local update_root="$TEST_TEMPORARY/guided-update"
  local update_home="$update_root/home"
  local repository="$update_root/repository"
  local fake_key="$update_home/.ssh/existing-account-key"
  local conflicting_key="$update_home/.ssh/another-account-key"
  local original_directory="$SCRIPT_DIRECTORY"
  local original_name="$SCRIPT_NAME"
  local original_ssh_directory="$SSH_DIRECTORY"
  local original_ssh_config="$SSH_CONFIG_FILE"
  local original_private_directory="$PRIVATE_DIRECTORY"
  local original_private_config="$PRIVATE_CONFIG_FILE"
  local remote=""
  local push_remote=""

  mkdir -p "$update_home/.ssh" "$repository"
  : > "$fake_key"
  : > "$conflicting_key"

  SCRIPT_DIRECTORY="$repository"
  SCRIPT_NAME="g.sh"
  PRIVATE_DIRECTORY="$update_root/private"
  PRIVATE_CONFIG_FILE="$PRIVATE_DIRECTORY/config.txt"
  ensure_private_config
  SSH_DIRECTORY="$update_home/.ssh"
  SSH_CONFIG_FILE="$SSH_DIRECTORY/config"

  printf 'Host github-old-user\n    HostName github.com\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n' "$fake_key" > "$SSH_CONFIG_FILE"
  load_accounts
  add_or_update_account "old-user" "101+old-user@users.noreply.github.com"
  write_accounts_to_private_config

  git -C "$repository" init -q
  GIT_ROOT="$repository"
  CURRENT_REPOSITORY_OWNER="old-user"
  CURRENT_REPOSITORY_NAME="old-repo"
  BOUND_USERNAME="old-user"
  BOUND_EMAIL="101+old-user@users.noreply.github.com"
  BOUND_SSH_ALIAS="github-old-user"
  BOUND_IDENTITY_FILE="$fake_key"
  save_project_binding

  UPDATE_ACCOUNT_USERNAME="old-user"
  UPDATE_OLD_USERNAME="old-user"
  UPDATE_OLD_EMAIL="101+old-user@users.noreply.github.com"
  UPDATE_OLD_OWNER="old-user"
  UPDATE_OLD_REPOSITORY="old-repo"
  UPDATE_NEW_USERNAME="old-user"
  UPDATE_NEW_EMAIL="$UPDATE_OLD_EMAIL"
  UPDATE_NEW_OWNER="old-user"
  UPDATE_NEW_REPOSITORY="new-repo"
  UPDATE_OLD_ALIAS="github-old-user"
  UPDATE_NEW_ALIAS="github-old-user"
  UPDATE_IDENTITY_FILE="$fake_key"
  UPDATE_INSTALL_ALIAS=false
  if update_apply_validated_settings no; then
    remote="$(git -C "$repository" remote get-url origin)"
    push_remote="$(git -C "$repository" remote get-url --push origin)"
    assert_equal "git@github-old-user:old-user/new-repo.git" "$remote" "repository-only update changes the origin repository name"
    assert_equal "$remote" "$push_remote" "repository-only update changes the explicit push address"
    assert_equal "old-user" "$(git -C "$repository" config --local user.name)" "repository-only update keeps the account identity"
  else
    fail_test "repository-only update applies validated settings"
  fi

  printf '\nHost github-new-user\n    HostName github.com\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n' "$conflicting_key" >> "$SSH_CONFIG_FILE"
  UPDATE_OLD_OWNER="old-user"
  UPDATE_OLD_REPOSITORY="new-repo"
  UPDATE_NEW_USERNAME="new-user"
  UPDATE_NEW_EMAIL="101+new-user@users.noreply.github.com"
  UPDATE_NEW_OWNER="new-user"
  UPDATE_NEW_REPOSITORY="new-repo"
  UPDATE_OLD_ALIAS="github-old-user"
  UPDATE_IDENTITY_FILE="$fake_key"
  update_prepare_alias yes
  assert_equal "github-new-user-1" "$UPDATE_NEW_ALIAS" "username update increments a conflicting new alias"
  assert_equal "true" "$UPDATE_INSTALL_ALIAS" "username update prepares a new alias for the existing key"

  if update_apply_validated_settings yes; then
    load_accounts
    assert_equal "1" "$ACCOUNT_COUNT" "username update replaces the visible account instead of adding a second account"
    assert_equal "new-user|101+new-user@users.noreply.github.com" "${ACCOUNT_USERNAMES[0]}|${ACCOUNT_EMAILS[0]}" "username update migrates the visible username and email"
    assert_equal "$fake_key" "$(resolve_alias_identity_file 'github-new-user-1')" "username update reuses the existing private key"
    assert_true "username update keeps the previous SSH alias" ssh_alias_is_github "github-old-user"
    assert_equal "new-user" "$(git -C "$repository" config --local user.name)" "username update changes the repository-local commit display name"
    assert_equal "git@github-new-user-1:new-user/new-repo.git" "$(git -C "$repository" remote get-url origin)" "username update migrates a personal repository owner"
    if [ ! -e "$SSH_DIRECTORY/id_ed25519_github-new-user" ] &&
       [ ! -e "$SSH_DIRECTORY/id_ed25519_github-new-user-1" ]; then
      pass "username update does not create another private key"
    else
      fail_test "username update does not create another private key"
    fi
  else
    fail_test "username-only update applies validated settings"
  fi

  if update_parse_repository_target "https://github.com/new-owner/moved-repo/settings" "new-user"; then
    fail_test "update rejects a repository owned by another account"
  else
    pass "update rejects a repository owned by another account"
  fi
  if update_parse_repository_target "https://github.com/new-user/moved-repo/settings" "new-user"; then
    assert_equal "new-user/moved-repo" "$UPDATE_NEW_OWNER/$UPDATE_NEW_REPOSITORY" "combined update accepts a full same-owner repository URL"
  else
    fail_test "combined update accepts a full same-owner repository URL"
  fi
  if update_parse_repository_target "renamed-again.git" "new-user"; then
    assert_equal "new-user/renamed-again" "$UPDATE_NEW_OWNER/$UPDATE_NEW_REPOSITORY" "combined update accepts only a new repository name"
  else
    fail_test "combined update accepts only a new repository name"
  fi

  UPDATE_ACCOUNT_USERNAME="new-user"
  UPDATE_OLD_USERNAME="new-user"
  UPDATE_NEW_USERNAME="final-user"
  UPDATE_NEW_EMAIL="101+final-user@users.noreply.github.com"
  UPDATE_NEW_OWNER="final-user"
  UPDATE_NEW_REPOSITORY="final-repo"
  UPDATE_OLD_ALIAS="github-new-user-1"
  UPDATE_IDENTITY_FILE="$fake_key"
  update_prepare_alias yes
  if update_apply_validated_settings yes; then
    load_accounts
    assert_equal "final-user" "${ACCOUNT_USERNAMES[0]}" "combined update migrates the account entry"
    assert_equal "git@${UPDATE_NEW_ALIAS}:final-user/final-repo.git" "$(git -C "$repository" remote get-url origin)" "combined update changes username and repository together"
    assert_equal "$fake_key" "$(git -C "$repository" config --local --get github-auto.identity-file)" "combined update preserves the strict key binding"
  else
    fail_test "combined username and repository update applies validated settings"
  fi

  SCRIPT_DIRECTORY="$original_directory"
  SCRIPT_NAME="$original_name"
  SSH_DIRECTORY="$original_ssh_directory"
  SSH_CONFIG_FILE="$original_ssh_config"
  PRIVATE_DIRECTORY="$original_private_directory"
  PRIVATE_CONFIG_FILE="$original_private_config"
  load_accounts
}

test_update_prompt_flow() {
  local flow_root="$TEST_TEMPORARY/update-prompt-flow"
  local flow_repository="$flow_root/repository"
  local flow_home="$flow_root/home"
  local flow_script="$flow_repository/g.sh"
  local flow_key="$flow_home/.ssh/account-key"
  local original_directory="$SCRIPT_DIRECTORY"
  local original_name="$SCRIPT_NAME"
  local original_ssh_directory="$SSH_DIRECTORY"
  local original_ssh_config="$SSH_CONFIG_FILE"
  local original_private_directory="$PRIVATE_DIRECTORY"
  local original_private_config="$PRIVATE_CONFIG_FILE"
  local saved_require_interactive=""
  local saved_identify_key_username=""
  local saved_run_git_with_identity=""
  local original_ui_language="$UI_LANGUAGE"
  local original_advanced_language="${ADVANCED_LANGUAGE:-en}"
  local output=""
  local before_git_config=""
  local before_private_config=""
  local before_ssh_config=""
  local identity_marker="$flow_root/unexpected-identity-check"
  local repository_marker="$flow_root/unexpected-repository-check"

  mkdir -p "$flow_repository" "$flow_home/.ssh"
  : > "$flow_script"
  chmod 755 "$flow_script"
  : > "$flow_key"
  printf 'Host github-flow-old\n    HostName github.com\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n' "$flow_key" > "$flow_home/.ssh/config"
  git -C "$flow_repository" init -q

  SCRIPT_DIRECTORY="$(cd "$flow_repository" && pwd -P)"
  SCRIPT_NAME="g.sh"
  SSH_DIRECTORY="$flow_home/.ssh"
  SSH_CONFIG_FILE="$SSH_DIRECTORY/config"
  PRIVATE_DIRECTORY="$flow_root/private"
  PRIVATE_CONFIG_FILE="$PRIVATE_DIRECTORY/config.txt"
  ensure_private_config
  GIT_ROOT="$flow_repository"
  load_accounts
  add_or_update_account "flow-old" "202+flow-old@users.noreply.github.com"
  write_accounts_to_private_config
  CURRENT_REPOSITORY_OWNER="flow-old"
  CURRENT_REPOSITORY_NAME="old-repo"
  BOUND_USERNAME="flow-old"
  BOUND_EMAIL="202+flow-old@users.noreply.github.com"
  BOUND_SSH_ALIAS="github-flow-old"
  BOUND_IDENTITY_FILE="$flow_key"
  save_project_binding

  saved_require_interactive="$(declare -f require_interactive)"
  saved_identify_key_username="$(declare -f identify_key_username)"
  saved_run_git_with_identity="$(declare -f run_git_with_identity)"
  require_interactive() {
    return 0
  }
  identify_key_username() {
    : > "$identity_marker"
    return 1
  }
  run_git_with_identity() {
    : > "$repository_marker"
    return 1
  }

  UI_LANGUAGE="zh"
  ADVANCED_LANGUAGE="zh"
  output="$(run_update_command 2>&1 <<< $'3\nflow-new\n\nrenamed-repo\n\n')"
  load_accounts
  assert_equal "flow-new" "${ACCOUNT_USERNAMES[0]}" "guided update collects a new username through the Chinese flow"
  assert_equal "flow-new@users.noreply.github.com" "${ACCOUNT_EMAILS[0]}" "guided update recommends a matching private commit email"
  assert_equal "git@github-flow-new:flow-new/renamed-repo.git" "$(git -C "$flow_repository" remote get-url origin)" "guided update applies username and repository changes after one confirmation"
  if printf '%s\n' "$output" | grep -Fq '已把指定的用户名、仓库地址、提交作者、SSH 密钥和 origin 保存到上面列出的本机配置文件中。' &&
     printf '%s\n' "$output" | grep -Fq '原账号密钥会继续使用，不会重复创建新密钥。'; then
    pass "guided update uses naturally localized Chinese explanations"
  else
    fail_test "guided update uses naturally localized Chinese explanations"
  fi
  if [ ! -e "$identity_marker" ] && [ ! -e "$repository_marker" ] &&
     printf '%s\n' "$output" | grep -Fq 'update 不会提前联网核对'; then
    pass "username and repository update runs no online precheck"
  else
    fail_test "username and repository update runs no online precheck"
  fi

  output="$(run_update_command 2>&1 <<< $'2\nlocal-only-repository\n\n')"
  assert_equal \
    "git@github-flow-new:flow-new/local-only-repository.git" \
    "$(git -C "$flow_repository" remote get-url origin)" \
    "repository-only update applies the new local destination"
  if [ ! -e "$identity_marker" ] && [ ! -e "$repository_marker" ]; then
    pass "repository-only update runs no SSH or remote access precheck"
  else
    fail_test "repository-only update runs no SSH or remote access precheck"
  fi

  before_git_config="$(git -C "$flow_repository" config --local --list | sort)"
  before_private_config="$(cat "$PRIVATE_CONFIG_FILE")"
  before_ssh_config="$(cat "$SSH_CONFIG_FILE")"
  output="$(run_update_command 2>&1 <<< $'2\nanother-repository\nn\n')"
  assert_equal "$before_git_config" "$(git -C "$flow_repository" config --local --list | sort)" "canceling update preserves every repository-local Git setting"
  assert_equal "$before_private_config" "$(cat "$PRIVATE_CONFIG_FILE")" "canceling update preserves private account configuration"
  assert_equal "$before_ssh_config" "$(cat "$SSH_CONFIG_FILE")" "canceling update preserves SSH configuration"
  if printf '%s\n' "$output" | grep -Fq '已取消；private/config.txt、~/.ssh/config、当前仓库的 .git/config、项目文件和 GitHub 远端仓库均未修改。'; then
    pass "Chinese update cancellation states the exact no-write result"
  else
    fail_test "Chinese update cancellation states the exact no-write result"
  fi

  eval "$saved_require_interactive"
  eval "$saved_identify_key_username"
  eval "$saved_run_git_with_identity"
  SCRIPT_DIRECTORY="$original_directory"
  SCRIPT_NAME="$original_name"
  SSH_DIRECTORY="$original_ssh_directory"
  SSH_CONFIG_FILE="$original_ssh_config"
  PRIVATE_DIRECTORY="$original_private_directory"
  PRIVATE_CONFIG_FILE="$original_private_config"
  UI_LANGUAGE="$original_ui_language"
  ADVANCED_LANGUAGE="$original_advanced_language"
  load_accounts
}

test_private_configuration() {
  local config_root="$TEST_TEMPORARY/private-configuration"
  local original_private_directory="$PRIVATE_DIRECTORY"
  local original_private_config="$PRIVATE_CONFIG_FILE"
  local original_ui_language="$UI_LANGUAGE"
  local original_theme="$THEME"
  local original_advanced_language="${ADVANCED_LANGUAGE:-en}"
  local engine_checksum_before=""
  local engine_checksum_after=""

  engine_checksum_before="$(cksum "$PROJECT_DIRECTORY/git-auto.sh" "$PROJECT_DIRECTORY"/src/*.sh "$PROJECT_DIRECTORY/src/option.txt" | cksum)"
  PRIVATE_DIRECTORY="$config_root/private"
  PRIVATE_CONFIG_FILE="$PRIVATE_DIRECTORY/config.txt"
  ensure_private_config
  load_accounts

  assert_equal "" "$(read_saved_language)" "new private config starts without a saved language"
  if choose_interface_language no >/dev/null 2>&1 <<< "2"; then
    assert_equal "zh" "$(read_saved_language)" "first language choice is written into private config"
  else
    fail_test "first language choice is written into private config"
  fi
  UI_LANGUAGE="en"
  initialize_language
  assert_equal "zh" "$UI_LANGUAGE" "later runs reuse the language stored in private config"

  save_theme_preference "dark"
  assert_equal "dark" "$(read_saved_theme)" "display preference is written into private config"
  if [ ! -e "$HOME/.config/github-auto" ]; then
    pass "preferences create no application config directory"
  else
    fail_test "preferences create no application config directory"
  fi

  if [ -f "$GIT_AUTO_OPTION_FILE" ] && [ ! -s "$GIT_AUTO_OPTION_FILE" ]; then
    pass "option file remains empty while no persistent switches exist"
  else
    fail_test "option file remains empty while no persistent switches exist"
  fi

  add_or_update_account "test-user" "test-user@example.com"
  write_accounts_to_private_config
  load_accounts

  assert_equal "1" "$ACCOUNT_COUNT" "private config stores a shared account"
  assert_equal "600" "$(file_mode "$PRIVATE_CONFIG_FILE")" "private config is readable only by its owner"
  assert_equal "700" "$(file_mode "$PRIVATE_DIRECTORY")" "private directory is accessible only by its owner"
  if grep -Fxq 'username: test-user' "$PRIVATE_CONFIG_FILE" &&
     grep -Fxq 'email: test-user@example.com' "$PRIVATE_CONFIG_FILE"; then
    pass "private account fields remain human-editable"
  else
    fail_test "private account fields remain human-editable"
  fi

  printf 'add-tags-to-historical-release: enabled\n' >> "$PRIVATE_CONFIG_FILE"
  load_accounts
  remove_retired_private_fields
  if ! grep -Fq 'add-tags-to-historical-release:' "$PRIVATE_CONFIG_FILE"; then
    pass "retired historical-tag setting is removed from private config"
  else
    fail_test "retired historical-tag setting is removed from private config"
  fi

  engine_checksum_after="$(cksum "$PROJECT_DIRECTORY/git-auto.sh" "$PROJECT_DIRECTORY"/src/*.sh "$PROJECT_DIRECTORY/src/option.txt" | cksum)"
  assert_equal "$engine_checksum_before" "$engine_checksum_after" "saving private settings never modifies the dispatcher or source modules"

  PRIVATE_DIRECTORY="$original_private_directory"
  PRIVATE_CONFIG_FILE="$original_private_config"
  UI_LANGUAGE="$original_ui_language"
  ADVANCED_LANGUAGE="$original_advanced_language"
  apply_theme "$original_theme"
  load_accounts
}

test_central_distribution() {
  local missing_module_root="$TEST_TEMPORARY/missing-module-installation"
  local missing_module_output=""
  local missing_module_status=0

  if [ ! -f "$PROJECT_DIRECTORY/git-auto.sh" ]; then
    fail_test "central git-auto.sh exists"
    return
  fi
  pass "central git-auto.sh exists"

  if ! grep -RFq '# >>> GITHUB ACCOUNTS >>>' "$PROJECT_DIRECTORY/git-auto.sh" "$PROJECT_DIRECTORY/src" &&
     ! grep -RFq '# interface-language:' "$PROJECT_DIRECTORY/git-auto.sh" "$PROJECT_DIRECTORY/src"; then
    pass "central engine contains no personalized account or preference block"
  else
    fail_test "central engine contains no personalized account or preference block"
  fi

  if grep -Fxq 'private/' "$PROJECT_DIRECTORY/.gitignore"; then
    pass "private is ignored by the public repository"
  else
    fail_test "private is ignored by the public repository"
  fi

  if [ -f "$PROJECT_DIRECTORY/src/option.txt" ] && [ ! -s "$PROJECT_DIRECTORY/src/option.txt" ]; then
    pass "tracked option file is empty while no persistent switches exist"
  else
    fail_test "tracked option file is empty while no persistent switches exist"
  fi

  if [ ! -e "$PROJECT_DIRECTORY/dist" ] && [ -f "$PROJECT_DIRECTORY/g.sh" ]; then
    pass "central project includes one public copy-ready launcher and no personal script copy"
  else
    fail_test "central project includes one public copy-ready launcher and no personal script copy"
  fi

  if ! grep -Eq '^/?g\.sh/?$' "$PROJECT_DIRECTORY/.gitignore" &&
     [ "$(find "$PROJECT_DIRECTORY" -maxdepth 1 -type f -name '*.sh' | wc -l | tr -d ' ')" -eq 2 ] &&
     [ "$(find "$PROJECT_DIRECTORY/src" -maxdepth 1 -type f -name '*.sh' | wc -l | tr -d ' ')" -eq 8 ] &&
     [ "$(wc -l < "$PROJECT_DIRECTORY/git-auto.sh" | tr -d ' ')" -le 100 ] &&
     grep -Fq 'GIT_AUTO_MODULES=(' "$PROJECT_DIRECTORY/git-auto.sh" &&
     grep -RFq 'run_project_flow()' "$PROJECT_DIRECTORY/src" &&
     ! grep -Fq 'run_project_flow()' "$PROJECT_DIRECTORY/g.sh"; then
    pass "git-auto.sh is a small dispatcher while src contains the central implementation"
  else
    fail_test "git-auto.sh is a small dispatcher while src contains the central implementation"
  fi

  mkdir -p "$missing_module_root/src" "$missing_module_root/private"
  cp "$PROJECT_DIRECTORY/git-auto.sh" "$missing_module_root/git-auto.sh"
  cp "$PROJECT_DIRECTORY"/src/*.sh "$missing_module_root/src/"
  rm "$missing_module_root/src/40-history.sh"
  GIT_AUTO_PRIVATE_DIRECTORY="$missing_module_root/private" \
    GITHUB_AUTO_TESTING=1 \
    bash "$missing_module_root/git-auto.sh" > /dev/null 2> "$missing_module_root/error.txt" || missing_module_status=$?
  missing_module_output="$(< "$missing_module_root/error.txt")"
  if [ "$missing_module_status" -ne 0 ] &&
     printf '%s\n' "$missing_module_output" | grep -Fq 'Required program module is missing'; then
    pass "dispatcher stops with an exact error before running an incomplete installation"
  else
    fail_test "dispatcher stops with an exact error before running an incomplete installation"
  fi
}

test_project_launcher() {
  local project_directory="$TEST_TEMPORARY/project launcher"
  local launcher_file="$project_directory/g.sh"
  local output=""
  local resolved_target=""
  local status=0

  mkdir -p "$project_directory"
  git -C "$project_directory" init -q
  if write_project_launcher "$project_directory"; then
    pass "central engine creates a lightweight project launcher"
  else
    fail_test "central engine creates a lightweight project launcher"
    return
  fi

  assert_true "generated launcher has valid Bash syntax" bash -n "$launcher_file"
  assert_equal "755" "$(file_mode "$launcher_file")" "generated launcher is executable"
  if [ "$(wc -l < "$launcher_file" | tr -d ' ')" -le 80 ] &&
     launcher_is_managed "$launcher_file" &&
     grep -Fq 'GIT_AUTO_LAUNCHER_PROTOCOL=1' "$launcher_file"; then
    pass "generated g.sh stays intentionally small"
  else
    fail_test "generated g.sh stays intentionally small"
  fi
  if cmp -s "$PROJECT_DIRECTORY/g.sh" "$launcher_file"; then
    pass "generated launcher is an exact copy of the public root g.sh"
  else
    fail_test "generated launcher is an exact copy of the public root g.sh"
  fi
  assert_equal "$PROJECT_DIRECTORY/git-auto.sh" "$(git -C "$project_directory" config --local --get github-auto.engine)" "launcher creation remembers the central engine only in local Git config"
  if git -C "$project_directory" check-ignore -q g.sh; then
    pass "generated launcher is excluded only in the local repository"
  else
    fail_test "generated launcher is excluded only in the local repository"
  fi

  output="$(GITHUB_AUTO_TESTING=0 "$launcher_file" invalid-command 2>&1)" || status=$?
  if [ "$status" -ne 0 ] && printf '%s\n' "$output" | grep -Fq './g.sh menu'; then
    pass "launcher forwards commands while preserving the g.sh interface name"
  else
    fail_test "launcher forwards commands while preserving the g.sh interface name"
  fi

  resolved_target="$(
    GIT_AUTO_PROJECT_ROOT="$project_directory" \
    GIT_AUTO_LAUNCHER_NAME="g.sh" \
    GIT_AUTO_LAUNCHER_ACTIVE=1 \
    GIT_AUTO_TESTING=1 \
    GIT_AUTO_PRIVATE_DIRECTORY="$GIT_AUTO_PRIVATE_DIRECTORY" \
      bash -c 'source "$1"; printf "%s" "$SCRIPT_DIRECTORY"' bash "$PROJECT_DIRECTORY/git-auto.sh"
  )"
  assert_equal "$(cd "$project_directory" && pwd -P)" "$resolved_target" "central engine uses the launcher folder as the exact project root"
}

test_public_documentation() {
  local product_name="Auto Script for GitHub Setup and Push"
  local file=""
  local english_sections=""
  local chinese_sections=""
  local english_versions=""
  local chinese_versions=""

  if grep -Fxq '[Simplified Chinese](README_zh.md)' "$PROJECT_DIRECTORY/README.md" &&
     ! grep -Fq '[English](' "$PROJECT_DIRECTORY/README.md"; then
    pass "English README links only to Simplified Chinese"
  else
    fail_test "English README links only to Simplified Chinese"
  fi

  if grep -Fxq '[English](README.md)' "$PROJECT_DIRECTORY/README_zh.md" &&
     ! grep -Fq '[Chinese](' "$PROJECT_DIRECTORY/README_zh.md"; then
    pass "Chinese README links only to English"
  else
    fail_test "Chinese README links only to English"
  fi

  if grep -Fxq '[Simplified Chinese](CHANGELOG_zh.md)' "$PROJECT_DIRECTORY/CHANGELOG.md" &&
     ! grep -Fq '[English](' "$PROJECT_DIRECTORY/CHANGELOG.md"; then
    pass "English changelog links only to Simplified Chinese"
  else
    fail_test "English changelog links only to Simplified Chinese"
  fi

  if grep -Fxq '[English](CHANGELOG.md)' "$PROJECT_DIRECTORY/CHANGELOG_zh.md" &&
     ! grep -Fq '[Chinese](' "$PROJECT_DIRECTORY/CHANGELOG_zh.md"; then
    pass "Chinese changelog links only to English"
  else
    fail_test "Chinese changelog links only to English"
  fi

  if LC_ALL=C grep -q '[^ -~[:space:]]' "$PROJECT_DIRECTORY/README.md"; then
    fail_test "primary README contains en-US ASCII prose only"
  else
    pass "primary README contains en-US ASCII prose only"
  fi

  for file in \
    "$PROJECT_DIRECTORY/git-auto.sh" \
    "$PROJECT_DIRECTORY/g.sh" \
    "$PROJECT_DIRECTORY/README.md" \
    "$PROJECT_DIRECTORY/README_zh.md" \
    "$PROJECT_DIRECTORY/CHANGELOG.md" \
    "$PROJECT_DIRECTORY/CHANGELOG_zh.md"; do
    if ! grep -Fq "$product_name" "$file"; then
      fail_test "uses the unified product name in ${file#"$PROJECT_DIRECTORY"/}"
      continue
    fi
    pass "uses the unified product name in ${file#"$PROJECT_DIRECTORY"/}"
  done

  english_sections="$(grep -c '^## ' "$PROJECT_DIRECTORY/README.md")"
  chinese_sections="$(grep -c '^## ' "$PROJECT_DIRECTORY/README_zh.md")"
  assert_equal "$english_sections" "$chinese_sections" "README language versions keep the same section count"

  english_versions="$(grep '^## [0-9]' "$PROJECT_DIRECTORY/CHANGELOG.md" | sed 's/[[:space:]]*$//')"
  chinese_versions="$(grep '^## [0-9]' "$PROJECT_DIRECTORY/CHANGELOG_zh.md" | sed 's/[[:space:]]*$//')"
  assert_equal "$english_versions" "$chinese_versions" "changelog language versions keep the same releases"
}

test_project_root_identity() {
  local repository="$TEST_TEMPORARY/root-identity/repository"
  local equivalent_path="$TEST_TEMPORARY/root-identity/equivalent-path"
  local nested_directory="$repository/nested"
  local original_directory="$SCRIPT_DIRECTORY"
  local original_name="$SCRIPT_NAME"
  local original_root="${GIT_ROOT:-}"
  local original_state="${PROJECT_GIT_STATE:-}"

  mkdir -p "$repository" "$nested_directory"
  git -C "$repository" init -q
  ln -s "$repository" "$equivalent_path"

  SCRIPT_DIRECTORY="$equivalent_path"
  SCRIPT_NAME="g.sh"
  if locate_project no && [ "$GIT_ROOT" -ef "$repository" ]; then
    pass "project-root detection accepts an equivalent path to the same directory"
  else
    fail_test "project-root detection accepts an equivalent path to the same directory"
  fi

  if (SCRIPT_DIRECTORY="$nested_directory"; locate_project no >/dev/null 2>&1) ||
     [ -e "$nested_directory/.git" ]; then
    fail_test "read-only project detection does not use the enclosing repository or initialize the child"
  else
    pass "read-only project detection does not use the enclosing repository or initialize the child"
  fi

  SCRIPT_DIRECTORY="$nested_directory"
  if locate_project yes >/dev/null 2>&1 &&
     [ "$GIT_ROOT" -ef "$nested_directory" ] &&
     [ "$PROJECT_GIT_STATE" = initialized ] &&
     [ "$(git -C "$nested_directory" rev-parse --show-toplevel)" -ef "$nested_directory" ] &&
     [ "$(git -C "$repository" rev-parse --show-toplevel)" -ef "$repository" ]; then
    pass "a child project can initialize its own nested Git repository without rebinding the parent"
  else
    fail_test "a child project can initialize its own nested Git repository without rebinding the parent"
  fi

  if locate_project no >/dev/null 2>&1 &&
     [ "$PROJECT_GIT_STATE" = existing ] &&
     [ "$GIT_ROOT" -ef "$nested_directory" ]; then
    pass "subsequent runs reuse the nested Git repository"
  else
    fail_test "subsequent runs reuse the nested Git repository"
  fi

  SCRIPT_DIRECTORY="$original_directory"
  SCRIPT_NAME="$original_name"
  GIT_ROOT="$original_root"
  PROJECT_GIT_STATE="$original_state"
}

test_existing_repository_state() {
  local repository="$TEST_TEMPORARY/existing-repository-state"
  local original_directory="$SCRIPT_DIRECTORY"
  local original_name="$SCRIPT_NAME"
  local original_root="${GIT_ROOT:-}"
  local original_state="${PROJECT_GIT_STATE:-}"
  local original_language="$UI_LANGUAGE"
  local before_config=""
  local after_config=""
  local output=""
  local git_directory=""

  mkdir -p "$repository"
  git -C "$repository" init -q
  git -C "$repository" config user.name tester
  git -C "$repository" config user.email tester@example.com
  printf 'existing\n' > "$repository/file.txt"
  git -C "$repository" add file.txt
  git -C "$repository" commit -qm existing
  git -C "$repository" branch -M main

  SCRIPT_DIRECTORY="$repository"
  SCRIPT_NAME="g.sh"
  UI_LANGUAGE="en"
  before_config="$(git -C "$repository" config --local --list | sort)"
  if locate_project no; then
    output="$(describe_and_validate_project_state 2>&1)"
    after_config="$(git -C "$repository" config --local --list | sort)"
    assert_equal "existing" "$PROJECT_GIT_STATE" "existing repository is classified before any setup"
    assert_equal "$before_config" "$after_config" "read-only project detection does not rewrite local Git configuration"
    if printf '%s\n' "$output" | grep -Fq 'Existing Git repository detected:' &&
       printf '%s\n' "$output" | grep -Fq 'git init will not run again.' &&
       printf '%s\n' "$output" | grep -Fq 'Current branch: main'; then
      pass "existing repository explanation distinguishes detection from initialization"
    else
      fail_test "existing repository explanation distinguishes detection from initialization"
    fi
  else
    fail_test "existing repository is classified before any setup"
    fail_test "read-only project detection does not rewrite local Git configuration"
    fail_test "existing repository explanation distinguishes detection from initialization"
  fi

  git -C "$repository" checkout -q --detach
  if describe_and_validate_project_state >/dev/null 2>&1; then
    fail_test "detached HEAD stops the normal push flow before changes"
  else
    pass "detached HEAD stops the normal push flow before changes"
  fi
  git -C "$repository" checkout -q main

  git_directory="$(git -C "$repository" rev-parse --absolute-git-dir)"
  mkdir -p "$git_directory/rebase-merge"
  if describe_and_validate_project_state >/dev/null 2>&1; then
    fail_test "an unfinished Git operation stops the normal push flow"
  else
    pass "an unfinished Git operation stops the normal push flow"
  fi
  rmdir "$git_directory/rebase-merge"

  SCRIPT_DIRECTORY="$original_directory"
  SCRIPT_NAME="$original_name"
  GIT_ROOT="$original_root"
  PROJECT_GIT_STATE="$original_state"
  UI_LANGUAGE="$original_language"
}

test_origin_alias_identity_selection() {
  local case_root="$TEST_TEMPORARY/origin-alias-identity"
  local repository="$case_root/repository"
  local fake_home="$case_root/home"
  local fake_key="$fake_home/.ssh/id_ed25519_github800"
  local original_ssh_directory="$SSH_DIRECTORY"
  local original_ssh_config="$SSH_CONFIG_FILE"
  local original_root="${GIT_ROOT:-}"
  local original_language="$UI_LANGUAGE"
  local saved_identify_key_username=""
  local before_config=""
  local identity_checks=0

  mkdir -p "$repository" "$fake_home/.ssh"
  git -C "$repository" init -q
  : > "$fake_key"
  printf 'Host github800\n    HostName github.com\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n' "$fake_key" > "$fake_home/.ssh/config"
  git -C "$repository" remote add origin git@github800:sd800/example.git
  git -C "$repository" config --local github-auto.username sd800
  git -C "$repository" config --local github-auto.ssh-alias github800
  git -C "$repository" config --local github-auto.identity-file "$fake_key"

  SSH_DIRECTORY="$fake_home/.ssh"
  SSH_CONFIG_FILE="$SSH_DIRECTORY/config"
  GIT_ROOT="$repository"
  UI_LANGUAGE="en"
  BOUND_USERNAME="sd800"
  BOUND_EMAIL="sd800@users.noreply.github.com"
  before_config="$(cat "$SSH_CONFIG_FILE")"
  saved_identify_key_username="$(declare -f identify_key_username)"
  identify_key_username() {
    identity_checks=$((identity_checks + 1))
    return 1
  }

  if read_origin_repository && ensure_bound_identity; then
    assert_equal "github800" "$CURRENT_ORIGIN_HOST" "existing origin preserves its SSH Host name as a local identity hint"
    assert_equal "github800|$fake_key" "$BOUND_SSH_ALIAS|$BOUND_IDENTITY_FILE" "saved project binding reuses its exact local SSH key"
    assert_equal "$before_config" "$(cat "$SSH_CONFIG_FILE")" "local binding reuse creates no replacement key or SSH Host"
    assert_equal "0" "$identity_checks" "ordinary identity selection runs no SSH authentication precheck"
  else
    fail_test "existing origin preserves its SSH Host name as a local identity hint"
    fail_test "saved project binding reuses its exact local SSH key"
    fail_test "local binding reuse creates no replacement key or SSH Host"
    fail_test "ordinary identity selection runs no SSH authentication precheck"
  fi

  eval "$saved_identify_key_username"
  SSH_DIRECTORY="$original_ssh_directory"
  SSH_CONFIG_FILE="$original_ssh_config"
  GIT_ROOT="$original_root"
  UI_LANGUAGE="$original_language"
}

test_repository_owner_account_enforcement() {
  local repository="$TEST_TEMPORARY/repository-owner-enforcement"
  local fake_ssh_directory="$TEST_TEMPORARY/repository-owner-ssh"
  local owner_key="$fake_ssh_directory/id_ed25519_github-sd800"
  local original_root="${GIT_ROOT:-}"
  local original_language="$UI_LANGUAGE"
  local original_ssh_directory="$SSH_DIRECTORY"
  local original_ssh_config="$SSH_CONFIG_FILE"
  local original_project_binding_reused="${PROJECT_BINDING_REUSED:-false}"
  local saved_ensure_bound_identity=""
  local saved_verify_repository_access=""
  local saved_identify_key_username=""
  local saved_run_git_with_identity=""
  local saved_prompt_commit_message=""
  local output=""
  local output_file="$TEST_TEMPORARY/repository-owner-fast-path-output"
  local message=""
  local identity_checks=0
  local repository_checks=0
  local commit_prompt_checks=0
  local identity_marker="$TEST_TEMPORARY/unexpected-bind-identity-check"
  local repository_marker="$TEST_TEMPORARY/unexpected-bind-repository-check"

  mkdir -p "$repository"
  git -C "$repository" init -q
  git -C "$repository" config --local github-auto.username davidsdd
  GIT_ROOT="$repository"
  CURRENT_REPOSITORY_OWNER="sd800"
  CURRENT_REPOSITORY_NAME="github-auto-script"
  ACCOUNT_USERNAMES=("davidsdd" "sd800")
  ACCOUNT_EMAILS=("davidsdd@example.com" "sd800@example.com")
  ACCOUNT_COUNT=2
  UI_LANGUAGE="en"

  output="$(select_account_for_repository "$CURRENT_REPOSITORY_OWNER" davidsdd 2>&1)"
  assert_equal "sd800" "$BOUND_USERNAME" "repository owner overrides a mismatched saved or supplied account"
  if printf '%s\n' "$output" | grep -Fq 'The mismatched binding will not be used.'; then
    pass "mismatched repository binding is explained before correction"
  else
    fail_test "mismatched repository binding is explained before correction"
  fi

  BOUND_USERNAME="davidsdd"
  BOUND_EMAIL="davidsdd@example.com"
  BOUND_SSH_ALIAS="github-davidsdd"
  BOUND_IDENTITY_FILE="$TEST_TEMPORARY/davidsdd-key"
  : > "$BOUND_IDENTITY_FILE"
  if save_project_binding >/dev/null 2>&1; then
    fail_test "binding refuses an account that differs from the repository owner"
  else
    pass "binding refuses an account that differs from the repository owner"
  fi

  mkdir -p "$fake_ssh_directory"
  : > "$owner_key"
  printf 'Host github-sd800\n    HostName github.com\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n' \
    "$owner_key" > "$fake_ssh_directory/config"
  SSH_DIRECTORY="$fake_ssh_directory"
  SSH_CONFIG_FILE="$fake_ssh_directory/config"
  BOUND_USERNAME="sd800"
  BOUND_EMAIL="sd800@example.com"
  BOUND_SSH_ALIAS="github-sd800"
  BOUND_IDENTITY_FILE="$owner_key"
  save_project_binding

  saved_ensure_bound_identity="$(declare -f ensure_bound_identity)"
  saved_verify_repository_access="$(declare -f verify_repository_access)"
  ensure_bound_identity() {
    identity_checks=$((identity_checks + 1))
    return 1
  }
  verify_repository_access() {
    repository_checks=$((repository_checks + 1))
    return 1
  }
  PROJECT_BINDING_REUSED=false
  configure_project > "$output_file" 2>&1
  output="$(< "$output_file")"
  assert_equal "true" "$PROJECT_BINDING_REUSED" "established owner binding enables the direct push path"
  assert_equal "0|0" "$identity_checks|$repository_checks" "direct push skips repeated SSH identity and ls-remote checks"
  if printf '%s\n' "$output" | grep -Fq 'directly to add, commit, and push'; then
    pass "direct push explains the simplified established-project flow"
  else
    fail_test "direct push explains the simplified established-project flow"
  fi
  eval "$saved_ensure_bound_identity"
  eval "$saved_verify_repository_access"

  git -C "$repository" config --local --unset-all remote.origin.pushurl
  saved_identify_key_username="$(declare -f identify_key_username)"
  saved_run_git_with_identity="$(declare -f run_git_with_identity)"
  identify_key_username() {
    : > "$identity_marker"
    return 1
  }
  run_git_with_identity() {
    : > "$repository_marker"
    return 1
  }
  if configure_project "" bind > "$output_file" 2>&1 &&
     [ ! -e "$identity_marker" ] && [ ! -e "$repository_marker" ] &&
     load_established_project_binding; then
    pass "ordinary project binding repairs local settings without an online precheck"
  else
    fail_test "ordinary project binding repairs local settings without an online precheck"
  fi
  eval "$saved_identify_key_username"
  eval "$saved_run_git_with_identity"

  saved_prompt_commit_message="$(declare -f prompt_commit_message)"
  prompt_commit_message() {
    commit_prompt_checks=$((commit_prompt_checks + 1))
    COMMIT_MESSAGE="$1"
    return 0
  }
  write_changelog "$repository/CHANGELOG.md" "9.1.1" "8.9.9"
  prepare_and_commit > "$output_file" 2>&1
  message="$(git -C "$repository" log -1 --pretty=%s)"
  assert_equal "Release 9.1.1" "$message" "established project uses the detected release after confirmation"
  assert_equal "1" "$commit_prompt_checks" "established project confirms the final commit message once"
  if prepare_and_commit > "$output_file" 2>&1; then
    pass "a clean established project continues to the push stage"
  else
    fail_test "a clean established project continues to the push stage"
  fi
  eval "$saved_prompt_commit_message"

  UI_LANGUAGE="en"
  output="$(explain_push_failure 'rejected: non-fast-forward' main 2>&1)"
  if printf '%s\n' "$output" | grep -Fq 'GitHub has commits on main'; then
    pass "push failure explains a non-fast-forward rejection"
  else
    fail_test "push failure explains a non-fast-forward rejection"
  fi
  UI_LANGUAGE="zh"
  output="$(explain_push_failure 'ssh: connect to host github.com port 22: Connection timed out' main 2>&1)"
  if printf '%s\n' "$output" | grep -Fq '网络不可用或连接中断'; then
    pass "push failure explains a transient connection problem in Chinese"
  else
    fail_test "push failure explains a transient connection problem in Chinese"
  fi

  GIT_ROOT="$original_root"
  UI_LANGUAGE="$original_language"
  SSH_DIRECTORY="$original_ssh_directory"
  SSH_CONFIG_FILE="$original_ssh_config"
  PROJECT_BINDING_REUSED="$original_project_binding_reused"
}

test_commit_cancellation_boundary() {
  local repository="$TEST_TEMPORARY/commit-cancellation"
  local empty_repository="$TEST_TEMPORARY/empty-repository"
  local original_root="${GIT_ROOT:-}"
  local original_language="$UI_LANGUAGE"
  local before_cached=""
  local after_cached=""
  local before_head=""
  local output=""
  local status=0

  mkdir -p "$repository"
  git -C "$repository" init -q
  git -C "$repository" config user.name tester
  git -C "$repository" config user.email tester@example.com
  printf 'one\n' > "$repository/staged.txt"
  printf 'one\n' > "$repository/unstaged.txt"
  git -C "$repository" add staged.txt unstaged.txt
  git -C "$repository" commit -qm baseline

  printf 'two\n' >> "$repository/staged.txt"
  git -C "$repository" add staged.txt
  printf 'two\n' >> "$repository/unstaged.txt"
  GIT_ROOT="$repository"
  UI_LANGUAGE="en"
  before_cached="$(git -C "$repository" diff --cached)"
  before_head="$(git -C "$repository" rev-parse HEAD)"
  output="$(prepare_and_commit 2>&1 <<< ':cancel')" || status=$?
  after_cached="$(git -C "$repository" diff --cached)"

  assert_equal "2" "$status" "commit cancellation returns the dedicated clean-stop status"
  assert_equal "$before_cached" "$after_cached" "commit cancellation preserves pre-existing staged changes"
  assert_equal "$before_head" "$(git -C "$repository" rev-parse HEAD)" "commit cancellation creates no commit"
  if ! git -C "$repository" diff --quiet -- unstaged.txt &&
     printf '%s\n' "$output" | grep -Fq 'Commit canceled before the staging area was changed.'; then
    pass "commit cancellation occurs before staging all working-tree changes"
  else
    fail_test "commit cancellation occurs before staging all working-tree changes"
  fi

  mkdir -p "$empty_repository"
  git -C "$empty_repository" init -q
  GIT_ROOT="$empty_repository"
  status=0
  output="$(prepare_and_commit 2>&1)" || status=$?
  assert_equal "3" "$status" "an empty repository stops cleanly without attempting a push"
  if printf '%s\n' "$output" | grep -Fq 'no commit and no project files available to commit'; then
    pass "an empty repository explains why there is nothing to upload"
  else
    fail_test "an empty repository explains why there is nothing to upload"
  fi

  GIT_ROOT="$original_root"
  UI_LANGUAGE="$original_language"
}

test_central_root_launcher_dispatch() {
  local saved_initialize_language=""
  local saved_run_project_flow=""
  local saved_run_central_menu=""
  local original_script_directory="$SCRIPT_DIRECTORY"
  local original_running="$RUNNING_FROM_LAUNCHER"
  local output=""

  saved_initialize_language="$(declare -f initialize_language)"
  saved_run_project_flow="$(declare -f run_project_flow)"
  saved_run_central_menu="$(declare -f run_central_menu)"
  initialize_language() { return 0; }
  run_project_flow() { printf 'project-flow\n'; }
  run_central_menu() { printf 'central-menu\n'; }
  SCRIPT_DIRECTORY="$ENGINE_DIRECTORY"

  RUNNING_FROM_LAUNCHER=1
  output="$(main)"
  assert_equal "project-flow" "$output" "root g.sh operates on the central repository as a normal project"

  RUNNING_FROM_LAUNCHER=0
  output="$(main)"
  assert_equal "central-menu" "$output" "direct git-auto.sh keeps the central management menu"

  eval "$saved_initialize_language"
  eval "$saved_run_project_flow"
  eval "$saved_run_central_menu"
  SCRIPT_DIRECTORY="$original_script_directory"
  RUNNING_FROM_LAUNCHER="$original_running"
}

test_self_exclusion_modes() {
  local source_repository="$TEST_TEMPORARY/source-repository"
  local copied_repository="$TEST_TEMPORARY/copied-repository"
  local original_directory="$SCRIPT_DIRECTORY"
  local original_name="$SCRIPT_NAME"
  local original_root="${GIT_ROOT:-}"

  mkdir -p "$source_repository" "$copied_repository"
  git -C "$source_repository" init -q
  git -C "$copied_repository" init -q
  : > "$source_repository/helper.sh"
  git -C "$source_repository" add helper.sh

  SCRIPT_NAME="helper.sh"
  SCRIPT_DIRECTORY="$source_repository"
  GIT_ROOT="$source_repository"
  ensure_script_excluded
  if git -C "$source_repository" ls-files --error-unmatch -- helper.sh >/dev/null 2>&1 &&
     ! grep -Fq '/helper.sh' "$source_repository/.git/info/exclude"; then
    pass "a tracked source script remains tracked and is not locally excluded"
  else
    fail_test "a tracked source script remains tracked and is not locally excluded"
  fi

  : > "$copied_repository/helper.sh"
  SCRIPT_DIRECTORY="$copied_repository"
  GIT_ROOT="$copied_repository"
  ensure_script_excluded
  if git -C "$copied_repository" check-ignore -q helper.sh &&
     ! git -C "$copied_repository" ls-files --error-unmatch -- helper.sh >/dev/null 2>&1; then
    pass "an untracked standalone script excludes itself locally"
  else
    fail_test "an untracked standalone script excludes itself locally"
  fi

  SCRIPT_DIRECTORY="$original_directory"
  SCRIPT_NAME="$original_name"
  GIT_ROOT="$original_root"
}

test_historical_release_import() {
  local releases="$TEST_TEMPORARY/historical releases"
  local first="$releases/project-1.0.0"
  local second="$releases/project-2.0.0"
  local key_notes="$second/private-key-format-notes.txt"
  local real_key="$second/renamed-private-key.txt"
  local putty_key="$second/legacy-key.ppk"
  local remote="$TEST_TEMPORARY/history-remote.git"
  local fake_key="$TEST_TEMPORARY/history-fake-key"
  local working_directory="$TEST_TEMPORARY/active-working-directory"
  local divergent_directory="$TEST_TEMPORARY/divergent-working-directory"
  local messages=""
  local first_commit=""
  local first_tree=""
  local final_tree=""
  local saved_prompt_function=""
  local remote_head=""
  local local_head=""
  local head_count=""
  local unrelated_commit=""
  local original_max="$HISTORY_MAX_FILE_BYTES"
  local risk_output=""
  local working_readme_before=""
  local divergent_file_before=""
  local PATH="$TEST_TEMPORARY/history-bin:$PATH"
  local FAKE_SSH_REPOSITORY="$remote"

  # Keep the production account/URL guard active and replace transport only.
  mkdir -p "$TEST_TEMPORARY/history-bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'for argument in "$@"; do\n'
    printf '  case "$argument" in\n'
    printf '    *git-upload-pack*) exec git-upload-pack "$FAKE_SSH_REPOSITORY" ;;\n'
    printf '    *git-receive-pack*) exec git-receive-pack "$FAKE_SSH_REPOSITORY" ;;\n'
    printf '  esac\n'
    printf 'done\nexit 1\n'
  } > "$TEST_TEMPORARY/history-bin/ssh"
  chmod 755 "$TEST_TEMPORARY/history-bin/ssh"
  export PATH FAKE_SSH_REPOSITORY

  mkdir -p "$first/.git" "$second/nested/.git" "$releases/notes"
  printf '# first\n' > "$first/README.md"
  printf 'old\n' > "$first/old.txt"
  printf 'included despite ignore\n' > "$first/debug.log"
  printf '*.log\n' > "$first/.gitignore"
  printf 'metadata\n' > "$first/.DS_Store"
  printf 'must not be imported\n' > "$first/.git/config"
  printf '## 1.0.0 - 2024-01-02\n' > "$first/CHANGELOG.md"

  printf '# second\n' > "$second/README.md"
  printf 'new\n' > "$second/new.txt"
  printf 'must not be imported\n' > "$second/nested/.git/config"
  printf '## 2.0.0 - August 3, 2025\n' > "$second/CHANGELOG.md"
  printf 'token=value\n' > "$second/.env"
  printf '%s\n' \
    'A private-key header may look like this:' \
    '-----BEGIN OPENSSH PRIVATE KEY-----' > "$key_notes"
  printf '%s\n' \
    '-----BEGIN OPENSSH PRIVATE KEY-----' \
    'b3BlbnNzaC1rZXktdjEAAAAA' \
    '-----END OPENSSH PRIVATE KEY-----' > "$real_key"
  printf '%s\n' \
    'PuTTY-User-Key-File-3: ssh-ed25519' \
    'Encryption: none' > "$putty_key"

  if history_contains_private_key_header "$PROJECT_DIRECTORY/src/40-history.sh"; then
    fail_test "private-key detector does not report its own source code"
  else
    pass "private-key detector does not report its own source code"
  fi
  if history_contains_private_key_header "$key_notes"; then
    fail_test "private-key detector ignores explanatory text that quotes a key header"
  else
    pass "private-key detector ignores explanatory text that quotes a key header"
  fi
  assert_true "private-key detector recognizes a renamed OpenSSH key" history_contains_private_key_header "$real_key"
  assert_true "private-key detector recognizes a PuTTY key" history_contains_private_key_header "$putty_key"
  assert_true "private-key filename detector recognizes ppk files" history_sensitive_name "archived-key.ppk"
  HISTORY_REBUILD_DATES=true
  assert_equal "2024-01-02T12:00:00 +0000" "$(history_commit_date_for_release '2024-01-02')" "release-date reconstruction defaults to an explicit historical timestamp"
  HISTORY_REBUILD_DATES=false
  assert_equal "" "$(history_commit_date_for_release '2024-01-02')" "declining date reconstruction leaves commit time to Git"
  HISTORY_REBUILD_DATES=true

  if normalize_history_directory_input "file://${releases// /%20}"; then
    assert_equal "$(cd "$releases" && pwd -P)" "$HISTORY_NORMALIZED_DIRECTORY" "normalizes dragged file URLs for release folders"
  else
    fail_test "normalizes dragged file URLs for release folders"
  fi

  reset_history_releases
  history_scan_parent_directory "$releases"
  history_sort_releases
  assert_equal "2" "$HISTORY_RELEASE_COUNT" "discovers versioned release folders and skips unrelated folders"
  assert_equal "1.0.0|2.0.0" "${HISTORY_RELEASE_VERSIONS[0]}|${HISTORY_RELEASE_VERSIONS[1]}" "sorts historical releases by semantic version"
  assert_equal "2024-01-02|2025-08-03" "${HISTORY_RELEASE_DATES[0]}|${HISTORY_RELEASE_DATES[1]}" "uses reliable changelog dates for reconstructed commits"
  assert_equal "no|yes" "${HISTORY_RELEASE_NEEDS_GITIGNORE[0]}|${HISTORY_RELEASE_NEEDS_GITIGNORE[1]}" "detects releases missing a root gitignore"

  ADVANCED_LANGUAGE="en"
  if history_collect_gitignore_content <<< $'node_modules/\n\n*.log\n:done'; then
    assert_equal $'node_modules/\n\n*.log' "$HISTORY_GITIGNORE_CONTENT" "accepts multiline gitignore content directly from the terminal"
  else
    fail_test "accepts multiline gitignore content directly from the terminal"
  fi

  HISTORY_MAX_FILE_BYTES=5
  history_scan_risks
  if [ "$HISTORY_LARGE_COUNT" -gt 0 ]; then
    pass "detects files above the configured push limit"
  else
    fail_test "detects files above the configured push limit"
  fi
  if [ "$HISTORY_SENSITIVE_COUNT" -gt 0 ]; then
    pass "detects sensitive-looking files before history construction"
  else
    fail_test "detects sensitive-looking files before history construction"
  fi
  ADVANCED_LANGUAGE="zh"
  risk_output="$(history_show_paginated_list sensitive)"
  if grep -Fq '原因：这个文件名通常用于保存凭据、私人配置或密钥材料。' <<< "$risk_output" &&
     grep -Fq '原因：文件开头符合常见私钥格式。' <<< "$risk_output"; then
    pass "sensitive-file review explains the exact reason in Chinese"
  else
    fail_test "sensitive-file review explains the exact reason in Chinese"
  fi
  ADVANCED_LANGUAGE="en"
  HISTORY_MAX_FILE_BYTES="$original_max"

  git init --bare -q "$remote"
  : > "$fake_key"
  BOUND_USERNAME="history-user"
  BOUND_EMAIL="history-user@example.com"
  BOUND_SSH_ALIAS="github-history-user"
  BOUND_IDENTITY_FILE="$fake_key"
  HISTORY_REMOTE_URL="git@github-history-user:history-user/history-repository.git"
  CURRENT_REPOSITORY_OWNER="history-user"
  CURRENT_REPOSITORY_NAME="history-repository"
  HISTORY_ADD_GITIGNORE=true
  HISTORY_GITIGNORE_CONTENT="*.tmp
.cache/"
  ADVANCED_LANGUAGE="en"
  HISTORY_COMMITS_CONFIRMED=false
  if history_build_repository; then
    fail_test "historical builder refuses unconfirmed commits"
  else
    pass "historical builder refuses unconfirmed commits"
  fi
  HISTORY_COMMITS_CONFIRMED=true

  if history_build_repository; then
    pass "builds a temporary historical release repository"
  else
    fail_test "builds a temporary historical release repository"
    return
  fi

  messages="$(git -C "$HISTORY_WORK_DIRECTORY" log --format=%s --reverse | paste -sd '|' -)"
  assert_equal "Release 1.0.0|Release 2.0.0" "$messages" "creates one ordered release commit per complete snapshot"
  assert_equal "main" "$(git -C "$HISTORY_WORK_DIRECTORY" branch --show-current)" "normalizes rebuilt history to the main branch"
  if [ -z "$(git -C "$HISTORY_WORK_DIRECTORY" tag --list)" ]; then
    pass "historical reconstruction creates no version tags"
  else
    fail_test "historical reconstruction creates no version tags"
  fi
  assert_equal "2024-01-02" "$(git -C "$HISTORY_WORK_DIRECTORY" log --reverse --format=%cs | sed -n '1p')" "preserves a reliable release date"

  first_commit="$(git -C "$HISTORY_WORK_DIRECTORY" rev-list --reverse main | sed -n '1p')"
  first_tree="$(git -C "$HISTORY_WORK_DIRECTORY" ls-tree -r --name-only "$first_commit")"
  final_tree="$(git -C "$HISTORY_WORK_DIRECTORY" ls-tree -r --name-only HEAD)"
  if printf '%s\n' "$first_tree" | grep -Fxq '.gitignore' &&
     printf '%s\n' "$first_tree" | grep -Fxq 'debug.log'; then
    pass "complete snapshots include gitignore files and files they ignore"
  else
    fail_test "complete snapshots include gitignore files and files they ignore"
  fi
  if ! printf '%s\n' "$first_tree" | grep -Fq '.DS_Store' &&
     ! printf '%s\n' "$first_tree" | grep -Fq '.git/' &&
     ! printf '%s\n' "$final_tree" | grep -Fxq 'old.txt'; then
    pass "snapshot replacement removes old files and excludes Git metadata"
  else
    fail_test "snapshot replacement removes old files and excludes Git metadata"
  fi
  assert_equal "*.tmp|.cache/" "$(git -C "$HISTORY_WORK_DIRECTORY" show HEAD:.gitignore | paste -sd '|' -)" "adds supplied gitignore content only to missing snapshots"
  if [ ! -e "$second/.gitignore" ] && [ -f "$second/.env" ]; then
    pass "historical source folders remain unchanged"
  else
    fail_test "historical source folders remain unchanged"
  fi

  if history_publish_repository; then
    remote_head="$(git --git-dir="$remote" rev-parse refs/heads/main)"
    local_head="$(git -C "$HISTORY_WORK_DIRECTORY" rev-parse main)"
    assert_equal "$local_head" "$remote_head" "publishes rebuilt history to an empty remote without force"
  else
    fail_test "publishes rebuilt history to an empty remote without force"
  fi

  mkdir -p "$working_directory"
  printf '# current work\n' > "$working_directory/README.md"
  printf 'current-only\n' > "$working_directory/current-only.txt"
  working_readme_before="$(cat "$working_directory/README.md")"
  if history_link_working_directory "$working_directory"; then
    assert_equal "$working_readme_before" "$(cat "$working_directory/README.md")" "history linking preserves files in a non-empty working directory"
    assert_equal "$local_head" "$(git -C "$working_directory" rev-parse HEAD)" "non-empty working directory is connected to rebuilt main"
    assert_equal "main" "$(git -C "$working_directory" branch --show-current)" "linked working directory uses main"
    assert_equal "git@github-history-user:history-user/history-repository.git" "$(git -C "$working_directory" remote get-url origin)" "linked working directory receives the strict owner remote"
    if [ -x "$working_directory/g.sh" ] &&
       git -C "$working_directory" check-ignore -q g.sh &&
       git -C "$working_directory" status --short | grep -Fq '?? current-only.txt'; then
      pass "linked working directory is ready for its next ./g.sh run"
    else
      fail_test "linked working directory is ready for its next ./g.sh run"
    fi
  else
    fail_test "history linking preserves files in a non-empty working directory"
    fail_test "non-empty working directory is connected to rebuilt main"
    fail_test "linked working directory uses main"
    fail_test "linked working directory receives the strict owner remote"
    fail_test "linked working directory is ready for its next ./g.sh run"
  fi

  mkdir -p "$divergent_directory"
  git -C "$divergent_directory" init -q
  git -C "$divergent_directory" config user.name tester
  git -C "$divergent_directory" config user.email tester@example.com
  printf 'before\n' > "$divergent_directory/active-only.txt"
  git -C "$divergent_directory" add active-only.txt
  git -C "$divergent_directory" commit -qm 'existing local history'
  printf 'current staged content\n' > "$divergent_directory/active-only.txt"
  git -C "$divergent_directory" add active-only.txt
  divergent_file_before="$(cat "$divergent_directory/active-only.txt")"
  saved_prompt_function="$(declare -f advanced_prompt_yes_no)"
  advanced_prompt_yes_no() {
    return 0
  }
  if history_link_working_directory "$divergent_directory"; then
    assert_equal "$divergent_file_before" "$(cat "$divergent_directory/active-only.txt")" "reconnecting unrelated history preserves current project files"
    assert_equal "$local_head" "$(git -C "$divergent_directory" rev-parse HEAD)" "unrelated local history reconnects to rebuilt main after confirmation"
    if git -C "$divergent_directory" diff --cached --quiet &&
       git -C "$divergent_directory" status --short | grep -Fq '?? active-only.txt'; then
      pass "reconnecting history returns staged content to ordinary uncommitted changes"
    else
      fail_test "reconnecting history returns staged content to ordinary uncommitted changes"
    fi
  else
    fail_test "reconnecting unrelated history preserves current project files"
    fail_test "unrelated local history reconnects to rebuilt main after confirmation"
    fail_test "reconnecting history returns staged content to ordinary uncommitted changes"
  fi

  unrelated_commit="$(
    printf 'Release 3.0.0\n' |
      git -C "$HISTORY_WORK_DIRECTORY" commit-tree \
        "$(git -C "$HISTORY_WORK_DIRECTORY" rev-parse 'HEAD^{tree}')"
  )"
  git -C "$HISTORY_WORK_DIRECTORY" update-ref refs/heads/main "$unrelated_commit"
  if history_publish_repository; then
    remote_head="$(git --git-dir="$remote" rev-parse refs/heads/main)"
    local_head="$(git -C "$HISTORY_WORK_DIRECTORY" rev-parse main)"
    assert_equal "$local_head" "$remote_head" "replaces an existing remote main with an exact force-with-lease"
  else
    fail_test "replaces an existing remote main with an exact force-with-lease"
  fi
  eval "$saved_prompt_function"

  head_count="$(git --git-dir="$remote" for-each-ref --format='%(refname)' refs/heads | wc -l | tr -d ' ')"
  assert_equal "1" "$head_count" "history replacement does not create a backup branch"

  history_remove_temporary_directory "$HISTORY_WORK_DIRECTORY" history || true
  HISTORY_WORK_DIRECTORY=""
  HISTORY_MAX_FILE_BYTES="$original_max"
}

test_paged_account_selection() {
  local saved_ui_prompt_function=""
  local menu_output="$TEST_TEMPORARY/paged-account-menu.txt"
  local detail_output="$TEST_TEMPORARY/github-target-summary.txt"
  local selection_status=0
  local index=0
  local username=""

  UI_LANGUAGE="en"
  ADVANCED_LANGUAGE="en"

  ACCOUNT_USERNAMES=("Zulu" "alpha" "Bravo")
  ACCOUNT_EMAILS=("z@example.com" "a@example.com" "b@example.com")
  ACCOUNT_COUNT=3
  sort_accounts_alphabetically
  assert_equal "alpha|Bravo|Zulu" \
    "${ACCOUNT_USERNAMES[0]}|${ACCOUNT_USERNAMES[1]}|${ACCOUNT_USERNAMES[2]}" \
    "account menus sort usernames alphabetically without regard to case"

  saved_ui_prompt_function="$(declare -f ui_prompt_value)"
  ui_prompt_value() {
    printf '%s' "$MENU_TEST_CHOICE"
  }

  MENU_TEST_CHOICE="2"
  select_account > "$menu_output" 2>&1 || selection_status=$?
  assert_equal "0" "$selection_status" "account selection accepts a displayed number"
  assert_equal "Bravo" "$SELECTED_USERNAME" "number selection uses the stable sorted account order"

  selection_status=0
  MENU_TEST_CHOICE="0"
  select_account > "$menu_output" 2>&1 || selection_status=$?
  assert_equal "2" "$selection_status" "zero cancels ordinary account selection without choosing an account"
  if grep -Fq '  0) Cancel' "$menu_output"; then
    pass "ordinary account selection displays zero as cancel"
  else
    fail_test "ordinary account selection displays zero as cancel"
  fi
  eval "$saved_ui_prompt_function"

  ACCOUNT_USERNAMES=("account-one" "account-two")
  ACCOUNT_EMAILS=("one@example.com" "two@example.com")
  ACCOUNT_COUNT=2
  print_account_menu_options 0 yes en > "$menu_output"
  if grep -Fq '  9) Add another account' "$menu_output" &&
     grep -Fq '  0) Cancel' "$menu_output"; then
    pass "small account menus display nine for add and zero last"
  else
    fail_test "small account menus display nine for add and zero last"
  fi

  ACCOUNT_USERNAMES=()
  ACCOUNT_EMAILS=()
  ACCOUNT_COUNT=0
  index=1
  while [ "$index" -le 24 ]; do
    username="$(printf 'account-%02d' "$index")"
    ACCOUNT_USERNAMES[$ACCOUNT_COUNT]="$username"
    ACCOUNT_EMAILS[$ACCOUNT_COUNT]="$username@example.com"
    ACCOUNT_COUNT=$((ACCOUNT_COUNT + 1))
    index=$((index + 1))
  done

  print_account_menu_options 0 yes en > "$menu_output"
  if grep -Fq '  a) account-09' "$menu_output" &&
     grep -Fq '  r) account-22' "$menu_output" &&
     grep -Fq '  y) Next page' "$menu_output" &&
     grep -Fq '  z) Add another account' "$menu_output" &&
     [ "$(tail -n 1 "$menu_output")" = '  0) Cancel' ]; then
    pass "long account menus use allowed letters, next-page, add, and zero last"
  else
    fail_test "long account menus use allowed letters, next-page, add, and zero last"
  fi

  if ! grep -Eq '^  (i|l|o|q|s|t|u|v|w)\)' "$menu_output"; then
    pass "reserved and excluded letters are never assigned to account choices"
  else
    fail_test "reserved and excluded letters are never assigned to account choices"
  fi

  print_account_menu_options 1 yes en > "$menu_output"
  if grep -Fq '  1) account-23' "$menu_output" &&
     grep -Fq '  2) account-24' "$menu_output" &&
     grep -Fq '  x) Previous page' "$menu_output" &&
     ! grep -Fq '  y) Next page' "$menu_output" &&
     [ "$(tail -n 1 "$menu_output")" = '  0) Cancel' ]; then
    pass "last account page displays previous-page and keeps zero last"
  else
    fail_test "last account page displays previous-page and keeps zero last"
  fi

  paged_choice_to_index "a" 0 "$ACCOUNT_COUNT"
  assert_equal "8" "$PAGED_CHOICE_INDEX" "letter a selects the ninth item on a page"
  paged_choice_to_index "r" 0 "$ACCOUNT_COUNT"
  assert_equal "21" "$PAGED_CHOICE_INDEX" "letter r selects the final item on a full page"
  paged_choice_to_index "2" 1 "$ACCOUNT_COUNT"
  assert_equal "23" "$PAGED_CHOICE_INDEX" "page-relative labels select the matching overflow item"

  github_target_summary \
    normal account-one owner-name repository-name \
    > "$detail_output"
  assert_equal "GitHub account: account-one" "$(sed -n '1p' "$detail_output")" \
    "normal destination summary shows the account first"
  assert_equal "GitHub repository: owner-name/repository-name" "$(sed -n '2p' "$detail_output")" \
    "normal destination summary shows the repository second"
  if ! grep -Eq 'Commit author|Commit email|SSH private key|Push address|Local branch' "$detail_output"; then
    pass "normal destination summary hides technical identity and transport details"
  else
    fail_test "normal destination summary hides technical identity and transport details"
  fi

}

test_project_release_policy() {
  local english_version=""
  local chinese_version=""
  local file_version=""

  english_version="$(sed -nE 's/^## ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$PROJECT_DIRECTORY/CHANGELOG.md" | sed -n '1p')"
  chinese_version="$(sed -nE 's/^## ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$PROJECT_DIRECTORY/CHANGELOG_zh.md" | sed -n '1p')"
  file_version="$(sed -n '1p' "$PROJECT_DIRECTORY/VERSION")"
  if [ -n "$english_version" ]; then
    pass "English changelog declares a release"
  else
    fail_test "English changelog declares a release"
  fi
  assert_equal "$english_version" "$chinese_version" "English and Chinese changelogs declare the same release"
  assert_equal "$english_version" "$file_version" "root VERSION matches both changelogs"
  assert_equal "1" "$(awk 'END { print NR }' "$PROJECT_DIRECTORY/VERSION")" "root VERSION contains one line only"
  if [[ "$english_version" != *4* ]] &&
     [[ "$english_version" =~ ^[1-9][0-9]*\.[1-9][0-9]*\.[1-9][0-9]*$ ]]; then
    pass "new project release obeys the no-4 and no-zero-component rule"
  else
    fail_test "new project release obeys the no-4 and no-zero-component rule"
  fi
}

test_focused_commit_confirmation() {
  local repository="$TEST_TEMPORARY/focused-commit-confirmation"
  local hidden_repository="$TEST_TEMPORARY/focused-hidden-change"
  local embedded_repository="$TEST_TEMPORARY/focused-embedded-project"
  local pager="$TEST_TEMPORARY/forbidden-git-pager"
  local pager_marker="$TEST_TEMPORARY/git-pager-was-opened"
  local original_root="${GIT_ROOT:-}"
  local original_binding_reused="${PROJECT_BINDING_REUSED:-false}"
  local original_git_pager="${GIT_PAGER-}"
  local original_pager_marker="${GIT_AUTO_PAGER_MARKER-}"
  local saved_prompt_commit_message=""
  local prompt_count=0
  local message=""
  local before_head=""
  local before_cached=""
  local output=""
  local output_file="$TEST_TEMPORARY/focused-embedded-project-output"
  local index=0
  local status=0

  mkdir -p "$repository"
  git -C "$repository" init -q
  git -C "$repository" config user.name tester
  git -C "$repository" config user.email tester@example.com
  write_changelog "$repository/CHANGELOG.md" "9.1.2" "9.1.1"
  printf 'first\n' > "$repository/file.txt"
  printf '#!/usr/bin/env bash\n: > "$GIT_AUTO_PAGER_MARKER"\ncat\n' > "$pager"
  chmod 700 "$pager"
  GIT_PAGER="$pager"
  GIT_AUTO_PAGER_MARKER="$pager_marker"
  export GIT_PAGER GIT_AUTO_PAGER_MARKER
  GIT_ROOT="$repository"
  PROJECT_BINDING_REUSED=false

  saved_prompt_commit_message="$(declare -f prompt_commit_message)"
  prompt_commit_message() {
    prompt_count=$((prompt_count + 1))
    COMMIT_MESSAGE="$1"
    return 0
  }
  if prepare_and_commit >/dev/null 2>&1; then
    message="$(git -C "$repository" log -1 --pretty=%s)"
    assert_equal "1|Release 9.1.2|true" \
      "$prompt_count|$message|$WORKFLOW_COMMIT_CREATED_THIS_RUN" \
      "ordinary commit is created only after its message is confirmed"
    if [ ! -e "$pager_marker" ]; then
      pass "commit change summaries never open Git's interactive pager"
    else
      fail_test "commit change summaries never open Git's interactive pager"
    fi
  else
    fail_test "ordinary commit is created only after its message is confirmed"
    fail_test "commit change summaries never open Git's interactive pager"
  fi

  if prepare_and_commit >/dev/null 2>&1 &&
     [ "$WORKFLOW_COMMIT_CREATED_THIS_RUN" = false ]; then
    pass "a clean working tree is recorded as having no commit confirmed during this run"
  else
    fail_test "a clean working tree is recorded as having no commit confirmed during this run"
  fi

  index=1
  while [ "$index" -le 25 ]; do
    printf 'change\n' > "$repository/review-$index.txt"
    index=$((index + 1))
  done
  status=0
  output="$(prepare_and_commit 2>&1)" || status=$?
  if [ "$status" -eq 0 ] &&
     [ "$(git -C "$repository" diff-tree --no-commit-id --name-only -r HEAD | wc -l | tr -d ' ')" = 25 ] &&
     ! printf '%s\n' "$output" | grep -Fq 'additional files are omitted'; then
    pass "exactly 25 changed files remain fully visible in the terminal"
  else
    fail_test "exactly 25 changed files remain fully visible in the terminal"
  fi

  index=1
  while [ "$index" -le 26 ]; do
    printf 'change\n' > "$repository/next-$index.txt"
    index=$((index + 1))
  done
  status=0
  output="$(prepare_and_commit 2>&1)" || status=$?
  if [ "$status" -eq 0 ] &&
     [ "$(git -C "$repository" diff-tree --no-commit-id --name-only -r HEAD | wc -l | tr -d ' ')" = 26 ] &&
     printf '%s\n' "$output" | grep -Fq 'Showing 25 of 26 changed files.' &&
     printf '%s\n' "$output" | grep -Fq 'Omitted here: 1.' &&
     printf '%s\n' "$output" | grep -Fq "Git's per-file commit output was omitted" &&
     ! printf '%s\n' "$output" | grep -Fq 'create mode'; then
    pass "26 changed files commit fully while terminal lists only 25 and states what was omitted"
  else
    fail_test "26 changed files commit fully while terminal lists only 25 and states what was omitted"
  fi

  mkdir -p "$hidden_repository"
  git -C "$hidden_repository" init -q
  git -C "$hidden_repository" config user.name tester
  git -C "$hidden_repository" config user.email tester@example.com
  printf 'before\n' > "$hidden_repository/file.txt"
  git -C "$hidden_repository" add file.txt
  git -C "$hidden_repository" commit -qm baseline
  git -C "$hidden_repository" update-index --assume-unchanged file.txt
  printf 'after\n' > "$hidden_repository/file.txt"
  GIT_ROOT="$hidden_repository"
  before_head="$(git -C "$hidden_repository" rev-parse HEAD)"
  prompt_commit_message() {
    return 2
  }
  status=0
  prepare_and_commit >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 2 ] &&
     [ "$(git -C "$hidden_repository" rev-parse HEAD)" = "$before_head" ] &&
     git -C "$hidden_repository" ls-files -v file.txt | grep -Eq '^[a-z] '; then
    pass "canceling a recovered review preserves the real index and hidden local change"
  else
    fail_test "canceling a recovered review preserves the real index and hidden local change"
  fi
  prompt_commit_message() {
    COMMIT_MESSAGE="Recovered change"
    return 0
  }
  status=0
  output="$(prepare_and_commit 2>&1)" || status=$?
  if [ "$status" -eq 0 ] &&
     [ "$(git -C "$hidden_repository" show HEAD:file.txt)" = "after" ] &&
     [ "$(git -C "$hidden_repository" log -1 --pretty=%s)" = "Recovered change" ] &&
     printf '%s\n' "$output" | grep -Fq \
       'A complete independent file scan recovered the accurate commit contents'; then
    pass "a complete independent scan recovers a tracked change omitted by the initial Git status"
  else
    fail_test "a complete independent scan recovers a tracked change omitted by the initial Git status"
  fi
  GIT_ROOT="$repository"

  printf 'second\n' >> "$repository/file.txt"
  before_head="$(git -C "$repository" rev-parse HEAD)"
  prompt_commit_message() {
    return 2
  }
  prepare_and_commit >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 2 ] &&
     [ "$(git -C "$repository" rev-parse HEAD)" = "$before_head" ] &&
     git -C "$repository" diff --cached --quiet; then
    pass "declining commit confirmation stops before staging"
  else
    fail_test "declining commit confirmation stops before staging"
  fi

  mkdir -p "$embedded_repository/native-scroll"
  git -C "$embedded_repository" init -q
  git -C "$embedded_repository" config user.name tester
  git -C "$embedded_repository" config user.email tester@example.com
  printf 'base\n' > "$embedded_repository/README.md"
  git -C "$embedded_repository" add README.md
  git -C "$embedded_repository" commit -qm baseline
  printf '{"name":"native-scroll"}\n' > "$embedded_repository/native-scroll/package.json"
  printf 'foreign\n' > "$embedded_repository/native-scroll/index.js"
  GIT_ROOT="$embedded_repository"
  PROJECT_BINDING_REUSED=true
  prompt_count=0
  prompt_commit_message() {
    prompt_count=$((prompt_count + 1))
    COMMIT_MESSAGE="$1"
    return 0
  }
  status=0
  prepare_and_commit > "$output_file" 2>&1 <<< '' || status=$?
  output="$(< "$output_file")"
  if [ "$status" -eq 2 ] &&
     [ "$prompt_count" -eq 0 ] &&
     git -C "$embedded_repository" diff --cached --quiet &&
     printf '%s\n' "$output" | grep -Fq 'A  native-scroll/index.js' &&
     printf '%s\n' "$output" | grep -Fq 'A  native-scroll/package.json' &&
     printf '%s\n' "$output" | grep -Fq 'project marker: package.json' &&
     ! printf '%s\n' "$output" | grep -Fq 'Looking for a release version'; then
    pass "established projects show every change and stop before staging a possible embedded project by default"
  else
    fail_test "established projects show every change and stop before staging a possible embedded project by default"
  fi

  git -C "$embedded_repository" add native-scroll
  before_cached="$(git -C "$embedded_repository" diff --cached)"
  status=0
  prepare_and_commit > "$output_file" 2>&1 <<< '' || status=$?
  if [ "$status" -eq 2 ] &&
     [ "$prompt_count" -eq 0 ] &&
     [ "$(git -C "$embedded_repository" diff --cached)" = "$before_cached" ]; then
    pass "the same default safeguard catches pre-staged project folders without changing the index"
  else
    fail_test "the same default safeguard catches pre-staged project folders without changing the index"
  fi

  status=0
  prepare_and_commit >/dev/null 2>&1 <<< 'y' || status=$?
  if [ "$status" -eq 0 ] &&
     git -C "$embedded_repository" ls-tree --name-only HEAD native-scroll | grep -Fxq native-scroll; then
    pass "an explicitly confirmed new project-like folder can still be committed"
  else
    fail_test "an explicitly confirmed new project-like folder can still be committed"
  fi

  mkdir -p "$embedded_repository/assets"
  printf 'ordinary\n' > "$embedded_repository/assets/example.txt"
  scan_possible_embedded_projects
  if [ "$POSSIBLE_EMBEDDED_PROJECT_COUNT" -eq 0 ]; then
    pass "an ordinary new folder adds no extra safety confirmation"
  else
    fail_test "an ordinary new folder adds no extra safety confirmation"
  fi

  mkdir -p "$embedded_repository/container/tool"
  printf '{"name":"nested-tool"}\n' > "$embedded_repository/container/tool/package.json"
  printf 'nested\n' > "$embedded_repository/container/tool/index.js"
  scan_possible_embedded_projects
  if possible_embedded_project_index "container/tool" >/dev/null 2>&1; then
    pass "a new nested directory with an independent-project marker is detected"
  else
    fail_test "a new nested directory with an independent-project marker is detected"
  fi
  git -C "$embedded_repository" add container
  git -C "$embedded_repository" commit -qm nested-fixture

  mkdir -p "$embedded_repository/bulk" "$embedded_repository/small-bulk"
  index=1
  while [ "$index" -le 20 ]; do
    printf 'bulk\n' > "$embedded_repository/bulk/file-$index.txt"
    if [ "$index" -le 19 ]; then
      printf 'small\n' > "$embedded_repository/small-bulk/file-$index.txt"
    fi
    index=$((index + 1))
  done
  scan_possible_embedded_projects
  if possible_embedded_project_index bulk >/dev/null 2>&1 &&
     ! possible_embedded_project_index small-bulk >/dev/null 2>&1; then
    pass "a completely new top-level directory is flagged at the 20-file threshold only"
  else
    fail_test "a completely new top-level directory is flagged at the 20-file threshold only"
  fi

  POSSIBLE_EMBEDDED_PROJECT_DIRECTORIES=()
  POSSIBLE_EMBEDDED_PROJECT_MARKERS=()
  POSSIBLE_EMBEDDED_PROJECT_COUNT=23
  index=0
  while [ "$index" -lt "$POSSIBLE_EMBEDDED_PROJECT_COUNT" ]; do
    POSSIBLE_EMBEDDED_PROJECT_DIRECTORIES[$index]="project-$((index + 1))"
    POSSIBLE_EMBEDDED_PROJECT_MARKERS[$index]="package.json"
    index=$((index + 1))
  done
  output="$(show_possible_embedded_projects 2>&1 <<< $'y\n0')"
  if printf '%s\n' "$output" | grep -Fq '  a) project-9' &&
     printf '%s\n' "$output" | grep -Fq '  r) project-22' &&
     printf '%s\n' "$output" | grep -Fq '  y) Next page' &&
     printf '%s\n' "$output" | grep -Fq '  1) project-23' &&
     printf '%s\n' "$output" | grep -Fq '  x) Previous page'; then
    pass "long embedded-project reviews use shared labels and x/y pagination"
  else
    fail_test "long embedded-project reviews use shared labels and x/y pagination"
  fi

  eval "$saved_prompt_commit_message"
  if [ -n "$original_git_pager" ]; then
    GIT_PAGER="$original_git_pager"
    export GIT_PAGER
  else
    unset GIT_PAGER
  fi
  if [ -n "$original_pager_marker" ]; then
    GIT_AUTO_PAGER_MARKER="$original_pager_marker"
    export GIT_AUTO_PAGER_MARKER
  else
    unset GIT_AUTO_PAGER_MARKER
  fi
  GIT_ROOT="$original_root"
  PROJECT_BINDING_REUSED="$original_binding_reused"
}

test_focused_exact_snapshot_edges() {
  local mixed_repository="$TEST_TEMPORARY/focused-mixed-hidden"
  local net_zero_repository="$TEST_TEMPORARY/focused-net-zero"
  local sparse_repository="$TEST_TEMPORARY/focused-sparse"
  local nested_repository="$TEST_TEMPORARY/focused-nested-repository"
  local submodule_source="$TEST_TEMPORARY/focused-submodule-source"
  local submodule_parent="$TEST_TEMPORARY/focused-submodule-parent"
  local hook_repository="$TEST_TEMPORARY/focused-post-commit-hook"
  local original_root="${GIT_ROOT:-}"
  local original_binding_reused="${PROJECT_BINDING_REUSED:-false}"
  local saved_prompt_commit_message=""
  local before_cached=""
  local output=""
  local status=0
  local prompt_count=0

  saved_prompt_commit_message="$(declare -f prompt_commit_message)"
  prompt_commit_message() {
    prompt_count=$((prompt_count + 1))
    COMMIT_MESSAGE="$1"
    return 0
  }
  PROJECT_BINDING_REUSED=true

  mkdir -p "$mixed_repository"
  git -C "$mixed_repository" init -q
  git -C "$mixed_repository" config user.name tester
  git -C "$mixed_repository" config user.email tester@example.com
  printf 'old hidden\n' > "$mixed_repository/hidden.txt"
  printf 'old visible\n' > "$mixed_repository/visible.txt"
  printf 'unchanged\n' > "$mixed_repository/untouched.txt"
  git -C "$mixed_repository" add -A
  git -C "$mixed_repository" commit -qm baseline
  git -C "$mixed_repository" update-index --assume-unchanged hidden.txt untouched.txt
  printf 'new hidden\n' > "$mixed_repository/hidden.txt"
  printf 'new visible\n' > "$mixed_repository/visible.txt"
  GIT_ROOT="$mixed_repository"
  output="$(prepare_and_commit 2>&1)" || status=$?
  if [ "$status" -eq 0 ] &&
     [ "$(git -C "$mixed_repository" show HEAD:hidden.txt)" = "new hidden" ] &&
     [ "$(git -C "$mixed_repository" show HEAD:visible.txt)" = "new visible" ] &&
     printf '%s\n' "$output" | grep -Fq 'M  hidden.txt' &&
     printf '%s\n' "$output" | grep -Fq 'M  visible.txt' &&
     git -C "$mixed_repository" ls-files -v untouched.txt | grep -Eq '^h '; then
    pass "one exact review includes visible and Git-index-hidden changes without clearing unrelated hints"
  else
    fail_test "one exact review includes visible and Git-index-hidden changes without clearing unrelated hints"
  fi

  mkdir -p "$net_zero_repository"
  git -C "$net_zero_repository" init -q
  git -C "$net_zero_repository" config user.name tester
  git -C "$net_zero_repository" config user.email tester@example.com
  printf 'original\n' > "$net_zero_repository/file.txt"
  git -C "$net_zero_repository" add file.txt
  git -C "$net_zero_repository" commit -qm baseline
  printf 'staged version\n' > "$net_zero_repository/file.txt"
  git -C "$net_zero_repository" add file.txt
  printf 'original\n' > "$net_zero_repository/file.txt"
  before_cached="$(git -C "$net_zero_repository" diff --cached)"
  GIT_ROOT="$net_zero_repository"
  prompt_count=0
  status=0
  output="$(prepare_and_commit 2>&1)" || status=$?
  if [ "$status" -eq 2 ] && [ "$prompt_count" -eq 0 ] &&
     [ "$(git -C "$net_zero_repository" diff --cached)" = "$before_cached" ] &&
     printf '%s\n' "$output" | grep -Fq 'changes that cancel each other'; then
    pass "staged and working-tree changes that cancel are left untouched"
  else
    fail_test "staged and working-tree changes that cancel are left untouched"
  fi

  mkdir -p "$sparse_repository/keep" "$sparse_repository/omit"
  git -C "$sparse_repository" init -q
  git -C "$sparse_repository" config user.name tester
  git -C "$sparse_repository" config user.email tester@example.com
  printf 'keep\n' > "$sparse_repository/keep/file.txt"
  printf 'omit\n' > "$sparse_repository/omit/file.txt"
  git -C "$sparse_repository" add -A
  git -C "$sparse_repository" commit -qm baseline
  git -C "$sparse_repository" sparse-checkout init --cone
  git -C "$sparse_repository" sparse-checkout set keep
  GIT_ROOT="$sparse_repository"
  status=0
  prepare_and_commit >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 0 ] && [ "$WORKFLOW_COMMIT_CREATED_THIS_RUN" = false ]; then
    pass "a clean sparse checkout is recognized without treating omitted files as deleted"
  else
    fail_test "a clean sparse checkout is recognized without treating omitted files as deleted"
  fi

  mkdir -p "$nested_repository/child"
  git -C "$nested_repository" init -q
  git -C "$nested_repository" config user.name tester
  git -C "$nested_repository" config user.email tester@example.com
  printf 'parent\n' > "$nested_repository/README.md"
  git -C "$nested_repository" add README.md
  git -C "$nested_repository" commit -qm baseline
  git -C "$nested_repository/child" init -q
  git -C "$nested_repository/child" config user.name tester
  git -C "$nested_repository/child" config user.email tester@example.com
  printf 'child\n' > "$nested_repository/child/file.txt"
  git -C "$nested_repository/child" add file.txt
  git -C "$nested_repository/child" commit -qm child
  GIT_ROOT="$nested_repository"
  prompt_count=0
  status=0
  output="$(prepare_and_commit 2>&1)" || status=$?
  if [ "$status" -eq 2 ] && [ "$prompt_count" -eq 0 ] &&
     git -C "$nested_repository" diff --cached --quiet &&
     printf '%s\n' "$output" | grep -Fq 'A separate Git repository is inside this project'; then
    pass "an unregistered nested Git repository is blocked instead of being mislabeled as ordinary files"
  else
    fail_test "an unregistered nested Git repository is blocked instead of being mislabeled as ordinary files"
  fi

  mkdir -p "$submodule_source" "$submodule_parent"
  git -C "$submodule_source" init -q
  git -C "$submodule_source" config user.name tester
  git -C "$submodule_source" config user.email tester@example.com
  printf 'submodule\n' > "$submodule_source/file.txt"
  git -C "$submodule_source" add file.txt
  git -C "$submodule_source" commit -qm baseline
  git -C "$submodule_parent" init -q
  git -C "$submodule_parent" config user.name tester
  git -C "$submodule_parent" config user.email tester@example.com
  git -C "$submodule_parent" -c protocol.file.allow=always \
    submodule add -q "$submodule_source" vendor/tool
  git -C "$submodule_parent" commit -qam baseline
  printf 'dirty\n' >> "$submodule_parent/vendor/tool/file.txt"
  GIT_ROOT="$submodule_parent"
  prompt_count=0
  status=0
  output="$(prepare_and_commit 2>&1)" || status=$?
  if [ "$status" -eq 2 ] && [ "$prompt_count" -eq 0 ] &&
     git -C "$submodule_parent" diff --cached --quiet &&
     printf '%s\n' "$output" | grep -Fq 'Uncommitted changes inside a Git submodule'; then
    pass "dirty submodule files are explained and blocked before the parent repository is staged"
  else
    fail_test "dirty submodule files are explained and blocked before the parent repository is staged"
  fi

  mkdir -p "$hook_repository/.git/hooks"
  git -C "$hook_repository" init -q
  git -C "$hook_repository" config user.name tester
  git -C "$hook_repository" config user.email tester@example.com
  printf 'base\n' > "$hook_repository/file.txt"
  git -C "$hook_repository" add file.txt
  git -C "$hook_repository" commit -qm baseline
  printf '#!/bin/sh\nprintf "\\nchanged by hook\\n" >> "$1"\n' > "$hook_repository/.git/hooks/commit-msg"
  chmod 700 "$hook_repository/.git/hooks/commit-msg"
  printf 'change\n' >> "$hook_repository/file.txt"
  GIT_ROOT="$hook_repository"
  status=0
  output="$(prepare_and_commit 2>&1)" || status=$?
  if [ "$status" -ne 0 ] && [ "$WORKFLOW_COMMIT_CREATED_THIS_RUN" = false ] &&
     printf '%s\n' "$output" | grep -Fq "confirmed files, message, or identity"; then
    pass "the created commit is rechecked against the confirmed files, message, and identity before push"
  else
    fail_test "the created commit is rechecked against the confirmed files, message, and identity before push"
  fi

  if GIT_DIR="$mixed_repository/.git" GIT_WORK_TREE="$mixed_repository" \
    GIT_AUTHOR_NAME=wrong GIT_COMMITTER_EMAIL=wrong@example.com \
    GITHUB_AUTO_TESTING=1 bash -c '
      source "$1"
      test -z "${GIT_DIR+x}" && test -z "${GIT_WORK_TREE+x}" &&
        test -z "${GIT_AUTHOR_NAME+x}" && test -z "${GIT_COMMITTER_EMAIL+x}"
    ' bash "$PROJECT_DIRECTORY/git-auto.sh"; then
    pass "the central engine discards inherited repository and commit-identity overrides"
  else
    fail_test "the central engine discards inherited repository and commit-identity overrides"
  fi

  eval "$saved_prompt_commit_message"
  GIT_ROOT="$original_root"
  PROJECT_BINDING_REUSED="$original_binding_reused"
}

test_focused_transaction_safety() {
  local repository="$TEST_TEMPORARY/focused-transaction"
  local changed_repository="$TEST_TEMPORARY/focused-changed-after-review"
  local racing_repository="$TEST_TEMPORARY/focused-racing-stage"
  local branch_repository="$TEST_TEMPORARY/focused-branch-switch"
  local output_file="$TEST_TEMPORARY/focused-transaction-output"
  local original_root="${GIT_ROOT:-}"
  local original_script_name="$SCRIPT_NAME"
  local saved_prompt_commit_message=""
  local saved_set_workflow_state=""
  local lock_directory=""
  local fake_key="$TEST_TEMPORARY/focused-transaction-key"
  local status=0

  mkdir -p "$repository"
  git -C "$repository" init -q
  git -C "$repository" config user.name tester
  git -C "$repository" config user.email tester@example.com
  printf 'base\n' > "$repository/file.txt"
  git -C "$repository" add file.txt
  git -C "$repository" commit -qm baseline
  GIT_ROOT="$repository"
  SCRIPT_NAME="g.sh"
  resolve_workflow_common_directory
  lock_directory="$WORKFLOW_COMMON_DIRECTORY/github-auto.workflow.lock"

  mkdir "$lock_directory"
  printf '%s\n' "$$" > "$lock_directory/pid"
  printf 'active-test\n' > "$lock_directory/token"
  WORKFLOW_LOCK_HELD=false
  if acquire_workflow_lock > "$output_file" 2>&1; then
    fail_test "an active same-repository workflow lock blocks an overlapping run"
  elif grep -Fq 'already preparing, committing, updating, or pushing this same Git repository' "$output_file"; then
    pass "an active same-repository workflow lock blocks an overlapping run"
  else
    fail_test "an active same-repository workflow lock blocks an overlapping run"
  fi
  rm -f "$lock_directory/pid" "$lock_directory/token"
  rmdir "$lock_directory"

  mkdir "$lock_directory"
  printf '99999999\n' > "$lock_directory/pid"
  printf 'stale-test\n' > "$lock_directory/token"
  WORKFLOW_LOCK_HELD=false
  if acquire_workflow_lock >/dev/null 2>&1 && [ "$WORKFLOW_LOCK_HELD" = true ]; then
    pass "a stale owned workflow lock is reclaimed safely"
  else
    fail_test "a stale owned workflow lock is reclaimed safely"
  fi
  release_workflow_lock

  mkdir "$lock_directory"
  printf '99999999\n' > "$lock_directory/pid 2"
  printf 'stale-provider-copy\n' > "$lock_directory/token 2"
  WORKFLOW_LOCK_HELD=false
  if acquire_workflow_lock >/dev/null 2>&1 && [ "$WORKFLOW_LOCK_HELD" = true ]; then
    pass "a stale lock whose metadata was numbered by a file provider is reclaimed safely"
  else
    fail_test "a stale lock whose metadata was numbered by a file provider is reclaimed safely"
  fi
  release_workflow_lock

  mkdir "$lock_directory"
  printf '%s\n' "$$" > "$lock_directory/pid 2"
  printf 'active-provider-copy\n' > "$lock_directory/token 2"
  WORKFLOW_LOCK_HELD=false
  if acquire_workflow_lock > "$output_file" 2>&1; then
    fail_test "a numbered lock owned by a live process still blocks an overlapping run"
  elif grep -Fq "Active process ID: $$" "$output_file"; then
    pass "a numbered lock owned by a live process still blocks an overlapping run"
  else
    fail_test "a numbered lock owned by a live process still blocks an overlapping run"
  fi
  rm -f "$lock_directory/pid 2" "$lock_directory/token 2"
  rmdir "$lock_directory"

  mkdir "$lock_directory"
  printf '99999999\n' > "$lock_directory/pid 2"
  printf 'stale-provider-copy\n' > "$lock_directory/token 2"
  printf 'not lock metadata\n' > "$lock_directory/project-file"
  WORKFLOW_LOCK_HELD=false
  if acquire_workflow_lock > "$output_file" 2>&1; then
    fail_test "unknown content beside numbered lock metadata prevents automatic cleanup"
  elif [ -f "$lock_directory/pid 2" ] &&
       [ -f "$lock_directory/token 2" ] &&
       [ -f "$lock_directory/project-file" ]; then
    pass "unknown content beside numbered lock metadata prevents automatic cleanup"
  else
    fail_test "unknown content beside numbered lock metadata prevents automatic cleanup"
  fi
  rm -f "$lock_directory/pid 2" "$lock_directory/token 2" "$lock_directory/project-file"
  rmdir "$lock_directory"

  printf 'phase: staged\npid: 99999999\n' > "$WORKFLOW_COMMON_DIRECTORY/github-auto.workflow-state"
  WORKFLOW_LOCK_HELD=false
  if acquire_workflow_lock > "$output_file" 2>&1 &&
     grep -Fq 'ended while preparing the Git staging area' "$output_file" &&
     [ ! -e "$WORKFLOW_COMMON_DIRECTORY/github-auto.workflow-state" ]; then
    pass "an interrupted staging record is explained before a fresh run"
  else
    fail_test "an interrupted staging record is explained before a fresh run"
  fi
  release_workflow_lock

  : > "$fake_key"
  git -C "$repository" remote add origin git@github-owner:owner/project.git
  git -C "$repository" config --local --add remote.origin.pushurl git@github-owner:owner/project.git
  git -C "$repository" config --local github-auto.username owner
  git -C "$repository" config --local github-auto.ssh-alias github-owner
  git -C "$repository" config --local github-auto.identity-file "$fake_key"
  GIT_ROOT="$repository"
  capture_workflow_checkpoint
  git -C "$repository" remote set-url origin git@github-owner:owner/changed.git
  status=0
  verify_workflow_checkpoint "uploading" "上传" > "$output_file" 2>&1 || status=$?
  if [ "$status" -ne 0 ] && grep -Fq 'the origin address changed' "$output_file"; then
    pass "an origin change after repository selection is blocked before push"
  else
    fail_test "an origin change after repository selection is blocked before push"
  fi

  saved_prompt_commit_message="$(declare -f prompt_commit_message)"
  mkdir -p "$changed_repository"
  git -C "$changed_repository" init -q
  git -C "$changed_repository" config user.name tester
  git -C "$changed_repository" config user.email tester@example.com
  printf 'base\n' > "$changed_repository/file.txt"
  git -C "$changed_repository" add file.txt
  git -C "$changed_repository" commit -qm baseline
  printf 'reviewed\n' >> "$changed_repository/file.txt"
  GIT_ROOT="$changed_repository"
  PROJECT_BINDING_REUSED=true
  prompt_commit_message() {
    printf 'changed after review\n' >> "$changed_repository/file.txt"
    COMMIT_MESSAGE="$1"
    return 0
  }
  status=0
  prepare_and_commit > "$output_file" 2>&1 || status=$?
  if [ "$status" -ne 0 ] &&
     git -C "$changed_repository" diff --cached --quiet &&
     grep -Fq 'changed after the review' "$output_file"; then
    pass "a working-tree change after confirmation stops before the real staging area is changed"
  else
    fail_test "a working-tree change after confirmation stops before the real staging area is changed"
  fi

  mkdir -p "$branch_repository"
  git -C "$branch_repository" init -q
  git -C "$branch_repository" config user.name tester
  git -C "$branch_repository" config user.email tester@example.com
  printf 'base\n' > "$branch_repository/file.txt"
  git -C "$branch_repository" add file.txt
  git -C "$branch_repository" commit -qm baseline
  printf 'reviewed\n' >> "$branch_repository/file.txt"
  GIT_ROOT="$branch_repository"
  prompt_commit_message() {
    git -C "$branch_repository" switch -qc changed-during-review
    COMMIT_MESSAGE="$1"
    return 0
  }
  status=0
  prepare_and_commit > "$output_file" 2>&1 || status=$?
  if [ "$status" -ne 0 ] &&
     git -C "$branch_repository" diff --cached --quiet &&
     grep -Fq 'the current branch changed' "$output_file"; then
    pass "a branch switch after confirmation stops before staging"
  else
    fail_test "a branch switch after confirmation stops before staging"
  fi

  mkdir -p "$racing_repository"
  git -C "$racing_repository" init -q
  git -C "$racing_repository" config user.name tester
  git -C "$racing_repository" config user.email tester@example.com
  printf 'base\n' > "$racing_repository/file.txt"
  git -C "$racing_repository" add file.txt
  git -C "$racing_repository" commit -qm baseline
  printf 'reviewed\n' >> "$racing_repository/file.txt"
  GIT_ROOT="$racing_repository"
  prompt_commit_message() {
    COMMIT_MESSAGE="$1"
    return 0
  }
  saved_set_workflow_state="$(declare -f set_workflow_state)"
  set_workflow_state() {
    if [ "$1" = staging ]; then
      printf 'arrived during staging\n' >> "$racing_repository/file.txt"
    fi
    return 0
  }
  status=0
  prepare_and_commit > "$output_file" 2>&1 || status=$?
  if [ "$status" -ne 0 ] &&
     [ "$(git -C "$racing_repository" log -1 --pretty=%s)" = baseline ] &&
     grep -Fq 'staged snapshot does not exactly match' "$output_file"; then
    pass "the exact staged tree guard blocks files that arrive during git add -A"
  else
    fail_test "the exact staged tree guard blocks files that arrive during git add -A"
  fi

  eval "$saved_set_workflow_state"
  eval "$saved_prompt_commit_message"
  clear_workflow_review_snapshot
  clear_workflow_state
  release_workflow_lock
  GIT_ROOT="$original_root"
  SCRIPT_NAME="$original_script_name"
}

test_focused_ssh_and_launcher() {
  local identity_home="$TEST_TEMPORARY/focused-identity-home"
  local engine_repository="$TEST_TEMPORARY/focused-engine"
  local binding_repository="$TEST_TEMPORARY/focused-binding"
  local legacy_key="$identity_home/.ssh/id_ed25519_github800"
  local stale_named_key="$identity_home/.ssh/id_stale_named"
  local first_key="$identity_home/.ssh/id_first"
  local second_key="$identity_home/.ssh/id_second"
  local unassigned_key="$identity_home/.ssh/id_unassigned"
  local real_ssh_config="$identity_home/.ssh/config.real"
  local launcher_project="$TEST_TEMPORARY/folder-input-project"
  local fake_engine_directory="$TEST_TEMPORARY/fake-central"
  local private_launcher_directory="$TEST_TEMPORARY/private-launcher"
  local canonical_launcher_project=""
  local original_engine_directory="$ENGINE_DIRECTORY"
  local original_engine_path="$ENGINE_PATH"
  local original_private_directory="$PRIVATE_DIRECTORY"
  local original_ssh_directory="$SSH_DIRECTORY"
  local original_ssh_config_file="$SSH_CONFIG_FILE"
  local original_root="${GIT_ROOT:-}"
  local saved_identify_key_username=""
  local saved_register_account_and_identity=""
  local saved_create_new_identity=""
  local saved_advanced_prompt_value=""
  local saved_advanced_select_account_for_history=""
  local saved_advanced_verify_key_matches_username=""
  local saved_advanced_verify_repository_access=""
  local saved_run_git_with_identity=""
  local push_marker="$TEST_TEMPORARY/focused-push-target"
  local push_head=""
  local registered_mapping=""
  local create_call_count=0
  local duplicate_history_identity_checks=0
  local output=""
  local status=0

  mkdir -p "$identity_home/.ssh" "$engine_repository"
  : > "$legacy_key"
  : > "$stale_named_key"
  printf 'Host github-sd800\n    HostName github.com\n    IdentityFile %s\n\nHost github800\n    HostName github.com\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n' \
    "$stale_named_key" "$legacy_key" > "$identity_home/.ssh/config"
  git -C "$engine_repository" init -q
  git -C "$engine_repository" config --local github-auto.username sd800
  git -C "$engine_repository" config --local github-auto.ssh-alias github800
  git -C "$engine_repository" config --local github-auto.identity-file "$legacy_key"

  ENGINE_DIRECTORY="$engine_repository"
  SSH_DIRECTORY="$identity_home/.ssh"
  SSH_CONFIG_FILE="$SSH_DIRECTORY/config"
  if find_local_identity_for_username sd800; then
    assert_equal "github800|$legacy_key" "$FOUND_SSH_ALIAS|$FOUND_IDENTITY_FILE" \
      "an exact central mapping takes priority over a stale username-shaped SSH Host"
  else
    fail_test "an exact central mapping takes priority over a stale username-shaped SSH Host"
  fi
  saved_register_account_and_identity="$(declare -f register_account_and_identity)"
  saved_create_new_identity="$(declare -f create_new_identity)"
  register_account_and_identity() {
    registered_mapping="$1|$3|$4"
  }
  create_new_identity() {
    create_call_count=$((create_call_count + 1))
    return 1
  }
  if setup_or_reuse_account sd800 sd800@users.noreply.github.com >/dev/null 2>&1; then
    assert_equal "sd800|github800|$legacy_key|0" \
      "$registered_mapping|$create_call_count" \
      "ordinary account setup reuses the exact key without entering key creation"
  else
    fail_test "ordinary account setup reuses the exact key without entering key creation"
  fi
  eval "$saved_register_account_and_identity"
  eval "$saved_create_new_identity"

  : > "$first_key"
  : > "$second_key"
  printf 'Host github-multi\n    HostName github.com\n    IdentityFile %s\n    IdentityFile %s\n' \
    "$first_key" "$second_key" > "$identity_home/.ssh/config"
  saved_identify_key_username="$(declare -f identify_key_username)"
  identify_key_username() {
    SSH_VERIFICATION_OUTPUT=""
    if [ "$1" = "$second_key" ]; then
      VERIFIED_GITHUB_USERNAME="sd800"
    else
      VERIFIED_GITHUB_USERNAME="another-account"
    fi
    return 0
  }
  if find_verified_identity_for_username sd800 github-multi; then
    assert_equal "$second_key" "$FOUND_IDENTITY_FILE" \
      "Advanced SSH discovery checks every existing identity listed for one Host"
  else
    fail_test "Advanced SSH discovery checks every existing identity listed for one Host"
  fi
  eval "$saved_identify_key_username"

  mv "$identity_home/.ssh/config" "$real_ssh_config"
  ln -s "$(basename "$real_ssh_config")" "$identity_home/.ssh/config"
  SSH_CONFIG_FILE="$identity_home/.ssh/config"
  if ensure_username_alias_for_identity sd800 github-multi "$second_key" &&
     [ -L "$SSH_CONFIG_FILE" ] &&
     same_existing_file \
       "$(resolve_alias_identity_file "$FOUND_SSH_ALIAS" || true)" \
       "$second_key"; then
    assert_equal "github-sd800" "$FOUND_SSH_ALIAS" \
      "a multi-key legacy Host gets an exact username Host instead of reusing its first key"
    pass "updating SSH aliases preserves a symlinked ~/.ssh/config"
  else
    fail_test "a multi-key legacy Host gets an exact username Host instead of reusing its first key"
    fail_test "updating SSH aliases preserves a symlinked ~/.ssh/config"
  fi

  mkdir -p "$binding_repository"
  git -C "$binding_repository" init -q
  git -C "$binding_repository" remote add origin git@github-sd800:sd800/example.git
  git -C "$binding_repository" config --local --add remote.origin.pushurl git@github-sd800:sd800/example.git
  git -C "$binding_repository" config --local user.name sd800
  git -C "$binding_repository" config --local user.email sd800@example.com
  git -C "$binding_repository" config --local github-auto.username sd800
  git -C "$binding_repository" config --local github-auto.ssh-alias github-sd800
  git -C "$binding_repository" config --local github-auto.identity-file "$second_key"
  git -C "$binding_repository" config --local github-auto.engine /old/git-auto.sh
  GIT_ROOT="$binding_repository"
  CURRENT_REPOSITORY_OWNER="sd800"
  CURRENT_REPOSITORY_NAME="example"
  ACCOUNT_USERNAMES=("sd800")
  ACCOUNT_EMAILS=("sd800@example.com")
  ACCOUNT_COUNT=1
  ENGINE_PATH="$PROJECT_DIRECTORY/git-auto.sh"
  if configure_project "" bind >/dev/null 2>&1 &&
     [ "$(git -C "$binding_repository" config --local --get github-auto.engine)" = "$ENGINE_PATH" ]; then
    pass "a complete fast binding silently refreshes only a moved central engine path"
  else
    fail_test "a complete fast binding silently refreshes only a moved central engine path"
  fi

  git -C "$binding_repository" config --local user.email wrong@example.com
  if load_established_project_binding; then
    fail_test "fast binding rejects a commit author email that differs from the saved owner account"
  else
    pass "fast binding rejects a commit author email that differs from the saved owner account"
  fi
  git -C "$binding_repository" config --local user.email sd800@example.com
  git -C "$binding_repository" remote set-url origin https://github.com/sd800/example.git
  if load_established_project_binding; then
    fail_test "fast binding rejects a fetch URL that bypasses the saved account SSH Host"
  else
    pass "fast binding rejects a fetch URL that bypasses the saved account SSH Host"
  fi

  git -C "$binding_repository" remote set-url origin git@github-sd800:sd800/example.git
  git -C "$binding_repository" remote add other git@github-sd800:sd800/other.git
  printf 'push fixture\n' > "$binding_repository/README.md"
  git -C "$binding_repository" add README.md
  git -C "$binding_repository" commit -qm baseline
  git -C "$binding_repository" branch -M main
  git -C "$binding_repository" config --local branch.main.remote other
  git -C "$binding_repository" config --local branch.main.merge refs/heads/main
  BOUND_USERNAME="sd800"
  BOUND_EMAIL="sd800@example.com"
  BOUND_SSH_ALIAS="github-sd800"
  BOUND_IDENTITY_FILE="$second_key"
  saved_run_git_with_identity="$(declare -f run_git_with_identity)"
  run_git_with_identity() {
    local argument=""
    local source_reference=""

    shift
    printf '%s\n' "$*" > "$push_marker"
    for argument in "$@"; do
      source_reference="$argument"
    done
    source_reference="${source_reference%%:*}"
    git -C "$GIT_ROOT" rev-parse "$source_reference" > "$push_marker.oid"
    printf 'transfer-progress\n'
    return 0
  }
  rm -f "$push_marker" "$push_marker.oid"
  status=0
  output="$(push_current_branch false 2>&1 <<< 'n')" || status=$?
  if [ "$status" -eq 2 ] &&
     [ ! -e "$push_marker" ] &&
     printf '%s\n' "$output" | grep -Fq 'Latest local commit message: baseline' &&
     printf '%s\n' "$output" | grep -Fq 'Continue with the GitHub push? [y/N]:' &&
     ! printf '%s\n' "$output" | grep -Fq 'Current branch:' &&
     ! printf '%s\n' "$output" | grep -Fq "$(git -C "$binding_repository" rev-parse --short HEAD)" &&
     printf '%s\n' "$output" | grep -Fq 'Upload canceled before connecting to GitHub'; then
    pass "English confirmation clearly labels the message and hides technical commit details"
  else
    fail_test "English confirmation clearly labels the message and hides technical commit details"
  fi
  UI_LANGUAGE="zh"
  status=0
  output="$(push_current_branch false 2>&1 <<< 'n')" || status=$?
  UI_LANGUAGE="en"
  if [ "$status" -eq 2 ] &&
     [ ! -e "$push_marker" ] &&
     printf '%s\n' "$output" | grep -Fq '最新本地提交说明：baseline' &&
     printf '%s\n' "$output" | grep -Fq '继续上传到 GitHub 吗？ [是(y)/否(N)，默认否]:' &&
     ! printf '%s\n' "$output" | grep -Fq '当前分支：'; then
    pass "Simplified Chinese confirmation is concise and clearly labels the commit message"
  else
    fail_test "Simplified Chinese confirmation is concise and clearly labels the commit message"
  fi
  status=0
  push_head="$(git -C "$binding_repository" rev-parse HEAD)"
  output="$(push_current_branch true 2>&1)" || status=$?
  if [ "$status" -eq 0 ] &&
     [[ "$(cat "$push_marker")" == push\ --progress\ origin\ refs/github-auto/push-*":refs/heads/main" ]] &&
     [ "$(cat "$push_marker.oid")" = "$push_head" ] &&
     [ -z "$(git -C "$binding_repository" for-each-ref --format='%(refname)' refs/github-auto/)" ] &&
     printf '%s\n' "$output" | grep -Fq 'transfer-progress'; then
    pass "daily push sends the exact reviewed commit to origin instead of an unrelated saved upstream"
  else
    fail_test "daily push sends the exact reviewed commit to origin instead of an unrelated saved upstream"
  fi
  run_git_with_identity() {
    shift
    printf 'rejected: non-fast-forward\n'
    return 1
  }
  status=0
  push_current_branch true > "$push_marker" 2>&1 || status=$?
  if [ "$status" -ne 0 ] &&
     grep -Fq 'GitHub has commits on main' "$push_marker" &&
     grep -Fq 'Keep the remote history and append this local version? [y/N]:' "$push_marker" &&
     grep -Fq 'The local commit and remote history remain unchanged.' "$push_marker"; then
    pass "live push progress preserves Git's failure status and detailed explanation"
  else
    fail_test "live push progress preserves Git's failure status and detailed explanation"
  fi
  eval "$saved_run_git_with_identity"

  : > "$real_ssh_config"
  git -C "$binding_repository" remote set-url origin git@legacy800:sd800/example.git
  git -C "$binding_repository" config --local --replace-all remote.origin.pushurl git@legacy800:sd800/example.git
  git -C "$binding_repository" config --local github-auto.ssh-alias legacy800
  git -C "$binding_repository" config --local github-auto.identity-file "$second_key"
  if read_origin_repository; then
    pass "a repository's exact saved custom SSH Host remains parseable while its SSH entry is repaired"
  else
    fail_test "a repository's exact saved custom SSH Host remains parseable while its SSH entry is repaired"
  fi

  ENGINE_DIRECTORY="$fake_engine_directory"
  BOUND_USERNAME="sd800"
  BOUND_EMAIL="sd800@example.com"
  if ensure_bound_identity >/dev/null 2>&1 &&
     same_existing_file "$BOUND_IDENTITY_FILE" "$second_key" &&
     [ "$BOUND_SSH_ALIAS" = "github-sd800" ]; then
    pass "a missing project SSH Host is repaired locally with its saved key instead of creating another key"
  else
    fail_test "a missing project SSH Host is repaired locally with its saved key instead of creating another key"
  fi

  printf '\nHost legacy-bad\n    HostName github.com\n    IdentityFile %s\n' \
    "$first_key" >> "$real_ssh_config"
  git -C "$binding_repository" config --local github-auto.ssh-alias legacy-bad
  if update_resolve_identity_file sd800 >/dev/null 2>&1 &&
     same_existing_file "$UPDATE_IDENTITY_FILE" "$second_key" &&
     [ -z "$UPDATE_OLD_ALIAS" ]; then
    pass "update keeps the project's exact saved key but rejects its inconsistent SSH Host"
  else
    fail_test "update keeps the project's exact saved key but rejects its inconsistent SSH Host"
  fi

  saved_advanced_prompt_value="$(declare -f advanced_prompt_value)"
  saved_advanced_select_account_for_history="$(declare -f advanced_select_account_for_history)"
  saved_advanced_verify_key_matches_username="$(declare -f advanced_verify_key_matches_username)"
  saved_advanced_verify_repository_access="$(declare -f advanced_verify_repository_access)"
  advanced_prompt_value() {
    printf 'sd800/example'
  }
  advanced_select_account_for_history() {
    BOUND_USERNAME="sd800"
    BOUND_EMAIL="sd800@example.com"
    BOUND_SSH_ALIAS="github-sd800"
    BOUND_IDENTITY_FILE="$second_key"
    return 0
  }
  advanced_verify_key_matches_username() {
    duplicate_history_identity_checks=$((duplicate_history_identity_checks + 1))
    return 0
  }
  advanced_verify_repository_access() {
    return 0
  }
  if advanced_prepare_history_destination >/dev/null 2>&1; then
    assert_equal "0" "$duplicate_history_identity_checks" \
      "historical import does not repeat the SSH account check already completed during account selection"
  else
    fail_test "historical import does not repeat the SSH account check already completed during account selection"
  fi
  eval "$saved_advanced_prompt_value"
  eval "$saved_advanced_select_account_for_history"
  eval "$saved_advanced_verify_key_matches_username"
  eval "$saved_advanced_verify_repository_access"

  printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' > "$unassigned_key"
  : > "$real_ssh_config"
  if configured_github_identity_exists; then
    pass "an unassigned conventional private key prevents ordinary setup from defaulting to another key"
  else
    fail_test "an unassigned conventional private key prevents ordinary setup from defaulting to another key"
  fi
  if grep -Fq -- '-o BatchMode=yes' "$PROJECT_DIRECTORY/src/10-ssh.sh"; then
    pass "Advanced identity checks cannot pause for an unexpected key passphrase prompt"
  else
    fail_test "Advanced identity checks cannot pause for an unexpected key passphrase prompt"
  fi
  if grep -Fq 'GIT_PAGER=cat' "$PROJECT_DIRECTORY/g.sh" &&
     grep -Fq 'GIT_PAGER=cat' "$PROJECT_DIRECTORY/git-auto.sh" &&
     grep -Fq -- '-o ServerAliveInterval=15' "$PROJECT_DIRECTORY/src/10-ssh.sh" &&
     grep -Fq -- '-o ServerAliveCountMax=2' "$PROJECT_DIRECTORY/src/10-ssh.sh" &&
     grep -Fq "'-o ServerAliveInterval=15'" "$PROJECT_DIRECTORY/src/30-workflow.sh" &&
     grep -Fq "'-o ServerAliveCountMax=2'" "$PROJECT_DIRECTORY/src/30-workflow.sh"; then
    pass "launcher, central engine, and Advanced SSH checks prevent unexplained terminal waits"
  else
    fail_test "launcher, central engine, and Advanced SSH checks prevent unexplained terminal waits"
  fi

  mkdir -p "$launcher_project" "$fake_engine_directory"
  canonical_launcher_project="$({ cd "$launcher_project" && pwd -P; })"
  cp "$PROJECT_DIRECTORY/g.sh" "$launcher_project/g.sh"
  chmod 755 "$launcher_project/g.sh"
  printf '#!/usr/bin/env bash\nprintf "folder-launch:%%s:%%s:pager=%%s\\n" "$GIT_AUTO_PROJECT_ROOT" "${1:-}" "${GIT_PAGER:-}"\n' \
    > "$fake_engine_directory/git-auto.sh"
  status=0
  output="$(
    cd "$launcher_project" &&
      printf '%s\n' "$fake_engine_directory" | GIT_PAGER=forbidden-pager bash ./g.sh probe 2>&1
  )" || status=$?
  if [ "$status" -eq 0 ] &&
     printf '%s\n' "$output" | grep -Fq \
       "folder-launch:$canonical_launcher_project:probe:pager=cat"; then
    pass "public g.sh accepts the folder containing git-auto.sh"
  else
    fail_test "public g.sh accepts the folder containing git-auto.sh"
  fi

  ENGINE_DIRECTORY="$PROJECT_DIRECTORY"
  ENGINE_PATH="$fake_engine_directory/git-auto.sh"
  PRIVATE_DIRECTORY="$private_launcher_directory"
  if write_private_launcher &&
     grep -Fq "DEFAULT_ENGINE_PATH='$fake_engine_directory/git-auto.sh'" \
       "$private_launcher_directory/g.sh" &&
     bash -n "$private_launcher_directory/g.sh"; then
    pass "private g.sh is copy-ready with the central engine path built in"
  else
    fail_test "private g.sh is copy-ready with the central engine path built in"
  fi

  ENGINE_DIRECTORY="$original_engine_directory"
  ENGINE_PATH="$original_engine_path"
  PRIVATE_DIRECTORY="$original_private_directory"
  SSH_DIRECTORY="$original_ssh_directory"
  SSH_CONFIG_FILE="$original_ssh_config_file"
  GIT_ROOT="$original_root"
}

test_focused_history_confirmation() {
  local release_directory="$TEST_TEMPORARY/focused-history-release"
  local fake_key="$TEST_TEMPORARY/focused-history-key"
  local message=""

  mkdir -p "$release_directory"
  printf 'release\n' > "$release_directory/README.md"
  : > "$fake_key"
  reset_history_releases
  HISTORY_RELEASE_VERSIONS[0]="1.1.1"
  HISTORY_RELEASE_DIRECTORIES[0]="$release_directory"
  HISTORY_RELEASE_DATES[0]=""
  HISTORY_RELEASE_NEEDS_GITIGNORE[0]="no"
  HISTORY_RELEASE_COUNT=1
  HISTORY_ADD_GITIGNORE=false
  HISTORY_REBUILD_DATES=false
  HISTORY_WORK_DIRECTORY=""
  CURRENT_REPOSITORY_OWNER="history-user"
  CURRENT_REPOSITORY_NAME="history-repository"
  BOUND_USERNAME="history-user"
  BOUND_EMAIL="history-user@example.com"
  BOUND_SSH_ALIAS="github-history-user"
  BOUND_IDENTITY_FILE="$fake_key"
  HISTORY_REMOTE_URL="$TEST_TEMPORARY/focused-history-remote.git"
  ADVANCED_LANGUAGE="en"

  HISTORY_COMMITS_CONFIRMED=false
  if history_build_repository >/dev/null 2>&1; then
    fail_test "historical builder refuses to create an unconfirmed commit"
  elif [ -z "$HISTORY_WORK_DIRECTORY" ]; then
    pass "historical builder refuses to create an unconfirmed commit"
  else
    fail_test "historical builder refuses to create an unconfirmed commit"
  fi

  HISTORY_COMMITS_CONFIRMED=true
  if history_build_repository >/dev/null 2>&1; then
    message="$(git -C "$HISTORY_WORK_DIRECTORY" log -1 --pretty=%s)"
    assert_equal "Release 1.1.1" "$message" \
      "confirmed historical plan creates its listed commit"
  else
    fail_test "confirmed historical plan creates its listed commit"
  fi
  history_remove_temporary_directory "$HISTORY_WORK_DIRECTORY" history || true
  HISTORY_WORK_DIRECTORY=""
}

test_user_interface_symbols() {
  local script_file="$TEST_TEMPORARY/combined-script-source.txt"
  local launcher_file="$PROJECT_DIRECTORY/g.sh"

  {
    sed -n '1,$p' "$PROJECT_DIRECTORY/git-auto.sh"
    for source_module in "$PROJECT_DIRECTORY"/src/*.sh; do
      sed -n '1,$p' "$source_module"
    done
  } > "$script_file"

  if ! grep -Fq 'ℹ' "$script_file" &&
     ! grep -Fq '✓' "$script_file" &&
     ! grep -Fq '✗' "$script_file" &&
     ! grep -Fq '✅' "$script_file" &&
     ! grep -Fq '❌' "$script_file" &&
     ! grep -Fq '🚀' "$script_file" &&
     ! grep -Fq '✅' "$launcher_file" &&
     ! grep -Fq '❌' "$launcher_file"; then
    pass "script user interfaces contain no emoji status symbols"
  else
    fail_test "script user interfaces contain no emoji status symbols"
  fi

  if grep -Fq "printf '  8) 高级功能" "$script_file" &&
     grep -Fq "printf '  8) Advanced features" "$script_file" &&
     grep -Fq "printf '  6) 界面语言" "$script_file" &&
     grep -Fq "printf '  6) Interface language" "$script_file"; then
    pass "menu exposes language selection and advanced features in both interfaces"
  else
    fail_test "menu exposes language selection and advanced features in both interfaces"
  fi

  if [ "$(grep -Fc 'muted "by Songming.org in 2026" "by Songming.org in 2026"' "$script_file")" -eq 2 ]; then
    pass "both menus show the same untranslated title credit in English and Chinese"
  else
    fail_test "both menus show the same untranslated title credit in English and Chinese"
  fi

  if grep -Fq '    update)' "$script_file" &&
     grep -Fq 'New GitHub username' "$script_file" &&
     grep -Fq '新的 GitHub 用户名' "$script_file"; then
    pass "update is a public command with English and localized Chinese interfaces"
  else
    fail_test "update is a public command with English and localized Chinese interfaces"
  fi

  if ! grep -Fq 'rsync' "$script_file"; then
    pass "historical import adds no rsync dependency"
  else
    fail_test "historical import adds no rsync dependency"
  fi

  if ! grep -Fq 'theme_settings_file' "$script_file" &&
     ! grep -Fq 'XDG_CONFIG_HOME' "$script_file" &&
     ! grep -Fq '.config/github-auto' "$script_file"; then
    pass "script stores its preferences without an application config directory"
  else
    fail_test "script stores its preferences without an application config directory"
  fi

  if ! grep -Eiq 'now automatically set up|set it up automatically now|secure connection|connection is ready|现在自动设置|自动配置\?|安全连接|连接正常|账号.*已准备好' "$script_file"; then
    pass "user interface avoids vague setup and connection status wording"
  else
    fail_test "user interface avoids vague setup and connection status wording"
  fi

  if grep -Fq 'Existing Git repository detected:' "$script_file" &&
     grep -Fq '已识别现有 Git 仓库：' "$script_file" &&
     grep -Fq 'Create and configure this separate SSH key now?' "$script_file" &&
     grep -Fq '现在创建并配置这把独立的 SSH 密钥吗？' "$script_file"; then
    pass "critical repository and SSH decisions have explicit English and Chinese copy"
  else
    fail_test "critical repository and SSH decisions have explicit English and Chinese copy"
  fi

  if grep -Fq 'PAGED_CHOICE_LETTERS="abcdefghjkmnpr"' "$script_file" &&
     grep -Fq "printf '  x) Previous page" "$script_file" &&
     grep -Fq "printf '  y) Next page" "$script_file" &&
     grep -Fq "printf 'z'" "$script_file" &&
     grep -Fq "printf '  0) Cancel" "$script_file"; then
    pass "shared menu component reserves letters and implements x, y, z, and zero"
  else
    fail_test "shared menu component reserves letters and implements x, y, z, and zero"
  fi

  if grep -Fq 'Menus with eight or fewer items' "$PROJECT_DIRECTORY/README.md" &&
     grep -Fq '菜单不超过 8 项时' "$PROJECT_DIRECTORY/README_zh.md"; then
    pass "both README versions explain the shared menu and pagination rules"
  else
    fail_test "both README versions explain the shared menu and pagination rules"
  fi

  if grep -Fq 'Discover and import GitHub accounts through SSH' "$script_file" &&
     grep -Fq '通过 SSH 识别并导入现有 GitHub 账号' "$script_file" &&
     grep -Fq 'Check this project locally' "$script_file" &&
     grep -Fq '核对当前项目的本机设置' "$script_file"; then
    pass "ordinary local checks and optional online diagnostics are separated in both interfaces"
  else
    fail_test "ordinary local checks and optional online diagnostics are separated in both interfaces"
  fi

  if ! grep -Fq 'curl ' "$script_file" &&
     ! grep -Fq 'SEARCH_ROOT=' "$launcher_file" &&
     ! grep -Fq 'command -v git-auto.sh' "$launcher_file"; then
    pass "ordinary setup and the lightweight launcher avoid optional network and directory-wide discovery"
  else
    fail_test "ordinary setup and the lightweight launcher avoid optional network and directory-wide discovery"
  fi

  if ! grep -Fq 'GIT_AUTO_DEBUG_DETAILS' "$script_file" &&
     ! grep -Fq 'history_tags_setting_menu' "$script_file" &&
     ! grep -Fq 'ls-remote --tags' "$script_file" &&
     ! grep -Fq 'refs/tags/' "$script_file"; then
    pass "technical-details and historical-tag features are absent from the program"
  else
    fail_test "technical-details and historical-tag features are absent from the program"
  fi

  if grep -Fq 'Fast, convenient, and simple is also the implementation rule.' "$PROJECT_DIRECTORY/README.md" &&
     grep -Fq '“快速、方便、简洁”同时也是技术实现规范。' "$PROJECT_DIRECTORY/README_zh.md" &&
     grep -Fq 'existing, normally non-empty working directory' "$PROJECT_DIRECTORY/README.md" &&
     grep -Fq '现有且通常并非空白的日常工作目录' "$PROJECT_DIRECTORY/README_zh.md"; then
    pass "both README versions document the engineering rule and non-empty history handoff"
  else
    fail_test "both README versions document the engineering rule and non-empty history handoff"
  fi
}

if [ "${1:-}" = "--version-resolution" ]; then
  printf 'TAP version 13\n'
  test_version_resolution
  test_project_release_policy
  printf '1..%s\n' "$TEST_COUNT"
  if [ "$FAILURE_COUNT" -gt 0 ]; then
    printf '%s test(s) failed\n' "$FAILURE_COUNT" >&2
    exit 1
  fi
  printf 'Focused tests passed.\n'
  exit 0
fi

if [ "${1:-}" = "--commit-confirmation" ]; then
  printf 'TAP version 13\n'
  test_focused_commit_confirmation
  test_focused_exact_snapshot_edges
  test_focused_transaction_safety
  test_focused_history_confirmation
  printf '1..%s\n' "$TEST_COUNT"
  if [ "$FAILURE_COUNT" -gt 0 ]; then
    printf '%s test(s) failed\n' "$FAILURE_COUNT" >&2
    exit 1
  fi
  printf 'Focused tests passed.\n'
  exit 0
fi

if [ "${1:-}" = "--ssh-launcher" ]; then
  printf 'TAP version 13\n'
  test_focused_ssh_and_launcher
  printf '1..%s\n' "$TEST_COUNT"
  if [ "$FAILURE_COUNT" -gt 0 ]; then
    printf '%s test(s) failed\n' "$FAILURE_COUNT" >&2
    exit 1
  fi
  printf 'Focused tests passed.\n'
  exit 0
fi

printf 'TAP version 13\n'
test_accounts
test_prompt_values
test_repository_parser
test_semver
test_version_resolution
test_ssh_config_discovery
test_alias_allocation
test_private_configuration
test_central_distribution
test_project_launcher
test_public_documentation
test_project_root_identity
test_existing_repository_state
test_origin_alias_identity_selection
test_repository_owner_account_enforcement
test_commit_cancellation_boundary
test_central_root_launcher_dispatch
test_self_exclusion_modes
test_git_binding_and_commit
test_guided_updates
test_update_prompt_flow
test_historical_release_import
test_paged_account_selection
test_user_interface_symbols
test_project_release_policy
test_focused_ssh_and_launcher
printf '1..%s\n' "$TEST_COUNT"

if [ "$FAILURE_COUNT" -gt 0 ]; then
  printf '%s test(s) failed\n' "$FAILURE_COUNT" >&2
  exit 1
fi

printf 'All tests passed.\n'
