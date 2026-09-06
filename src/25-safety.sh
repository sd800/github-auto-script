# -----------------------------------------------------------------------------
# Repository transaction safety
# -----------------------------------------------------------------------------

WORKFLOW_COMMON_DIRECTORY=""
WORKFLOW_LOCK_DIRECTORY=""
WORKFLOW_LOCK_TOKEN=""
WORKFLOW_LOCK_HELD=false
WORKFLOW_STATE_FILE=""
WORKFLOW_REVIEW_SNAPSHOT=""
WORKFLOW_EXPECTED_STAGED_TREE=""
WORKFLOW_EXPECTED_INDEX_FILE=""
WORKFLOW_EXPECTED_ORIGINAL_INDEX_TREE=""
WORKFLOW_EXPECTED_HEAD_TREE=""
WORKFLOW_SPARSE_CHECKOUT=false
WORKFLOW_PUSH_REFERENCE=""
WORKFLOW_REMOTE_REFERENCE=""
WORKFLOW_TRANSACTION_ACTIVE=false
WORKFLOW_CHECKPOINT_ACTIVE=false
WORKFLOW_EXPECTED_ROOT=""
WORKFLOW_EXPECTED_COMMON_DIRECTORY=""
WORKFLOW_EXPECTED_SYMBOLIC_HEAD=""
WORKFLOW_EXPECTED_HEAD=""
WORKFLOW_EXPECTED_ORIGIN_FETCH=""
WORKFLOW_EXPECTED_ORIGIN_PUSH=""
WORKFLOW_EXPECTED_USERNAME=""
WORKFLOW_EXPECTED_AUTHOR_NAME=""
WORKFLOW_EXPECTED_EMAIL=""
WORKFLOW_EXPECTED_ALIAS=""
WORKFLOW_EXPECTED_IDENTITY_FILE=""
WORKFLOW_EXPECTED_IDENTITY_HASH=""
WORKFLOW_APPROVED_PROJECT_DIRECTORIES=()
WORKFLOW_APPROVED_PROJECT_MARKERS=()
WORKFLOW_APPROVED_PROJECT_COUNT=0

resolve_workflow_common_directory() {
  local common_directory=""

  common_directory="$(git -C "$GIT_ROOT" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common_directory" in
    /*)
      ;;
    *)
      common_directory="$GIT_ROOT/$common_directory"
      ;;
  esac
  common_directory="$({ cd "$common_directory" 2>/dev/null && pwd -P; })" || return 1
  WORKFLOW_COMMON_DIRECTORY="$common_directory"
  return 0
}

workflow_lock_metadata_name_is_recognized() {
  local name="$1"

  case "$name" in
    pid|token)
      return 0
      ;;
  esac
  [[ "$name" =~ ^(pid|token)\ [2-9][0-9]*$ ]]
}

workflow_lock_pid_name_is_recognized() {
  local name="$1"

  [ "$name" = pid ] || [[ "$name" =~ ^pid\ [2-9][0-9]*$ ]]
}

workflow_lock_owner_pids() {
  local lock_directory="$1"
  local entry=""
  local name=""
  local owner_pid=""
  local found=false

  [ -d "$lock_directory" ] || return 1
  while IFS= read -r -d '' entry; do
    name="${entry##*/}"
    workflow_lock_metadata_name_is_recognized "$name" || return 1
    [ -f "$entry" ] && [ ! -L "$entry" ] || return 1
    if workflow_lock_pid_name_is_recognized "$name"; then
      IFS= read -r owner_pid < "$entry" || true
      [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || return 1
      printf '%s\n' "$owner_pid"
      found=true
    fi
  done < <(find "$lock_directory" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  [ "$found" = true ]
}

remove_stale_workflow_lock() {
  local lock_directory="$1"
  local entries=()
  local entry=""
  local name=""

  while IFS= read -r -d '' entry; do
    name="${entry##*/}"
    workflow_lock_metadata_name_is_recognized "$name" || return 1
    [ -f "$entry" ] && [ ! -L "$entry" ] || return 1
    entries+=("$entry")
  done < <(find "$lock_directory" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  for entry in "${entries[@]}"; do
    rm -f "$entry" || return 1
  done
  rmdir "$lock_directory" 2>/dev/null
}

report_previous_workflow_state() {
  local phase=""

  [ -f "$WORKFLOW_STATE_FILE" ] || return 0
  phase="$(sed -nE 's/^phase:[[:space:]]*//p' "$WORKFLOW_STATE_FILE" | sed -n '1p')"
  case "$phase" in
    staging|staged)
      warn \
        "A previous $SCRIPT_NAME run ended while preparing the Git staging area." \
        "上一次运行 ${SCRIPT_NAME} 时，在准备 Git 暂存区的过程中提前结束了。"
      ;;
    committing)
      warn \
        "A previous $SCRIPT_NAME run ended while Git was creating a commit." \
        "上一次运行 ${SCRIPT_NAME} 时，在 Git 创建提交的过程中提前结束了。"
      ;;
    pushing)
      warn \
        "A previous $SCRIPT_NAME run ended while Git was pushing to GitHub." \
        "上一次运行 ${SCRIPT_NAME} 时，在 Git 上传到 GitHub 的过程中提前结束了。"
      ;;
    reconciling)
      warn \
        "A previous $SCRIPT_NAME run ended while connecting local and remote history." \
        "上一次运行 ${SCRIPT_NAME} 时，在衔接本机与远端提交记录的过程中提前结束了。"
      ;;
    *)
      warn \
        "A previous $SCRIPT_NAME run did not record a clean finish." \
        "上一次运行 ${SCRIPT_NAME} 时没有正常记录流程结束。"
      ;;
  esac
  muted \
    "Nothing will be cleared or reused silently. The current repository, branch, commit, origin, and complete Git status will be checked again before any new commit or push." \
    "脚本不会静默清空或沿用上次准备的内容。本次会重新核对当前仓库、分支、提交、origin 和完整 Git 状态，再决定是否创建提交或上传。"
}

