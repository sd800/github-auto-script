# -----------------------------------------------------------------------------
# SSH discovery and identity isolation
# -----------------------------------------------------------------------------

SSH_DIRECTORY="${HOME:-}/.ssh"
SSH_CONFIG_FILE="$SSH_DIRECTORY/config"
DISCOVERED_SSH_ALIASES=()
DISCOVERED_SSH_ALIAS_COUNT=0
SSH_SCAN_DIRECTORY=""
SSH_SCAN_SEEN_FILE=""
SSH_SCAN_ALIAS_FILE=""

ensure_home_available() {
  if [ -z "${HOME:-}" ]; then
    fail \
      "The user home directory (HOME) could not be determined." \
      "无法确定用户目录（HOME）。"
  fi
}

canonical_existing_file() {
  local file="$1"
  local directory=""
  local target=""
  local links=0

  [ -e "$file" ] || return 1
  while [ -L "$file" ]; do
    links=$((links + 1))
    [ "$links" -le 40 ] || return 1
    target="$(readlink "$file" 2>/dev/null || true)"
    [ -n "$target" ] || return 1
    case "$target" in
      /*)
        file="$target"
        ;;
      *)
        file="$(dirname "$file")/$target"
        ;;
    esac
    [ -e "$file" ] || return 1
  done
  directory="$({ cd "$(dirname "$file")" 2>/dev/null && pwd -P; } || return 1)"
  printf '%s/%s' "$directory" "$(basename "$file")"
}

same_existing_file() {
  [ -f "$1" ] && [ -f "$2" ] && [ "$1" -ef "$2" ]
}

strip_optional_quotes() {
  local value="$1"

  case "$value" in
    \"*\")
      value="${value#\"}"
      value="${value%\"}"
      ;;
    \'*\')
      value="${value#\'}"
      value="${value%\'}"
      ;;
  esac

  printf '%s' "$value"
}

collect_ssh_config_file() {
  local requested_file="$1"
  local file=""
  local line=""
  local cleaned=""
  local directive=""
  local remainder=""
  local directive_lc=""
  local token=""
  local pattern=""
  local match=""
  local alias=""
  local include_tokens=()
  local host_tokens=()

  [ -f "$requested_file" ] || return 0
  file="$(canonical_existing_file "$requested_file")" || return 0

  if grep -Fqx "$file" "$SSH_SCAN_SEEN_FILE" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$file" >> "$SSH_SCAN_SEEN_FILE"

  while IFS= read -r line || [ -n "$line" ]; do
    cleaned="$(trim "${line%%#*}")"
    [ -n "$cleaned" ] || continue

    directive="${cleaned%%[[:space:]]*}"
    if [ "$directive" = "$cleaned" ]; then
      remainder=""
    else
      remainder="${cleaned#"$directive"}"
      remainder="$(trim "$remainder")"
    fi
    directive_lc="$(lowercase "$directive")"

    case "$directive_lc" in
      include)
        include_tokens=()
        read -r -a include_tokens <<< "$remainder"
        for token in "${include_tokens[@]}"; do
          token="$(strip_optional_quotes "$token")"
          case "$token" in
            '~/'*)
              pattern="${HOME:-}/${token#\~/}"
              ;;
            /*)
              pattern="$token"
              ;;
            *)
              pattern="$SSH_DIRECTORY/$token"
              ;;
          esac

          while IFS= read -r match; do
            [ -n "$match" ] || continue
            collect_ssh_config_file "$match"
          done < <(compgen -G "$pattern" 2>/dev/null || true)
        done
        ;;
      host)
        host_tokens=()
        read -r -a host_tokens <<< "$remainder"
        for alias in "${host_tokens[@]}"; do
          case "$alias" in
            *'*'*|*'?'*|*'!'*|'')
              continue
              ;;
          esac
          printf '%s\n' "$alias" >> "$SSH_SCAN_ALIAS_FILE"
        done
        ;;
    esac
  done < "$file"
}

scan_ssh_aliases() {
  local alias=""
  local github_dot_com_present=false

  DISCOVERED_SSH_ALIASES=()
  DISCOVERED_SSH_ALIAS_COUNT=0

  if [ -f "$SSH_CONFIG_FILE" ]; then
    SSH_SCAN_DIRECTORY="$(safe_mktemp_directory)" || return 1
    SSH_SCAN_SEEN_FILE="$SSH_SCAN_DIRECTORY/seen"
    SSH_SCAN_ALIAS_FILE="$SSH_SCAN_DIRECTORY/aliases"
    : > "$SSH_SCAN_SEEN_FILE"
    : > "$SSH_SCAN_ALIAS_FILE"

    collect_ssh_config_file "$SSH_CONFIG_FILE"

    while IFS= read -r alias; do
      [ -n "$alias" ] || continue
      DISCOVERED_SSH_ALIASES[$DISCOVERED_SSH_ALIAS_COUNT]="$alias"
      DISCOVERED_SSH_ALIAS_COUNT=$((DISCOVERED_SSH_ALIAS_COUNT + 1))
      if [ "$(lowercase "$alias")" = "github.com" ]; then
        github_dot_com_present=true
      fi
    done < <(sort -fu "$SSH_SCAN_ALIAS_FILE")

    rm -rf "$SSH_SCAN_DIRECTORY"
    SSH_SCAN_DIRECTORY=""
  fi

  # OpenSSH can use standard default keys for github.com even when no explicit
  # Host block exists. Include that effective connection in local discovery.
  if [ "$github_dot_com_present" != true ]; then
    DISCOVERED_SSH_ALIASES[$DISCOVERED_SSH_ALIAS_COUNT]="github.com"
    DISCOVERED_SSH_ALIAS_COUNT=$((DISCOVERED_SSH_ALIAS_COUNT + 1))
  fi
}

ssh_alias_exists() {
  local candidate_lc
  local index=0

  candidate_lc="$(lowercase "$1")"
  while [ "$index" -lt "$DISCOVERED_SSH_ALIAS_COUNT" ]; do
    if [ "$(lowercase "${DISCOVERED_SSH_ALIASES[$index]}")" = "$candidate_lc" ]; then
      return 0
    fi
    index=$((index + 1))
  done

  return 1
}

ssh_effective_value() {
  local alias="$1"
  local key="$2"
  local config_file="$SSH_CONFIG_FILE"

  if [ ! -f "$config_file" ]; then
    config_file="/dev/null"
  fi

  ssh -F "$config_file" -G "$alias" 2>/dev/null |
    awk -v wanted="$(lowercase "$key")" '
      tolower($1) == wanted {
        $1 = ""
        sub(/^[[:space:]]+/, "")
        print
        exit
      }
    '
}

ssh_alias_is_github() {
  local hostname

  hostname="$(ssh_effective_value "$1" hostname)"
  [ "$(lowercase "$hostname")" = "github.com" ]
}

resolve_alias_identity_file() {
  local alias="$1"
  local line=""
  local path=""
  local first_path=""
  local config_file="$SSH_CONFIG_FILE"

  if [ ! -f "$config_file" ]; then
    config_file="/dev/null"
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="$(expand_home_path "$line")"
    path="${path//%d/${HOME:-}}"
    if [ -z "$first_path" ]; then
      first_path="$path"
    fi
    if [ -f "$path" ]; then
      printf '%s' "$path"
      return 0
    fi
  done < <(
    ssh -F "$config_file" -G "$alias" 2>/dev/null |
      awk 'tolower($1) == "identityfile" { $1=""; sub(/^[[:space:]]+/, ""); print }'
  )

  if [ -n "$first_path" ]; then
    printf '%s' "$first_path"
  fi
  return 1
}

list_existing_alias_identity_files() {
  local alias="$1"
  local line=""
  local path=""
  local config_file="$SSH_CONFIG_FILE"

  if [ ! -f "$config_file" ]; then
    config_file="/dev/null"
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="$(expand_home_path "$line")"
    path="${path//%d/${HOME:-}}"
    [ -f "$path" ] || continue
    printf '%s\n' "$path"
  done < <(
    ssh -F "$config_file" -G "$alias" 2>/dev/null |
      awk 'tolower($1) == "identityfile" { $1=""; sub(/^[[:space:]]+/, ""); print }'
  )
}

key_fingerprint() {
  local private_key="$1"
  local public_key="${private_key}.pub"

  if [ -f "$public_key" ]; then
    ssh-keygen -lf "$public_key" 2>/dev/null |
      awk '{ print $2; exit }'
    return
  fi

  return 1
}

identify_key_username() {
  local private_key="$1"
  local output=""
  local username=""

  VERIFIED_GITHUB_USERNAME=""
  SSH_VERIFICATION_OUTPUT=""

  if [ ! -f "$private_key" ]; then
    return 1
  fi

  output="$(
    ssh \
      -T \
      -F /dev/null \
      -o HostName=github.com \
      -o User=git \
      -o IdentitiesOnly=yes \
      -o PreferredAuthentications=publickey \
      -o PasswordAuthentication=no \
      -o BatchMode=yes \
      -o ConnectTimeout=12 \
      -o ServerAliveInterval=15 \
      -o ServerAliveCountMax=2 \
      -i "$private_key" \
      github.com \
      2>&1
  )" || true

  username="$(
    printf '%s\n' "$output" |
      sed -nE 's/^Hi ([^!]+)!.*/\1/p' |
      sed -n '1p'
  )"

  if [ -n "$username" ]; then
    VERIFIED_GITHUB_USERNAME="$username"
    return 0
  fi

  SSH_VERIFICATION_OUTPUT="$output"
  return 1
}

