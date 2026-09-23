# -----------------------------------------------------------------------------
# Git repository binding and strict push identity
# -----------------------------------------------------------------------------

GIT_ROOT=""
PROJECT_GIT_STATE=""
CURRENT_BRANCH=""
CURRENT_ORIGIN_URL=""
CURRENT_ORIGIN_HOST=""
ORIGIN_VERIFIED_USERNAME=""
ORIGIN_VERIFIED_ALIAS=""
ORIGIN_VERIFIED_IDENTITY_FILE=""
CURRENT_REPOSITORY_OWNER=""
CURRENT_REPOSITORY_NAME=""
BOUND_USERNAME=""
BOUND_EMAIL=""
BOUND_SSH_ALIAS=""
BOUND_IDENTITY_FILE=""
PROJECT_BINDING_REUSED=false
PROJECT_BINDING_ENGINE_STALE=false
WORKFLOW_COMMIT_CREATED_THIS_RUN=false

require_core_commands() {
  local missing=""
  local command_name=""

  for command_name in git ssh awk sed find tee cmp cp; do
    if ! command_exists "$command_name"; then
      missing="$missing $command_name"
    fi
  done

  if [ -n "$missing" ]; then
    fail \
      "Required tools are missing: $(trim "$missing")" \
      "缺少必要工具：$(trim "$missing")"
  fi
}

check_before_git_init() {
  local directory="$1"

  if [ -e "$directory/.git" ] || [ -L "$directory/.git" ] ||
     [ "$(git -C "$directory" rev-parse --is-bare-repository 2>/dev/null || true)" = true ]; then
    error_message \
      "This folder already contains Git metadata, but Git could not open it as a working repository: $(human_path "$directory")" \
      "这个文件夹已有 Git 记录，但 Git 无法把它作为工作仓库打开：$(human_path "$directory")"
    muted \
      "No git init was run. Repair the existing repository first, or select its working directory if this is a bare repository." \
      "脚本没有执行 git init。请先修复现有仓库；如果这是不含工作文件的裸仓库，请改为选择实际的工作目录。"
    return 1
  fi
  return 0
}

locate_project() {
  local initialize="${1:-yes}"
  local existing_root=""

  if existing_root="$(git -C "$SCRIPT_DIRECTORY" rev-parse --show-toplevel 2>/dev/null)"; then
    existing_root="$({ cd "$existing_root" 2>/dev/null && pwd -P; } || return 1)"
    # macOS can spell the same directory with different case or an equivalent
    # physical prefix (for example /var and /private/var). Compare the actual
    # directory objects instead of their displayed path strings.
    if [ ! "$existing_root" -ef "$SCRIPT_DIRECTORY" ]; then
      fail \
        "$SCRIPT_NAME is in $(human_path "$SCRIPT_DIRECTORY"), but the Git repository root is $(human_path "$existing_root"). Place $SCRIPT_NAME in that repository root before running it." \
        "$SCRIPT_NAME 位于 $(human_path "$SCRIPT_DIRECTORY")，但这个 Git 仓库的根目录是 $(human_path "$existing_root")。请把 $SCRIPT_NAME 放到该仓库根目录后再运行。"
    fi
    GIT_ROOT="$existing_root"
    PROJECT_GIT_STATE="existing"
    return 0
  fi

  if [ "$initialize" != "yes" ]; then
    return 1
  fi
  check_before_git_init "$SCRIPT_DIRECTORY" || return 1

  heading "Prepare the local Git repository" "准备本地 Git 仓库"
  warn \
    "No Git repository exists at $(human_path "$SCRIPT_DIRECTORY")." \
    "$(human_path "$SCRIPT_DIRECTORY") 还不是 Git 仓库。"
  muted \
    "The script will run git init in this folder. This creates local .git metadata only; it does not create a GitHub repository or upload files." \
    "接下来只会在这个文件夹中执行 git init，创建本地 .git 记录；此时不会创建 GitHub 仓库，也不会上传文件。"
  if ! git -C "$SCRIPT_DIRECTORY" init >/dev/null; then
    fail "The Git project could not be initialized." "Git 项目初始化失败。"
  fi
  GIT_ROOT="$SCRIPT_DIRECTORY"
  PROJECT_GIT_STATE="initialized"
  success \
    "Created the local Git repository: $(human_path "$GIT_ROOT")" \
    "已创建本地 Git 仓库：$(human_path "$GIT_ROOT")"
}

git_operation_in_progress() {
  local git_directory=""
  local state_name=""

  git_directory="$(git -C "$GIT_ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)"
  [ -n "$git_directory" ] || return 1
  for state_name in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    [ -e "$git_directory/$state_name" ] && return 0
  done
  for state_name in rebase-merge rebase-apply sequencer; do
    [ -d "$git_directory/$state_name" ] && return 0
  done
  return 1
}

describe_and_validate_project_state() {
  local unmerged=""

  CURRENT_BRANCH="$(git -C "$GIT_ROOT" branch --show-current 2>/dev/null || true)"
  heading "Current local project" "当前本地项目"

  if [ "$PROJECT_GIT_STATE" = "existing" ]; then
    success \
      "Existing Git repository detected: $(human_path "$GIT_ROOT")" \
      "已识别现有 Git 仓库：$(human_path "$GIT_ROOT")"
    muted \
      "git init will not run again. Existing commits, branches, staged changes, and remotes will be preserved." \
      "不会再次执行 git init；现有提交记录、分支、暂存内容和远端设置都会保留。"
  else
    success \
      "Using the Git repository just created in $(human_path "$GIT_ROOT")." \
      "将使用刚刚在 $(human_path "$GIT_ROOT") 创建的 Git 仓库。"
  fi

  if [ -n "$CURRENT_BRANCH" ]; then
    muted "Current branch: $CURRENT_BRANCH" "当前分支：$CURRENT_BRANCH"
  elif git -C "$GIT_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    error_message \
      "HEAD is detached, so there is no current branch to push. Check out the intended branch and run ./$SCRIPT_NAME again." \
      "当前处于 detached HEAD 状态，没有可直接上传的当前分支。请先切换到目标分支，再重新运行 ./${SCRIPT_NAME}。"
    return 1
  else
    muted \
      "This repository has no commits yet; the first branch will be named main." \
      "这个仓库还没有提交记录；首次提交后分支名将统一为 main。"
  fi

  unmerged="$(git -C "$GIT_ROOT" diff --name-only --diff-filter=U 2>/dev/null || true)"
  if [ -n "$unmerged" ]; then
    error_message \
      "Unresolved merge conflicts were found. Resolve the files listed by git status before running this script." \
      "检测到尚未解决的合并冲突。请先按照 git status 列出的文件完成处理，再运行本脚本。"
    git -C "$GIT_ROOT" --no-pager status --short
    return 1
  fi
  if git_operation_in_progress; then
    error_message \
      "A merge, rebase, cherry-pick, or revert is still in progress. Finish or cancel that Git operation before running this script." \
      "当前还有尚未完成的 merge、rebase、cherry-pick 或 revert。请先完成或取消该 Git 操作，再运行本脚本。"
    return 1
  fi
}