clear_workflow_state() {
  if [ -f "$WORKFLOW_STATE_FILE" ] || [ -L "$WORKFLOW_STATE_FILE" ]; then
    rm -f "$WORKFLOW_STATE_FILE"
  fi
}

set_workflow_state() {
  local phase="$1"
  local temporary_file=""

  [ "$WORKFLOW_TRANSACTION_ACTIVE" = true ] || return 0
  [ -n "$WORKFLOW_STATE_FILE" ] || return 1
  temporary_file="$(safe_mktemp_file "$WORKFLOW_COMMON_DIRECTORY" "github-auto-state")" || return 1
  {
    printf 'phase: %s\n' "$phase"
    printf 'pid: %s\n' "$$"
  } > "$temporary_file" || {
    rm -f "$temporary_file"
    return 1
  }
  if ! mv "$temporary_file" "$WORKFLOW_STATE_FILE"; then
    rm -f "$temporary_file"
    return 1
  fi
}

acquire_workflow_lock() {
  local active_pid=""
  local owner_pid=""
  local owner_pids=""
  local owners_known=false

  if [ "$WORKFLOW_LOCK_HELD" = true ]; then
    return 0
  fi
  resolve_workflow_common_directory || {
    error_message \
      "The repository's Git control directory could not be resolved safely." \
      "无法安全识别当前仓库的 Git 控制目录。"
    return 1
  }
  WORKFLOW_LOCK_DIRECTORY="$WORKFLOW_COMMON_DIRECTORY/github-auto.workflow.lock"
  WORKFLOW_STATE_FILE="$WORKFLOW_COMMON_DIRECTORY/github-auto.workflow-state"
  WORKFLOW_LOCK_TOKEN="$$-${RANDOM:-1}-${RANDOM:-1}"

  if ! mkdir "$WORKFLOW_LOCK_DIRECTORY" 2>/dev/null; then
    if owner_pids="$(workflow_lock_owner_pids "$WORKFLOW_LOCK_DIRECTORY")"; then
      owners_known=true
      while IFS= read -r owner_pid; do
        [ -n "$owner_pid" ] || continue
        if kill -0 "$owner_pid" 2>/dev/null; then
          active_pid="$owner_pid"
          break
        fi
      done <<< "$owner_pids"
    fi
    if [ "$owners_known" = true ] && [ -z "$active_pid" ]; then
      if ! remove_stale_workflow_lock "$WORKFLOW_LOCK_DIRECTORY" ||
         ! mkdir "$WORKFLOW_LOCK_DIRECTORY" 2>/dev/null; then
        error_message \
          "A stale workflow lock exists but could not be removed safely: $WORKFLOW_LOCK_DIRECTORY" \
          "发现上次遗留的流程锁，但无法安全移除：${WORKFLOW_LOCK_DIRECTORY}"
        return 1
      fi
    else
      error_message \
        "Another $SCRIPT_NAME process is already preparing, committing, updating, or pushing this same Git repository. Let that process finish before running this command again." \
        "另一个 ${SCRIPT_NAME} 进程正在处理同一个 Git 仓库，可能正在准备、提交、更新设置或上传。请等待该进程结束后再运行本命令。"
      if [ -n "$active_pid" ]; then
        muted "Active process ID: $active_pid" "正在运行的进程编号：$active_pid"
      else
        muted \
          "The lock owner could not be identified, so the script stopped instead of risking two overlapping Git operations." \
          "由于无法确认流程锁的归属，脚本已停止，避免两次 Git 操作发生重叠。"
      fi
      return 1
    fi
  fi

  if ! printf '%s\n' "$$" > "$WORKFLOW_LOCK_DIRECTORY/pid" ||
     ! printf '%s\n' "$WORKFLOW_LOCK_TOKEN" > "$WORKFLOW_LOCK_DIRECTORY/token"; then
    rm -f "$WORKFLOW_LOCK_DIRECTORY/pid" "$WORKFLOW_LOCK_DIRECTORY/token"
    rmdir "$WORKFLOW_LOCK_DIRECTORY" 2>/dev/null || true
    error_message \
      "The repository workflow lock could not be recorded safely." \
      "无法安全写入当前仓库的流程锁。"
    return 1
  fi

  WORKFLOW_LOCK_HELD=true
  report_previous_workflow_state
  clear_workflow_state
  return 0
}