list_conventional_private_key_files() {
  local private_key=""
  local first_line=""

  [ -d "$SSH_DIRECTORY" ] || return 0
  for private_key in "$SSH_DIRECTORY"/id_*; do
    [ -f "$private_key" ] || continue
    case "$private_key" in
      *.pub|*-cert.pub)
        continue
        ;;
    esac
    first_line="$(LC_ALL=C sed -n '1p' "$private_key" 2>/dev/null || true)"
    case "$first_line" in
      '-----BEGIN OPENSSH PRIVATE KEY-----'|\
      '-----BEGIN RSA PRIVATE KEY-----'|\
      '-----BEGIN DSA PRIVATE KEY-----'|\
      '-----BEGIN EC PRIVATE KEY-----'|\
      '-----BEGIN PRIVATE KEY-----')
        printf '%s\n' "$private_key"
        ;;
    esac
  done
}

verify_key_matches_username() {
  local private_key="$1"
  local expected_username="$2"

  info \
    "Asking GitHub which account accepts this exact SSH private key; saved account and repository settings will not be changed." \
    "正在用这把指定的 SSH 私钥向 GitHub 核对账号；这一步不会修改已保存账号或仓库设置。"
  if ! identify_key_username "$private_key"; then
    error_message \
      "GitHub did not accept the private key $(human_path "$private_key") for SSH authentication." \
      "GitHub 没有接受私钥 $(human_path "$private_key") 的 SSH 身份验证。"
    if [ -n "${SSH_VERIFICATION_OUTPUT:-}" ]; then
      muted "${SSH_VERIFICATION_OUTPUT##*$'\n'}"
    fi
    return 1
  fi

  if [ "$(lowercase "$VERIFIED_GITHUB_USERNAME")" != "$(lowercase "$expected_username")" ]; then
    error_message \
      "This key belongs to ${VERIFIED_GITHUB_USERNAME}, not ${expected_username}." \
      "这个密钥实际属于 ${VERIFIED_GITHUB_USERNAME}，并不是 ${expected_username}。"
    return 1
  fi

  success \
    "GitHub confirmed that this key belongs to account $VERIFIED_GITHUB_USERNAME." \
    "GitHub 已确认这把密钥属于账号 ${VERIFIED_GITHUB_USERNAME}。"
  return 0
}