ensure_script_excluded() {
  local exclude_file=""
  local temporary_file=""
  local line=""
  local skipping=false
  local marker_start="# >>> github-auto script >>>"
  local marker_end="# <<< github-auto script <<<"

  # The public launcher in the central repository is intentionally tracked.
  # Only standalone project copies belong in the repository-local exclude file.
  if git -C "$GIT_ROOT" ls-files --error-unmatch -- "$SCRIPT_NAME" >/dev/null 2>&1; then
    return 0
  fi

  exclude_file="$(git -C "$GIT_ROOT" rev-parse --git-path info/exclude)"
  case "$exclude_file" in
    /*)
      ;;
    *)
      exclude_file="$GIT_ROOT/$exclude_file"
      ;;
  esac

  mkdir -p "$(dirname "$exclude_file")" || fail \
    "The local Git exclusion settings could not be prepared." \
    "无法准备 Git 本地排除设置。"
  [ -f "$exclude_file" ] || : > "$exclude_file"
  if grep -Fqx "$marker_start" "$exclude_file" 2>/dev/null &&
     grep -Fqx "/$SCRIPT_NAME" "$exclude_file" 2>/dev/null &&
     grep -Fqx "$marker_end" "$exclude_file" 2>/dev/null; then
    return 0
  fi
  temporary_file="$(safe_mktemp_file "$(dirname "$exclude_file")" "exclude")" ||
    fail \
      "The local Git exclusion settings could not be updated." \
      "无法更新 Git 本地排除设置。"

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$marker_start" ]; then
      skipping=true
      continue
    fi
    if [ "$skipping" = true ]; then
      if [ "$line" = "$marker_end" ]; then
        skipping=false
      fi
      continue
    fi
    printf '%s\n' "$line" >> "$temporary_file"
  done < "$exclude_file"

  if [ -s "$temporary_file" ]; then
    printf '\n' >> "$temporary_file"
  fi
  printf '%s\n/%s\n%s\n' "$marker_start" "$SCRIPT_NAME" "$marker_end" >> "$temporary_file"
  mv "$temporary_file" "$exclude_file" || fail \
    "The local Git exclusion settings could not be saved." \
    "无法保存 Git 本地排除设置。"
}

read_origin_repository() {
  local url=""

  ORIGIN_VERIFIED_USERNAME=""
  ORIGIN_VERIFIED_ALIAS=""
  ORIGIN_VERIFIED_IDENTITY_FILE=""
  if ! url="$(git -C "$GIT_ROOT" remote get-url origin 2>/dev/null)"; then
    return 1
  fi
  if ! parse_repository_input "$url"; then
    return 1
  fi

  CURRENT_ORIGIN_URL="$url"
  CURRENT_ORIGIN_HOST="$REPOSITORY_INPUT_HOST"
  CURRENT_REPOSITORY_OWNER="$REPOSITORY_OWNER"
  CURRENT_REPOSITORY_NAME="$REPOSITORY_NAME"
  return 0
}

identify_origin_ssh_account() {
  local key=""

  [ -n "$CURRENT_ORIGIN_HOST" ] || return 1
  ssh_alias_is_github "$CURRENT_ORIGIN_HOST" || return 1
  key="$(resolve_alias_identity_file "$CURRENT_ORIGIN_HOST" || true)"
  [ -f "$key" ] || return 1

  info \
    "The existing origin uses SSH Host $CURRENT_ORIGIN_HOST. Asking GitHub which account accepts its key; saved account and repository settings will not be changed." \
    "现有 origin 使用 SSH 主机名 ${CURRENT_ORIGIN_HOST}。正在向 GitHub 核对该主机名所用密钥对应的账号；这一步不会修改已保存账号或仓库设置。"
  if ! identify_key_username "$key"; then
    warn \
      "GitHub did not confirm the key currently referenced by origin SSH Host $CURRENT_ORIGIN_HOST." \
      "GitHub 暂时没有确认 origin 的 SSH 主机名 ${CURRENT_ORIGIN_HOST} 所引用的密钥。"
    if [ -n "${SSH_VERIFICATION_OUTPUT:-}" ]; then
      muted \
        "SSH result: ${SSH_VERIFICATION_OUTPUT##*$'\n'}" \
        "SSH 返回信息：${SSH_VERIFICATION_OUTPUT##*$'\n'}"
    fi
    return 1
  fi

  ORIGIN_VERIFIED_USERNAME="$VERIFIED_GITHUB_USERNAME"
  ORIGIN_VERIFIED_ALIAS="$CURRENT_ORIGIN_HOST"
  ORIGIN_VERIFIED_IDENTITY_FILE="$key"
  return 0
}

select_verified_origin_account() {
  local allow_registration="${1:-yes}"
  local index=""
  local email=""

  if [ -z "$ORIGIN_VERIFIED_USERNAME" ]; then
    identify_origin_ssh_account || return 1
  fi

  if [ -n "${CURRENT_REPOSITORY_OWNER:-}" ] &&
     [ "$(lowercase "$ORIGIN_VERIFIED_USERNAME")" != "$(lowercase "$CURRENT_REPOSITORY_OWNER")" ]; then
    warn \
      "The origin key authenticates as $ORIGIN_VERIFIED_USERNAME, but this repository belongs to $CURRENT_REPOSITORY_OWNER. The origin account will not be selected." \
      "origin 使用的密钥登录账号是 ${ORIGIN_VERIFIED_USERNAME}，但当前仓库属于 ${CURRENT_REPOSITORY_OWNER}。脚本不会选择这个 origin 账号。"
    return 1
  fi

  if index="$(account_index "$ORIGIN_VERIFIED_USERNAME")"; then
    BOUND_USERNAME="${ACCOUNT_USERNAMES[$index]}"
    BOUND_EMAIL="${ACCOUNT_EMAILS[$index]}"
    info \
      "The existing origin authenticates as saved account $BOUND_USERNAME, so that account was selected." \
      "现有 origin 使用的密钥已验证为已保存账号 ${BOUND_USERNAME}，因此本次直接使用该账号。"
    return 0
  fi

  [ "$allow_registration" = "yes" ] || return 1
  heading "Use the account already connected to this repository" "使用当前仓库已经连接的账号"
  success \
    "GitHub confirmed that origin SSH Host $ORIGIN_VERIFIED_ALIAS authenticates as $ORIGIN_VERIFIED_USERNAME." \
    "GitHub 已确认 origin 的 SSH 主机名 ${ORIGIN_VERIFIED_ALIAS} 使用账号 ${ORIGIN_VERIFIED_USERNAME}。"
  muted \
    "Only the commit email is still needed. The existing SSH key will be reused, and Git will not be initialized again." \
    "现在只需确认提交邮箱。脚本会继续使用现有 SSH 密钥，也不会重新初始化 Git 仓库。"
  email="$(prompt_account_email "$ORIGIN_VERIFIED_USERNAME")" || return 1
  register_account_and_identity \
    "$ORIGIN_VERIFIED_USERNAME" \
    "$email" \
    "$ORIGIN_VERIFIED_ALIAS" \
    "$ORIGIN_VERIFIED_IDENTITY_FILE"
  BOUND_USERNAME="$SELECTED_USERNAME"
  BOUND_EMAIL="$SELECTED_EMAIL"
  return 0
}

select_account_for_repository() {
  local owner="$1"
  local preferred_username="${2:-}"
  local saved_username=""
  local index=""
  local email=""

  saved_username="$(git -C "$GIT_ROOT" config --local --get github-auto.username 2>/dev/null || true)"
  if [ -n "$saved_username" ] &&
     [ "$(lowercase "$saved_username")" != "$(lowercase "$owner")" ]; then
    warn \
      "This repository was previously saved with account $saved_username, but its GitHub owner is $owner. The mismatched binding will not be used." \
      "当前仓库以前保存的账号是 ${saved_username}，但 GitHub 仓库属于 ${owner}。脚本不会继续使用这个不匹配的账号。"
  fi

  if [ -n "$preferred_username" ] &&
     [ "$(lowercase "$preferred_username")" != "$(lowercase "$owner")" ]; then
    warn \
      "Account $preferred_username was supplied by an earlier setup step, but this repository belongs to $owner. Only account $owner can be used for this repository." \
      "前面的设置步骤提供了账号 ${preferred_username}，但当前仓库属于 ${owner}。这个仓库只能使用账号 ${owner}。"
  fi

  if index="$(account_index "$owner")"; then
    BOUND_USERNAME="${ACCOUNT_USERNAMES[$index]}"
    BOUND_EMAIL="${ACCOUNT_EMAILS[$index]}"
    info \
      "The repository owner matches saved account $BOUND_USERNAME, so that account was selected." \
      "仓库所属用户名与已保存账号 $BOUND_USERNAME 一致，因此本次使用该账号。"
    return 0
  fi

  heading \
    "Set up the account that owns this repository" \
    "配置当前仓库所属的 GitHub 账号"
  muted \
    "The destination is $owner/${CURRENT_REPOSITORY_NAME}. To prevent accounts from being mixed, this repository must use GitHub account $owner." \
    "目标仓库是 ${owner}/${CURRENT_REPOSITORY_NAME}。为避免多个账号相互串用，当前仓库必须使用 GitHub 账号 ${owner}。"
  muted \
    "Only the commit email is needed. The script uses a local SSH Host named for $owner, or creates a separate one when none exists." \
    "现在只需确认提交邮箱。脚本会使用按账号 ${owner} 命名的本机 SSH 主机；没有对应配置时，再为该账号创建独立密钥。"
  email="$(prompt_account_email "$owner")" || return 1
  setup_or_reuse_account "$owner" "$email" || return 1
  BOUND_USERNAME="$SELECTED_USERNAME"
  BOUND_EMAIL="$SELECTED_EMAIL"
}

repository_account_matches_owner() {
  [ -n "${BOUND_USERNAME:-}" ] &&
    [ -n "${CURRENT_REPOSITORY_OWNER:-}" ] &&
    [ "$(lowercase "$BOUND_USERNAME")" = "$(lowercase "$CURRENT_REPOSITORY_OWNER")" ]
}

require_repository_account_match() {
  if repository_account_matches_owner; then
    return 0
  fi
  error_message \
    "Stopped because account ${BOUND_USERNAME:-<none>} does not match repository owner ${CURRENT_REPOSITORY_OWNER:-<unknown>}. No remote operation was attempted." \
    "操作已停止：当前账号 ${BOUND_USERNAME:-<未选择>} 与仓库所属账号 ${CURRENT_REPOSITORY_OWNER:-<无法识别>} 不一致。脚本没有执行任何远端操作。"
  return 1
}

load_established_project_binding() {
  local saved_username=""
  local saved_alias=""
  local saved_key=""
  local alias_key=""
  local fetch_url=""
  local push_url=""
  local expected_url=""
  local saved_name=""
  local saved_email=""
  local saved_engine=""
  local index=""

  PROJECT_BINDING_REUSED=false
  PROJECT_BINDING_ENGINE_STALE=false
  saved_username="$(git -C "$GIT_ROOT" config --local --get github-auto.username 2>/dev/null || true)"
  [ -n "$saved_username" ] || return 1
  [ "$(lowercase "$saved_username")" = "$(lowercase "$CURRENT_REPOSITORY_OWNER")" ] || return 1
  index="$(account_index "$CURRENT_REPOSITORY_OWNER" 2>/dev/null)" || return 1

  saved_alias="$(git -C "$GIT_ROOT" config --local --get github-auto.ssh-alias 2>/dev/null || true)"
  saved_key="$(git -C "$GIT_ROOT" config --local --get github-auto.identity-file 2>/dev/null || true)"
  saved_key="$(expand_home_path "$saved_key")"
  saved_key="${saved_key//%d/${HOME:-}}"
  [ -n "$saved_alias" ] && [ -f "$saved_key" ] || return 1
  ssh_alias_is_github "$saved_alias" || return 1
  alias_key="$(resolve_alias_identity_file "$saved_alias" || true)"
  same_existing_file "$saved_key" "$alias_key" || return 1

  expected_url="git@${saved_alias}:${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}.git"
  fetch_url="$(git -C "$GIT_ROOT" remote get-url --all origin 2>/dev/null || true)"
  push_url="$(git -C "$GIT_ROOT" remote get-url --push --all origin 2>/dev/null || true)"
  [ "$fetch_url" = "$expected_url" ] || return 1
  [ "$push_url" = "$expected_url" ] || return 1

  saved_name="$(git -C "$GIT_ROOT" config --local --get user.name 2>/dev/null || true)"
  saved_email="$(git -C "$GIT_ROOT" config --local --get user.email 2>/dev/null || true)"
  [ "$saved_name" = "${ACCOUNT_USERNAMES[$index]}" ] || return 1
  [ "$saved_email" = "${ACCOUNT_EMAILS[$index]}" ] || return 1

  BOUND_USERNAME="${ACCOUNT_USERNAMES[$index]}"
  BOUND_EMAIL="${ACCOUNT_EMAILS[$index]}"
  BOUND_SSH_ALIAS="$saved_alias"
  BOUND_IDENTITY_FILE="$saved_key"
  PROJECT_BINDING_REUSED=true

  saved_engine="$(git -C "$GIT_ROOT" config --local --get github-auto.engine 2>/dev/null || true)"
  if [ "$saved_engine" != "$ENGINE_PATH" ]; then
    PROJECT_BINDING_ENGINE_STALE=true
  fi
  return 0
}

ensure_bound_identity_with_github_verification() {
  local preferred_alias=""
  local saved_key=""
  local verification_detail=""

  preferred_alias="$(git -C "$GIT_ROOT" config --local --get github-auto.ssh-alias 2>/dev/null || true)"
  saved_key="$(git -C "$GIT_ROOT" config --local --get github-auto.identity-file 2>/dev/null || true)"
  saved_key="$(expand_home_path "$saved_key")"
  saved_key="${saved_key//%d/${HOME:-}}"

  if [ -n "$ORIGIN_VERIFIED_USERNAME" ] &&
     [ "$(lowercase "$ORIGIN_VERIFIED_USERNAME")" = "$(lowercase "$BOUND_USERNAME")" ] &&
     [ -f "$ORIGIN_VERIFIED_IDENTITY_FILE" ]; then
    BOUND_SSH_ALIAS="$ORIGIN_VERIFIED_ALIAS"
    BOUND_IDENTITY_FILE="$ORIGIN_VERIFIED_IDENTITY_FILE"
    success \
      "GitHub account confirmed: $BOUND_USERNAME." \
      "已确认本次使用 GitHub 账号：${BOUND_USERNAME}。"
    return 0
  fi

  if [ -z "$preferred_alias" ] && [ -n "$CURRENT_ORIGIN_HOST" ]; then
    case "$(lowercase "$CURRENT_ORIGIN_HOST")" in
      github.com|www.github.com|ssh.github.com)
        ;;
      *)
        if ssh_alias_is_github "$CURRENT_ORIGIN_HOST"; then
          preferred_alias="$CURRENT_ORIGIN_HOST"
        fi
        ;;
    esac
  fi

  if [ -n "$saved_key" ] && [ -f "$saved_key" ]; then
    if identify_key_username "$saved_key" &&
       [ "$(lowercase "$VERIFIED_GITHUB_USERNAME")" = "$(lowercase "$BOUND_USERNAME")" ]; then
      BOUND_IDENTITY_FILE="$saved_key"
      if find_github_alias_for_identity_file "$saved_key" "$preferred_alias"; then
        BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
      else
        next_available_alias "$BOUND_USERNAME" || fail \
          "An unused SSH Host name could not be selected for this repository's existing key." \
          "无法为当前仓库已有的密钥找到不冲突的 SSH 主机名。"
        BOUND_SSH_ALIAS="$NEW_SSH_ALIAS"
        info \
          "The saved key has no usable GitHub SSH Host entry. Adding $BOUND_SSH_ALIAS to ~/.ssh/config for this existing key." \
          "当前仓库保存的密钥还没有可用的 GitHub SSH 主机配置。将把 ${BOUND_SSH_ALIAS} 添加到 ~/.ssh/config，并继续使用这把现有密钥。"
        install_ssh_alias_block "$BOUND_USERNAME" "$BOUND_SSH_ALIAS" "$BOUND_IDENTITY_FILE"
      fi
      success \
        "GitHub account confirmed: $BOUND_USERNAME." \
        "已确认本次使用 GitHub 账号：${BOUND_USERNAME}。"
      return 0
    fi
  fi

  if find_verified_identity_for_username "$BOUND_USERNAME" "$preferred_alias"; then
    BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
    BOUND_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
    success \
      "GitHub account confirmed: $BOUND_USERNAME." \
      "已确认本次使用 GitHub 账号：${BOUND_USERNAME}。"
    return 0
  fi

  heading "GitHub SSH identity" "核对 GitHub SSH 身份"
  if [ -n "$FOUND_UNVERIFIED_IDENTITY_FILE" ]; then
    warn \
      "An existing key was found at $(human_path "$FOUND_UNVERIFIED_IDENTITY_FILE"), but GitHub did not confirm it for account $BOUND_USERNAME." \
      "找到了现有密钥 $(human_path "$FOUND_UNVERIFIED_IDENTITY_FILE")，但暂时无法确认它属于 GitHub 账号 ${BOUND_USERNAME}。"
    verification_detail="${SSH_VERIFICATION_OUTPUT##*$'\n'}"
    if [ -n "$verification_detail" ]; then
      muted "SSH result: $verification_detail" "SSH 返回信息：$verification_detail"
    fi
    muted \
      "This can mean the network cannot reach GitHub, or that this public key is not registered with the account." \
      "这通常表示当前网络无法连接 GitHub，或这把密钥的公钥尚未添加到该账号。"
    if ui_prompt_yes_no \
      "Verify this existing key with GitHub again before creating anything?" \
      "要先重新验证这把现有密钥，再决定是否创建新密钥吗？" \
      "yes"; then
      if identify_key_username "$FOUND_UNVERIFIED_IDENTITY_FILE" &&
         [ "$(lowercase "$VERIFIED_GITHUB_USERNAME")" = "$(lowercase "$BOUND_USERNAME")" ]; then
        BOUND_SSH_ALIAS="$FOUND_UNVERIFIED_SSH_ALIAS"
        BOUND_IDENTITY_FILE="$FOUND_UNVERIFIED_IDENTITY_FILE"
        ensure_username_alias_for_identity \
          "$BOUND_USERNAME" "$BOUND_SSH_ALIAS" "$BOUND_IDENTITY_FILE" || return 1
        BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
        BOUND_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
        success \
          "GitHub confirmed that the existing key belongs to account $BOUND_USERNAME." \
          "GitHub 已确认这把现有密钥属于账号 ${BOUND_USERNAME}。"
        return 0
      fi
      warn \
        "GitHub still did not confirm this key for account $BOUND_USERNAME." \
        "GitHub 仍未确认这把密钥属于账号 ${BOUND_USERNAME}。"
    fi
  else
    warn \
      "No local SSH private key inspected by this Advanced check was accepted by GitHub for account $BOUND_USERNAME." \
      "高级核对已经检查本机可识别的 SSH 私钥，但 GitHub 没有确认其中任何一把属于账号 $BOUND_USERNAME。"
  fi

  next_available_alias "$BOUND_USERNAME" || fail \
    "An unused SSH Host name and key filename could not be selected." \
    "无法为新密钥找到不冲突的 SSH 主机名和文件名。"
  muted \
    "Continuing will create $(human_path "$NEW_IDENTITY_FILE") and add SSH Host $NEW_SSH_ALIAS to ~/.ssh/config." \
    "如果继续，脚本将创建 $(human_path "$NEW_IDENTITY_FILE")，并在 ~/.ssh/config 中加入 SSH 主机名 ${NEW_SSH_ALIAS}。"
  muted \
    "The public key will be shown for you to add to GitHub. This advanced path verifies the new key before it returns." \
    "随后会显示公钥，供你添加到 GitHub。这条高级流程会在返回前联网核对新密钥。"
  if ! ui_prompt_yes_no \
    "Create and configure this separate SSH key now?" \
    "现在创建并配置这把独立的 SSH 密钥吗？" \
    "no"; then
    warn \
      "Stopped before creating a key, changing the repository's account settings, committing, or pushing." \
      "操作已停止；没有创建新密钥，也没有修改当前仓库的账号设置、提交或上传。"
    return 1
  fi

  if create_new_identity "$BOUND_USERNAME" "$BOUND_EMAIL" &&
     verify_key_matches_username "$FOUND_IDENTITY_FILE" "$BOUND_USERNAME"; then
    BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
    BOUND_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
    return 0
  fi
  return 1
}

ensure_bound_identity() {
  local saved_username=""
  local preferred_alias=""
  local saved_key=""
  local alias_key=""

  saved_username="$(git -C "$GIT_ROOT" config --local --get github-auto.username 2>/dev/null || true)"
  if [ "$(lowercase "$saved_username")" = "$(lowercase "$BOUND_USERNAME")" ]; then
    preferred_alias="$(git -C "$GIT_ROOT" config --local --get github-auto.ssh-alias 2>/dev/null || true)"
    saved_key="$(git -C "$GIT_ROOT" config --local --get github-auto.identity-file 2>/dev/null || true)"
    saved_key="$(expand_home_path "$saved_key")"
    saved_key="${saved_key//%d/${HOME:-}}"
    if [ -n "$preferred_alias" ] && [ -f "$saved_key" ]; then
      alias_key="$(resolve_alias_identity_file "$preferred_alias" || true)"
    fi
    if same_existing_file "$saved_key" "$alias_key"; then
      BOUND_SSH_ALIAS="$preferred_alias"
      BOUND_IDENTITY_FILE="$saved_key"
      info \
        "Using the local SSH key assigned to account $BOUND_USERNAME. No online identity precheck is run; git push will return GitHub's actual result." \
        "正在使用本机为账号 ${BOUND_USERNAME} 指定的 SSH 密钥。这里不会提前联网核对；执行 git push 时，再以 GitHub 的实际返回结果为准。"
      return 0
    fi

    if find_engine_identity_for_username "$BOUND_USERNAME"; then
      BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
      BOUND_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
      info \
        "Using the local SSH key assigned to account $BOUND_USERNAME. No online identity precheck is run; git push will return GitHub's actual result." \
        "正在使用本机为账号 ${BOUND_USERNAME} 指定的 SSH 密钥。这里不会提前联网核对；执行 git push 时，再以 GitHub 的实际返回结果为准。"
      return 0
    fi

    if [ -f "$saved_key" ] &&
       ensure_username_alias_for_identity \
         "$BOUND_USERNAME" "$preferred_alias" "$saved_key"; then
      BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
      BOUND_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
      info \
        "Repaired the local SSH Host for account $BOUND_USERNAME and kept using this project's saved key. No new key or online identity precheck was needed." \
        "已修复账号 ${BOUND_USERNAME} 的本机 SSH 主机配置，并继续使用当前项目保存的原密钥；没有创建新密钥，也没有提前联网核对。"
      return 0
    fi
  fi

  if find_local_identity_for_username "$BOUND_USERNAME"; then
    BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
    BOUND_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
    info \
      "Using the local SSH key assigned to account $BOUND_USERNAME. No online identity precheck is run; git push will return GitHub's actual result." \
      "正在使用本机为账号 ${BOUND_USERNAME} 指定的 SSH 密钥。这里不会提前联网核对；执行 git push 时，再以 GitHub 的实际返回结果为准。"
    return 0
  fi

  setup_or_reuse_account "$BOUND_USERNAME" "$BOUND_EMAIL" || return 1
  BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
  BOUND_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
  return 0
}

save_project_binding() {
  local remote_url=""

  require_repository_account_match || return 1
  remote_url="git@${BOUND_SSH_ALIAS}:${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}.git"

  git -C "$GIT_ROOT" config --local user.name "$BOUND_USERNAME" || return 1
  git -C "$GIT_ROOT" config --local user.email "$BOUND_EMAIL" || return 1
  git -C "$GIT_ROOT" config --local github-auto.username "$BOUND_USERNAME" || return 1
  git -C "$GIT_ROOT" config --local github-auto.ssh-alias "$BOUND_SSH_ALIAS" || return 1
  git -C "$GIT_ROOT" config --local github-auto.identity-file "$BOUND_IDENTITY_FILE" || return 1
  git -C "$GIT_ROOT" config --local github-auto.engine "$ENGINE_PATH" || return 1

  if git -C "$GIT_ROOT" remote get-url origin >/dev/null 2>&1; then
    git -C "$GIT_ROOT" config --local --replace-all remote.origin.url "$remote_url" || return 1
  else
    git -C "$GIT_ROOT" remote add origin "$remote_url" || return 1
  fi
  git -C "$GIT_ROOT" config --local --replace-all remote.origin.pushurl "$remote_url" || return 1

  return 0
}

create_pinned_ssh_wrapper() {
  PINNED_SSH_DIRECTORY="$(safe_mktemp_directory)" || return 1
  PINNED_SSH_WRAPPER="$PINNED_SSH_DIRECTORY/ssh"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'exec ssh -F /dev/null '
    printf '%s ' \
      '-o HostName=github.com' \
      '-o User=git' \
      '-o IdentitiesOnly=yes' \
      '-o PreferredAuthentications=publickey' \
      '-o PasswordAuthentication=no' \
      '-o ConnectTimeout=8' \
      '-o ConnectionAttempts=1' \
      '-o ServerAliveInterval=15' \
      '-o ServerAliveCountMax=2'
    printf '%s ' '-i "$GITHUB_AUTO_IDENTITY_FILE"'
    printf '"$@"\n'
  } > "$PINNED_SSH_WRAPPER"
  chmod 700 "$PINNED_SSH_WRAPPER"
}

require_single_origin_push_target() {
  local expected_url="git@${BOUND_SSH_ALIAS}:${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}.git"
  local push_urls=""

  require_repository_account_match || return 1
  push_urls="$(git -C "$GIT_ROOT" remote get-url --push --all origin 2>/dev/null)" || return 1
  [ "$push_urls" = "$expected_url" ] && return 0
  error_message \
    "origin does not have exactly one push address matching the selected account and repository. No upload was attempted." \
    "origin 的上传地址不是当前所选账号和仓库的唯一对应地址。本次没有上传。"
  muted \
    "Run ./$SCRIPT_NAME update to save the intended repository again. If this persists, check Git configuration includes and URL rewrite rules for extra push destinations." \
    "请运行 ./${SCRIPT_NAME} update，重新保存目标仓库。如果仍然出现此提示，请检查 Git 引入的其他配置文件和地址重写规则，确认它们没有增加额外的上传目标。"
  return 1
}

run_git_with_identity() {
  local private_key="$1"
  shift
  if [ "${1:-}" = push ]; then
    require_single_origin_push_target || return 1
  fi

  create_pinned_ssh_wrapper || return 1
  # Explicit refspecs alone do not disable followTags or mirror configuration.
  # These process-local push settings do not affect read-only Git operations.
  GITHUB_AUTO_IDENTITY_FILE="$private_key" \
    GIT_SSH_COMMAND="$(shell_single_quoted_value "$PINNED_SSH_WRAPPER")" \
    GIT_SSH_VARIANT=ssh \
    git -C "$GIT_ROOT" -c remote.origin.mirror=false \
      -c push.followTags=false -c push.recurseSubmodules=no "$@"
  local status=$?
  rm -rf "$PINNED_SSH_DIRECTORY"
  return "$status"
}

verify_repository_access() {
  local retry="${1:-yes}"
  local target="${2:-origin}"
  local output=""
  local detail=""

  require_repository_account_match || return 1
  while true; do
    info \
      "Checking ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME} with the SSH key verified for its owner, $BOUND_USERNAME. This does not upload or change the repository." \
      "正在使用已确认为仓库所属账号 ${BOUND_USERNAME} 的 SSH 密钥，检查 ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}；这一步不会上传或修改仓库。"
    output="$(run_git_with_identity "$BOUND_IDENTITY_FILE" ls-remote "$target" HEAD 2>&1)" && {
      success \
        "The repository responded to the SSH key verified for account $BOUND_USERNAME. Upload permission will be confirmed when git push runs." \
        "仓库已响应账号 ${BOUND_USERNAME} 的已验证 SSH 密钥。实际上传权限将在执行 git push 时得到最终确认。"
      return 0
    }

    error_message \
      "Could not read remote information for ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME} with account $BOUND_USERNAME." \
      "无法使用账号 ${BOUND_USERNAME} 读取 ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME} 的远端信息。"
    detail="${output##*$'\n'}"
    if [ -n "$detail" ]; then
      muted "Git result: $detail" "Git 返回信息：$detail"
    fi
    muted \
      "Check the network, confirm that the repository exists, and confirm that this exact account has access." \
      "请检查网络，并确认仓库确实存在且这个账号拥有访问权限。"
    muted \
      "Create a repository: https://github.com/new" \
      "创建仓库：https://github.com/new"

    if [ "$retry" != "yes" ] ||
       ! ui_prompt_yes_no \
         "Run the same read-only access check again?" \
         "要再次执行同一项只读访问检查吗？" \
         "yes"; then
      return 1
    fi
  done
}

configure_project() {
  local preferred_username="${1:-}"
  local purpose="${2:-push}"

  if ! read_origin_repository; then
    warn \
      "This local Git repository has no origin that identifies a GitHub repository." \
      "这个本地 Git 仓库还没有能够识别为 GitHub 仓库的 origin。"
    muted \
      "Paste the GitHub repository that should receive this existing local history. Nothing is uploaded until the final git push." \
      "请粘贴这个现有本地仓库应当上传到的 GitHub 仓库地址；只有最后执行 git push 时才会上传。"
    if ! prompt_repository; then
      return 1
    fi
    CURRENT_REPOSITORY_OWNER="$REPOSITORY_OWNER"
    CURRENT_REPOSITORY_NAME="$REPOSITORY_NAME"
    CURRENT_ORIGIN_URL=""
    CURRENT_ORIGIN_HOST="$REPOSITORY_INPUT_HOST"
  fi

  if load_established_project_binding; then
    if [ "$PROJECT_BINDING_ENGINE_STALE" = true ]; then
      git -C "$GIT_ROOT" config --local github-auto.engine "$ENGINE_PATH" || return 1
    fi
    if [ -n "$preferred_username" ] &&
       [ "$(lowercase "$preferred_username")" != "$(lowercase "$CURRENT_REPOSITORY_OWNER")" ]; then
      warn \
        "Account $preferred_username was requested, but this repository belongs to $CURRENT_REPOSITORY_OWNER. The saved owner account will be used." \
        "前一步选择了账号 ${preferred_username}，但当前仓库属于 ${CURRENT_REPOSITORY_OWNER}。本次仍使用已经保存的仓库所属账号。"
    fi
    github_target_summary \
      normal \
      "$BOUND_USERNAME" \
      "$CURRENT_REPOSITORY_OWNER" \
      "$CURRENT_REPOSITORY_NAME"
    if [ "$purpose" = "push" ]; then
      info \
        "Using the saved owner account and SSH key. This run will go directly to add, commit, and push." \
        "使用已经保存的仓库所属账号和 SSH 密钥；本次直接执行暂存、提交和上传。"
    else
      success \
        "This project is already bound to its GitHub owner and exact SSH key." \
        "当前项目已经绑定到仓库所属账号及其指定 SSH 密钥，无需修改。"
    fi
    return 0
  fi

  select_account_for_repository \
    "$CURRENT_REPOSITORY_OWNER" \
    "$preferred_username" || return $?
  if ! ensure_bound_identity; then
    return 1
  fi

  heading "Confirm the GitHub upload target" "确认 GitHub 上传目标"
  github_target_summary \
    normal \
    "$BOUND_USERNAME" \
    "$CURRENT_REPOSITORY_OWNER" \
    "$CURRENT_REPOSITORY_NAME"

  if ! save_project_binding; then
    fail \
      "The account settings for this project could not be saved." \
      "无法保存当前项目的账号设置。"
  fi
  success \
    "Saved this GitHub account and repository for the current project." \
    "已为当前项目保存上述 GitHub 账号和仓库。"
}

prompt_commit_message() {
  local proposed="$1"
  local entered=""
  local previous_message=""

  heading "Confirm commit message" "确认提交说明"
  muted "Commit message: $proposed" "本次提交说明：$proposed"
  previous_message="$(previous_github_commit_message || true)"
  if [ -n "$previous_message" ]; then
    muted "Previous commit message: $previous_message" "上次提交说明：$previous_message"
  else
    muted "Previous commit message: None recorded for this GitHub branch" "上次提交说明：当前本机尚无该 GitHub 分支的提交记录"
  fi
  entered="$(ui_prompt_value \
    "Press Enter to confirm, or type another commit message.
Enter :cancel to stop before staging.
" \
    "直接按 Enter 确认；也可以输入其他说明，
或输入 :cancel 在暂存前停止
" \
    "$proposed")" || return 1
  if [ "$(lowercase "$entered")" = ":cancel" ]; then
    return 2
  fi
  COMMIT_MESSAGE="$entered"
}

previous_github_commit_message() {
  local branch=""
  local remote_reference=""

  branch="$(git -C "$GIT_ROOT" branch --show-current 2>/dev/null || true)"
  [ -n "$branch" ] || return 1
  remote_reference="refs/remotes/origin/$branch"
  git -C "$GIT_ROOT" show-ref --verify --quiet "$remote_reference" || return 1
  git -C "$GIT_ROOT" log -1 --format='%s' "$remote_reference" 2>/dev/null
}

show_staged_changes() {
  local file_count="${1:-0}"

  heading "Changes in this commit" "本次改动"
  git -C "$GIT_ROOT" --no-pager diff --cached --stat --stat-count=25
  if [ "$file_count" -gt 25 ]; then
    muted \
      "Omitted file details: $((file_count - 25)). All changes remain staged." \
      "另有 $((file_count - 25)) 个文件的明细未在此展开；全部改动仍已暂存。"
  fi
}

show_workflow_review_snapshot() {
  local file_count="$1"

  sed -n '1,25p' "$WORKFLOW_REVIEW_SNAPSHOT"
  if [ "$file_count" -gt 25 ]; then
    muted \
      "Showing 25 of $file_count changed files." \
      "共 $file_count 个改动文件，仅显示前 25 个。"
    muted \
      "Omitted here: $((file_count - 25)). All $file_count will still be checked and included in the commit." \
      "其余 $((file_count - 25)) 个未在此展开；全部 $file_count 个仍会检查并提交。"
  fi
}

POSSIBLE_EMBEDDED_PROJECT_DIRECTORIES=()
POSSIBLE_EMBEDDED_PROJECT_MARKERS=()
POSSIBLE_EMBEDDED_PROJECT_COUNT=0

top_level_project_marker() {
  local directory="$1"
  local marker=""
  local marker_names=(
    .git
    package.json
    pyproject.toml
    setup.py
    Cargo.toml
    go.mod
    pom.xml
    build.gradle
    build.gradle.kts
    settings.gradle
    settings.gradle.kts
    Gemfile
    composer.json
    mix.exs
    Package.swift
    pubspec.yaml
    CMakeLists.txt
  )

  for marker in "${marker_names[@]}"; do
    if [ -e "$directory/$marker" ] || [ -L "$directory/$marker" ]; then
      printf '%s' "$marker"
      return 0
    fi
  done
  return 1
}

possible_embedded_project_index() {
  local directory="$1"
  local index=0

  while [ "$index" -lt "$POSSIBLE_EMBEDDED_PROJECT_COUNT" ]; do
    if [ "${POSSIBLE_EMBEDDED_PROJECT_DIRECTORIES[$index]}" = "$directory" ]; then
      printf '%s' "$index"
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

scan_possible_embedded_projects() {
  local entry=""
  local top_level=""
  local directory=""
  local marker=""
  local index=0
  local count_index=""
  local has_head=false
  local top_level_names=()
  local top_level_counts=()

  # Inspect the same prospective snapshot shown to the user, including paths
  # that are only intent-to-add in the real index. After staging, use the real
  # index because the temporary review index has already been removed.
  if [ -n "$WORKFLOW_EXPECTED_INDEX_FILE" ] && [ -f "$WORKFLOW_EXPECTED_INDEX_FILE" ]; then
    local GIT_INDEX_FILE="$WORKFLOW_EXPECTED_INDEX_FILE"
    export GIT_INDEX_FILE
  fi

  POSSIBLE_EMBEDDED_PROJECT_DIRECTORIES=()
  POSSIBLE_EMBEDDED_PROJECT_MARKERS=()
  POSSIBLE_EMBEDDED_PROJECT_COUNT=0
  if git -C "$GIT_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    has_head=true
  fi

  while IFS= read -r -d '' entry; do
    entry="${entry%/}"
    top_level="${entry%%/*}"
    count_index=""
    index=0
    while [ "$index" -lt "${#top_level_names[@]}" ]; do
      if [ "${top_level_names[$index]}" = "$top_level" ]; then
        count_index="$index"
        break
      fi
      index=$((index + 1))
    done
    if [ -z "$count_index" ]; then
      count_index="${#top_level_names[@]}"
      top_level_names[$count_index]="$top_level"
      top_level_counts[$count_index]=0
    fi
    top_level_counts[$count_index]=$((top_level_counts[$count_index] + 1))

    if [ -d "$GIT_ROOT/$entry" ]; then
      directory="$entry"
    else
      case "$entry" in
      */*)
        directory="${entry%/*}"
        ;;
      *)
        directory="$entry"
        ;;
      esac
    fi
    [ -d "$GIT_ROOT/$directory" ] || continue
    [ ! -L "$GIT_ROOT/$directory" ] || continue
    possible_embedded_project_index "$directory" >/dev/null 2>&1 && continue
    marker="$(top_level_project_marker "$GIT_ROOT/$directory" || true)"
    [ -n "$marker" ] || continue
    if [ "$marker" = .git ] && registered_submodule_path "$directory"; then
      continue
    fi
    if [ "$has_head" = true ] &&
       [ -n "$(git --literal-pathspecs -C "$GIT_ROOT" ls-tree -r --name-only HEAD -- "$directory/" 2>/dev/null)" ]; then
      continue
    fi
    POSSIBLE_EMBEDDED_PROJECT_DIRECTORIES[$POSSIBLE_EMBEDDED_PROJECT_COUNT]="$directory"
    POSSIBLE_EMBEDDED_PROJECT_MARKERS[$POSSIBLE_EMBEDDED_PROJECT_COUNT]="$marker"
    POSSIBLE_EMBEDDED_PROJECT_COUNT=$((POSSIBLE_EMBEDDED_PROJECT_COUNT + 1))
  done < <(
    git -C "$GIT_ROOT" ls-files \
      --others --exclude-standard -z 2>/dev/null
    git -C "$GIT_ROOT" diff \
      --cached --name-only --diff-filter=A -z -- 2>/dev/null
  )

  index=0
  while [ "$index" -lt "${#top_level_names[@]}" ]; do
    top_level="${top_level_names[$index]}"
    if [ "${top_level_counts[$index]}" -ge 20 ] &&
       [ -d "$GIT_ROOT/$top_level" ] &&
       [ ! -L "$GIT_ROOT/$top_level" ] &&
       ! possible_embedded_project_index "$top_level" >/dev/null 2>&1 &&
       { [ "$has_head" = false ] ||
         [ -z "$(git --literal-pathspecs -C "$GIT_ROOT" ls-tree -r --name-only HEAD -- "$top_level/" 2>/dev/null)" ]; }; then
      POSSIBLE_EMBEDDED_PROJECT_DIRECTORIES[$POSSIBLE_EMBEDDED_PROJECT_COUNT]="$top_level"
      POSSIBLE_EMBEDDED_PROJECT_MARKERS[$POSSIBLE_EMBEDDED_PROJECT_COUNT]="many-new-files:${top_level_counts[$index]}"
      POSSIBLE_EMBEDDED_PROJECT_COUNT=$((POSSIBLE_EMBEDDED_PROJECT_COUNT + 1))
    fi
    index=$((index + 1))
  done
}

