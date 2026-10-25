# -----------------------------------------------------------------------------
# Minimal menu and public commands
# -----------------------------------------------------------------------------

launcher_is_managed() {
  local launcher_file="$1"

  [ -f "$launcher_file" ] &&
    [ ! -L "$launcher_file" ] &&
    sed -n '1,8p' "$launcher_file" | grep -Eq '^# Managed git-auto project launcher\.' &&
    grep -Fxq 'exec bash "$ENGINE_PATH" "$@"' "$launcher_file" 2>/dev/null
}

shell_single_quoted_value() {
  local value="$1"

  printf "'"
  printf '%s' "$value" | sed "s/'/'\\\\''/g"
  printf "'"
}

write_private_launcher() {
  local public_launcher="$ENGINE_DIRECTORY/g.sh"
  local private_launcher="$PRIVATE_DIRECTORY/g.sh"
  local temporary_file=""
  local quoted_engine_path=""
  local line=""
  local replaced=false

  [ -f "$public_launcher" ] || return 1
  mkdir -p "$PRIVATE_DIRECTORY" || return 1
  temporary_file="$(safe_mktemp_file "$PRIVATE_DIRECTORY" "g.sh")" || return 1
  quoted_engine_path="$(shell_single_quoted_value "$ENGINE_PATH")"

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = 'DEFAULT_ENGINE_PATH=""' ]; then
      printf 'DEFAULT_ENGINE_PATH=%s\n' "$quoted_engine_path" >> "$temporary_file"
      replaced=true
    else
      printf '%s\n' "$line" >> "$temporary_file"
    fi
  done < "$public_launcher"

  if [ "$replaced" != true ] ||
     ! bash -n "$temporary_file" >/dev/null 2>&1 ||
     ! chmod 755 "$temporary_file" ||
     ! mv "$temporary_file" "$private_launcher"; then
    rm -f "$temporary_file"
    return 1
  fi
}

write_project_launcher() {
  local project_directory="$1"
  local launcher_file="$project_directory/g.sh"
  local temporary_file=""
  local project_git_root=""
  local saved_script_directory="$SCRIPT_DIRECTORY"
  local saved_script_name="$SCRIPT_NAME"
  local saved_git_root="${GIT_ROOT:-}"

  temporary_file="$(safe_mktemp_file "$project_directory" "g.sh")" || return 1
  if ! cp "$ENGINE_DIRECTORY/g.sh" "$temporary_file"; then
    rm -f "$temporary_file"
    return 1
  fi

  if ! bash -n "$temporary_file" >/dev/null 2>&1 ||
     ! chmod 755 "$temporary_file" ||
     ! mv "$temporary_file" "$launcher_file"; then
    rm -f "$temporary_file"
    return 1
  fi

  if project_git_root="$(git -C "$project_directory" rev-parse --show-toplevel 2>/dev/null)" &&
     [ "$project_git_root" -ef "$project_directory" ]; then
    SCRIPT_DIRECTORY="$project_directory"
    SCRIPT_NAME="g.sh"
    GIT_ROOT="$project_directory"
    ensure_script_excluded
    if ! git -C "$GIT_ROOT" config --local github-auto.engine "$ENGINE_PATH"; then
      SCRIPT_DIRECTORY="$saved_script_directory"
      SCRIPT_NAME="$saved_script_name"
      GIT_ROOT="$saved_git_root"
      return 1
    fi
  fi

  SCRIPT_DIRECTORY="$saved_script_directory"
  SCRIPT_NAME="$saved_script_name"
  GIT_ROOT="$saved_git_root"
  return 0
}