FOUND_SSH_ALIAS=""
FOUND_IDENTITY_FILE=""
FOUND_UNVERIFIED_SSH_ALIAS=""
FOUND_UNVERIFIED_IDENTITY_FILE=""

find_verified_identity_for_username() {
  local username="$1"
  local preferred_alias="${2:-}"
  local alias=""
  local key=""
  local index=0
  local passes=0
  local canonical_key=""
  local checked_keys="|"

  FOUND_SSH_ALIAS=""
  FOUND_IDENTITY_FILE=""
  FOUND_UNVERIFIED_SSH_ALIAS=""
  FOUND_UNVERIFIED_IDENTITY_FILE=""

  scan_ssh_aliases || return 1

  # Prefer the repository's saved alias, then aliases named after the account.
  while [ "$passes" -lt 3 ]; do
    index=0
    while [ "$index" -lt "$DISCOVERED_SSH_ALIAS_COUNT" ]; do
      alias="${DISCOVERED_SSH_ALIASES[$index]}"
      index=$((index + 1))

      case "$passes" in
        0)
          [ -n "$preferred_alias" ] &&
            [ "$(lowercase "$alias")" = "$(lowercase "$preferred_alias")" ] || continue
          ;;
        1)
          case "$(lowercase "$alias")" in
            "github-$(lowercase "$username")"|"github-$(lowercase "$username")-"[0-9]*)
              ;;
            *)
              continue
              ;;
          esac
          ;;
        2)
          ;;
      esac

      ssh_alias_is_github "$alias" || continue
      while IFS= read -r key; do
        [ -f "$key" ] || continue
        canonical_key="$(canonical_existing_file "$key" || true)"
        [ -n "$canonical_key" ] || continue
        case "$checked_keys" in
          *"|$canonical_key|"*)
            continue
            ;;
        esac
        checked_keys="${checked_keys}${canonical_key}|"

        if identify_key_username "$key" &&
           [ "$(lowercase "$VERIFIED_GITHUB_USERNAME")" = "$(lowercase "$username")" ]; then
          FOUND_SSH_ALIAS="$alias"
          FOUND_IDENTITY_FILE="$key"
          return 0
        fi
        if [ -z "$VERIFIED_GITHUB_USERNAME" ] &&
           [ -z "$FOUND_UNVERIFIED_IDENTITY_FILE" ]; then
          FOUND_UNVERIFIED_SSH_ALIAS="$alias"
          FOUND_UNVERIFIED_IDENTITY_FILE="$key"
        fi
      done < <(list_existing_alias_identity_files "$alias")
    done
    passes=$((passes + 1))
  done

  # A conventional ~/.ssh/id_* private key may exist without any Host entry.
  # It is never trusted locally, but an explicitly selected Advanced check can
  # ask GitHub whether it belongs to the requested account.
  while IFS= read -r key; do
    [ -f "$key" ] || continue
    canonical_key="$(canonical_existing_file "$key" || true)"
    [ -n "$canonical_key" ] || continue
    case "$checked_keys" in
      *"|$canonical_key|"*)
        continue
        ;;
    esac
    checked_keys="${checked_keys}${canonical_key}|"

    if identify_key_username "$key" &&
       [ "$(lowercase "$VERIFIED_GITHUB_USERNAME")" = "$(lowercase "$username")" ]; then
      FOUND_SSH_ALIAS="github.com"
      FOUND_IDENTITY_FILE="$key"
      return 0
    fi
    if [ -z "$VERIFIED_GITHUB_USERNAME" ] &&
       [ -z "$FOUND_UNVERIFIED_IDENTITY_FILE" ]; then
      FOUND_UNVERIFIED_SSH_ALIAS="github.com"
      FOUND_UNVERIFIED_IDENTITY_FILE="$key"
    fi
  done < <(list_conventional_private_key_files)

  return 1
}

find_local_identity_for_username() {
  local username="$1"
  local preferred_alias="${2:-}"
  local username_lc=""
  local alias=""
  local key=""
  local index=0
  local pass=0

  FOUND_SSH_ALIAS=""
  FOUND_IDENTITY_FILE=""
  username_lc="$(lowercase "$username")"
  scan_ssh_aliases || return 1

  while [ "$pass" -lt 2 ]; do
    index=0
    while [ "$index" -lt "$DISCOVERED_SSH_ALIAS_COUNT" ]; do
      alias="${DISCOVERED_SSH_ALIASES[$index]}"
      index=$((index + 1))
      if [ "$pass" -eq 0 ]; then
        [ -n "$preferred_alias" ] &&
          [ "$(lowercase "$alias")" = "$(lowercase "$preferred_alias")" ] || continue
      else
        case "$(lowercase "$alias")" in
          "github-$username_lc"|"github-$username_lc-"[0-9]*)
            ;;
          *)
            continue
            ;;
        esac
      fi
      ssh_alias_is_github "$alias" || continue
      key="$(resolve_alias_identity_file "$alias" || true)"
      [ -f "$key" ] || continue
      FOUND_SSH_ALIAS="$alias"
      FOUND_IDENTITY_FILE="$key"
      return 0
    done
    pass=$((pass + 1))
    if [ "$pass" -eq 1 ] && find_engine_identity_for_username "$username"; then
      return 0
    fi
  done

  return 1
}