show_possible_embedded_projects() {
  local page=0
  local page_count=""
  local start=0
  local end=0
  local index=0
  local label=""
  local choice=""
  local default_choice="y"

  page_count="$(paged_choice_page_count "$POSSIBLE_EMBEDDED_PROJECT_COUNT")"
  while true; do
    start=$((page * PAGED_CHOICE_PAGE_SIZE))
    end=$((start + PAGED_CHOICE_PAGE_SIZE))
    [ "$end" -le "$POSSIBLE_EMBEDDED_PROJECT_COUNT" ] ||
      end="$POSSIBLE_EMBEDDED_PROJECT_COUNT"
    print_paged_page_status "$page" "$POSSIBLE_EMBEDDED_PROJECT_COUNT" "$UI_LANGUAGE"

    index="$start"
    while [ "$index" -lt "$end" ]; do
      label="$(paged_choice_label "$((index - start))")" || return 1
      if [ "$UI_LANGUAGE" = "zh" ]; then
        case "${POSSIBLE_EMBEDDED_PROJECT_MARKERS[$index]}" in
          many-new-files:*)
            printf '  %s) %s（识别依据：包含 %s 个新增文件）\n' \
              "$label" \
              "${POSSIBLE_EMBEDDED_PROJECT_DIRECTORIES[$index]}" \
              "${POSSIBLE_EMBEDDED_PROJECT_MARKERS[$index]#many-new-files:}"
            ;;
          *)
            printf '  %s) %s（识别依据：独立项目标志 %s）\n' \
              "$label" \
              "${POSSIBLE_EMBEDDED_PROJECT_DIRECTORIES[$index]}" \
              "${POSSIBLE_EMBEDDED_PROJECT_MARKERS[$index]}"
            ;;
        esac
      else
        case "${POSSIBLE_EMBEDDED_PROJECT_MARKERS[$index]}" in
          many-new-files:*)
            printf '  %s) %s (reason: %s newly added files)\n' \
              "$label" \
              "${POSSIBLE_EMBEDDED_PROJECT_DIRECTORIES[$index]}" \
              "${POSSIBLE_EMBEDDED_PROJECT_MARKERS[$index]#many-new-files:}"
            ;;
          *)
            printf '  %s) %s (independent-project marker: %s)\n' \
              "$label" \
              "${POSSIBLE_EMBEDDED_PROJECT_DIRECTORIES[$index]}" \
              "${POSSIBLE_EMBEDDED_PROJECT_MARKERS[$index]}"
            ;;
        esac
      fi
      index=$((index + 1))
    done

    [ "$page_count" -gt 1 ] || return 0
    print_paged_navigation "$page" "$POSSIBLE_EMBEDDED_PROJECT_COUNT" "$UI_LANGUAGE"
    if [ "$UI_LANGUAGE" = "zh" ]; then
      printf '  0) 查看完毕，继续确认\n'
    else
      printf '  0) Finish reviewing this list\n'
    fi
    if [ "$page" -eq $((page_count - 1)) ]; then
      default_choice="0"
    else
      default_choice="y"
    fi

    while true; do
      choice="$(ui_prompt_value "Choose" "选择" "$default_choice")" || return 1
      choice="$(lowercase "$choice")"
      if [ "$choice" = "x" ] && [ "$page" -gt 0 ]; then
        page=$((page - 1))
        break
      fi
      if [ "$choice" = "y" ] && [ "$page" -lt $((page_count - 1)) ]; then
        page=$((page + 1))
        break
      fi
      if [ "$choice" = "0" ]; then
        return 0
      fi
      warn "Enter one of the choices shown." "请输入当前页面中显示的选项。"
    done
    printf '\n'
  done
}