create_or_repair_project_launcher() {
  local default_directory="$SCRIPT_DIRECTORY"
  local input=""
  local project_directory=""
  local launcher_file=""

  require_interactive
  if [ "$SCRIPT_DIRECTORY" -ef "$ENGINE_DIRECTORY" ]; then
    default_directory=""
  fi

  heading "Create a project launcher" "创建项目启动器"
  muted \
    "Choose the project folder that should receive the lightweight g.sh file." \
    "请选择需要放置轻量级 g.sh 的项目文件夹。"
  while true; do
    input="$(ui_prompt_value "Project folder" "项目文件夹" "$default_directory")" || return 1
    if normalize_history_directory_input "$input"; then
      project_directory="$HISTORY_NORMALIZED_DIRECTORY"
      break
    fi
    warn "That folder could not be opened." "无法打开这个文件夹，请重新输入。"
  done

  if [ "$project_directory" -ef "$ENGINE_DIRECTORY" ]; then
    warn \
      "The central git-auto repository already contains its public, copy-ready g.sh, so no file was replaced." \
      "中央 git-auto 仓库已经包含公开且可直接复制的 g.sh，因此没有替换任何文件。"
    return 0
  fi

  launcher_file="$project_directory/g.sh"
  if { [ -e "$launcher_file" ] || [ -L "$launcher_file" ]; } &&
     ! launcher_is_managed "$launcher_file"; then
    warn \
      "This project already has a g.sh that cannot be confirmed as a regular git-auto launcher." \
      "这个项目已有 g.sh，但无法确认它是普通的 git-auto 启动器文件。"
    if ! ui_prompt_yes_no \
      "Replace it with the lightweight launcher?" \
      "要用新的轻量级启动器替换它吗？" \
      "no"; then
      return 0
    fi
  fi

  if ! write_project_launcher "$project_directory"; then
    fail \
      "The project launcher could not be created." \
      "无法创建项目启动器。"
  fi
  success \
    "Created the lightweight launcher: $launcher_file" \
    "已创建轻量启动器：$launcher_file"
  muted \
    "From now on, use ./g.sh, ./g.sh new, ./g.sh update, or ./g.sh menu in that project." \
    "以后在这个项目中直接使用 ./g.sh、./g.sh new、./g.sh update 或 ./g.sh menu。"
}

check_saved_account_identity() {
  local username="$1"
  local email="$2"
  local detail=""

  muted \
    "Checking SSH keys for GitHub account $username..." \
    "正在核对 GitHub 账号 $username 的 SSH 密钥……"
  if find_verified_identity_for_username "$username"; then
    ensure_username_alias_for_identity \
      "$username" "$FOUND_SSH_ALIAS" "$FOUND_IDENTITY_FILE" || return 1
    success \
      "GitHub accepted $(human_path "$FOUND_IDENTITY_FILE") as account $username through SSH Host $FOUND_SSH_ALIAS." \
      "GitHub 已确认密钥 $(human_path "$FOUND_IDENTITY_FILE") 属于账号 ${username}；对应的 SSH 主机名是 ${FOUND_SSH_ALIAS}。"
    return 0
  fi

  if [ -n "$FOUND_UNVERIFIED_IDENTITY_FILE" ]; then
    warn \
      "The key $(human_path "$FOUND_UNVERIFIED_IDENTITY_FILE") exists, but GitHub did not confirm it for account $username." \
      "密钥 $(human_path "$FOUND_UNVERIFIED_IDENTITY_FILE") 确实存在，但 GitHub 暂时没有确认它属于账号 ${username}。"
    detail="${SSH_VERIFICATION_OUTPUT##*$'\n'}"
    if [ -n "$detail" ]; then
      muted "SSH result: $detail" "SSH 返回信息：$detail"
    fi
    if ui_prompt_yes_no \
      "Verify this existing key with GitHub one more time?" \
      "要再用这把现有密钥向 GitHub 核对一次账号吗？" \
      "yes"; then
      if identify_key_username "$FOUND_UNVERIFIED_IDENTITY_FILE" &&
         [ "$(lowercase "$VERIFIED_GITHUB_USERNAME")" = "$(lowercase "$username")" ]; then
        FOUND_SSH_ALIAS="$FOUND_UNVERIFIED_SSH_ALIAS"
        FOUND_IDENTITY_FILE="$FOUND_UNVERIFIED_IDENTITY_FILE"
        ensure_username_alias_for_identity \
          "$username" "$FOUND_SSH_ALIAS" "$FOUND_IDENTITY_FILE" || return 1
        success \
          "GitHub confirmed that the existing key belongs to account $username." \
          "GitHub 已确认这把现有密钥属于账号 ${username}。"
        return 0
      fi
    fi
  else
    warn \
      "No local SSH private key inspected by this Advanced check was accepted by GitHub for account $username." \
      "高级核对已经检查本机可识别的 SSH 私钥，但 GitHub 没有确认其中任何一把属于账号 $username。"
  fi

  next_available_alias "$username" || return 1
  muted \
    "Creating another key will add private key $(human_path "$NEW_IDENTITY_FILE") and SSH Host $NEW_SSH_ALIAS; existing keys and Host entries will remain unchanged." \
    "如果新建，将增加私钥 $(human_path "$NEW_IDENTITY_FILE") 和 SSH 主机名 ${NEW_SSH_ALIAS}；已有密钥和主机配置不会被删除或覆盖。"
  if ! ui_prompt_yes_no \
    "Create and verify this separate SSH key for account $username?" \
    "要为账号 $username 创建并验证这把独立的 SSH 密钥吗？" \
    "no"; then
    warn \
      "No new SSH key was created for account $username." \
      "没有为账号 $username 创建新的 SSH 密钥。"
    return 1
  fi
  create_new_identity "$username" "$email" || return 1
  verify_key_matches_username "$FOUND_IDENTITY_FILE" "$username"
}