find_engine_identity_for_username() {
  local username="$1"
  local saved_username=""
  local saved_alias=""
  local saved_key=""
  local alias_key=""
  local engine_git_root=""

  engine_git_root="$(git -C "$ENGINE_DIRECTORY" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$engine_git_root" ] && [ "$engine_git_root" -ef "$ENGINE_DIRECTORY" ] || return 1
  saved_username="$(git -C "$ENGINE_DIRECTORY" config --local --get github-auto.username 2>/dev/null || true)"
  [ "$(lowercase "$saved_username")" = "$(lowercase "$username")" ] || return 1

  saved_alias="$(git -C "$ENGINE_DIRECTORY" config --local --get github-auto.ssh-alias 2>/dev/null || true)"
  saved_key="$(git -C "$ENGINE_DIRECTORY" config --local --get github-auto.identity-file 2>/dev/null || true)"
  saved_key="$(expand_home_path "$saved_key")"
  saved_key="${saved_key//%d/${HOME:-}}"
  [ -n "$saved_alias" ] && [ -f "$saved_key" ] || return 1
  ssh_alias_is_github "$saved_alias" || return 1

  alias_key="$(resolve_alias_identity_file "$saved_alias" || true)"
  same_existing_file "$saved_key" "$alias_key" || return 1

  FOUND_SSH_ALIAS="$saved_alias"
  FOUND_IDENTITY_FILE="$saved_key"
  return 0
}

configured_github_identity_exists() {
  local index=0
  local alias=""
  local key=""

  scan_ssh_aliases || return 1
  while [ "$index" -lt "$DISCOVERED_SSH_ALIAS_COUNT" ]; do
    alias="${DISCOVERED_SSH_ALIASES[$index]}"
    index=$((index + 1))
    ssh_alias_is_github "$alias" || continue
    key="$(resolve_alias_identity_file "$alias" || true)"
    [ -f "$key" ] && return 0
  done
  while IFS= read -r key; do
    [ -f "$key" ] && return 0
  done < <(list_conventional_private_key_files)
  return 1
}

ensure_username_alias_for_identity() {
  local username="$1"
  local current_alias="$2"
  local identity_file="$3"
  local username_lc=""
  local alias=""
  local key=""
  local index=0

  username_lc="$(lowercase "$username")"
  [ -f "$identity_file" ] || return 1
  case "$(lowercase "$current_alias")" in
    "github-$username_lc"|"github-$username_lc-"[0-9]*)
      key="$(resolve_alias_identity_file "$current_alias" || true)"
      if same_existing_file "$identity_file" "$key"; then
        FOUND_SSH_ALIAS="$current_alias"
        FOUND_IDENTITY_FILE="$identity_file"
        return 0
      fi
      ;;
  esac

  scan_ssh_aliases || return 1
  while [ "$index" -lt "$DISCOVERED_SSH_ALIAS_COUNT" ]; do
    alias="${DISCOVERED_SSH_ALIASES[$index]}"
    index=$((index + 1))
    case "$(lowercase "$alias")" in
      "github-$username_lc"|"github-$username_lc-"[0-9]*)
        key="$(resolve_alias_identity_file "$alias" || true)"
        if same_existing_file "$key" "$identity_file"; then
          FOUND_SSH_ALIAS="$alias"
          FOUND_IDENTITY_FILE="$identity_file"
          return 0
        fi
        ;;
    esac
  done

  next_available_alias "$username" || return 1
  install_ssh_alias_block "$username" "$NEW_SSH_ALIAS" "$identity_file"
  FOUND_SSH_ALIAS="$NEW_SSH_ALIAS"
  FOUND_IDENTITY_FILE="$identity_file"
  return 0
}

find_github_alias_for_identity_file() {
  local identity_file="$1"
  local preferred_alias="${2:-}"
  local alias=""
  local candidate_key=""
  local index=0
  local pass=0

  FOUND_SSH_ALIAS=""
  [ -f "$identity_file" ] || return 1
  scan_ssh_aliases || return 1

  while [ "$pass" -lt 2 ]; do
    index=0
    while [ "$index" -lt "$DISCOVERED_SSH_ALIAS_COUNT" ]; do
      alias="${DISCOVERED_SSH_ALIASES[$index]}"
      index=$((index + 1))

      if [ "$pass" -eq 0 ]; then
        [ -n "$preferred_alias" ] &&
          [ "$(lowercase "$alias")" = "$(lowercase "$preferred_alias")" ] || continue
      fi

      ssh_alias_is_github "$alias" || continue
      candidate_key="$(resolve_alias_identity_file "$alias" || true)"
      if same_existing_file "$candidate_key" "$identity_file"; then
        FOUND_SSH_ALIAS="$alias"
        return 0
      fi
    done
    pass=$((pass + 1))
  done

  return 1
}

