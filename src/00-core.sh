# -----------------------------------------------------------------------------
# Small utilities
# -----------------------------------------------------------------------------

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

trim() {
  printf '%s' "$1" |
    sed -E \
      -e 's/^[[:space:]]+//' \
      -e 's/[[:space:]]+$//'
}

repeat_character() {
  local character="$1"
  local count="$2"
  local result=""

  while [ "$count" -gt 0 ]; do
    result="$result$character"
    count=$((count - 1))
  done

  printf '%s' "$result"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_interactive() {
  if [ ! -t 0 ]; then
    fail \
      "Run this command in an interactive terminal." \
      "请在交互式终端中运行这个命令。"
  fi
}

safe_mktemp_file() {
  local directory="$1"
  local prefix="$2"

  mktemp "$directory/.${prefix}.XXXXXX"
}

safe_mktemp_directory() {
  mktemp -d "${TMPDIR:-/tmp}/github-auto.XXXXXX"
}

ensure_private_config() {
  local temporary_file=""

  if ! mkdir -p "$PRIVATE_DIRECTORY" || ! chmod 700 "$PRIVATE_DIRECTORY"; then
    printf '%s\n' "[Error] Could not prepare the private configuration directory: $PRIVATE_DIRECTORY" >&2
    return 1
  fi

  if [ ! -f "$PRIVATE_CONFIG_FILE" ]; then
    temporary_file="$(safe_mktemp_file "$PRIVATE_DIRECTORY" "config")" || return 1
    {
      printf '# Auto Script for GitHub Setup and Push - private configuration\n'
      printf 'language:\n'
      printf 'display-theme: auto\n'
      printf '\n'
      printf '# GitHub accounts: one field per line, with a blank line between accounts.\n'
    } > "$temporary_file"
    chmod 600 "$temporary_file" || {
      rm -f "$temporary_file"
      return 1
    }
    mv "$temporary_file" "$PRIVATE_CONFIG_FILE" || {
      rm -f "$temporary_file"
      return 1
    }
  fi

  chmod 600 "$PRIVATE_CONFIG_FILE" || return 1
}

ensure_option_config() {
  local option_directory="${OPTION_CONFIG_FILE%/*}"
  local temporary_file=""

  if [ -f "$OPTION_CONFIG_FILE" ]; then
    return 0
  fi

  [ -d "$option_directory" ] || return 1
  temporary_file="$(safe_mktemp_file "$option_directory" "option")" || return 1
  : > "$temporary_file"
  chmod 644 "$temporary_file" || {
    rm -f "$temporary_file"
    return 1
  }
  mv "$temporary_file" "$OPTION_CONFIG_FILE" || {
    rm -f "$temporary_file"
    return 1
  }
}

ensure_private_config || exit 1
ensure_option_config || {
  printf '%s\n' "[Error] Could not prepare the option configuration file: $OPTION_CONFIG_FILE" >&2
  exit 1
}

file_mode() {
  local file="$1"

  if stat -f '%Lp' "$file" >/dev/null 2>&1; then
    stat -f '%Lp' "$file"
  else
    stat -c '%a' "$file"
  fi
}

human_path() {
  local path="$1"

  case "$path" in
    "${HOME:-}"/*)
      printf '~/%s' "${path#"${HOME:-}"/}"
      ;;
    *)
      printf '%s' "$path"
      ;;
  esac
}

expand_home_path() {
  local path="$1"

  case "$path" in
    '~')
      printf '%s' "${HOME:-}"
      ;;
    '~/'*)
      printf '%s/%s' "${HOME:-}" "${path#\~/}"
      ;;
    '%d/'*)
      printf '%s/%s' "${HOME:-}" "${path#%d/}"
      ;;
    *)
      printf '%s' "$path"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Theme and accessible colors
# -----------------------------------------------------------------------------

THEME="none"
COLOR_RESET=""
COLOR_HEADING=""
COLOR_INFO=""
COLOR_SUCCESS=""
COLOR_WARNING=""
COLOR_ERROR=""
COLOR_MUTED=""

read_saved_theme() {
  local line=""
  local value=""

  line="$(grep -m 1 -F "$THEME_FIELD_PREFIX" "$PRIVATE_CONFIG_FILE" 2>/dev/null || true)"
  value="$(trim "${line#"$THEME_FIELD_PREFIX"}")"
  value="$(lowercase "$value")"

  case "$value" in
    auto|dark|light|none)
      printf '%s' "$value"
      ;;
    *)
      printf 'auto'
      ;;
  esac
}

detect_automatic_theme() {
  local background=""
  local style=""

  if [ -n "${COLORFGBG:-}" ]; then
    background="${COLORFGBG##*;}"
    case "$background" in
      7|15)
        printf 'light'
        return
        ;;
      0|1|2|3|4|5|6|8)
        printf 'dark'
        return
        ;;
    esac
  fi

  if [ "$(uname -s 2>/dev/null || true)" = "Darwin" ] && command_exists defaults; then
    style="$(defaults read -g AppleInterfaceStyle 2>/dev/null || true)"
    if [ "$(lowercase "$(trim "$style")")" = "dark" ]; then
      printf 'dark'
    else
      printf 'light'
    fi
    return
  fi

  # A conservative dark-terminal fallback is preferable to low-contrast blue.
  printf 'dark'
}

apply_theme() {
  local requested

  requested="${1:-auto}"

  if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ] || [ ! -t 1 ]; then
    requested="none"
  elif [ "$requested" = "auto" ]; then
    requested="$(detect_automatic_theme)"
  fi

  THEME="$requested"
  COLOR_RESET='\033[0m'

  case "$THEME" in
    dark)
      COLOR_HEADING='\033[38;5;255m'
      COLOR_INFO='\033[38;5;116m'
      COLOR_SUCCESS='\033[38;5;114m'
      COLOR_WARNING='\033[38;5;222m'
      COLOR_ERROR='\033[38;5;217m'
      COLOR_MUTED='\033[38;5;250m'
      ;;
    light)
      COLOR_HEADING='\033[1;30m'
      COLOR_INFO='\033[0;34m'
      COLOR_SUCCESS='\033[0;32m'
      COLOR_WARNING='\033[0;35m'
      COLOR_ERROR='\033[0;31m'
      COLOR_MUTED='\033[0;90m'
      ;;
    *)
      THEME="none"
      COLOR_RESET=""
      COLOR_HEADING=""
      COLOR_INFO=""
      COLOR_SUCCESS=""
      COLOR_WARNING=""
      COLOR_ERROR=""
      COLOR_MUTED=""
      ;;
  esac
}

apply_theme "$(read_saved_theme)"

# -----------------------------------------------------------------------------
# Persistent interface language
# -----------------------------------------------------------------------------

read_saved_language() {
  local line=""
  local value=""

  line="$(grep -m 1 -F "$LANGUAGE_FIELD_PREFIX" "$PRIVATE_CONFIG_FILE" 2>/dev/null || true)"
  value="$(trim "${line#"$LANGUAGE_FIELD_PREFIX"}")"
  value="$(lowercase "$value")"

  case "$value" in
    en|zh)
      printf '%s' "$value"
      ;;
  esac
}

save_language_preference() {
  save_private_config "$1" "$(read_saved_theme)"
}

choose_interface_language() {
  local allow_return="${1:-no}"
  local choice=""
  local default_choice="1"

  [ "$UI_LANGUAGE" = "zh" ] && default_choice="2"
  printf '\n'
  print_colored "$COLOR_HEADING" "Choose interface language / 选择界面语言"
  printf '  1) English\n'
  printf '  2) 中文\n'
  if [ "$allow_return" = "yes" ]; then
    printf '  0) Return / 返回\n'
  fi

  while true; do
    choice="$(prompt_value "Language / 语言" "$default_choice")" || return 1
    case "$choice" in
      1)
        UI_LANGUAGE="en"
        break
        ;;
      2)
        UI_LANGUAGE="zh"
        break
        ;;
      0)
        if [ "$allow_return" = "yes" ]; then
          return 2
        fi
        ;;
    esac
    print_colored "$COLOR_WARNING" "[Notice / 注意] Enter a listed number / 请输入列表中的序号。"
  done

  if ! save_language_preference "$UI_LANGUAGE"; then
    print_colored "$COLOR_WARNING" "[Notice / 注意] The language preference could not be saved in private/config.txt / 无法把语言偏好保存到 private/config.txt。"
  fi
  return 0
}

initialize_language() {
  local saved_language=""

  saved_language="$(read_saved_language)"
  if [ -n "$saved_language" ]; then
    UI_LANGUAGE="$saved_language"
    return 0
  fi

  if [ -t 0 ] && [ -t 1 ]; then
    choose_interface_language no
  else
    UI_LANGUAGE="en"
  fi
}

INITIAL_SAVED_LANGUAGE="$(read_saved_language)"
if [ -n "$INITIAL_SAVED_LANGUAGE" ]; then
  UI_LANGUAGE="$INITIAL_SAVED_LANGUAGE"
fi
unset INITIAL_SAVED_LANGUAGE

localized_text() {
  local english_text="$1"
  local chinese_text="${2:-$1}"

  if [ "$UI_LANGUAGE" = "zh" ]; then
    printf '%s' "$chinese_text"
  else
    printf '%s' "$english_text"
  fi
}

print_colored() {
  local color="$1"
  local text="$2"
  local destination="${3:-stdout}"

  if [ "$destination" = "stderr" ]; then
    printf '%b%s%b\n' "$color" "$text" "$COLOR_RESET" >&2
  else
    printf '%b%s%b\n' "$color" "$text" "$COLOR_RESET"
  fi
}

heading() {
  printf '\n'
  print_colored "$COLOR_HEADING" "$(localized_text "$1" "${2:-$1}")"
}

info() {
  if [ "$UI_LANGUAGE" = "zh" ]; then
    print_colored "$COLOR_INFO" "[信息] ${2:-$1}"
  else
    print_colored "$COLOR_INFO" "[Info] $1"
  fi
}

success() {
  if [ "$UI_LANGUAGE" = "zh" ]; then
    print_colored "$COLOR_SUCCESS" "[完成] ${2:-$1}"
  else
    print_colored "$COLOR_SUCCESS" "[Done] $1"
  fi
}

warn() {
  if [ "$UI_LANGUAGE" = "zh" ]; then
    print_colored "$COLOR_WARNING" "[注意] ${2:-$1}"
  else
    print_colored "$COLOR_WARNING" "[Notice] $1"
  fi
}

error_message() {
  if [ "$UI_LANGUAGE" = "zh" ]; then
    print_colored "$COLOR_ERROR" "[错误] ${2:-$1}" stderr
  else
    print_colored "$COLOR_ERROR" "[Error] $1" stderr
  fi
}

muted() {
  print_colored "$COLOR_MUTED" "$(localized_text "$1" "${2:-$1}")"
}

github_target_summary() {
  local style="$1"
  local account="$2"
  local owner="$3"
  local repository="$4"

  if [ "$style" = "advanced" ]; then
    advanced_muted "GitHub account: $account" "GitHub 账号：$account"
    advanced_muted \
      "GitHub repository: $owner/$repository" \
      "GitHub 仓库：$owner/$repository"
  else
    muted "GitHub account: $account" "GitHub 账号：$account"
    muted \
      "GitHub repository: $owner/$repository" \
      "GitHub 仓库：$owner/$repository"
  fi

}

fail() {
  error_message "$1" "${2:-$1}"
  exit 1
}

ui_prompt_value() {
  local english_label="$1"
  local chinese_label="$2"
  local default_value="${3:-}"

  prompt_value "$(localized_text "$english_label" "$chinese_label")" "$default_value"
}

ui_prompt_yes_no() {
  local english_label="$1"
  local chinese_label="$2"
  local default_answer="${3:-yes}"

  prompt_yes_no "$(localized_text "$english_label" "$chinese_label")" "$default_answer"
}

prompt_value() {
  local label="$1"
  local default_value="${2:-}"
  local answer=""

  if [ -n "$default_value" ]; then
    printf '%b%s [%s]: %b' "$COLOR_INFO" "$label" "$default_value" "$COLOR_RESET" >&2
  else
    printf '%b%s: %b' "$COLOR_INFO" "$label" "$COLOR_RESET" >&2
  fi

  IFS= read -r answer || return 1
  answer="$(trim "$answer")"

  if [ -z "$answer" ]; then
    answer="$default_value"
  fi

  printf '%s' "$answer"
}

prompt_yes_no() {
  local label="$1"
  local default_answer="${2:-yes}"
  local hint="[Y/n]"
  local answer=""

  if [ "$UI_LANGUAGE" = "zh" ]; then
    if [ "$default_answer" = "no" ]; then
      hint="[是(y)/否(N)，默认否]"
    else
      hint="[是(Y)/否(n)，默认是]"
    fi
  elif [ "$default_answer" = "no" ]; then
    hint="[y/N]"
  fi

  while true; do
    printf '%b%s %s: %b' "$COLOR_INFO" "$label" "$hint" "$COLOR_RESET"
    IFS= read -r answer || return 1
    answer="$(lowercase "$(trim "$answer")")"

    if [ -z "$answer" ]; then
      [ "$default_answer" = "yes" ]
      return
    fi

    case "$answer" in
      y|yes|是|好|好的)
        return 0
        ;;
      n|no|否|不)
        return 1
        ;;
      *)
        warn \
          "Enter y or n. Press Enter to use the recommended option." \
          "请输入 y 或 n；直接按 Enter 使用推荐选项。"
        ;;
    esac
  done
}

pause_for_user() {
  local english_label="${1:-Press Enter to continue}"
  local chinese_label="${2:-按 Enter 继续}"
  local ignored=""

  printf '%b%s%b' "$COLOR_INFO" "$(localized_text "$english_label" "$chinese_label")" "$COLOR_RESET"
  IFS= read -r ignored || true
}

# -----------------------------------------------------------------------------
# Human-editable private configuration
# -----------------------------------------------------------------------------

ACCOUNT_USERNAMES=()
ACCOUNT_EMAILS=()
ACCOUNT_COUNT=0
PAGED_CHOICE_LETTERS="abcdefghjkmnpr"
PAGED_CHOICE_PAGE_SIZE=$((8 + ${#PAGED_CHOICE_LETTERS}))
PAGED_CHOICE_INDEX=-1

valid_github_username() {
  local username="$1"

  if ! [[ "$username" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]]; then
    return 1
  fi

  case "$username" in
    *-)
      return 1
      ;;
  esac

  return 0
}

valid_email() {
  local email="$1"

  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

account_index() {
  local username_lc
  local index=0

  username_lc="$(lowercase "$1")"
  while [ "$index" -lt "$ACCOUNT_COUNT" ]; do
    if [ "$(lowercase "${ACCOUNT_USERNAMES[$index]}")" = "$username_lc" ]; then
      printf '%s' "$index"
      return 0
    fi
    index=$((index + 1))
  done

  return 1
}

sort_accounts_alphabetically() {
  local index=0
  local candidate=0
  local selected=0
  local candidate_name=""
  local selected_name=""
  local temporary=""

  while [ "$index" -lt $((ACCOUNT_COUNT - 1)) ]; do
    selected="$index"
    candidate=$((index + 1))
    while [ "$candidate" -lt "$ACCOUNT_COUNT" ]; do
      candidate_name="$(lowercase "${ACCOUNT_USERNAMES[$candidate]}")"
      selected_name="$(lowercase "${ACCOUNT_USERNAMES[$selected]}")"
      if [[ "$candidate_name" < "$selected_name" ]]; then
        selected="$candidate"
      fi
      candidate=$((candidate + 1))
    done

    if [ "$selected" -ne "$index" ]; then
      temporary="${ACCOUNT_USERNAMES[$index]}"
      ACCOUNT_USERNAMES[$index]="${ACCOUNT_USERNAMES[$selected]}"
      ACCOUNT_USERNAMES[$selected]="$temporary"
      temporary="${ACCOUNT_EMAILS[$index]}"
      ACCOUNT_EMAILS[$index]="${ACCOUNT_EMAILS[$selected]}"
      ACCOUNT_EMAILS[$selected]="$temporary"
    fi
    index=$((index + 1))
  done
}

append_loaded_account() {
  local username="$1"
  local email="$2"

  if ! valid_github_username "$username"; then
    fail \
      "Invalid GitHub username in the account list: $username" \
      "账号列表中的 GitHub 用户名无效：$username"
  fi

  if ! valid_email "$email"; then
    fail \
      "Invalid email for account $username: $email" \
      "账号 $username 的邮箱格式无效：$email"
  fi

  if account_index "$username" >/dev/null 2>&1; then
    fail \
      "Duplicate username in the account list: $username" \
      "账号列表中存在重复用户名：$username"
  fi

  ACCOUNT_USERNAMES[$ACCOUNT_COUNT]="$username"
  ACCOUNT_EMAILS[$ACCOUNT_COUNT]="$email"
  ACCOUNT_COUNT=$((ACCOUNT_COUNT + 1))
}

load_accounts() {
  local line=""
  local content=""
  local value=""
  local pending_username=""
  local pending_email=""

  ACCOUNT_USERNAMES=()
  ACCOUNT_EMAILS=()
  ACCOUNT_COUNT=0

  while IFS= read -r line || [ -n "$line" ]; do
    content="$(trim "$line")"
    if [ -z "$content" ]; then
      if [ -n "$pending_username" ] || [ -n "$pending_email" ]; then
        if [ -z "$pending_username" ] || [ -z "$pending_email" ]; then
          fail \
            "An account entry is incomplete. Every account needs username and email." \
            "账号列表中有不完整的记录；每个账号都需要 username 和 email。"
        fi
        append_loaded_account "$pending_username" "$pending_email"
        pending_username=""
        pending_email=""
      fi
      continue
    fi

    case "$content" in
      \#*)
        continue
        ;;
      "$LANGUAGE_FIELD_PREFIX"*|"$THEME_FIELD_PREFIX"*|add-tags-to-historical-release:*)
        continue
        ;;
    esac

    case "$content" in
      username:*)
        value="$(trim "${content#username:}")"
        if [ -n "$pending_username" ]; then
          if [ -z "$pending_email" ]; then
            fail \
              "Account $pending_username is missing an email field in private/config.txt." \
              "private/config.txt 中的账号 $pending_username 缺少 email 字段。"
          fi
          append_loaded_account "$pending_username" "$pending_email"
          pending_email=""
        fi
        pending_username="$value"
        ;;
      email:*)
        value="$(trim "${content#email:}")"
        if [ -n "$pending_email" ]; then
          fail \
            "An account entry in private/config.txt contains more than one email field." \
            "private/config.txt 的同一条账号记录中出现了重复的 email 字段。"
        fi
        pending_email="$value"
        ;;
      *)
        fail \
          "Unrecognized field in private/config.txt: $content" \
          "private/config.txt 中存在无法识别的字段：$content"
        ;;
    esac
  done < "$PRIVATE_CONFIG_FILE"

  if [ -n "$pending_username" ] || [ -n "$pending_email" ]; then
    if [ -z "$pending_username" ] || [ -z "$pending_email" ]; then
      fail \
        "An account entry in private/config.txt is incomplete. Every account needs username and email." \
        "private/config.txt 中有不完整的账号记录；每个账号都需要 username 和 email。"
    fi
    append_loaded_account "$pending_username" "$pending_email"
  fi

  sort_accounts_alphabetically
}

account_email() {
  local index

  if index="$(account_index "$1")"; then
    printf '%s' "${ACCOUNT_EMAILS[$index]}"
    return 0
  fi

  return 1
}

add_or_update_account() {
  local username="$1"
  local email="$2"
  local index

  if index="$(account_index "$username")"; then
    ACCOUNT_USERNAMES[$index]="$username"
    ACCOUNT_EMAILS[$index]="$email"
  else
    ACCOUNT_USERNAMES[$ACCOUNT_COUNT]="$username"
    ACCOUNT_EMAILS[$ACCOUNT_COUNT]="$email"
    ACCOUNT_COUNT=$((ACCOUNT_COUNT + 1))
  fi
}

save_private_config() {
  local language_value="${1:-$(read_saved_language)}"
  local theme_value="${2:-$(read_saved_theme)}"
  local temporary_file=""
  local index=0

  sort_accounts_alphabetically
  ensure_private_config || return 1
  temporary_file="$(safe_mktemp_file "$PRIVATE_DIRECTORY" "config")" || return 1
  {
    printf '# Auto Script for GitHub Setup and Push - private configuration\n'
    printf 'language: %s\n' "$language_value"
    printf 'display-theme: %s\n' "$theme_value"
    printf '\n'
    printf '# GitHub accounts: one field per line, with a blank line between accounts.\n'
    while [ "$index" -lt "$ACCOUNT_COUNT" ]; do
      printf 'username: %s\n' "${ACCOUNT_USERNAMES[$index]}"
      printf 'email: %s\n' "${ACCOUNT_EMAILS[$index]}"
      if [ $((index + 1)) -lt "$ACCOUNT_COUNT" ]; then
        printf '\n'
      fi
      index=$((index + 1))
    done
  } > "$temporary_file"

  chmod 600 "$temporary_file" || {
    rm -f "$temporary_file"
    return 1
  }
  if ! mv "$temporary_file" "$PRIVATE_CONFIG_FILE"; then
    rm -f "$temporary_file"
    return 1
  fi
  return 0
}

write_accounts_to_private_config() {
  if ! save_private_config "$(read_saved_language)" "$(read_saved_theme)"; then
    fail \
      "The account list could not be saved in private/config.txt." \
      "无法把账号列表保存到 private/config.txt。"
  fi
}

paged_choice_label() {
  local offset="$1"
  local letter_index=0

  if [ "$offset" -lt 8 ]; then
    printf '%s' "$((offset + 1))"
    return 0
  fi

  letter_index=$((offset - 8))
  if [ "$letter_index" -lt "${#PAGED_CHOICE_LETTERS}" ]; then
    printf '%s' "${PAGED_CHOICE_LETTERS:$letter_index:1}"
    return 0
  fi
  return 1
}

paged_choice_page_count() {
  local item_count="$1"

  if [ "$item_count" -le 0 ]; then
    printf '1'
  else
    printf '%s' "$(((item_count + PAGED_CHOICE_PAGE_SIZE - 1) / PAGED_CHOICE_PAGE_SIZE))"
  fi
}

paged_choice_to_index() {
  local choice="$(lowercase "$1")"
  local page="$2"
  local item_count="$3"
  local offset=-1
  local letter_index=0

  if [[ "$choice" =~ ^[1-8]$ ]]; then
    offset=$((choice - 1))
  else
    while [ "$letter_index" -lt "${#PAGED_CHOICE_LETTERS}" ]; do
      if [ "$choice" = "${PAGED_CHOICE_LETTERS:$letter_index:1}" ]; then
        offset=$((letter_index + 8))
        break
      fi
      letter_index=$((letter_index + 1))
    done
  fi

  [ "$offset" -ge 0 ] || return 1
  PAGED_CHOICE_INDEX=$((page * PAGED_CHOICE_PAGE_SIZE + offset))
  [ "$PAGED_CHOICE_INDEX" -lt "$item_count" ]
}

print_paged_navigation() {
  local page="$1"
  local item_count="$2"
  local language="$3"
  local page_count=""

  page_count="$(paged_choice_page_count "$item_count")"
  [ "$page_count" -gt 1 ] || return 0

  if [ "$language" = "en" ]; then
    if [ "$page" -gt 0 ]; then
      printf '  x) Previous page\n'
    fi
    if [ "$page" -lt $((page_count - 1)) ]; then
      printf '  y) Next page\n'
    fi
  else
    if [ "$page" -gt 0 ]; then
      printf '  x) 上一页\n'
    fi
    if [ "$page" -lt $((page_count - 1)) ]; then
      printf '  y) 下一页\n'
    fi
  fi
}

print_paged_page_status() {
  local page="$1"
  local item_count="$2"
  local language="$3"
  local page_count=""

  page_count="$(paged_choice_page_count "$item_count")"
  [ "$page_count" -gt 1 ] || return 0
  if [ "$language" = "en" ]; then
    printf '  Page %s of %s\n' "$((page + 1))" "$page_count"
  else
    printf '  第 %s 页，共 %s 页\n' "$((page + 1))" "$page_count"
  fi
}

advanced_paged_review_navigation() {
  local page="$1"
  local item_count="$2"
  local page_count=""
  local choice=""
  local default_choice="y"

  page_count="$(paged_choice_page_count "$item_count")"
  [ "$page_count" -gt 1 ] || return 2

  print_paged_navigation "$page" "$item_count" "$ADVANCED_LANGUAGE"
  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    printf '  0) Finish reviewing this list\n'
  else
    printf '  0) 查看完毕，返回当前流程\n'
  fi

  if [ "$page" -eq $((page_count - 1)) ]; then
    default_choice="0"
  fi

  while true; do
    choice="$(advanced_prompt_value "Choose" "选择" "$default_choice")" || return 1
    choice="$(lowercase "$choice")"
    if [ "$choice" = "x" ] && [ "$page" -gt 0 ]; then
      PAGED_CHOICE_PAGE=$((page - 1))
      return 0
    fi
    if [ "$choice" = "y" ] && [ "$page" -lt $((page_count - 1)) ]; then
      PAGED_CHOICE_PAGE=$((page + 1))
      return 0
    fi
    if [ "$choice" = "0" ]; then
      return 2
    fi
    advanced_warn "Enter one of the choices shown." "请输入当前页面中显示的选项。"
  done
}

list_accounts_compact() {
  local page="${1:-0}"
  local language="${2:-$UI_LANGUAGE}"
  local page_count=""
  local start=0
  local end=0
  local index=0
  local label=""

  page_count="$(paged_choice_page_count "$ACCOUNT_COUNT")"
  start=$((page * PAGED_CHOICE_PAGE_SIZE))
  end=$((start + PAGED_CHOICE_PAGE_SIZE))
  [ "$end" -le "$ACCOUNT_COUNT" ] || end="$ACCOUNT_COUNT"

  print_paged_page_status "$page" "$ACCOUNT_COUNT" "$language"

  index="$start"
  while [ "$index" -lt "$end" ]; do
    label="$(paged_choice_label "$((index - start))")" || return 1
    printf '  %s) %s\n' "$label" "${ACCOUNT_USERNAMES[$index]}"
    index=$((index + 1))
  done
}

account_add_choice() {
  if [ "$ACCOUNT_COUNT" -le 8 ]; then
    printf '9'
  else
    printf 'z'
  fi
}

print_account_menu_options() {
  local page="$1"
  local allow_add="$2"
  local language="$3"
  local add_choice=""

  list_accounts_compact "$page" "$language" || return 1
  print_paged_navigation "$page" "$ACCOUNT_COUNT" "$language"

  if [ "$allow_add" = "yes" ]; then
    add_choice="$(account_add_choice)"
    if [ "$language" = "en" ]; then
      printf '  %s) Add another account\n' "$add_choice"
    else
      printf '  %s) 添加另一个账号\n' "$add_choice"
    fi
  fi

  if [ "$language" = "en" ]; then
    printf '  0) Cancel\n'
  else
    printf '  0) 取消\n'
  fi
}

select_account() {
  local english_prompt="${1:-Choose a GitHub account}"
  local chinese_prompt="${2:-选择 GitHub 账号}"
  local answer=""
  local index=0
  local page=0
  local page_count=""

  if [ "$ACCOUNT_COUNT" -eq 0 ]; then
    return 1
  fi

  if [ "$ACCOUNT_COUNT" -eq 1 ]; then
    SELECTED_USERNAME="${ACCOUNT_USERNAMES[0]}"
    SELECTED_EMAIL="${ACCOUNT_EMAILS[0]}"
    return 0
  fi

  heading "$english_prompt" "$chinese_prompt"
  page_count="$(paged_choice_page_count "$ACCOUNT_COUNT")"
  print_account_menu_options "$page" no "$UI_LANGUAGE" || return 1

  while true; do
    answer="$(ui_prompt_value "Enter a choice" "输入选项" "1")" || return 1
    answer="$(lowercase "$answer")"
    if [ "$answer" = "0" ]; then
      info "Account selection canceled." "已取消选择账号。"
      return 2
    fi
    if [ "$answer" = "x" ] && [ "$page" -gt 0 ]; then
      page=$((page - 1))
      printf '\n'
      print_account_menu_options "$page" no "$UI_LANGUAGE" || return 1
      continue
    fi
    if [ "$answer" = "y" ] && [ "$page" -lt $((page_count - 1)) ]; then
      page=$((page + 1))
      printf '\n'
      print_account_menu_options "$page" no "$UI_LANGUAGE" || return 1
      continue
    fi
    if paged_choice_to_index "$answer" "$page" "$ACCOUNT_COUNT"; then
      index="$PAGED_CHOICE_INDEX"
      SELECTED_USERNAME="${ACCOUNT_USERNAMES[$index]}"
      SELECTED_EMAIL="${ACCOUNT_EMAILS[$index]}"
      return 0
    fi
    warn "Enter one of the choices shown." "请输入当前页面中显示的选项。"
  done
}

remove_retired_private_fields() {
  if grep -q '^add-tags-to-historical-release:' "$PRIVATE_CONFIG_FILE" 2>/dev/null; then
    save_private_config "$(read_saved_language)" "$(read_saved_theme)"
  fi
}

load_accounts
remove_retired_private_fields || exit 1