import_existing_accounts_online() {
  local index=0
  local username=""
  local email=""
  local imported=0

  require_core_commands
  heading "Discover GitHub accounts through SSH" "通过 SSH 识别现有 GitHub 账号"
  muted \
    "This advanced action contacts GitHub once for each distinct key found through local SSH settings and conventional ~/.ssh/id_* files, then offers to import confirmed accounts." \
    "这项高级操作会用本机 SSH 设置和常见 ~/.ssh/id_* 文件中找到的每一把不同密钥分别连接 GitHub，再询问是否导入已经确认的账号。"
  discover_verified_github_identities || return 1
  while [ "$index" -lt "$VERIFIED_IDENTITY_COUNT" ]; do
    username="${VERIFIED_IDENTITY_USERNAMES[$index]}"
    if account_index "$username" >/dev/null 2>&1; then
      success \
        "Account $username is already saved." \
        "账号 ${username} 已经保存在 private/config.txt 中。"
    elif ui_prompt_yes_no \
      "Import account $username and this verified key?" \
      "要导入账号 ${username} 及这把已经核对的密钥吗？" \
      "yes"; then
      email="$(prompt_account_email "$username")" || return 1
      FOUND_SSH_ALIAS="${VERIFIED_IDENTITY_ALIASES[$index]}"
      FOUND_IDENTITY_FILE="${VERIFIED_IDENTITY_FILES[$index]}"
      ensure_username_alias_for_identity \
        "$username" "$FOUND_SSH_ALIAS" "$FOUND_IDENTITY_FILE" || return 1
      register_account_and_identity \
        "$username" "$email" "$FOUND_SSH_ALIAS" "$FOUND_IDENTITY_FILE"
      imported=$((imported + 1))
    fi
    index=$((index + 1))
  done
  success \
    "Imported $imported new account(s)." \
    "本次共导入 ${imported} 个新账号。"
}