review_possible_embedded_projects() {
  local index=0
  local has_nested_repository=false

  scan_possible_embedded_projects || return 1
  [ "$POSSIBLE_EMBEDDED_PROJECT_COUNT" -gt 0 ] || return 0

  while [ "$index" -lt "$POSSIBLE_EMBEDDED_PROJECT_COUNT" ]; do
    if [ "${POSSIBLE_EMBEDDED_PROJECT_MARKERS[$index]}" = .git ]; then
      has_nested_repository=true
      break
    fi
    index=$((index + 1))
  done
  if [ "$has_nested_repository" = true ]; then
    heading \
      "A separate Git repository is inside this project" \
      "当前项目中包含另一个 Git 仓库"
    warn \
      "Git cannot add the files inside the following folders as ordinary project files. It would record only a link to another repository, so this run has stopped before staging." \
      "Git 无法把下列文件夹中的内容当作当前项目的普通文件加入提交，只会记录一个指向其他仓库的链接。为避免上传内容与预期不符，本次已在暂存前停止。"
    index=0
    while [ "$index" -lt "$POSSIBLE_EMBEDDED_PROJECT_COUNT" ]; do
      if [ "${POSSIBLE_EMBEDDED_PROJECT_MARKERS[$index]}" = .git ]; then
        printf '  - %s\n' "${POSSIBLE_EMBEDDED_PROJECT_DIRECTORIES[$index]}"
      fi
      index=$((index + 1))
    done
    muted \
      "If these files belong to this project, remove or move that folder's own .git directory first. If it is intentionally a submodule, configure it with Git before running ./$SCRIPT_NAME again." \
      "如果这些文件本来就属于当前项目，请先移走或删除该文件夹自己的 .git 目录；如果它本来就是子模块，请先用 Git 正确配置子模块，再重新运行 ./${SCRIPT_NAME}。"
    return 2
  fi

  heading \
    "New folders that may belong to another project" \
    "发现可能属于其他项目的新目录"
  warn \
    "Each folder below is absent from the current committed history and either contains an independent-project marker or introduces an unusually large group of files." \
    "下面每个目录都没有出现在当前提交历史中，并且包含独立项目标志，或者一次新增了数量异常多的文件。"
  show_possible_embedded_projects || return 1
  muted \
    "git add -A will include every listed folder in this repository. Continue only if all of them belong here." \
    "执行 git add -A 后，上面列出的文件夹都会进入当前仓库。请只在确认它们确实属于本项目时继续。"
  if ui_prompt_yes_no \
    "Include all of these folders in this commit?" \
    "确认把这些文件夹全部纳入本次提交吗？" \
    "no"; then
    return 0
  fi

  warn \
    "Commit stopped before the staging area was changed. Existing staged changes were left unchanged; no commit or push was performed." \
    "已在改动暂存区前停止；原有暂存内容保持不变，也没有创建提交或上传文件。"
  return 2
}