next_available_alias() {
  local username_lc
  local base=""
  local candidate=""
  local suffix=0
  local key_path=""

  username_lc="$(lowercase "$1")"
  base="github-$username_lc"
  candidate="$base"

  scan_ssh_aliases || return 1

  while true; do
    key_path="$SSH_DIRECTORY/id_ed25519_$candidate"
    if ! ssh_alias_exists "$candidate" &&
       [ ! -e "$key_path" ] &&
       [ ! -L "$key_path" ] &&
       [ ! -e "${key_path}.pub" ] &&
       [ ! -L "${key_path}.pub" ]; then
      NEW_SSH_ALIAS="$candidate"
      NEW_IDENTITY_FILE="$key_path"
      return 0
    fi
    suffix=$((suffix + 1))
    candidate="$base-$suffix"
  done
}

ensure_ssh_storage() {
  ensure_home_available

  if [ -L "$SSH_DIRECTORY" ] && [ ! -d "$SSH_DIRECTORY" ]; then
    fail \
      "The SSH directory is a broken symbolic link: $(human_path "$SSH_DIRECTORY")." \
      "SSH 文件夹是失效的符号链接：$(human_path "$SSH_DIRECTORY")。"
  fi
  if [ ! -d "$SSH_DIRECTORY" ]; then
    mkdir -p "$SSH_DIRECTORY" || fail \
      "Could not create $(human_path "$SSH_DIRECTORY")." \
      "无法创建 $(human_path "$SSH_DIRECTORY")。"
  fi
  chmod 700 "$SSH_DIRECTORY" || fail \
    "Could not secure the SSH directory permissions." \
    "无法设置 SSH 目录的安全权限。"

  if [ -L "$SSH_CONFIG_FILE" ] && [ ! -f "$SSH_CONFIG_FILE" ]; then
    fail \
      "The SSH configuration file is a broken symbolic link: $(human_path "$SSH_CONFIG_FILE")." \
      "SSH 配置文件是失效的符号链接：$(human_path "$SSH_CONFIG_FILE")。"
  fi
  if [ -e "$SSH_CONFIG_FILE" ] && [ ! -f "$SSH_CONFIG_FILE" ]; then
    fail \
      "The SSH configuration path is not a regular file: $(human_path "$SSH_CONFIG_FILE")." \
      "SSH 配置路径不是普通文件：$(human_path "$SSH_CONFIG_FILE")。"
  fi
  if [ ! -f "$SSH_CONFIG_FILE" ]; then
    : > "$SSH_CONFIG_FILE" || fail \
      "Could not create the SSH configuration file." \
      "无法创建 SSH 配置文件。"
  fi
  chmod 600 "$SSH_CONFIG_FILE" || fail \
    "Could not secure the SSH configuration file permissions." \
    "无法设置 SSH 配置文件的安全权限。"
}

install_ssh_alias_block() {
  local username="$1"
  local alias="$2"
  local private_key="$3"
  local temporary_file=""
  local display_key=""
  local resolved_hostname=""
  local resolved_identity=""
  local config_write_file=""
  local write_directory=""
  local escaped_key=""

  ensure_ssh_storage
  config_write_file="$SSH_CONFIG_FILE"
  if [ -L "$SSH_CONFIG_FILE" ]; then
    config_write_file="$(canonical_existing_file "$SSH_CONFIG_FILE")" || return 1
  fi
  write_directory="$({ cd "$(dirname "$config_write_file")" 2>/dev/null && pwd -P; } || return 1)"
  config_write_file="$write_directory/$(basename "$config_write_file")"
  temporary_file="$(safe_mktemp_file "$write_directory" "config")" ||
    fail \
      "A temporary SSH configuration file could not be created." \
      "无法创建 SSH 配置临时文件。"

  display_key="$(human_path "$private_key")"
  escaped_key="$(printf '%s' "$display_key" | sed 's/\\/\\\\/g; s/"/\\"/g')"

  {
    printf '# >>> %s:%s >>>\n' "$SSH_BLOCK_PREFIX" "$username"
    printf 'Host %s\n' "$alias"
    printf '    HostName github.com\n'
    printf '    User git\n'
    printf '    IdentityFile "%s"\n' "$escaped_key"
    printf '    IdentitiesOnly yes\n'
    printf '    AddKeysToAgent yes\n'
    if [ "$(uname -s 2>/dev/null || true)" = "Darwin" ]; then
      printf '    UseKeychain yes\n'
    fi
    printf '# <<< %s:%s <<<\n\n' "$SSH_BLOCK_PREFIX" "$username"
    if [ -s "$SSH_CONFIG_FILE" ]; then
      sed -n '1,$p' "$SSH_CONFIG_FILE"
    fi
  } >> "$temporary_file"

  chmod 600 "$temporary_file" || {
    rm -f "$temporary_file"
    fail \
      "Could not secure the new SSH configuration." \
      "无法设置新 SSH 配置的安全权限。"
  }

  resolved_hostname="$(
    ssh -F "$temporary_file" -G "$alias" 2>/dev/null |
      awk 'tolower($1) == "hostname" { print $2; exit }'
  )"
  resolved_identity="$(
    ssh -F "$temporary_file" -G "$alias" 2>/dev/null |
      awk 'tolower($1) == "identityfile" { $1=""; sub(/^[[:space:]]+/, ""); print; exit }'
  )"
  resolved_identity="$(expand_home_path "$resolved_identity")"
  resolved_identity="${resolved_identity//%d/${HOME:-}}"

  if [ "$(lowercase "$resolved_hostname")" != "github.com" ] ||
     ! same_existing_file "$resolved_identity" "$private_key"; then
    rm -f "$temporary_file"
    fail \
      "The new SSH configuration failed validation. The original configuration was kept." \
      "新的 SSH 配置没有通过验证，原配置保持不变。"
  fi

  mv "$temporary_file" "$config_write_file" || {
    rm -f "$temporary_file"
    fail \
      "The SSH configuration could not be saved." \
      "无法保存 SSH 配置。"
  }
}