check_private_accounts() {
  local index=0
  local username=""
  local email=""
  local missing_count=0

  require_core_commands
  heading "Verify saved GitHub SSH keys" "核对已保存账号的 SSH 密钥"
  if [ "$ACCOUNT_COUNT" -eq 0 ]; then
    warn "No GitHub account has been added yet." "还没有添加 GitHub 账号。"
    muted \
      "Use Add GitHub account first, then return to this advanced online check if needed." \
      "请先使用“添加 GitHub 账号”；如有需要，再回到这里执行高级联网核对。"
    return 0
  fi

  while [ "$index" -lt "$ACCOUNT_COUNT" ]; do
    username="${ACCOUNT_USERNAMES[$index]}"
    email="${ACCOUNT_EMAILS[$index]}"
    if ! check_saved_account_identity "$username" "$email"; then
      missing_count=$((missing_count + 1))
    fi
    index=$((index + 1))
  done

  if [ "$missing_count" -eq 0 ]; then
    success \
      "GitHub accepted an SSH key for every saved account." \
      "GitHub 已分别确认每个已保存账号对应的 SSH 密钥。"
  else
    warn \
      "$missing_count saved account(s) still have no SSH key verified by GitHub." \
      "仍有 $missing_count 个已保存账号没有通过 GitHub 验证的 SSH 密钥。"
  fi
}

run_central_menu() {
  local choice=""

  require_interactive
  while true; do
    heading "Auto Script for GitHub Setup and Push" \
      "Auto Script for GitHub Setup and Push"
    muted "by Songming.org in 2026" "by Songming.org in 2026"
    muted \
      "Central engine: $ENGINE_PATH" \
      "中央脚本：$ENGINE_PATH"
    if [ "$UI_LANGUAGE" = "zh" ]; then
      printf '  1) 为项目创建或修复 g.sh\n'
      printf '  2) 添加 GitHub 账号\n'
      printf '  3) 界面语言\n'
      printf '  4) 显示模式\n'
      printf '  5) 高级功能\n'
      printf '  0) 退出\n'
    else
      printf '  1) Create or repair a project g.sh\n'
      printf '  2) Add a GitHub account\n'
      printf '  3) Interface language\n'
      printf '  4) Display mode\n'
      printf '  5) Advanced features\n'
      printf '  0) Exit\n'
    fi

    choice="$(ui_prompt_value "Choose" "选择" "1")" || return 1
    case "$choice" in
      1)
        create_or_repair_project_launcher || true
        pause_for_user
        ;;
      2)
        run_account_setup || true
        pause_for_user
        ;;
      3)
        language_menu || true
        ;;
      4)
        appearance_menu || true
        ;;
      5)
        run_advanced_menu || true
        ;;
      0)
        return 0
        ;;
      *)
        warn "Enter a number from the list." "请输入列表中的序号。"
        ;;
    esac
  done
}

theme_label() {
  case "$1" in
    auto)
      localized_text "Automatic" "自动"
      ;;
    dark)
      localized_text "Dark" "深色"
      ;;
    light)
      localized_text "Light" "浅色"
      ;;
    none)
      localized_text "No color" "无颜色"
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

save_theme_preference() {
  local preference="$1"

  if ! save_private_config "$(read_saved_language)" "$preference"; then
    fail \
      "The display preference could not be saved in private/config.txt." \
      "无法把显示偏好保存到 private/config.txt。"
  fi
  apply_theme "$preference"
}

appearance_menu() {
  local choice=""
  local selected=""

  while true; do
    heading "Display mode" "显示模式"
    muted \
      "Current: $(theme_label "$(read_saved_theme)")" \
      "当前：$(theme_label "$(read_saved_theme)")"
    if [ "$UI_LANGUAGE" = "zh" ]; then
      printf '  1) 自动（推荐）\n'
      printf '  2) 深色\n'
      printf '  3) 浅色\n'
      printf '  4) 无颜色\n'
      printf '  0) 返回\n'
    else
      printf '  1) Automatic (recommended)\n'
      printf '  2) Dark\n'
      printf '  3) Light\n'
      printf '  4) No color\n'
      printf '  0) Return\n'
    fi

    choice="$(ui_prompt_value "Choose" "选择" "1")" || return 1
    case "$choice" in
      1)
        selected="auto"
        ;;
      2)
        selected="dark"
        ;;
      3)
        selected="light"
        ;;
      4)
        selected="none"
        ;;
      0)
        return 0
        ;;
      *)
        warn "Enter a number from the list." "请输入列表中的序号。"
        continue
        ;;
    esac

    save_theme_preference "$selected"
    success \
      "Display mode set to: $(theme_label "$selected")" \
      "显示模式已设为：$(theme_label "$selected")"
    return 0
  done
}

