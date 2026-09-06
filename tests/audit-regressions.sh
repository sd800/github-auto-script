#!/usr/bin/env bash
# Real Git fixtures only: no GitHub connection or user repository changes.
set -uo pipefail
AUDIT_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
AUDIT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/git-auto-audit.XXXXXX")"
trap 'rm -rf "$AUDIT_TMP"' EXIT
export GITHUB_AUTO_TESTING=1 NO_COLOR=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
source "$AUDIT_PROJECT/git-auto.sh"
AUDIT_FAILURES=0
AUDIT_COUNT=0
check() {
  AUDIT_COUNT=$((AUDIT_COUNT + 1))
  if "$@"; then printf 'ok %s - %s\n' "$AUDIT_COUNT" "$1";
  else printf 'not ok %s - %s\n' "$AUDIT_COUNT" "$1"; AUDIT_FAILURES=$((AUDIT_FAILURES + 1)); fi
}
fixture() {
  GIT_ROOT="$AUDIT_TMP/$1"
  mkdir -p "$GIT_ROOT"
  git -C "$GIT_ROOT" init -q
  git -C "$GIT_ROOT" symbolic-ref HEAD refs/heads/main
  git -C "$GIT_ROOT" config user.name tester
  git -C "$GIT_ROOT" config user.email tester@example.com
  git -C "$GIT_ROOT" config commit.gpgSign false
}
baseline() {
  printf 'baseline\n' > "$GIT_ROOT/base.txt"
  git -C "$GIT_ROOT" add -A && git -C "$GIT_ROOT" commit -qm baseline
}
matches_native_add() {
  local before actual expected
  before="$(git -C "$GIT_ROOT" write-tree)"
  prepare_expected_staged_tree || return 1
  expected="$WORKFLOW_EXPECTED_STAGED_TREE"
  [ "$(git -C "$GIT_ROOT" write-tree)" = "$before" ] || return 1
  git -C "$GIT_ROOT" add -A || return 1
  actual="$(git -C "$GIT_ROOT" write-tree)"
  clear_workflow_review_snapshot
  [ "$actual" = "$expected" ]
}
forced_ignored_file() {
  fixture forced && baseline || return 1
  printf 'release.bin\n' > "$GIT_ROOT/.gitignore"
  printf 'intentionally included\n' > "$GIT_ROOT/release.bin"
  git -C "$GIT_ROOT" add -f release.bin
  matches_native_add
}
unborn_forced_ignored_file() {
  fixture unborn || return 1
  printf 'release.bin\n' > "$GIT_ROOT/.gitignore"
  printf 'intentionally included\n' > "$GIT_ROOT/release.bin"
  git -C "$GIT_ROOT" add -f release.bin
  matches_native_add
}
intent_to_add_ignored_file() {
  fixture intent && baseline || return 1
  printf 'release.bin\n' > "$GIT_ROOT/.gitignore"
  printf 'intentionally included\n' > "$GIT_ROOT/release.bin"
  git -C "$GIT_ROOT" add -N -f release.bin
  matches_native_add
}
removed_from_tracking() {
  fixture untrack && baseline || return 1
  printf 'base.txt\n' > "$GIT_ROOT/.gitignore"
  git -C "$GIT_ROOT" rm -q --cached base.txt
  matches_native_add
}
sparse_staged_removal() {
  fixture sparse || return 1
  mkdir -p "$GIT_ROOT/keep" "$GIT_ROOT/omit"
  printf 'keep\n' > "$GIT_ROOT/keep/file"
  printf 'omit\n' > "$GIT_ROOT/omit/file"
  baseline || return 1
  git -C "$GIT_ROOT" sparse-checkout init --cone
  git -C "$GIT_ROOT" sparse-checkout set keep
  git -C "$GIT_ROOT" rm --sparse -q --cached omit/file
  matches_native_add
}
nested_repository_at_depth() {
  fixture nested && baseline || return 1
  local parent="$GIT_ROOT" result=0
  fixture nested/vendor/tool && baseline || return 1
  GIT_ROOT="$parent"
  review_possible_embedded_projects > "$AUDIT_TMP/nested-output" 2>&1 || result=$?
  [ "$result" -eq 2 ] && grep -Fq 'vendor/tool' "$AUDIT_TMP/nested-output" &&
    git -C "$GIT_ROOT" diff --cached --quiet
}
registered_new_submodule() {
  fixture submodule-source && baseline || return 1
  local source="$GIT_ROOT" result=0
  fixture submodule-parent && baseline || return 1
  git -C "$GIT_ROOT" -c protocol.file.allow=always submodule add -q "$source" library || return 1
  review_possible_embedded_projects > "$AUDIT_TMP/submodule-output" 2>&1 || result=$?
  [ "$result" -eq 0 ]
}
confirmed_comment_message() {
  fixture message && baseline || return 1
  git -C "$GIT_ROOT" config commit.cleanup strip
  printf 'changed\n' >> "$GIT_ROOT/base.txt"
  local PROJECT_BINDING_REUSED=true
  ( prompt_commit_message() { COMMIT_MESSAGE='#123 Fix the reported issue'; }
    prepare_and_commit > "$AUDIT_TMP/message-output" 2>&1 &&
      [ "$(git -C "$GIT_ROOT" log -1 --format=%s)" = '#123 Fix the reported issue' ] )
}
previous_github_commit_message_is_shown() {
  fixture previous-message && baseline || return 1
  git -C "$GIT_ROOT" update-ref refs/remotes/origin/main HEAD || return 1
  printf 'local draft\n' >> "$GIT_ROOT/base.txt"
  git -C "$GIT_ROOT" add -A || return 1
  git -C "$GIT_ROOT" commit -qm 'Local draft' || return 1
  local UI_LANGUAGE=en
  prompt_commit_message Update > "$AUDIT_TMP/previous-message-en" 2>&1 <<< '' || return 1
  UI_LANGUAGE=zh
  prompt_commit_message Update > "$AUDIT_TMP/previous-message-zh" 2>&1 <<< '' || return 1
  grep -Fq 'Commit message: Update' "$AUDIT_TMP/previous-message-en" &&
    grep -Fq 'Previous commit message: baseline' "$AUDIT_TMP/previous-message-en" &&
    grep -Fq '本次提交说明：Update' "$AUDIT_TMP/previous-message-zh" &&
    grep -Fq '上次提交说明：baseline' "$AUDIT_TMP/previous-message-zh" &&
    ! grep -Fq 'Previous commit message: Local draft' "$AUDIT_TMP/previous-message-en"
}
ssh_wrapper_with_spaces() {
  fixture ssh-path || return 1
  local TMPDIR="$AUDIT_TMP/temporary space's directory" PATH="$AUDIT_TMP/bin:$PATH"
  export TMPDIR PATH
  mkdir -p "$TMPDIR" "$AUDIT_TMP/bin"
  printf '#!/bin/sh\nprintf "invoked\\n" > "%s"\nexit 1\n' "$AUDIT_TMP/ssh-invoked" > "$AUDIT_TMP/bin/ssh"
  chmod +x "$AUDIT_TMP/bin/ssh"
  run_git_with_identity "$AUDIT_TMP/key" ls-remote git@github-test:tester/repo.git > "$AUDIT_TMP/ssh-output" 2>&1 || true
  [ -f "$AUDIT_TMP/ssh-invoked" ]
}
push_fixture() {
  fixture "$1" && baseline || return 1
  BOUND_USERNAME=tester
  BOUND_SSH_ALIAS=github-tester
  CURRENT_REPOSITORY_OWNER=tester
  CURRENT_REPOSITORY_NAME=repo
  git -C "$GIT_ROOT" remote add origin git@github-tester:tester/repo.git
  AUDIT_REMOTE="$AUDIT_TMP/$1-remote.git"
  git init --bare -q "$AUDIT_REMOTE"
  mkdir -p "$AUDIT_TMP/transport"
  printf '#!/bin/sh\nprintf "invoked\\n" >> "$AUDIT_SSH_LOG"\nfor argument in "$@"; do\n  case "$argument" in\n    *git-upload-pack*) exec git-upload-pack "$AUDIT_REMOTE" ;;\n    *git-receive-pack*) exec git-receive-pack "$AUDIT_REMOTE" ;;\n  esac\ndone\nexit 1\n' > "$AUDIT_TMP/transport/ssh"
  chmod +x "$AUDIT_TMP/transport/ssh"
  export AUDIT_REMOTE
}
multiple_push_destinations() {
  push_fixture multiple || return 1
  local PATH="$AUDIT_TMP/transport:$PATH" AUDIT_SSH_LOG="$AUDIT_TMP/multiple-log" result=0
  export PATH AUDIT_SSH_LOG
  git -C "$GIT_ROOT" config --add remote.origin.pushurl git@github-tester:tester/repo.git
  git -C "$GIT_ROOT" config --add remote.origin.pushurl git@github-tester:someone/other.git
  run_git_with_identity "$AUDIT_TMP/key" push origin HEAD:refs/heads/main > "$AUDIT_TMP/multiple-output" 2>&1 || result=$?
  [ "$result" -ne 0 ] && [ ! -f "$AUDIT_SSH_LOG" ] &&
    [ -z "$(git --git-dir="$AUDIT_REMOTE" for-each-ref)" ]
}
push_does_not_follow_tags() {
  push_fixture tags || return 1
  local PATH="$AUDIT_TMP/transport:$PATH" AUDIT_SSH_LOG="$AUDIT_TMP/tags-log"
  export PATH AUDIT_SSH_LOG
  git -C "$GIT_ROOT" tag -am 'unrequested tag' existing-tag
  git -C "$GIT_ROOT" config push.followTags true
  run_git_with_identity "$AUDIT_TMP/key" push origin HEAD:refs/heads/main > "$AUDIT_TMP/tags-output" 2>&1 || return 1
  [ "$(git --git-dir="$AUDIT_REMOTE" rev-parse refs/heads/main)" = "$(git -C "$GIT_ROOT" rev-parse HEAD)" ] &&
    [ -z "$(git --git-dir="$AUDIT_REMOTE" tag -l)" ] &&
    [ "$(git -C "$GIT_ROOT" config push.followTags)" = true ]
}
push_ignores_mirror_mode() {
  push_fixture mirror || return 1
  local PATH="$AUDIT_TMP/transport:$PATH" AUDIT_SSH_LOG="$AUDIT_TMP/mirror-log"
  export PATH AUDIT_SSH_LOG
  git -C "$GIT_ROOT" config remote.origin.mirror true
  run_git_with_identity "$AUDIT_TMP/key" push origin HEAD:refs/heads/main > "$AUDIT_TMP/mirror-output" 2>&1 || return 1
  [ "$(git --git-dir="$AUDIT_REMOTE" for-each-ref --format='%(refname)')" = refs/heads/main ] &&
    [ "$(git -C "$GIT_ROOT" config remote.origin.mirror)" = true ]
}
damaged_metadata_is_not_initialized() {
  fixture damaged && baseline || return 1
  local SCRIPT_DIRECTORY="$GIT_ROOT" result=0
  rm "$GIT_ROOT/.git/HEAD"
  ( locate_project yes ) > "$AUDIT_TMP/damaged-output" 2>&1 || result=$?
  [ "$result" -ne 0 ] && [ ! -f "$GIT_ROOT/.git/HEAD" ]
}
unfinished_cherry_pick_sequence() {
  fixture sequence && baseline || return 1
  git -C "$GIT_ROOT" checkout -qb source
  printf 'source\n' > "$GIT_ROOT/base.txt"
  git -C "$GIT_ROOT" commit -qam source
  local picked="$(git -C "$GIT_ROOT" rev-parse HEAD)"
  printf 'second\n' > "$GIT_ROOT/second.txt"
  git -C "$GIT_ROOT" add -A && git -C "$GIT_ROOT" commit -qm second
  local second="$(git -C "$GIT_ROOT" rev-parse HEAD)"
  git -C "$GIT_ROOT" checkout -q main
  printf 'conflict\n' > "$GIT_ROOT/base.txt"
  git -C "$GIT_ROOT" commit -qam conflict
  git -C "$GIT_ROOT" cherry-pick "$picked" "$second" >/dev/null 2>&1 || true
  printf 'resolved\n' > "$GIT_ROOT/base.txt"
  git -C "$GIT_ROOT" add -A && git -C "$GIT_ROOT" commit -qm resolved
  [ ! -e "$GIT_ROOT/.git/CHERRY_PICK_HEAD" ] && [ -d "$GIT_ROOT/.git/sequencer" ] &&
    git_operation_in_progress
}
ordinary_changes_use_one_hint_scan() {
  fixture bulk || return 1
  local n=0 calls=0
  while [ "$n" -lt 150 ]; do
    printf 'old\n' > "$GIT_ROOT/file-$n"
    n=$((n + 1))
  done
  baseline || return 1
  n=0
  while [ "$n" -lt 150 ]; do
    printf 'new\n' > "$GIT_ROOT/file-$n"
    n=$((n + 1))
  done
  prepare_expected_staged_tree || return 1
  ( git() { printf 'call\n' >> "$AUDIT_TMP/bulk-calls"; command git "$@"; }
    prepare_real_index_for_exact_staging ) || return 1
  calls="$(wc -l < "$AUDIT_TMP/bulk-calls" | tr -d ' ')"
  clear_workflow_review_snapshot
  [ "$calls" -eq 1 ]
}
hidden_literal_filenames() {
  fixture literal || return 1
  local path=$'line\nbreak' PROJECT_BINDING_REUSED=true
  printf 'old\n' > "$GIT_ROOT/$path"
  printf 'old\n' > "$GIT_ROOT/[name]*.txt"
  printf 'unrelated\n' > "$GIT_ROOT/name-other.txt"
  baseline || return 1
  git -C "$GIT_ROOT" update-index --assume-unchanged -- "$path" '[name]*.txt' name-other.txt
  printf 'new\n' > "$GIT_ROOT/$path"
  printf 'new\n' > "$GIT_ROOT/[name]*.txt"
  ( prompt_commit_message() { COMMIT_MESSAGE=confirmed; }
    prepare_and_commit > "$AUDIT_TMP/literal-output" 2>&1 ) || return 1
  [ "$(git -C "$GIT_ROOT" show "HEAD:$path")" = new ] &&
    [ "$(git -C "$GIT_ROOT" show 'HEAD:[name]*.txt')" = new ] &&
    [ "$(git -C "$GIT_ROOT" ls-files -v name-other.txt)" = 'h name-other.txt' ]
}
intent_to_add_project_is_reviewed() {
  fixture intended-project && baseline || return 1
  mkdir -p "$GIT_ROOT/library"
  printf 'library/\n' > "$GIT_ROOT/.gitignore"
  printf '{"name":"separate-project"}\n' > "$GIT_ROOT/library/package.json"
  git -C "$GIT_ROOT" add -N -f library/package.json
  local before="$(git -C "$GIT_ROOT" write-tree)" result=0
  prepare_expected_staged_tree || return 1
  review_possible_embedded_projects > "$AUDIT_TMP/intent-review" 2>&1 <<< n || result=$?
  clear_workflow_review_snapshot
  [ "$result" -eq 2 ] && [ "$(git -C "$GIT_ROOT" write-tree)" = "$before" ] &&
    grep -Fq 'library' "$AUDIT_TMP/intent-review"
}
prepare_remote_ahead_fixture() {
  local name="$1"
  push_fixture "$name" || return 1
  local remote_work="$AUDIT_TMP/$name-remote-work"
  git -C "$AUDIT_REMOTE" symbolic-ref HEAD refs/heads/main
  mkdir -p "$remote_work"
  git -C "$remote_work" init -q
  git -C "$remote_work" symbolic-ref HEAD refs/heads/main
  git -C "$remote_work" remote add origin "$AUDIT_REMOTE"
  git -C "$remote_work" config user.name remote-user
  git -C "$remote_work" config user.email remote@example.com
  printf 'remote history\n' > "$remote_work/remote.txt"
  git -C "$remote_work" add -A
  git -C "$remote_work" commit -qm 'Remote release'
  git -C "$remote_work" push -q origin main
  AUDIT_REMOTE_HEAD="$(git --git-dir="$AUDIT_REMOTE" rev-parse refs/heads/main)"
  AUDIT_LOCAL_HEAD="$(git -C "$GIT_ROOT" rev-parse HEAD)"
  AUDIT_LOCAL_TREE="$(git -C "$GIT_ROOT" rev-parse 'HEAD^{tree}')"
  : > "$AUDIT_TMP/$name-key"
  BOUND_EMAIL=tester@example.com
  BOUND_IDENTITY_FILE="$AUDIT_TMP/$name-key"
  git -C "$GIT_ROOT" config user.name tester
  git -C "$GIT_ROOT" config user.email tester@example.com
  git -C "$GIT_ROOT" config github-auto.username tester
  git -C "$GIT_ROOT" config github-auto.ssh-alias github-tester
  git -C "$GIT_ROOT" config github-auto.identity-file "$BOUND_IDENTITY_FILE"
  capture_workflow_checkpoint
}
remote_history_append_defaults_to_no() {
  prepare_remote_ahead_fixture append-no || return 1
  local PATH="$AUDIT_TMP/transport:$PATH" AUDIT_SSH_LOG="$AUDIT_TMP/append-no-log" result=0
  export PATH AUDIT_SSH_LOG
  append_current_version_to_remote_history main "$AUDIT_LOCAL_HEAD" \
    > "$AUDIT_TMP/append-no-output" 2>&1 <<< '' || result=$?
  [ "$result" -eq 2 ] && [ ! -f "$AUDIT_SSH_LOG" ] &&
    [ "$(git -C "$GIT_ROOT" rev-parse HEAD)" = "$AUDIT_LOCAL_HEAD" ] &&
    [ "$(git --git-dir="$AUDIT_REMOTE" rev-parse refs/heads/main)" = "$AUDIT_REMOTE_HEAD" ]
}
remote_history_is_retained_before_local_snapshot() {
  prepare_remote_ahead_fixture append-yes || return 1
  local PATH="$AUDIT_TMP/transport:$PATH" AUDIT_SSH_LOG="$AUDIT_TMP/append-yes-log" result=0
  export PATH AUDIT_SSH_LOG
  ( ui_prompt_yes_no() { return 0; }
    prompt_commit_message() { COMMIT_MESSAGE="$1"; return 0; }
    append_current_version_to_remote_history main "$AUDIT_LOCAL_HEAD" ) \
      > "$AUDIT_TMP/append-yes-output" 2>&1 || result=$?
  local published="$(git --git-dir="$AUDIT_REMOTE" rev-parse refs/heads/main)"
  [ "$result" -eq 0 ] &&
    [ "$(git -C "$GIT_ROOT" rev-parse HEAD)" = "$published" ] &&
    [ "$(git --git-dir="$AUDIT_REMOTE" show -s --format='%T' "$published")" = "$AUDIT_LOCAL_TREE" ] &&
    [ "$(git --git-dir="$AUDIT_REMOTE" show -s --format='%P' "$published")" = "$AUDIT_REMOTE_HEAD $AUDIT_LOCAL_HEAD" ] &&
    git --git-dir="$AUDIT_REMOTE" cat-file -e "$AUDIT_REMOTE_HEAD^{commit}" &&
    git --git-dir="$AUDIT_REMOTE" cat-file -e "$AUDIT_LOCAL_HEAD^{commit}" &&
    [ -z "$(git -C "$GIT_ROOT" for-each-ref --format='%(refname)' refs/github-auto/)" ]
}
remote_history_append_message_can_be_canceled() {
  prepare_remote_ahead_fixture append-cancel || return 1
  local PATH="$AUDIT_TMP/transport:$PATH" AUDIT_SSH_LOG="$AUDIT_TMP/append-cancel-log" result=0
  export PATH AUDIT_SSH_LOG
  ( ui_prompt_yes_no() { return 0; }
    prompt_commit_message() { return 2; }
    append_current_version_to_remote_history main "$AUDIT_LOCAL_HEAD" ) \
      > "$AUDIT_TMP/append-cancel-output" 2>&1 || result=$?
  [ "$result" -eq 2 ] && [ -s "$AUDIT_SSH_LOG" ] &&
    [ "$(git -C "$GIT_ROOT" rev-parse HEAD)" = "$AUDIT_LOCAL_HEAD" ] &&
    [ "$(git --git-dir="$AUDIT_REMOTE" rev-parse refs/heads/main)" = "$AUDIT_REMOTE_HEAD" ] &&
    [ -z "$(git -C "$GIT_ROOT" for-each-ref --format='%(refname)' refs/github-auto/)" ]
}
remote_hook_rejection_does_not_offer_history_append() {
  ! push_rejection_is_remote_ahead 'Updates were rejected by a pre-receive hook'
}
localized_default_letter_is_uppercase() {
  local UI_LANGUAGE=zh ADVANCED_LANGUAGE=zh result=0
  prompt_yes_no '确认默认是' yes > "$AUDIT_TMP/prompt-yes" 2>&1 <<< '' || return 1
  prompt_yes_no '确认默认否' no > "$AUDIT_TMP/prompt-no" 2>&1 <<< '' || result=$?
  [ "$result" -eq 1 ] &&
    grep -Fq '[是(Y)/否(n)，默认是]' "$AUDIT_TMP/prompt-yes" &&
    grep -Fq '[是(y)/否(N)，默认否]' "$AUDIT_TMP/prompt-no" &&
    advanced_prompt_yes_no 'advanced' '高级默认是' yes > "$AUDIT_TMP/advanced-yes" 2>&1 <<< '' &&
    grep -Fq '[是(Y)/否(n)，默认是]' "$AUDIT_TMP/advanced-yes"
}
check forced_ignored_file
check unborn_forced_ignored_file
check intent_to_add_ignored_file
check removed_from_tracking
check sparse_staged_removal
check nested_repository_at_depth
check registered_new_submodule
check confirmed_comment_message
check previous_github_commit_message_is_shown
check ssh_wrapper_with_spaces
check multiple_push_destinations
check push_does_not_follow_tags
check push_ignores_mirror_mode
check damaged_metadata_is_not_initialized
check unfinished_cherry_pick_sequence
check ordinary_changes_use_one_hint_scan
check hidden_literal_filenames
check intent_to_add_project_is_reviewed
check remote_history_append_defaults_to_no
check remote_history_is_retained_before_local_snapshot
check remote_history_append_message_can_be_canceled
check remote_hook_rejection_does_not_offer_history_append
check localized_default_letter_is_uppercase
printf '%s checks; %s failures\n' "$AUDIT_COUNT" "$AUDIT_FAILURES"
[ "$AUDIT_FAILURES" -eq 0 ]