registered_submodule_path() {
  local path="$1"
  local record=""
  [ -f "$GIT_ROOT/.gitmodules" ] || return 1
  case "$(git --literal-pathspecs -C "$GIT_ROOT" ls-files --stage -- "$path")" in
    160000' '*) ;;
    *) return 1 ;;
  esac
  while IFS= read -r -d '' record; do
    [ "${record#*$'\n'}" = "$path" ] && return 0
  done < <(git -C "$GIT_ROOT" config -z --file .gitmodules --get-regexp '^submodule\..*\.path$')
  return 1
}

list_dirty_submodules() {
  [ -f "$GIT_ROOT/.gitmodules" ] || return 0
  git -C "$GIT_ROOT" submodule foreach --quiet --recursive '
    submodule_status=$(git -c core.fsmonitor=false status --porcelain --untracked-files=all) || exit 1
    if test -n "$submodule_status"; then
      printf "%s\n" "${displaypath:-$sm_path}"
    fi
  '
}

prompt_release_version_after_timeout() {
  local fallback_message="$1"
  local entered=""

  warn \
    "Version lookup stopped after 5 seconds so this commit does not keep you waiting." \
    "查找版本号已在 5 秒后停止，避免本次提交继续等待。"
  muted \
    "If this is a release, enter its version now (for example, 2.3.1). Press Enter to use: $fallback_message" \
    "如果本次需要发布版本，请现在输入版本号（例如 2.3.1）；直接按 Enter 将使用：${fallback_message}"
  while true; do
    entered="$(ui_prompt_value "Release version (optional)" "本次版本号（可留空）")" || return 1
    entered="$(trim "$entered")"
    if [ -z "$entered" ]; then
      return 1
    fi
    case "$entered" in
      v*|V*) entered="${entered#?}" ;;
    esac
    if valid_release_version "$entered"; then
      RELEASE_VERSION="$entered"
      VERSION_SOURCE="manual input after timeout"
      VERSION_POSITION="manual"
      return 0
    fi
    warn \
      "Enter a dotted version such as 2.3.1 or 1.2.3.4, or press Enter to use $fallback_message." \
      "请输入用点分隔的版本号，例如 2.3.1 或 1.2.3.4；也可以直接按 Enter 使用 ${fallback_message}。"
  done
}