copy_public_key() {
  local public_key="$1"

  if command_exists pbcopy; then
    pbcopy < "$public_key"
    return 0
  fi
  if command_exists wl-copy; then
    wl-copy < "$public_key"
    return 0
  fi
  if command_exists xclip; then
    xclip -selection clipboard < "$public_key"
    return 0
  fi

  return 1
}

open_github_key_page() {
  local url="https://github.com/settings/ssh/new"

  if [ "$(uname -s 2>/dev/null || true)" = "Darwin" ] && command_exists open; then
    open "$url" >/dev/null 2>&1 || true
  elif command_exists xdg-open; then
    xdg-open "$url" >/dev/null 2>&1 || true
  fi
}

create_new_identity() {
  local username="$1"
  local email="$2"
  local public_key=""

  if ! command_exists ssh-keygen; then
    fail \
      "ssh-keygen is required only when creating a new SSH key, but it is not available on this computer." \
      "当前需要新建 SSH 密钥，但这台电脑上没有可用的 ssh-keygen。"
  fi

  ensure_ssh_storage
  next_available_alias "$username" || fail \
    "An unused SSH Host name and key filename could not be selected." \
    "无法为新密钥找到不冲突的 SSH 主机名和文件名。"

  heading "Create a GitHub SSH key" "创建 GitHub SSH 密钥"
  muted "GitHub account: $username" "GitHub 账号：$username"
  muted \
    "New private key: $(human_path "$NEW_IDENTITY_FILE")" \
    "新私钥位置：$(human_path "$NEW_IDENTITY_FILE")"
  muted \
    "New SSH Host entry: $NEW_SSH_ALIAS -> github.com" \
    "将写入 SSH 主机配置：$NEW_SSH_ALIAS -> github.com"
  muted \
    "ssh-keygen will ask for an optional key passphrase twice. Press Enter twice to create the key without a passphrase." \
    "接下来 ssh-keygen 会连续两次询问密钥口令；如果不需要口令，请连续按两次 Enter。"

  if ! ssh-keygen -t ed25519 -C "$email" -f "$NEW_IDENTITY_FILE"; then
    fail "The key was not created." "密钥创建未完成。"
  fi
  chmod 600 "$NEW_IDENTITY_FILE" || true
  chmod 644 "${NEW_IDENTITY_FILE}.pub" || true

  install_ssh_alias_block "$username" "$NEW_SSH_ALIAS" "$NEW_IDENTITY_FILE"

  public_key="${NEW_IDENTITY_FILE}.pub"
  heading "Add the public key to the correct GitHub account" "把公钥添加到正确的 GitHub 账号"
  if copy_public_key "$public_key"; then
    success "The public key was copied to the clipboard." "公钥已复制到剪贴板。"
  else
    muted "Copy the complete line below:" "请复制下面这一整行："
    sed -n '1p' "$public_key"
  fi
  muted \
    "Make sure the browser is signed in as ${username}, then paste and save the key." \
    "请确认浏览器登录的是 GitHub 账号 ${username}，然后粘贴并保存密钥。"
  muted \
    "Use this computer's name for Title if helpful, and keep Key type as Authentication Key." \
    "Title 可以填写这台电脑的名称，Key type 保持 Authentication Key。"

  if ui_prompt_yes_no \
    "Open GitHub's Add SSH key page now?" \
    "现在打开 GitHub 的 SSH 密钥添加页面？" \
    "yes"; then
    open_github_key_page
  else
    muted \
      "Open: https://github.com/settings/ssh/new" \
      "请打开：https://github.com/settings/ssh/new"
  fi

  pause_for_user \
    "After saving the key on GitHub, press Enter to continue: " \
    "在 GitHub 保存密钥后，按 Enter 继续："

  FOUND_SSH_ALIAS="$NEW_SSH_ALIAS"
  FOUND_IDENTITY_FILE="$NEW_IDENTITY_FILE"
  success \
    "The key and SSH Host are ready locally. The next git push for account $username will let GitHub accept or reject this key." \
    "密钥和 SSH 主机名已经在本机配置完成。账号 ${username} 下次执行 git push 时，将由 GitHub 接受或拒绝这把密钥。"
  return 0
}

VERIFIED_IDENTITY_USERNAMES=()
VERIFIED_IDENTITY_ALIASES=()
VERIFIED_IDENTITY_FILES=()
VERIFIED_IDENTITY_COUNT=0