release_workflow_lock() {
  local saved_token=""

  [ "$WORKFLOW_LOCK_HELD" = true ] || return 0
  if [ -f "$WORKFLOW_LOCK_DIRECTORY/token" ]; then
    IFS= read -r saved_token < "$WORKFLOW_LOCK_DIRECTORY/token" || true
  fi
  if [ "$saved_token" = "$WORKFLOW_LOCK_TOKEN" ]; then
    rm -f "$WORKFLOW_LOCK_DIRECTORY/pid" "$WORKFLOW_LOCK_DIRECTORY/token"
    rmdir "$WORKFLOW_LOCK_DIRECTORY" 2>/dev/null || true
  fi
  WORKFLOW_LOCK_HELD=false
}

cleanup_workflow_runtime() {
  clear_workflow_review_snapshot
  if [ -n "$WORKFLOW_PUSH_REFERENCE" ]; then
    git -C "$GIT_ROOT" update-ref -d "$WORKFLOW_PUSH_REFERENCE" >/dev/null 2>&1 || true
    WORKFLOW_PUSH_REFERENCE=""
  fi
  if [ -n "$WORKFLOW_REMOTE_REFERENCE" ]; then
    git -C "$GIT_ROOT" update-ref -d "$WORKFLOW_REMOTE_REFERENCE" >/dev/null 2>&1 || true
    WORKFLOW_REMOTE_REFERENCE=""
  fi
  release_workflow_lock
}