prepare_and_commit() {
  local has_commits=true
  local rename_initial_branch=false
  local existing_local_branch=""
  local proposed="$DEFAULT_COMMIT_MESSAGE"
  local review_status=0
  local initial_status_empty=false
  local dirty_submodules=""
  local version_status=0
  local fallback_message="$DEFAULT_COMMIT_MESSAGE"
  local review_file_count=0
  local commit_options=()

  WORKFLOW_COMMIT_CREATED_THIS_RUN=false

  info \
    "Checking the working tree for changes to commit..." \
    "正在检查工作区中是否有需要提交的改动……"
  if ! git -C "$GIT_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    has_commits=false
    existing_local_branch="$(
      git -C "$GIT_ROOT" for-each-ref --format='%(refname)' refs/heads/ 2>/dev/null |
        sed -n '1p'
    )"
    if [ -z "$existing_local_branch" ]; then
      rename_initial_branch=true
    fi
  fi

  if ! capture_workflow_checkpoint ||
     ! capture_workflow_review_snapshot ||
     ! prepare_expected_staged_tree; then
    clear_workflow_review_snapshot
    error_message \
      "The repository state could not be recorded for a safe commit review." \
      "无法记录当前仓库状态，因此不能安全地进行提交检查。"
    return 1
  fi

  [ -s "$WORKFLOW_REVIEW_SNAPSHOT" ] || initial_status_empty=true
  if ! dirty_submodules="$(list_dirty_submodules)"; then
    clear_workflow_review_snapshot
    error_message \
      "Git could not inspect the submodules. No files were staged, committed, or pushed; resolve the Git error above and retry." \
      "Git 无法完成子模块检查。本次没有暂存、提交或上传文件；请先处理上方的 Git 错误，再重新运行。"
    return 1
  fi
  if [ -n "$dirty_submodules" ]; then
    clear_workflow_review_snapshot
    heading "Uncommitted changes inside a Git submodule" "Git 子模块中还有未提交的改动"
    warn \
      "The parent repository cannot include file changes made inside these submodules:" \
      "当前主仓库无法直接提交下列子模块内部的文件改动："
    printf '%s\n' "$dirty_submodules" | sed 's/^/  - /'
    muted \
      "Commit those files inside each submodule first, then run ./$SCRIPT_NAME again. Nothing was staged, committed, or pushed by this run." \
      "请先分别进入这些子模块完成提交，再重新运行 ./${SCRIPT_NAME}。本次没有暂存、提交或上传任何内容。"
    return 2
  fi

  if ! verify_reviewed_file_tree; then
    clear_workflow_review_snapshot
    error_message \
      "The repository state could not be recorded for a safe commit review." \
      "无法记录当前仓库状态，因此不能安全地进行提交检查。"
    return 1
  fi

  if ! expected_staged_tree_has_changes; then
    clear_workflow_review_snapshot
    if [ "$initial_status_empty" != true ]; then
      warn \
        "The staging area and working tree contain changes that cancel each other. git add -A would produce no new commit, so this run stopped without changing the staging area or pushing." \
        "暂存区和工作区中的改动相互抵消；即使执行 git add -A，也不会产生新的提交。脚本已保持现有暂存状态并停止，本次不会上传。"
      muted \
        "Review git status, keep the version you want, then run ./$SCRIPT_NAME again." \
        "请用 git status 核对现状，保留你真正需要的版本后，再重新运行 ./${SCRIPT_NAME}。"
      return 2
    fi
    if [ "$has_commits" = false ]; then
      warn \
        "This repository has no commit and no project files available to commit. Nothing was pushed." \
        "当前仓库还没有提交记录，也没有可提交的项目文件，因此本次不会上传。"
      return 3
    fi
    info \
      "The working tree has no uncommitted changes. No commit will be created; any existing local commits will still be considered for push." \
      "工作区没有尚未提交的改动，因此不会创建新提交；如果本地已有尚未上传的提交，后续仍会考虑上传。"
    return 0
  fi

  if ! write_exact_workflow_review_snapshot || ! verify_reviewed_file_tree; then
    clear_workflow_review_snapshot
    error_message \
      "The exact file snapshot for review could not be prepared safely. The real Git staging area was not changed." \
      "无法安全生成本次检查所需的准确文件快照。真实 Git 暂存区没有发生变化。"
    return 1
  fi
  if [ "$initial_status_empty" = true ]; then
    warn \
      "The initial Git status did not list these changes. A complete independent file scan recovered the accurate commit contents shown below." \
      "首次 Git 状态检查没有列出这些改动。程序已通过独立的完整文件扫描恢复准确内容，并在下方列出。"
  fi

  heading "Review changes before committing" "提交前检查改动"
  muted \
    "This preview comes from the exact file snapshot git add -A will prepare. A means added, M modified, D deleted, R renamed, and T a file-type change." \
    "下面的预览来自执行 git add -A 后将要提交的准确文件清单：A 表示新增，M 表示修改，D 表示删除，R 表示重命名，T 表示文件类型发生变化。"
  review_file_count="$(awk 'END { print NR }' "$WORKFLOW_REVIEW_SNAPSHOT")"
  show_workflow_review_snapshot "$review_file_count"
  muted \
    "After the commit message is confirmed, git add -A will include all $review_file_count changes, including deletions and any files omitted from this preview." \
    "确认提交说明后，脚本会执行 git add -A，纳入全部 $review_file_count 个改动，包括删除的文件和上面省略显示的文件。"

  review_status=0
  review_possible_embedded_projects || review_status=$?
  if [ "$review_status" -eq 2 ]; then
    clear_workflow_review_snapshot
    return 2
  elif [ "$review_status" -ne 0 ]; then
    clear_workflow_review_snapshot
    return 1
  fi
  remember_approved_project_directories

  if [ "$has_commits" = false ]; then
    fallback_message="$INITIAL_COMMIT_MESSAGE"
  fi

  info \
    "Checking project version files, metadata, and changelogs..." \
    "正在查找项目中的版本文件、元数据和更新记录……"
  resolve_release_version yes || version_status=$?
  if [ "$version_status" -eq 0 ]; then
    proposed="${RELEASE_PREFIX}${RELEASE_VERSION}"
    info \
      "Detected version ${RELEASE_VERSION} (${VERSION_SOURCE})" \
      "识别到版本 ${RELEASE_VERSION}（${VERSION_SOURCE}）"
    case "$VERSION_POSITION" in
      bottom)
        warn \
          "This changelog is ordered oldest to newest, so the bottom version was used." \
          "这个 CHANGELOG 按旧版本到新版本排列，已采用底部版本。"
        ;;
      single)
        muted \
          "Only one version was found in this changelog." \
          "这个 CHANGELOG 中只识别到一个版本。"
        ;;
    esac
  elif [ "$version_status" -eq 124 ]; then
    if prompt_release_version_after_timeout "$fallback_message"; then
      proposed="${RELEASE_PREFIX}${RELEASE_VERSION}"
      info \
        "Using version ${RELEASE_VERSION} entered after the automatic lookup stopped." \
        "将使用自动查找停止后输入的版本号 ${RELEASE_VERSION}。"
    else
      proposed="$fallback_message"
      muted \
        "No version was entered, so the fallback commit message will be used." \
        "没有输入版本号，将使用备用提交说明。"
    fi
  elif [ "$has_commits" = false ]; then
    proposed="$fallback_message"
    muted \
      "No release version was found, so the first commit message will be used." \
      "没有发现发布版本号，将使用首次提交说明。"
  else
    muted \
      "No release version was found, so a general commit message will be used." \
      "没有发现发布版本号，将使用通用提交说明。"
  fi

  prompt_commit_message "$proposed"
  case "$?" in
    0)
      ;;
    2)
      clear_workflow_review_snapshot
      warn \
        "Commit canceled before the staging area was changed. This step did not stage, commit, or push any files." \
        "已在改动暂存区前取消；这一步没有暂存、提交或上传任何文件。"
      return 2
      ;;
    *)
      clear_workflow_review_snapshot
      return 1
      ;;
  esac

  if ! verify_workflow_checkpoint "staging" "执行暂存"; then
    clear_workflow_review_snapshot
    return 1
  fi
  if ! verify_reviewed_file_tree; then
    clear_workflow_review_snapshot
    return 1
  fi
  if ! set_workflow_state staging; then
    clear_workflow_review_snapshot
    error_message \
      "The commit safety record could not be written. Stopped before changing the staging area." \
      "无法写入本次提交的安全记录。脚本已在改动暂存区前停止。"
    return 1
  fi

  info \
    "Staging all confirmed changes with git add -A..." \
    "正在执行 git add -A，暂存刚才确认的全部改动……"
  if ! prepare_real_index_for_exact_staging || ! git -C "$GIT_ROOT" -c core.fsmonitor=false add -A; then
    clear_workflow_review_snapshot
    error_message \
      "git add -A failed. Git may have staged some paths before stopping; inspect git status. No commit or push was attempted." \
      "git add -A 执行失败。Git 可能已经暂存了部分文件，请用 git status 检查；脚本没有继续提交或上传。"
    return 1
  fi
  clear_workflow_review_snapshot
  if ! verify_staging_finished_cleanly; then
    return 1
  fi
  set_workflow_state staged || {
    error_message \
      "The post-staging safety record could not be written. Stopped before commit; the staging area was preserved." \
      "无法写入暂存完成后的安全记录。脚本已在创建提交前停止，并保留当前暂存状态。"
    return 1
  }
  if ! verify_workflow_checkpoint "committing" "创建提交" ||
     ! verify_staging_finished_cleanly; then
    return 1
  fi
  if [ "$PROJECT_BINDING_REUSED" != true ]; then
    show_staged_changes "$review_file_count"
  fi

  if ! set_workflow_state committing; then
    error_message \
      "The commit safety record could not be updated. Stopped before git commit; the staging area was preserved." \
      "无法更新本次提交的安全记录。脚本已在执行 git commit 前停止，并保留当前暂存状态。"
    return 1
  fi
  info \
    "Creating commit: $COMMIT_MESSAGE. Any Git hooks or commit-signing prompt configured for this repository runs during this step." \
    "正在创建提交：${COMMIT_MESSAGE}。如果当前仓库配置了 Git hook 或提交签名，它们会在这一步运行并可能显示自己的提示。"
  commit_options=(--cleanup=verbatim -m "$COMMIT_MESSAGE")
  if [ "$review_file_count" -gt 25 ]; then
    commit_options+=(--quiet)
  fi
  if ! GIT_AUTHOR_NAME="$WORKFLOW_EXPECTED_AUTHOR_NAME" \
    GIT_AUTHOR_EMAIL="$WORKFLOW_EXPECTED_EMAIL" \
    GIT_COMMITTER_NAME="$WORKFLOW_EXPECTED_AUTHOR_NAME" \
    GIT_COMMITTER_EMAIL="$WORKFLOW_EXPECTED_EMAIL" \
    git -C "$GIT_ROOT" \
    -c "user.name=$WORKFLOW_EXPECTED_AUTHOR_NAME" \
    -c "user.email=$WORKFLOW_EXPECTED_EMAIL" \
    commit "${commit_options[@]}"; then
    error_message \
      "The commit failed. The selected changes remain staged for inspection, and no push was attempted." \
      "提交失败。本次选择的改动仍保留在暂存区，便于检查；脚本没有执行上传。"
    return 1
  fi

  if ! accept_created_commit_checkpoint \
    "finishing the commit" "完成提交" \
    "$COMMIT_MESSAGE" "$WORKFLOW_EXPECTED_AUTHOR_NAME" "$WORKFLOW_EXPECTED_EMAIL"; then
    return 1
  fi
  success "Committed: $COMMIT_MESSAGE" "已提交：$COMMIT_MESSAGE"
  if [ "$review_file_count" -gt 25 ]; then
    muted \
      "All $review_file_count changed files were committed; Git's per-file commit output was omitted." \
      "全部 $review_file_count 个改动文件已提交；Git 逐项列出文件的输出已省略。"
  fi

  if [ "$rename_initial_branch" = true ]; then
    git -C "$GIT_ROOT" branch -M main || fail \
      "The initial branch could not be named main." \
      "无法把初始分支设置为 main。"
  fi
  if ! capture_workflow_checkpoint; then
    error_message \
      "The repository state could not be recorded after the commit. The new local commit was preserved, but no push was attempted." \
      "提交完成后无法重新记录仓库状态。新的本地提交已经保留，但脚本没有继续上传。"
    return 1
  fi
  WORKFLOW_COMMIT_CREATED_THIS_RUN=true
  clear_workflow_state
}