language_menu() {
  local status=0

  choose_interface_language yes || status=$?
  if [ "$status" -eq 2 ]; then
    return 0
  elif [ "$status" -ne 0 ]; then
    return 1
  fi

  ADVANCED_LANGUAGE="$UI_LANGUAGE"
  success \
    "Interface language set to English." \
    "界面语言已设为中文。"
}

bind_project_owner() (
  require_core_commands
  if ! locate_project no; then
    warn "The current folder is not a Git project." "当前文件夹还不是 Git 项目。"
    return 1
  fi
  acquire_workflow_lock || return 1
  install_workflow_cleanup_traps
  if ! read_origin_repository; then
    warn \
      "The current project does not have a recognizable GitHub repository." \
      "当前项目还没有可识别的 GitHub 仓库。"
    return 1
  fi
  configure_project "" bind || return 1
  success \
    "This project uses its owner account, ${CURRENT_REPOSITORY_OWNER}." \
    "当前项目使用仓库所属账号 ${CURRENT_REPOSITORY_OWNER}。"
)

check_local_project_binding() (
  local username=""

  require_core_commands
  heading "Check this project's local GitHub settings" "核对当前项目的本机 GitHub 设置"

  if locate_project no; then
    acquire_workflow_lock || return 1
    install_workflow_cleanup_traps
    success \
      "Existing Git repository detected: $(human_path "$GIT_ROOT"). git init will not run." \
      "已识别现有 Git 仓库：$(human_path "$GIT_ROOT")。不会执行 git init。"
    if read_origin_repository; then
      muted \
        "Current repository: ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}" \
        "当前仓库：${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}"
      if load_established_project_binding; then
        success \
          "The current project has a complete local binding for owner account $BOUND_USERNAME and its exact SSH key." \
          "当前项目已经完整绑定仓库所属账号 ${BOUND_USERNAME} 及其指定 SSH 密钥。"
      else
        username="$(git -C "$GIT_ROOT" config --local --get github-auto.username 2>/dev/null || true)"
        if [ -n "$username" ] &&
           [ "$(lowercase "$username")" != "$(lowercase "$CURRENT_REPOSITORY_OWNER")" ]; then
          warn \
            "This repository is saved with account $username, but its GitHub owner is $CURRENT_REPOSITORY_OWNER. The mismatched account will not be used." \
            "当前仓库保存的账号是 ${username}，但 GitHub 仓库属于 ${CURRENT_REPOSITORY_OWNER}。脚本不会继续使用这个不匹配的账号。"
        elif ! account_index "$CURRENT_REPOSITORY_OWNER" >/dev/null 2>&1; then
          warn \
            "Repository owner $CURRENT_REPOSITORY_OWNER has not been added to private/config.txt." \
            "private/config.txt 中还没有保存仓库所属账号 ${CURRENT_REPOSITORY_OWNER}。"
        else
          warn \
            "The project-local owner, SSH key, or origin binding is missing or inconsistent." \
            "当前项目保存的所属账号、SSH 密钥或 origin 绑定缺失，或者彼此不一致。"
        fi
        muted \
          "Repair uses repository owner $CURRENT_REPOSITORY_OWNER and changes only local account, SSH key, and origin settings. It does not contact GitHub." \
          "修复时会固定使用仓库所属账号 ${CURRENT_REPOSITORY_OWNER}，只调整本机保存的账号、SSH 密钥和 origin 设置，不会连接 GitHub。"
        if ui_prompt_yes_no \
          "Repair this project's local owner binding now?" \
          "现在修复当前项目的本机所属账号绑定吗？" \
          "yes"; then
          configure_project "" bind || return 1
        fi
      fi
    else
      warn \
        "This Git repository has no origin that identifies a GitHub repository." \
        "这个 Git 仓库还没有能够识别为 GitHub 仓库的 origin。"
    fi
  else
    muted \
      "The current folder is not a Git repository; this local check did not run git init." \
      "当前文件夹还不是 Git 仓库；本次本机检查不会执行 git init。"
  fi
)