verified_identity_index() {
  local username_lc
  local index=0

  username_lc="$(lowercase "$1")"
  while [ "$index" -lt "$VERIFIED_IDENTITY_COUNT" ]; do
    if [ "$(lowercase "${VERIFIED_IDENTITY_USERNAMES[$index]}")" = "$username_lc" ]; then
      printf '%s' "$index"
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

discover_verified_github_identities() {
  local alias=""
  local key=""
  local canonical_key=""
  local checked_keys="|"
  local index=0

  VERIFIED_IDENTITY_USERNAMES=()
  VERIFIED_IDENTITY_ALIASES=()
  VERIFIED_IDENTITY_FILES=()
  VERIFIED_IDENTITY_COUNT=0

  scan_ssh_aliases || return 1
  [ "$DISCOVERED_SSH_ALIAS_COUNT" -gt 0 ] || return 0

  heading \
    "Find GitHub accounts on this computer" \
    "查找这台电脑上的 GitHub 账号"

  while [ "$index" -lt "$DISCOVERED_SSH_ALIAS_COUNT" ]; do
    alias="${DISCOVERED_SSH_ALIASES[$index]}"
    index=$((index + 1))

    ssh_alias_is_github "$alias" || continue
    while IFS= read -r key; do
      [ -f "$key" ] || continue
      canonical_key="$(canonical_existing_file "$key" || true)"
      [ -n "$canonical_key" ] || continue
      case "$checked_keys" in
        *"|$canonical_key|"*)
          continue
          ;;
      esac
      checked_keys="${checked_keys}${canonical_key}|"

      muted \
        "Asking GitHub which account accepts key $(human_path "$key") from SSH Host $alias; saved account and repository settings will not be changed." \
        "正在核对 SSH 主机名 $alias 指定的密钥 $(human_path "$key") 对应哪个 GitHub 账号；这一步不会修改已保存账号或仓库设置。"
      if identify_key_username "$key"; then
        if ! verified_identity_index "$VERIFIED_GITHUB_USERNAME" >/dev/null 2>&1; then
          VERIFIED_IDENTITY_USERNAMES[$VERIFIED_IDENTITY_COUNT]="$VERIFIED_GITHUB_USERNAME"
          VERIFIED_IDENTITY_ALIASES[$VERIFIED_IDENTITY_COUNT]="$alias"
          VERIFIED_IDENTITY_FILES[$VERIFIED_IDENTITY_COUNT]="$key"
          VERIFIED_IDENTITY_COUNT=$((VERIFIED_IDENTITY_COUNT + 1))
          success \
            "Found GitHub account: $VERIFIED_GITHUB_USERNAME" \
            "发现 GitHub 账号：$VERIFIED_GITHUB_USERNAME"
        fi
      fi
    done < <(list_existing_alias_identity_files "$alias")
  done

  while IFS= read -r key; do
    [ -f "$key" ] || continue
    canonical_key="$(canonical_existing_file "$key" || true)"
    [ -n "$canonical_key" ] || continue
    case "$checked_keys" in
      *"|$canonical_key|"*)
        continue
        ;;
    esac
    checked_keys="${checked_keys}${canonical_key}|"

    muted \
      "Asking GitHub which account accepts unassigned key $(human_path "$key"); saved account and repository settings will not be changed." \
      "正在核对尚未写入 SSH 主机配置的密钥 $(human_path "$key") 对应哪个 GitHub 账号；这一步不会修改已保存账号或仓库设置。"
    if identify_key_username "$key" &&
       ! verified_identity_index "$VERIFIED_GITHUB_USERNAME" >/dev/null 2>&1; then
      VERIFIED_IDENTITY_USERNAMES[$VERIFIED_IDENTITY_COUNT]="$VERIFIED_GITHUB_USERNAME"
      VERIFIED_IDENTITY_ALIASES[$VERIFIED_IDENTITY_COUNT]="github.com"
      VERIFIED_IDENTITY_FILES[$VERIFIED_IDENTITY_COUNT]="$key"
      VERIFIED_IDENTITY_COUNT=$((VERIFIED_IDENTITY_COUNT + 1))
      success \
        "Found GitHub account: $VERIFIED_GITHUB_USERNAME" \
        "发现 GitHub 账号：$VERIFIED_GITHUB_USERNAME"
    fi
  done < <(list_conventional_private_key_files)

  if [ "$VERIFIED_IDENTITY_COUNT" -eq 0 ]; then
    muted \
      "GitHub did not accept any private key found through the scanned SSH connections or conventional ~/.ssh/id_* files." \
      "从已扫描的 SSH 连接和常见 ~/.ssh/id_* 私钥文件中，没有找到 GitHub 接受的密钥。"
  fi
}

default_email_for_username() {
  local username="$1"
  local configured=""

  configured="$(account_email "$username" 2>/dev/null || true)"
  if [ -n "$configured" ]; then
    printf '%s' "$configured"
    return
  fi

  printf '%s@users.noreply.github.com' "$(lowercase "$username")"
}

prompt_account_email() {
  local username="$1"
  local default_email=""
  local email=""

  default_email="$(default_email_for_username "$username")"

  while true; do
    email="$(ui_prompt_value "Commit email" "提交邮箱" "$default_email")" || return 1
    if valid_email "$email"; then
      printf '%s' "$email"
      return 0
    fi
    warn "Enter a valid email address." "这个邮箱地址无法识别，请重新输入。"
  done
}

prompt_github_username() {
  local username=""

  while true; do
    username="$(ui_prompt_value "GitHub username, or :cancel to stop" "GitHub 用户名；如需停止，请输入 :cancel")" || return 1
    username="$(lowercase "$username")"
    if [ "$username" = ":cancel" ]; then
      return 2
    fi
    if valid_github_username "$username"; then
      printf '%s' "$username"
      return 0
    fi
    warn \
      "A GitHub username normally contains only letters, numbers, and hyphens." \
      "GitHub 用户名通常只包含字母、数字和连字符，请重新输入。"
  done
}

register_account_and_identity() {
  local username="$1"
  local email="$2"
  local alias="$3"
  local private_key="$4"

  add_or_update_account "$username" "$email"
  write_accounts_to_private_config

  SELECTED_USERNAME="$username"
  SELECTED_EMAIL="$email"
  FOUND_SSH_ALIAS="$alias"
  FOUND_IDENTITY_FILE="$private_key"

  success \
    "Saved account $username, its commit email, and its local SSH key mapping." \
    "已保存账号 ${username}、提交邮箱及其本机 SSH 密钥对应关系。"
}