push_current_branch() {
  local confirmed_commit_created_this_run="${1:-false}"
  local allow_history_append="${2:-yes}"
  local branch=""
  local push_head=""
  local latest_commit_message=""
  local push_reference=""
  local output=""
  local output_file=""
  local push_status=0
  local tee_status=0
  local pipeline_status=()

  require_repository_account_match || return 1
  if [ "$WORKFLOW_TRANSACTION_ACTIVE" = true ] &&
     ! verify_workflow_checkpoint "uploading" "上传"; then
    return 1
  fi
  branch="$(git -C "$GIT_ROOT" branch --show-current)"
  if [ -z "$branch" ]; then
    fail \
      "The repository is in detached HEAD state, so a branch cannot be selected safely." \
      "当前处于 detached HEAD 状态，无法安全判断要推送的分支。"
  fi
  if [ "$WORKFLOW_TRANSACTION_ACTIVE" = true ]; then
    push_head="$WORKFLOW_EXPECTED_HEAD"
  else
    push_head="$(git -C "$GIT_ROOT" rev-parse --verify HEAD 2>/dev/null || true)"
  fi
  if [ -z "$push_head" ] || [ "$push_head" = "<unborn>" ]; then
    fail \
      "No local commit is available to push." \
      "当前没有可上传的本地提交。"
  fi

  heading "Push to GitHub" "上传到 GitHub"
  github_target_summary \
    normal \
    "$BOUND_USERNAME" \
    "$CURRENT_REPOSITORY_OWNER" \
    "$CURRENT_REPOSITORY_NAME"
  if [ "$confirmed_commit_created_this_run" != true ]; then
    latest_commit_message="$(git -C "$GIT_ROOT" log -1 --format='%s' "$push_head" 2>/dev/null || true)"
    muted \
      "No new file changes need to be committed, so this run will not create a commit." \
      "当前没有需要提交的新文件改动，因此本次不会创建提交。"
    muted \
      "Latest local commit message: $latest_commit_message" \
      "最新本地提交说明：$latest_commit_message"
    if ! ui_prompt_yes_no \
      "Continue with the GitHub push?" \
      "继续上传到 GitHub 吗？" \
      "no"; then
      warn \
        "Upload canceled before connecting to GitHub. All local commits remain unchanged." \
        "已在连接 GitHub 前取消上传；所有本地提交均保持不变。"
      return 2
    fi
    if [ "$WORKFLOW_TRANSACTION_ACTIVE" = true ] &&
       ! verify_workflow_checkpoint "uploading" "上传"; then
      return 1
    fi
  fi

  push_reference="refs/github-auto/push-${WORKFLOW_LOCK_TOKEN:-$$-${RANDOM:-1}}"
  if ! git -C "$GIT_ROOT" check-ref-format "$push_reference" >/dev/null 2>&1 ||
     ! git -C "$GIT_ROOT" update-ref "$push_reference" "$push_head"; then
    error_message \
      "The exact local commit could not be pinned for upload. No connection to GitHub was attempted." \
      "无法在本机固定本次应当上传的准确提交。脚本没有连接 GitHub。"
    return 1
  fi
  WORKFLOW_PUSH_REFERENCE="$push_reference"

  info \
    "Connecting to GitHub and uploading branch $branch. Git transfer progress will appear below; large files or a slow network can make this step take longer." \
    "正在连接 GitHub 并上传 ${branch} 分支。下方会实时显示 Git 的传输进度；文件较大或网络较慢时，这一步会需要更长时间。"
  if ! output_file="$(safe_mktemp_file "${TMPDIR:-/tmp}" "push-output")"; then
    git -C "$GIT_ROOT" update-ref -d "$push_reference" >/dev/null 2>&1 || true
    WORKFLOW_PUSH_REFERENCE=""
    return 1
  fi
  if ! set_workflow_state pushing; then
    rm -f "$output_file"
    git -C "$GIT_ROOT" update-ref -d "$push_reference" >/dev/null 2>&1 || true
    WORKFLOW_PUSH_REFERENCE=""
    error_message \
      "The push safety record could not be written. No connection to GitHub was attempted." \
      "无法写入本次上传的安全记录。脚本没有连接 GitHub。"
    return 1
  fi
  run_git_with_identity "$BOUND_IDENTITY_FILE" \
    push --progress origin "$push_reference:refs/heads/$branch" 2>&1 | tee "$output_file"
  pipeline_status=("${PIPESTATUS[@]}")
  push_status=${pipeline_status[0]}
  tee_status=${pipeline_status[1]}
  output="$(sed -n '1,$p' "$output_file")"
  rm -f "$output_file"
  git -C "$GIT_ROOT" update-ref -d "$push_reference" >/dev/null 2>&1 || true
  WORKFLOW_PUSH_REFERENCE=""
  clear_workflow_state
  if [ "$tee_status" -ne 0 ]; then
    error_message \
      "The live Git progress output could not be displayed completely." \
      "无法完整显示 Git 的实时传输进度。"
    return 1
  fi
  if [ "$push_status" -ne 0 ]; then
    explain_push_failure "$output" "$branch"
    if [ "$allow_history_append" = yes ] && push_rejection_is_remote_ahead "$output"; then
      append_current_version_to_remote_history "$branch" "$push_head"
      return $?
    fi
    return 1
  fi
  if ! git -C "$GIT_ROOT" config --local "branch.$branch.remote" origin ||
     ! git -C "$GIT_ROOT" config --local "branch.$branch.merge" "refs/heads/$branch"; then
    warn \
      "The exact confirmed commit was uploaded, but Git could not save origin/$branch as this branch's upstream. The next ./$SCRIPT_NAME run can still push explicitly." \
      "已经上传刚才确认的准确提交，但 Git 无法把 origin/${branch} 保存为当前分支的上游。下次运行 ./${SCRIPT_NAME} 时仍可继续明确上传。"
  fi
  success \
    "Upload completed with account $BOUND_USERNAME to ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}." \
    "已使用账号 $BOUND_USERNAME 上传到 ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}。"
}

push_rejection_is_remote_ahead() {
  local normalized=""

  normalized="$(lowercase "$1")"
  case "$normalized" in
    *non-fast-forward*|*fetch\ first*|*remote\ contains\ work\ that\ you\ do\ not*)
      return 0
      ;;
  esac
  return 1
}

clear_remote_history_reference() {
  if [ -n "$WORKFLOW_REMOTE_REFERENCE" ]; then
    git -C "$GIT_ROOT" update-ref -d "$WORKFLOW_REMOTE_REFERENCE" >/dev/null 2>&1 || true
    WORKFLOW_REMOTE_REFERENCE=""
  fi
}

verify_clean_current_snapshot() {
  local expected_tree="$1"
  local result=0

  if ! prepare_expected_staged_tree; then
    clear_workflow_review_snapshot
    return 1
  fi
  if [ "$WORKFLOW_EXPECTED_ORIGINAL_INDEX_TREE" != "$expected_tree" ] ||
     [ "$WORKFLOW_EXPECTED_STAGED_TREE" != "$expected_tree" ]; then
    result=1
  fi
  clear_workflow_review_snapshot
  return "$result"
}