verify_current_project_online() {
  require_core_commands
  heading "Verify the current project with GitHub" "联网核对当前项目"
  muted \
    "This advanced diagnostic runs SSH authentication and a read-only remote check. It does not commit, push, or change the repository." \
    "这项高级诊断会执行 SSH 身份验证和远端只读检查，但不会提交、上传或修改仓库。"
  if ! locate_project no || ! read_origin_repository; then
    error_message \
      "The current folder has no recognizable GitHub project." \
      "当前文件夹中没有可识别的 GitHub 项目。"
    return 1
  fi
  if ! load_established_project_binding; then
    error_message \
      "The local owner/key/origin binding is incomplete. Use the main menu's local project check first." \
      "当前项目的本机所属账号、密钥或 origin 绑定还不完整。请先使用主菜单中的本机项目检查。"
    return 1
  fi
  verify_key_matches_username "$BOUND_IDENTITY_FILE" "$BOUND_USERNAME" || return 1
  verify_repository_access yes origin
}

run_new_command() {
  local account_ready=false
  local project_owner_required=false
  local index=""
  local email=""

  require_core_commands
  if locate_project no && read_origin_repository; then
    project_owner_required=true
    if index="$(account_index "$CURRENT_REPOSITORY_OWNER" 2>/dev/null)"; then
      SELECTED_USERNAME="${ACCOUNT_USERNAMES[$index]}"
      SELECTED_EMAIL="${ACCOUNT_EMAILS[$index]}"
      account_ready=true
      info \
        "This repository belongs to saved account $SELECTED_USERNAME, so no account choice is needed." \
        "当前仓库属于已保存账号 ${SELECTED_USERNAME}，无需再选择其他账号。"
    else
      heading \
        "Add the account that owns this repository" \
        "添加当前仓库所属的 GitHub 账号"
      muted \
        "The repository is ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}. To prevent accounts from being mixed, this project can add and use only account $CURRENT_REPOSITORY_OWNER." \
        "当前仓库是 ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}。为避免多个账号相互串用，这个项目只能添加并使用账号 ${CURRENT_REPOSITORY_OWNER}。"
      email="$(prompt_account_email "$CURRENT_REPOSITORY_OWNER")" || return 1
      setup_or_reuse_account "$CURRENT_REPOSITORY_OWNER" "$email" || return 1
      account_ready=true
    fi
  fi

  if [ "$account_ready" = false ]; then
    if [ "$project_owner_required" = true ]; then
      return 1
    fi
    if ! run_account_setup; then
      return 1
    fi
  fi

  if ui_prompt_yes_no \
    "Use account $SELECTED_USERNAME for this project, review its changes, commit them, and push its current branch?" \
    "要使用账号 $SELECTED_USERNAME 核对当前项目、检查改动、创建提交并上传当前分支吗？" \
    "yes"; then
    run_project_flow "$SELECTED_USERNAME"
  else
    success \
      "The account and commit email were saved. The current project was not changed or pushed." \
      "账号和提交邮箱已经保存；当前项目没有被修改，也没有上传。"
  fi
}