setup_or_reuse_account() {
  local username="$1"
  local email="$2"
  local choice=""

  if find_local_identity_for_username "$username"; then
    info \
      "Using trusted local mapping for account $username: SSH Host $FOUND_SSH_ALIAS and its existing key. No online identity check is run." \
      "已找到账号 ${username} 的可信本机绑定，将继续使用 SSH 主机名 ${FOUND_SSH_ALIAS} 及其现有密钥；这里不会联网核对。"
    register_account_and_identity "$username" "$email" "$FOUND_SSH_ALIAS" "$FOUND_IDENTITY_FILE"
    return 0
  fi

  if configured_github_identity_exists; then
    heading "Existing SSH keys need account identification" "发现尚未确认账号归属的 SSH 密钥"
    muted \
      "This computer already has SSH private keys that may be used with GitHub, but local settings do not establish which one belongs to account $username. The script will not guess or create a duplicate key automatically." \
      "这台电脑已经存在可能用于 GitHub 的 SSH 私钥，但仅凭本机设置还无法确定哪一把属于账号 ${username}。脚本不会猜测账号归属，也不会直接重复创建密钥。"
    muted \
      "The Advanced check contacts GitHub only to identify the existing keys. It does not read, change, or upload any repository." \
      "高级核对只会连接 GitHub 识别现有密钥对应的账号，不会读取、修改或上传任何仓库。"
    while true; do
      if [ "$UI_LANGUAGE" = "zh" ]; then
        printf '  1) 高级联网核对现有密钥（推荐）\n'
        printf '  2) 明确为这个账号新建独立密钥\n'
        printf '  0) 停止，不修改 SSH 配置\n'
      else
        printf '  1) Run the Advanced online check for existing keys (recommended)\n'
        printf '  2) Create a separate key for this account\n'
        printf '  0) Stop without changing SSH configuration\n'
      fi
      choice="$(ui_prompt_value "Choose" "选择" "1")" || return 1
      case "$choice" in
        1)
          info \
            "Advanced check: asking GitHub which existing key belongs to account $username..." \
            "高级核对：正在向 GitHub 确认哪一把现有密钥属于账号 ${username}……"
          if find_verified_identity_for_username "$username" &&
             ensure_username_alias_for_identity \
               "$username" "$FOUND_SSH_ALIAS" "$FOUND_IDENTITY_FILE"; then
            register_account_and_identity \
              "$username" "$email" "$FOUND_SSH_ALIAS" "$FOUND_IDENTITY_FILE"
            return 0
          fi
          warn \
            "GitHub did not confirm an existing key for account $username. No key was created." \
            "GitHub 没有确认现有密钥属于账号 ${username}；脚本尚未创建新密钥。"
          ;;
        2)
          break
          ;;
        0)
          warn \
            "Stopped without creating a key or changing SSH configuration." \
            "操作已停止；没有创建密钥，也没有修改 SSH 配置。"
          return 1
          ;;
        *)
          warn "Enter a number from the list." "请输入列表中的序号。"
          ;;
      esac
    done
  fi

  next_available_alias "$username" || return 1
  heading "Create a separate SSH key" "创建独立的 SSH 密钥"
  muted \
    "If you continue, the script will create $(human_path "$NEW_IDENTITY_FILE") and add SSH Host $NEW_SSH_ALIAS to ~/.ssh/config. Existing keys and Host entries will not be replaced." \
    "如果继续，脚本会创建 $(human_path "$NEW_IDENTITY_FILE")，并在 ~/.ssh/config 中加入 SSH 主机名 ${NEW_SSH_ALIAS}；现有密钥和主机配置不会被替换。"
  if ! ui_prompt_yes_no \
    "Create and configure this key for account $username now?" \
    "现在为账号 $username 创建并配置这把密钥吗？" \
    "yes"; then
    warn \
      "Stopped before creating a key or saving account $username." \
      "操作已停止；没有创建新密钥，也没有保存账号 ${username}。"
    return 1
  fi

  if create_new_identity "$username" "$email"; then
    register_account_and_identity "$username" "$email" "$FOUND_SSH_ALIAS" "$FOUND_IDENTITY_FILE"
    return 0
  fi

  return 1
}

run_account_setup() {
  local username=""
  local email=""

  require_interactive
  ensure_home_available

  heading "Add a GitHub account" "添加 GitHub 账号"
  muted \
    "Enter the account once. This ordinary setup uses only local SSH configuration and does not contact GitHub for a precheck; a later git push returns the actual remote result." \
    "只需输入一次账号信息。普通设置只处理本机 SSH 配置，不会提前联网核对；以后执行 git push 时，再以 GitHub 的实际返回结果为准。"
  username="$(prompt_github_username)"
  case "$?" in
    0)
      ;;
    2)
      warn \
        "Account setup canceled. No project was committed or pushed." \
        "已退出账号设置；没有提交或上传任何项目。"
      return 2
      ;;
    *)
      return 1
      ;;
  esac
  email="$(prompt_account_email "$username")" || return 1

  if setup_or_reuse_account "$username" "$email"; then
    return 0
  fi

  fail \
    "The account setup did not finish. Any key already created remains in ~/.ssh, but no project was committed or pushed." \
    "账号设置未完成。过程中已经创建的密钥会保留在 ~/.ssh 中，但没有提交或上传任何项目。"
}