append_current_version_to_remote_history() {
  local branch="$1"
  local local_head="$2"
  local local_tree=""
  local remote_head=""
  local remote_reference=""
  local proposed_message=""
  local new_commit=""
  local commit_status=0

  heading \
    "Keep the remote history and append this version" \
    "保留远端历史并追加当前版本"
  muted \
    "GitHub's existing $branch history and this repository's local history will both remain. The newest commit will keep the current local files exactly as they are, and the upload will not use force." \
    "GitHub 上现有的 ${branch} 历史和当前仓库的本机历史都会保留。最新提交中的文件将与当前本机版本完全一致，上传过程不会使用强制推送。"
  muted \
    "If you continue, the script will first read the latest remote commit, then ask you to confirm the connecting commit message before changing the local branch." \
    "选择继续后，脚本会先读取远端最新提交，再请你确认用于衔接两边历史的提交说明；在确认之前，不会改动本机分支。"
  if ! ui_prompt_yes_no \
    "Keep the remote history and append this local version?" \
    "要保留远端历史，并把当前本机版本追加为最新版本吗？" \
    "no"; then
    warn \
      "This option was not used. The local commit and remote history remain unchanged." \
      "没有执行这项操作；本机提交和远端历史均保持不变。"
    return 2
  fi

  if [ "$WORKFLOW_TRANSACTION_ACTIVE" = true ] &&
     ! verify_workflow_checkpoint "reading the remote history" "读取远端历史"; then
    return 1
  fi
  require_single_origin_push_target || return 1
  remote_reference="refs/github-auto/remote-${WORKFLOW_LOCK_TOKEN:-$$-${RANDOM:-1}}"
  if ! git -C "$GIT_ROOT" check-ref-format "$remote_reference" >/dev/null 2>&1; then
    error_message \
      "A temporary reference for the remote history could not be created." \
      "无法为远端历史创建本机临时引用。"
    return 1
  fi
  WORKFLOW_REMOTE_REFERENCE="$remote_reference"
  if ! set_workflow_state reconciling; then
    clear_remote_history_reference
    error_message \
      "The history-connection safety record could not be written. No remote history was read and no local branch was changed." \
      "无法写入历史衔接的安全记录。脚本没有读取远端历史，也没有改动本机分支。"
    return 1
  fi

  info \
    "Reading GitHub's latest $branch commit. Git's real transfer progress will appear below." \
    "正在读取 GitHub 上 ${branch} 分支的最新提交；下方会显示 Git 的实际传输进度。"
  if ! run_git_with_identity "$BOUND_IDENTITY_FILE" fetch --progress --no-tags \
    --no-write-fetch-head origin "+refs/heads/$branch:$remote_reference"; then
    clear_remote_history_reference
    clear_workflow_state
    error_message \
      "The latest remote history could not be read. The local branch and remote repository remain unchanged." \
      "无法读取远端最新历史；本机分支和远端仓库均保持不变。"
    return 1
  fi
  remote_head="$(git -C "$GIT_ROOT" rev-parse --verify "$remote_reference" 2>/dev/null || true)"
  if [ -z "$remote_head" ]; then
    clear_remote_history_reference
    clear_workflow_state
    error_message \
      "Git did not return a valid latest commit for the remote branch. The local branch was not changed." \
      "Git 没有返回有效的远端分支最新提交；本机分支没有改动。"
    return 1
  fi
  if [ "$WORKFLOW_TRANSACTION_ACTIVE" = true ] &&
     ! verify_workflow_checkpoint "connecting the histories" "衔接两边历史"; then
    clear_remote_history_reference
    clear_workflow_state
    return 1
  fi

  if [ "$remote_head" = "$local_head" ]; then
    clear_remote_history_reference
    clear_workflow_state
    git -C "$GIT_ROOT" config --local "branch.$branch.remote" origin || true
    git -C "$GIT_ROOT" config --local "branch.$branch.merge" "refs/heads/$branch" || true
    success \
      "GitHub already has this exact commit; no connecting commit or second upload was needed." \
      "GitHub 已经包含这个准确提交，因此无需创建衔接提交，也无需再次上传。"
    return 0
  fi
  if git -C "$GIT_ROOT" merge-base --is-ancestor "$remote_head" "$local_head" 2>/dev/null; then
    clear_remote_history_reference
    clear_workflow_state
    info \
      "The refreshed remote history is already contained in the local branch. Retrying the same normal upload now." \
      "重新读取后，远端历史已经包含在本机分支中；现在重新进行同一次普通上传。"
    push_current_branch true no
    return $?
  fi

  local_tree="$(git -C "$GIT_ROOT" rev-parse --verify "${local_head}^{tree}" 2>/dev/null || true)"
  proposed_message="$(git -C "$GIT_ROOT" log -1 --format='%s' "$local_head" 2>/dev/null || true)"
  [ -n "$proposed_message" ] || proposed_message="$DEFAULT_COMMIT_MESSAGE"
  muted \
    "The connecting commit will place the remote history first, retain the existing local history, and use the current local commit's complete file snapshot." \
    "衔接提交会把远端历史接在主线上，同时保留现有本机历史，并采用当前本机提交的完整文件快照。"
  prompt_commit_message "$proposed_message" || commit_status=$?
  if [ "$commit_status" -eq 2 ]; then
    clear_remote_history_reference
    clear_workflow_state
    warn \
      "History connection canceled before the local branch changed. The local commit and remote history remain unchanged." \
      "已在改动本机分支前取消历史衔接；本机提交和远端历史均保持不变。"
    return 2
  elif [ "$commit_status" -ne 0 ]; then
    clear_remote_history_reference
    clear_workflow_state
    return 1
  fi
  if [ "$WORKFLOW_TRANSACTION_ACTIVE" = true ] &&
     ! verify_workflow_checkpoint "creating the connecting commit" "创建衔接提交"; then
    clear_remote_history_reference
    clear_workflow_state
    return 1
  fi
  if [ -z "$local_tree" ] || ! verify_clean_current_snapshot "$local_tree"; then
    clear_remote_history_reference
    clear_workflow_state
    error_message \
      "Local files or the staging area changed before the histories were connected. Nothing was committed or uploaded." \
      "在衔接历史前，本机文件或暂存区发生了变化。脚本没有创建提交，也没有上传。"
    return 1
  fi
  if [ "$(git -C "$GIT_ROOT" rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)" != "$local_head" ] ||
     [ "$(git -C "$GIT_ROOT" rev-parse --verify "$remote_reference" 2>/dev/null || true)" != "$remote_head" ]; then
    clear_remote_history_reference
    clear_workflow_state
    error_message \
      "The local or fetched remote commit changed before the connecting commit was created. Nothing was uploaded." \
      "创建衔接提交前，本机提交或已读取的远端提交发生了变化。脚本没有上传。"
    return 1
  fi

  info \
    "Creating the confirmed connecting commit without changing the current files..." \
    "正在创建已确认的衔接提交；当前文件不会发生变化……"
  new_commit="$(
    printf '%s\n' "$COMMIT_MESSAGE" |
      GIT_AUTHOR_NAME="$WORKFLOW_EXPECTED_AUTHOR_NAME" \
      GIT_AUTHOR_EMAIL="$WORKFLOW_EXPECTED_EMAIL" \
      GIT_COMMITTER_NAME="$WORKFLOW_EXPECTED_AUTHOR_NAME" \
      GIT_COMMITTER_EMAIL="$WORKFLOW_EXPECTED_EMAIL" \
      git -C "$GIT_ROOT" \
        -c "user.name=$WORKFLOW_EXPECTED_AUTHOR_NAME" \
        -c "user.email=$WORKFLOW_EXPECTED_EMAIL" \
        commit-tree "$local_tree" -p "$remote_head" -p "$local_head" -F -
  )" || new_commit=""
  if [ -z "$new_commit" ] ||
     [ "$(git -C "$GIT_ROOT" show -s --format='%T' "$new_commit" 2>/dev/null || true)" != "$local_tree" ] ||
     [ "$(git -C "$GIT_ROOT" show -s --format='%P' "$new_commit" 2>/dev/null || true)" != "$remote_head $local_head" ] ||
     [ "$(git -C "$GIT_ROOT" show -s --format='%B' "$new_commit" 2>/dev/null || true)" != "$COMMIT_MESSAGE" ] ||
     [ "$(git -C "$GIT_ROOT" show -s --format='%an <%ae>' "$new_commit" 2>/dev/null || true)" != "$WORKFLOW_EXPECTED_AUTHOR_NAME <$WORKFLOW_EXPECTED_EMAIL>" ] ||
     [ "$(git -C "$GIT_ROOT" show -s --format='%cn <%ce>' "$new_commit" 2>/dev/null || true)" != "$WORKFLOW_EXPECTED_AUTHOR_NAME <$WORKFLOW_EXPECTED_EMAIL>" ]; then
    clear_remote_history_reference
    clear_workflow_state
    error_message \
      "The connecting commit could not be created and verified exactly. The local branch and remote repository remain unchanged." \
      "无法准确创建并核对衔接提交；本机分支和远端仓库均保持不变。"
    return 1
  fi
  if ! git -C "$GIT_ROOT" update-ref "refs/heads/$branch" "$new_commit" "$local_head"; then
    clear_remote_history_reference
    clear_workflow_state
    error_message \
      "The local branch could not be advanced safely because it changed or Git could not write it. Nothing was uploaded." \
      "无法安全更新本机分支：它可能已经发生变化，或者 Git 无法写入。脚本没有上传。"
    return 1
  fi
  clear_remote_history_reference
  clear_workflow_state
  if ! capture_workflow_checkpoint; then
    error_message \
      "The connecting commit was created locally, but its final state could not be recorded. No upload was attempted." \
      "衔接提交已经在本机创建，但无法记录完成后的状态。脚本没有上传。"
    return 1
  fi
  success \
    "Remote and local history are now connected locally. Retrying the normal upload without force." \
    "远端历史与本机历史已经在本机完成衔接；现在重新进行普通上传，不会使用强制推送。"
  push_current_branch true no
}

explain_push_failure() {
  local output="$1"
  local branch="$2"
  local normalized=""

  normalized="$(lowercase "$output")"
  error_message \
    "The push did not complete. No force push was used, no remote history was overwritten, and any new commit remains safely in this local repository." \
    "本次上传没有完成。脚本没有强制推送，也没有覆盖远端历史；刚刚创建的提交仍安全保留在当前本地仓库中。"
  case "$normalized" in
    *non-fast-forward*|*fetch\ first*|*remote\ contains\ work\ that\ you\ do\ not*)
      muted \
        "GitHub has commits on $branch that are not in this local branch. You can use the option below to retain both histories and append the current local version, or leave both sides unchanged." \
        "GitHub 上的 ${branch} 分支包含本机尚未拥有的提交。你可以使用下方选项，在保留两边历史的同时追加当前本机版本；也可以不作处理，让两边保持原状。"
      ;;
    *permission\ denied*|*publickey*|*repository\ not\ found*|*write\ access*)
      muted \
        "GitHub rejected this repository or SSH identity. Open ./$SCRIPT_NAME menu, choose Advanced features, then verify the current project; also confirm that ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME} exists under account $BOUND_USERNAME." \
        "GitHub 拒绝了当前仓库或 SSH 身份。请运行 ./${SCRIPT_NAME} menu，进入“高级功能”后选择“联网核对当前项目”，并确认 ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME} 确实位于账号 ${BOUND_USERNAME} 名下。"
      ;;
    *could\ not\ resolve\ hostname*|*connection\ timed\ out*|*connection\ reset*|*network\ is\ unreachable*|*remote\ end\ hung\ up*)
      muted \
        "The connection to GitHub was interrupted or unavailable. Check the network and run ./$SCRIPT_NAME again; the existing local commit will be reused rather than recreated." \
        "本次连接 GitHub 时网络不可用或连接中断。请检查网络后重新运行 ./${SCRIPT_NAME}；现有本地提交会直接继续使用，不会重复创建。"
      ;;
    *)
      muted \
        "The Git output above contains the exact failure reported by the remote. Correct that condition and run ./$SCRIPT_NAME again; the script will not duplicate the local commit." \
        "上方 Git 返回信息包含远端报告的具体原因。处理后重新运行 ./${SCRIPT_NAME} 即可；脚本不会重复创建本地提交。"
      ;;
  esac
}

run_project_flow() (
  local preferred_username="${1:-}"
  local account_status=0
  local commit_status=0
  local push_status=0

  require_interactive
  require_core_commands
  locate_project yes
  acquire_workflow_lock || return 1
  install_workflow_cleanup_traps
  WORKFLOW_TRANSACTION_ACTIVE=true
  describe_and_validate_project_state || return 1
  ensure_script_excluded

  configure_project "$preferred_username" || account_status=$?
  if [ "$account_status" -eq 2 ]; then
    return 0
  elif [ "$account_status" -ne 0 ]; then
    return 1
  fi
  prepare_and_commit || commit_status=$?
  if [ "$commit_status" -eq 2 ]; then
    return 0
  elif [ "$commit_status" -eq 3 ]; then
    return 0
  elif [ "$commit_status" -ne 0 ]; then
    return 1
  fi
  push_current_branch "$WORKFLOW_COMMIT_CREATED_THIS_RUN" || push_status=$?
  if [ "$push_status" -eq 2 ]; then
    return 0
  fi
  return "$push_status"
)