run_menu() {
  local choice=""

  require_interactive
  while true; do
    heading "Auto Script for GitHub Setup and Push"
    muted "by Songming.org in 2026" "by Songming.org in 2026"
    if [ "$UI_LANGUAGE" = "zh" ]; then
      printf '  1) 提交并上传当前项目\n'
      printf '  2) 添加 GitHub 账号\n'
      printf '  3) 绑定当前项目的所属账号\n'
      printf '  4) 同步用户名或仓库改名\n'
      printf '  5) 核对当前项目的本机设置\n'
      printf '  6) 界面语言\n'
      printf '  7) 显示模式\n'
      printf '  8) 高级功能\n'
      printf '  0) 退出\n'
    else
      printf '  1) Commit and push the current project\n'
      printf '  2) Add a GitHub account\n'
      printf '  3) Bind the current project to its owner\n'
      printf '  4) Sync a renamed username or repository\n'
      printf '  5) Check this project locally\n'
      printf '  6) Interface language\n'
      printf '  7) Display mode\n'
      printf '  8) Advanced features\n'
      printf '  0) Exit\n'
    fi

    choice="$(ui_prompt_value "Choose" "选择" "1")" || return 1
    case "$choice" in
      1)
        run_project_flow
        return
        ;;
      2)
        run_new_command
        return
        ;;
      3)
        bind_project_owner || true
        pause_for_user
        ;;
      4)
        run_update_command || true
        advanced_pause
        ;;
      5)
        check_local_project_binding || true
        pause_for_user
        ;;
      6)
        language_menu || true
        ;;
      7)
        appearance_menu || true
        ;;
      8)
        run_advanced_menu || true
        ;;
      0)
        return 0
        ;;
      *)
        warn "Enter a number from the list." "请输入列表中的序号。"
        ;;
    esac
  done
}

show_usage() {
  if [ "$UI_LANGUAGE" = "zh" ]; then
    printf '用法：\n'
    printf '  ./%s         提交并上传当前项目\n' "$SCRIPT_NAME"
    printf '  ./%s new     添加 GitHub 账号\n' "$SCRIPT_NAME"
    printf '  ./%s update  同步用户名或仓库改名\n' "$SCRIPT_NAME"
    printf '  ./%s menu    打开菜单\n' "$SCRIPT_NAME"
  else
    printf 'Usage:\n'
    printf '  ./%s         Commit and push the current project\n' "$SCRIPT_NAME"
    printf '  ./%s new     Add a GitHub account\n' "$SCRIPT_NAME"
    printf '  ./%s update  Sync a renamed username or repository\n' "$SCRIPT_NAME"
    printf '  ./%s menu    Open the menu\n' "$SCRIPT_NAME"
  fi
}

show_central_usage() {
  if [ "$UI_LANGUAGE" = "zh" ]; then
    printf '用法：\n'
    printf '  ./%s         打开中央管理菜单\n' "$ENGINE_NAME"
    printf '  ./%s new     添加 GitHub 账号\n' "$ENGINE_NAME"
    printf '  ./%s menu    打开中央管理菜单\n' "$ENGINE_NAME"
  else
    printf 'Usage:\n'
    printf '  ./%s         Open the central management menu\n' "$ENGINE_NAME"
    printf '  ./%s new     Add a GitHub account\n' "$ENGINE_NAME"
    printf '  ./%s menu    Open the central management menu\n' "$ENGINE_NAME"
  fi
}

main() {
  local command_name="${1:-push}"
  local at_engine_home=false

  initialize_language || return 1
  ADVANCED_LANGUAGE="$UI_LANGUAGE"

  if [ "$RUNNING_FROM_LAUNCHER" != "1" ] &&
     [ "$SCRIPT_DIRECTORY" -ef "$ENGINE_DIRECTORY" ]; then
    at_engine_home=true
    command_name="${1:-menu}"
  fi

  if [ "$#" -gt 1 ]; then
    if [ "$at_engine_home" = true ]; then
      show_central_usage
    else
      show_usage
    fi
    return 1
  fi

  if [ "$at_engine_home" = true ]; then
    case "$command_name" in
      menu)
        run_central_menu
        ;;
      new)
        run_account_setup
        ;;
      *)
        show_central_usage
        return 1
        ;;
    esac
    return
  fi

  case "$command_name" in
    push)
      run_project_flow
      ;;
    new)
      run_new_command
      ;;
    update)
      run_update_command
      ;;
    menu)
      run_menu
      ;;
    *)
      show_usage
      return 1
      ;;
  esac
}