install_workflow_cleanup_traps() {
  trap 'cleanup_workflow_runtime' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

workflow_head_value() {
  git -C "$GIT_ROOT" rev-parse --verify HEAD 2>/dev/null || printf '<unborn>'
}

capture_workflow_checkpoint() {
  local current_root=""
  local identity_path=""

  current_root="$(git -C "$GIT_ROOT" rev-parse --show-toplevel 2>/dev/null)" || return 1
  current_root="$({ cd "$current_root" 2>/dev/null && pwd -P; })" || return 1
  resolve_workflow_common_directory || return 1

  WORKFLOW_EXPECTED_ROOT="$current_root"
  WORKFLOW_EXPECTED_COMMON_DIRECTORY="$WORKFLOW_COMMON_DIRECTORY"
  WORKFLOW_EXPECTED_SYMBOLIC_HEAD="$(git -C "$GIT_ROOT" symbolic-ref -q HEAD 2>/dev/null || true)"
  WORKFLOW_EXPECTED_HEAD="$(workflow_head_value)"
  WORKFLOW_EXPECTED_ORIGIN_FETCH="$(git -C "$GIT_ROOT" remote get-url --all origin 2>/dev/null || true)"
  WORKFLOW_EXPECTED_ORIGIN_PUSH="$(git -C "$GIT_ROOT" remote get-url --push --all origin 2>/dev/null || true)"
  WORKFLOW_EXPECTED_USERNAME="$(git -C "$GIT_ROOT" config --local --get github-auto.username 2>/dev/null || true)"
  WORKFLOW_EXPECTED_AUTHOR_NAME="$(git -C "$GIT_ROOT" config --local --get user.name 2>/dev/null || true)"
  WORKFLOW_EXPECTED_EMAIL="$(git -C "$GIT_ROOT" config --local --get user.email 2>/dev/null || true)"
  WORKFLOW_EXPECTED_ALIAS="$(git -C "$GIT_ROOT" config --local --get github-auto.ssh-alias 2>/dev/null || true)"
  WORKFLOW_EXPECTED_IDENTITY_FILE="$(git -C "$GIT_ROOT" config --local --get github-auto.identity-file 2>/dev/null || true)"
  identity_path="$(expand_home_path "$WORKFLOW_EXPECTED_IDENTITY_FILE")"
  identity_path="${identity_path//%d/${HOME:-}}"
  WORKFLOW_EXPECTED_IDENTITY_HASH=""
  if [ -n "$identity_path" ] && [ -f "$identity_path" ]; then
    WORKFLOW_EXPECTED_IDENTITY_HASH="$(git hash-object --no-filters "$identity_path" 2>/dev/null || true)"
  fi
  WORKFLOW_CHECKPOINT_ACTIVE=true
}

workflow_checkpoint_change() {
  local english_reason="$1"
  local chinese_reason="$2"
  local stage_en="$3"
  local stage_zh="$4"

  if [ "$stage_en" = "finishing the commit" ]; then
    error_message \
      "The local commit was created, but $english_reason changed before its final safety check completed. The new local commit was preserved; no automatic reset or push was performed." \
      "本地提交已经创建，但在完成最终安全核对前，${chinese_reason}发生了变化。新的本地提交已经保留；脚本没有自动重置，也没有继续上传。"
  else
    error_message \
      "Stopped before $stage_en because $english_reason changed after this run selected the repository. No automatic reset, commit, or push was performed." \
      "已在${stage_zh}前停止：本次选定仓库后，${chinese_reason}发生了变化。脚本没有自动重置，也没有继续创建提交或上传。"
  fi
  muted \
    "Review git status and the repository settings, then run ./$SCRIPT_NAME again." \
    "请检查 git status 和当前仓库设置，确认无误后重新运行 ./${SCRIPT_NAME}。"
  return 1
}

verify_workflow_checkpoint() {
  local stage_en="$1"
  local stage_zh="$2"
  local current_root=""
  local current_common=""
  local current_identity=""
  local identity_path=""

  [ "$WORKFLOW_CHECKPOINT_ACTIVE" = true ] || return 1
  current_root="$(git -C "$GIT_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$current_root" ]; then
    workflow_checkpoint_change "the Git repository" "Git 仓库" "$stage_en" "$stage_zh"
    return 1
  fi
  current_root="$({ cd "$current_root" 2>/dev/null && pwd -P; } || true)"
  if [ -z "$current_root" ] || [ ! "$current_root" -ef "$WORKFLOW_EXPECTED_ROOT" ]; then
    workflow_checkpoint_change "the Git repository root" "Git 仓库根目录" "$stage_en" "$stage_zh"
    return 1
  fi
  resolve_workflow_common_directory || {
    workflow_checkpoint_change "the Git control directory" "Git 控制目录" "$stage_en" "$stage_zh"
    return 1
  }
  current_common="$WORKFLOW_COMMON_DIRECTORY"
  if [ ! "$current_common" -ef "$WORKFLOW_EXPECTED_COMMON_DIRECTORY" ]; then
    workflow_checkpoint_change "the Git control directory" "Git 控制目录" "$stage_en" "$stage_zh"
    return 1
  fi
  if [ "$(git -C "$GIT_ROOT" symbolic-ref -q HEAD 2>/dev/null || true)" != "$WORKFLOW_EXPECTED_SYMBOLIC_HEAD" ]; then
    workflow_checkpoint_change "the current branch" "当前分支" "$stage_en" "$stage_zh"
    return 1
  fi
  if [ "$(workflow_head_value)" != "$WORKFLOW_EXPECTED_HEAD" ]; then
    workflow_checkpoint_change "the current commit" "当前提交" "$stage_en" "$stage_zh"
    return 1
  fi
  if [ "$(git -C "$GIT_ROOT" remote get-url --all origin 2>/dev/null || true)" != "$WORKFLOW_EXPECTED_ORIGIN_FETCH" ] ||
     [ "$(git -C "$GIT_ROOT" remote get-url --push --all origin 2>/dev/null || true)" != "$WORKFLOW_EXPECTED_ORIGIN_PUSH" ]; then
    workflow_checkpoint_change "the origin address" "origin 地址" "$stage_en" "$stage_zh"
    return 1
  fi
  if [ "$(git -C "$GIT_ROOT" config --local --get github-auto.username 2>/dev/null || true)" != "$WORKFLOW_EXPECTED_USERNAME" ]; then
    workflow_checkpoint_change "the repository's saved GitHub account" "当前仓库保存的 GitHub 账号" "$stage_en" "$stage_zh"
    return 1
  fi
  if [ "$(git -C "$GIT_ROOT" config --local --get user.name 2>/dev/null || true)" != "$WORKFLOW_EXPECTED_AUTHOR_NAME" ] ||
     [ "$(git -C "$GIT_ROOT" config --local --get user.email 2>/dev/null || true)" != "$WORKFLOW_EXPECTED_EMAIL" ]; then
    workflow_checkpoint_change "the commit author settings" "提交作者设置" "$stage_en" "$stage_zh"
    return 1
  fi
  if [ "$(git -C "$GIT_ROOT" config --local --get github-auto.ssh-alias 2>/dev/null || true)" != "$WORKFLOW_EXPECTED_ALIAS" ]; then
    workflow_checkpoint_change "the repository's SSH Host binding" "当前仓库绑定的 SSH 主机名" "$stage_en" "$stage_zh"
    return 1
  fi
  current_identity="$(git -C "$GIT_ROOT" config --local --get github-auto.identity-file 2>/dev/null || true)"
  if [ "$current_identity" != "$WORKFLOW_EXPECTED_IDENTITY_FILE" ]; then
    workflow_checkpoint_change "the repository's SSH key binding" "当前仓库绑定的 SSH 密钥" "$stage_en" "$stage_zh"
    return 1
  fi
  identity_path="$(expand_home_path "$WORKFLOW_EXPECTED_IDENTITY_FILE")"
  identity_path="${identity_path//%d/${HOME:-}}"
  if [ -n "$identity_path" ] &&
     { [ ! -f "$identity_path" ] ||
       [ "$(git hash-object --no-filters "$identity_path" 2>/dev/null || true)" != "$WORKFLOW_EXPECTED_IDENTITY_HASH" ]; }; then
    workflow_checkpoint_change "the SSH private key file" "SSH 私钥文件" "$stage_en" "$stage_zh"
    return 1
  fi
  return 0
}

accept_created_commit_checkpoint() {
  local stage_en="$1"
  local stage_zh="$2"
  local expected_message="$3"
  local expected_name="$4"
  local expected_email="$5"
  local previous_head="$WORKFLOW_EXPECTED_HEAD"
  local new_head=""
  local commit_line=""
  local commit_parts=()

  if [ "$(git -C "$GIT_ROOT" symbolic-ref -q HEAD 2>/dev/null || true)" != "$WORKFLOW_EXPECTED_SYMBOLIC_HEAD" ]; then
    workflow_checkpoint_change "the current branch" "当前分支" "$stage_en" "$stage_zh"
    return 1
  fi
  new_head="$(git -C "$GIT_ROOT" rev-parse --verify HEAD 2>/dev/null || true)"
  [ -n "$new_head" ] || {
    workflow_checkpoint_change "the commit that Git was creating" "Git 正在创建的提交" "$stage_en" "$stage_zh"
    return 1
  }
  commit_line="$(git -C "$GIT_ROOT" rev-list --parents -n 1 "$new_head" 2>/dev/null || true)"
  read -r -a commit_parts <<< "$commit_line"
  if [ "$previous_head" = "<unborn>" ]; then
    if [ "${#commit_parts[@]}" -ne 1 ]; then
      workflow_checkpoint_change "the first commit's parent history" "首次提交的父提交关系" "$stage_en" "$stage_zh"
      return 1
    fi
  elif [ "${#commit_parts[@]}" -ne 2 ] || [ "${commit_parts[1]}" != "$previous_head" ]; then
    workflow_checkpoint_change "the new commit's parent history" "新提交的父提交关系" "$stage_en" "$stage_zh"
    return 1
  fi
  if [ "$(git -C "$GIT_ROOT" show -s --format='%T' "$new_head" 2>/dev/null || true)" != "$WORKFLOW_EXPECTED_STAGED_TREE" ] ||
     [ "$(git -C "$GIT_ROOT" show -s --format='%B' "$new_head" 2>/dev/null || true)" != "$expected_message" ] ||
     [ "$(git -C "$GIT_ROOT" show -s --format='%an' "$new_head" 2>/dev/null || true)" != "$expected_name" ] ||
     [ "$(git -C "$GIT_ROOT" show -s --format='%ae' "$new_head" 2>/dev/null || true)" != "$expected_email" ] ||
     [ "$(git -C "$GIT_ROOT" show -s --format='%cn' "$new_head" 2>/dev/null || true)" != "$expected_name" ] ||
     [ "$(git -C "$GIT_ROOT" show -s --format='%ce' "$new_head" 2>/dev/null || true)" != "$expected_email" ]; then
    workflow_checkpoint_change \
      "the new commit's confirmed files, message, or identity" \
      "新提交中已经确认的文件、提交说明或账号身份" \
      "$stage_en" "$stage_zh"
    return 1
  fi

  WORKFLOW_EXPECTED_HEAD="$new_head"
  verify_workflow_checkpoint "$stage_en" "$stage_zh"
}

capture_workflow_review_snapshot() {
  [ -z "$WORKFLOW_REVIEW_SNAPSHOT" ] || rm -f "$WORKFLOW_REVIEW_SNAPSHOT"
  WORKFLOW_REVIEW_SNAPSHOT="$(safe_mktemp_file "${TMPDIR:-/tmp}" "github-auto-review")" || return 1
  git -C "$GIT_ROOT" --no-pager status \
    --porcelain=v1 --untracked-files=all > "$WORKFLOW_REVIEW_SNAPSHOT"
}

clear_workflow_review_snapshot() {
  if [ -n "$WORKFLOW_REVIEW_SNAPSHOT" ]; then
    rm -f "$WORKFLOW_REVIEW_SNAPSHOT"
    WORKFLOW_REVIEW_SNAPSHOT=""
  fi
  if [ -n "$WORKFLOW_EXPECTED_INDEX_FILE" ]; then
    rm -f "$WORKFLOW_EXPECTED_INDEX_FILE"
    WORKFLOW_EXPECTED_INDEX_FILE=""
  fi
}

prepare_expected_staged_tree() {
  local real_index=""
  local index_directory=""
  local temporary_index=""
  local has_head=true
  local entry=""

  WORKFLOW_EXPECTED_STAGED_TREE=""
  WORKFLOW_EXPECTED_ORIGINAL_INDEX_TREE=""
  WORKFLOW_EXPECTED_HEAD_TREE=""
  WORKFLOW_SPARSE_CHECKOUT=false
  [ -z "$WORKFLOW_EXPECTED_INDEX_FILE" ] || rm -f "$WORKFLOW_EXPECTED_INDEX_FILE"
  WORKFLOW_EXPECTED_INDEX_FILE=""
  real_index="$(git -C "$GIT_ROOT" rev-parse --git-path index 2>/dev/null)" || return 1
  case "$real_index" in
    /*)
      ;;
    *)
      real_index="$GIT_ROOT/$real_index"
      ;;
  esac
  index_directory="${real_index%/*}"
  temporary_index="$(safe_mktemp_file "$index_directory" "github-auto-index")" || return 1

  WORKFLOW_EXPECTED_ORIGINAL_INDEX_TREE="$(git -C "$GIT_ROOT" write-tree 2>/dev/null)" || true
  if [ -z "$WORKFLOW_EXPECTED_ORIGINAL_INDEX_TREE" ]; then
    rm -f "$temporary_index"
    return 1
  fi

  git -C "$GIT_ROOT" rev-parse --verify HEAD >/dev/null 2>&1 || has_head=false
  rm -f "$temporary_index"
  if [ "$has_head" = true ]; then
    WORKFLOW_EXPECTED_HEAD_TREE="$(
      git -C "$GIT_ROOT" rev-parse 'HEAD^{tree}' 2>/dev/null
    )" || true
  else
    WORKFLOW_EXPECTED_HEAD_TREE="$(
      git -C "$GIT_ROOT" hash-object -t tree --stdin < /dev/null
    )" || true
  fi
  # Reconstruct tracking entries, not HEAD or cached filesystem timestamps.
  # This keeps forced additions, intent-to-add and staged removals exactly as
  # native git add -A sees them, while forcing a fresh scan of visible files.
  if ! GIT_INDEX_FILE="$temporary_index" git -C "$GIT_ROOT" read-tree --empty ||
     ! git -C "$GIT_ROOT" ls-files --stage -z |
       GIT_INDEX_FILE="$temporary_index" git -C "$GIT_ROOT" update-index -z --index-info; then
    rm -f "$temporary_index"
    return 1
  fi
  if [ "$(git -C "$GIT_ROOT" config --bool core.sparseCheckout 2>/dev/null || true)" = true ]; then
    WORKFLOW_SPARSE_CHECKOUT=true
  fi
  if [ "$WORKFLOW_SPARSE_CHECKOUT" = true ]; then
    if ! git -C "$GIT_ROOT" ls-files -v -z |
       { while IFS= read -r -d '' entry; do
           case "$entry" in [Ss]' '*) printf '%s\0' "${entry:2}" ;; esac
         done; } |
       GIT_INDEX_FILE="$temporary_index" git -C "$GIT_ROOT" update-index --skip-worktree -z --stdin; then
      rm -f "$temporary_index"
      return 1
    fi
  fi
  if [ -z "$WORKFLOW_EXPECTED_HEAD_TREE" ] ||
     ! GIT_INDEX_FILE="$temporary_index" git -C "$GIT_ROOT" -c core.fsmonitor=false add -A ||
     ! WORKFLOW_EXPECTED_STAGED_TREE="$(
       GIT_INDEX_FILE="$temporary_index" git -C "$GIT_ROOT" write-tree 2>/dev/null
     )" ||
     [ -z "$WORKFLOW_EXPECTED_STAGED_TREE" ]; then
    rm -f "$temporary_index"
    WORKFLOW_EXPECTED_STAGED_TREE=""
    WORKFLOW_EXPECTED_ORIGINAL_INDEX_TREE=""
    WORKFLOW_EXPECTED_HEAD_TREE=""
    return 1
  fi
  WORKFLOW_EXPECTED_INDEX_FILE="$temporary_index"
  return 0
}

expected_staged_tree_has_changes() {
  [ -n "$WORKFLOW_EXPECTED_STAGED_TREE" ] &&
    [ -n "$WORKFLOW_EXPECTED_HEAD_TREE" ] &&
    [ "$WORKFLOW_EXPECTED_STAGED_TREE" != "$WORKFLOW_EXPECTED_HEAD_TREE" ]
}

write_exact_workflow_review_snapshot() {
  [ -f "$WORKFLOW_EXPECTED_INDEX_FILE" ] || return 1
  if ! GIT_INDEX_FILE="$WORKFLOW_EXPECTED_INDEX_FILE" \
    git -C "$GIT_ROOT" -c core.fsmonitor=false --no-pager status \
      --porcelain=v1 --untracked-files=all > "$WORKFLOW_REVIEW_SNAPSHOT"; then
    return 1
  fi
  [ -s "$WORKFLOW_REVIEW_SNAPSHOT" ] || return 1
}

prepare_real_index_for_exact_staging() {
  local changed_paths=""
  local path=""
  local entry=""
  local result=0

  changed_paths="$(safe_mktemp_file "${TMPDIR:-/tmp}" "github-auto-paths")" || return 1
  # Ordinary changed files need no index-hint work. Inspect only hidden entries
  # and clear the affected ones in a single batch, not several Git calls/file.
  while IFS= read -r -d '' entry; do
    case "$entry" in [a-zS]' '*) ;; *) continue ;; esac
    path="${entry:2}"
    result=0
    git --literal-pathspecs -C "$GIT_ROOT" diff-tree --quiet \
      "$WORKFLOW_EXPECTED_HEAD_TREE" "$WORKFLOW_EXPECTED_STAGED_TREE" -- "$path" || result=$?
    if [ "$result" -eq 1 ]; then
      printf '%s\0' "$path" >> "$changed_paths"
    elif [ "$result" -ne 0 ]; then
      rm -f "$changed_paths"
      return 1
    fi
  done < <(git -C "$GIT_ROOT" ls-files -v -z)
  result=0
  if [ -s "$changed_paths" ]; then
    git -C "$GIT_ROOT" update-index --no-assume-unchanged -z --stdin < "$changed_paths" || result=$?
    if [ "$result" -eq 0 ] && [ "$WORKFLOW_SPARSE_CHECKOUT" != true ]; then
      git -C "$GIT_ROOT" update-index --no-skip-worktree -z --stdin < "$changed_paths" || result=$?
    fi
  fi
  rm -f "$changed_paths"
  return "$result"
}

verify_reviewed_file_tree() {
  local current_index_tree=""

  [ -f "$WORKFLOW_EXPECTED_INDEX_FILE" ] || return 1
  current_index_tree="$(git -C "$GIT_ROOT" write-tree 2>/dev/null || true)"
  if [ "$current_index_tree" = "$WORKFLOW_EXPECTED_ORIGINAL_INDEX_TREE" ] &&
     GIT_INDEX_FILE="$WORKFLOW_EXPECTED_INDEX_FILE" git -C "$GIT_ROOT" -c core.fsmonitor=false diff --quiet -- &&
     [ -z "$(
       GIT_INDEX_FILE="$WORKFLOW_EXPECTED_INDEX_FILE" \
         git -C "$GIT_ROOT" ls-files --others --exclude-standard 2>/dev/null
     )" ]; then
    return 0
  fi

  error_message \
    "File contents or the staging area changed after the review. Stopped before changing the real Git staging area; no commit or push was performed." \
    "检查清单显示后，文件内容或暂存区又发生了变化。脚本已在改动真实 Git 暂存区前停止，也没有继续创建提交或上传。"
  muted \
    "The current git status is shown below. Review the latest files, then run ./$SCRIPT_NAME again." \
    "下面显示的是当前最新 git status。请重新核对文件后，再运行 ./${SCRIPT_NAME}。"
  git -C "$GIT_ROOT" --no-pager status --short --untracked-files=all
  return 1
}

remember_approved_project_directories() {
  local index=0

  WORKFLOW_APPROVED_PROJECT_DIRECTORIES=()
  WORKFLOW_APPROVED_PROJECT_MARKERS=()
  WORKFLOW_APPROVED_PROJECT_COUNT="$POSSIBLE_EMBEDDED_PROJECT_COUNT"
  while [ "$index" -lt "$POSSIBLE_EMBEDDED_PROJECT_COUNT" ]; do
    WORKFLOW_APPROVED_PROJECT_DIRECTORIES[$index]="${POSSIBLE_EMBEDDED_PROJECT_DIRECTORIES[$index]}"
    WORKFLOW_APPROVED_PROJECT_MARKERS[$index]="${POSSIBLE_EMBEDDED_PROJECT_MARKERS[$index]}"
    index=$((index + 1))
  done
}

approved_project_directory_index() {
  local directory="$1"
  local marker="$2"
  local index=0

  while [ "$index" -lt "$WORKFLOW_APPROVED_PROJECT_COUNT" ]; do
    if [ "${WORKFLOW_APPROVED_PROJECT_DIRECTORIES[$index]}" = "$directory" ] &&
       [ "${WORKFLOW_APPROVED_PROJECT_MARKERS[$index]}" = "$marker" ]; then
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

verify_staged_project_directories() {
  local index=0

  scan_possible_embedded_projects || return 1
  if [ "$POSSIBLE_EMBEDDED_PROJECT_COUNT" -ne "$WORKFLOW_APPROVED_PROJECT_COUNT" ]; then
    return 1
  fi
  while [ "$index" -lt "$POSSIBLE_EMBEDDED_PROJECT_COUNT" ]; do
    approved_project_directory_index \
      "${POSSIBLE_EMBEDDED_PROJECT_DIRECTORIES[$index]}" \
      "${POSSIBLE_EMBEDDED_PROJECT_MARKERS[$index]}" || return 1
    index=$((index + 1))
  done
  return 0
}

verify_staging_finished_cleanly() {
  local staged_tree=""

  staged_tree="$(git -C "$GIT_ROOT" write-tree 2>/dev/null || true)"
  if [ -z "$WORKFLOW_EXPECTED_STAGED_TREE" ] ||
     [ "$staged_tree" != "$WORKFLOW_EXPECTED_STAGED_TREE" ] ||
     ! git -C "$GIT_ROOT" -c core.fsmonitor=false diff --quiet -- ||
     [ -n "$(git -C "$GIT_ROOT" ls-files --others --exclude-standard 2>/dev/null)" ] ||
     ! verify_staged_project_directories; then
    error_message \
      "The staged snapshot does not exactly match the files prepared from the confirmed review, files changed while git add -A was running, or a new unapproved project-like folder appeared. Stopped before commit; the current staging area was preserved for inspection." \
      "暂存快照与根据确认清单预先生成的文件快照并不完全一致，或者执行 git add -A 期间又有文件发生变化，或者出现了尚未确认的疑似独立项目目录。脚本已在创建提交前停止，并保留当前暂存状态供你检查。"
    git -C "$GIT_ROOT" --no-pager status --short --untracked-files=all
    return 1
  fi
  return 0
}
