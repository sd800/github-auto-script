# -----------------------------------------------------------------------------
# Advanced features and historical release import
# -----------------------------------------------------------------------------

ADVANCED_LANGUAGE="en"
HISTORY_RELEASE_VERSIONS=()
HISTORY_RELEASE_DIRECTORIES=()
HISTORY_RELEASE_DATES=()
HISTORY_RELEASE_NEEDS_GITIGNORE=()
HISTORY_RELEASE_COUNT=0
HISTORY_CONFLICT_DIRECTORIES=()
HISTORY_CONFLICT_FOLDER_VERSIONS=()
HISTORY_CONFLICT_CONTENT_VERSIONS=()
HISTORY_CONFLICT_COUNT=0
HISTORY_SKIPPED_DIRECTORIES=()
HISTORY_SKIPPED_COUNT=0
HISTORY_SENSITIVE_FILES=()
HISTORY_SENSITIVE_REASONS=()
HISTORY_SENSITIVE_COUNT=0
HISTORY_LARGE_FILES=()
HISTORY_LARGE_COUNT=0
HISTORY_MAX_FILE_BYTES=104857600
HISTORY_GITIGNORE_CONTENT=""
HISTORY_ADD_GITIGNORE=false
HISTORY_WORK_DIRECTORY=""
HISTORY_REBUILD_DATES=true
HISTORY_COMMITS_CONFIRMED=false

advanced_heading() {
  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    heading "$1"
  else
    heading "$2"
  fi
}

advanced_muted() {
  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    muted "$1"
  else
    muted "$2"
  fi
}

advanced_info() {
  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    print_colored "$COLOR_INFO" "[Info] $1"
  else
    print_colored "$COLOR_INFO" "[信息] $2"
  fi
}

advanced_success() {
  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    print_colored "$COLOR_SUCCESS" "[Done] $1"
  else
    print_colored "$COLOR_SUCCESS" "[完成] $2"
  fi
}

advanced_warn() {
  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    print_colored "$COLOR_WARNING" "[Notice] $1"
  else
    print_colored "$COLOR_WARNING" "[注意] $2"
  fi
}

advanced_error() {
  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    print_colored "$COLOR_ERROR" "[Error] $1" stderr
  else
    print_colored "$COLOR_ERROR" "[错误] $2" stderr
  fi
}

advanced_prompt_value() {
  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    prompt_value "$1" "${3:-}"
  else
    prompt_value "$2" "${3:-}"
  fi
}

advanced_prompt_yes_no() {
  local english_label="$1"
  local chinese_label="$2"
  local default_answer="${3:-yes}"
  local english_detail="${4:-}"
  local chinese_detail="${5:-}"
  local label="$english_label"
  local detail="$english_detail"
  local hint="[Y/n]"
  local answer=""

  if [ "$ADVANCED_LANGUAGE" != "en" ]; then
    label="$chinese_label"
    detail="$chinese_detail"
    if [ "$default_answer" = "no" ]; then
      hint="[是(y)/否(N)，默认否]"
    else
      hint="[是(Y)/否(n)，默认是]"
    fi
  elif [ "$default_answer" = "no" ]; then
    hint="[y/N]"
  fi

  if [ -n "$detail" ]; then
    print_colored "$COLOR_INFO" "$label"
    print_colored "$COLOR_MUTED" "$detail"
    label=""
  fi

  while true; do
    if [ -n "$label" ]; then
      printf '%b%s %s: %b' "$COLOR_INFO" "$label" "$hint" "$COLOR_RESET"
    else
      printf '%b%s: %b' "$COLOR_INFO" "$hint" "$COLOR_RESET"
    fi
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
        advanced_warn \
          "Enter y or n. Press Enter to use the recommended option." \
          "请输入 y 或 n；直接按 Enter 使用推荐选项。"
        ;;
    esac
  done
}

advanced_pause() {
  local ignored=""

  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    printf '%bPress Enter to continue%b' "$COLOR_INFO" "$COLOR_RESET"
  else
    printf '%b按 Enter 继续%b' "$COLOR_INFO" "$COLOR_RESET"
  fi
  IFS= read -r ignored || true
}

normalize_history_directory_input() {
  local path=""

  HISTORY_NORMALIZED_DIRECTORY=""
  path="$(trim "$1")"
  path="$(strip_optional_quotes "$path")"
  case "$path" in
    file://localhost/*)
      path="/${path#file://localhost/}"
      ;;
    file:///*)
      path="${path#file://}"
      ;;
  esac

  path="${path//%20/ }"
  path="${path//%5B/[}"
  path="${path//%5D/]}"
  path="${path//%28/(}"
  path="${path//%29/)}"
  path="${path//\\ / }"
  path="${path//\\(/(}"
  path="${path//\\)/)}"
  path="${path//\\[/[}"
  path="${path//\\]/]}"
  path="$(expand_home_path "$path")"

  [ -d "$path" ] || return 1
  HISTORY_NORMALIZED_DIRECTORY="$({ cd "$path" 2>/dev/null && pwd -P; } || return 1)"
}

extract_version_from_directory_name() {
  local name="$1"

  HISTORY_DIRECTORY_VERSION=""
  if [[ "$name" =~ (^|[^0-9A-Za-z])[vV]?(${STRICT_SEMVER_PATTERN})($|[^0-9A-Za-z]) ]]; then
    HISTORY_DIRECTORY_VERSION="${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

detect_release_version_from_contents() {
  local directory="$1"
  local original_root="$GIT_ROOT"
  local file=""
  local version=""
  local best=""

  HISTORY_CONTENT_VERSION=""
  GIT_ROOT="$directory"

  if version="$(get_package_version 2>/dev/null)"; then
    HISTORY_CONTENT_VERSION="$version"
    GIT_ROOT="$original_root"
    return 0
  fi

  while IFS= read -r -d '' file; do
    if extract_version_from_changelog "$file" &&
       valid_release_version "$CHANGELOG_EXTRACTED_VERSION"; then
      version="$CHANGELOG_EXTRACTED_VERSION"
      if [ -z "$best" ]; then
        best="$version"
      else
        compare_semver "$version" "$best"
        if [ "$SEMVER_COMPARISON" -gt 0 ]; then
          best="$version"
        fi
      fi
    fi
  done < <(find "$directory" -mindepth 1 -maxdepth 1 -type f -iname 'CHANGELOG*' -print0)

  if [ -z "$best" ]; then
    while IFS= read -r -d '' file; do
      if version="$(extract_version_from_version_file "$file" 2>/dev/null)"; then
        if [ -z "$best" ]; then
          best="$version"
        else
          compare_semver "$version" "$best"
          if [ "$SEMVER_COMPARISON" -gt 0 ]; then
            best="$version"
          fi
        fi
      fi
    done < <(find "$directory" -mindepth 1 -maxdepth 1 -type f -iname 'VERSION*' -print0)
  fi

  GIT_ROOT="$original_root"
  if [ -n "$best" ]; then
    HISTORY_CONTENT_VERSION="$best"
    return 0
  fi
  return 1
}

history_month_number() {
  case "$(lowercase "$1")" in
    jan|january) printf '1' ;;
    feb|february) printf '2' ;;
    mar|march) printf '3' ;;
    apr|april) printf '4' ;;
    may) printf '5' ;;
    jun|june) printf '6' ;;
    jul|july) printf '7' ;;
    aug|august) printf '8' ;;
    sep|sept|september) printf '9' ;;
    oct|october) printf '10' ;;
    nov|november) printf '11' ;;
    dec|december) printf '12' ;;
    *) return 1 ;;
  esac
}

normalize_history_date() {
  local value=""
  local year=""
  local month=""
  local day=""
  local first=""
  local second=""
  local third=""
  local extra=""

  HISTORY_NORMALIZED_DATE=""
  value="$(trim "$1")"
  value="${value#\(}"
  value="${value%\)}"
  value="${value//,/}"
  value="$(trim "$value")"

  if [[ "$value" =~ ^([0-9]{4})[-./]([0-9]{1,2})[-./]([0-9]{1,2})$ ]]; then
    year="${BASH_REMATCH[1]}"
    month="${BASH_REMATCH[2]}"
    day="${BASH_REMATCH[3]}"
  elif [[ "$value" =~ ^([0-9]{4})年([0-9]{1,2})月([0-9]{1,2})日$ ]]; then
    year="${BASH_REMATCH[1]}"
    month="${BASH_REMATCH[2]}"
    day="${BASH_REMATCH[3]}"
  else
    IFS=' ' read -r first second third extra <<< "$value"
    [ -z "$extra" ] || return 1
    if month="$(history_month_number "$first" 2>/dev/null)"; then
      day="$second"
      year="$third"
    elif month="$(history_month_number "$second" 2>/dev/null)"; then
      day="$first"
      year="$third"
    else
      return 1
    fi
  fi

  [[ "$year" =~ ^[0-9]{4}$ ]] || return 1
  [[ "$month" =~ ^[0-9]{1,2}$ ]] || return 1
  [[ "$day" =~ ^[0-9]{1,2}$ ]] || return 1
  month="$((10#$month))"
  day="$((10#$day))"
  [ "$month" -ge 1 ] && [ "$month" -le 12 ] || return 1
  [ "$day" -ge 1 ] && [ "$day" -le 31 ] || return 1

  case "$month" in
    4|6|9|11)
      [ "$day" -le 30 ] || return 1
      ;;
    2)
      if [ $((10#$year % 400)) -eq 0 ] ||
         { [ $((10#$year % 4)) -eq 0 ] && [ $((10#$year % 100)) -ne 0 ]; }; then
        [ "$day" -le 29 ] || return 1
      else
        [ "$day" -le 28 ] || return 1
      fi
      ;;
  esac

  printf -v HISTORY_NORMALIZED_DATE '%04d-%02d-%02d' "$year" "$month" "$day"
  return 0
}

extract_history_date_from_changelog() {
  local file="$1"
  local expected_version="$2"
  local line=""
  local normalized=""
  local found_version=""
  local date_text=""
  local match_pattern=""

  HISTORY_CHANGELOG_DATE=""
  match_pattern="^[[:space:]]*#{0,6}[[:space:]]*\\[?[vV]?(${SEMVER_PATTERN})\\]?[[:space:]]*-[[:space:]]*(.+)$"

  while IFS= read -r line || [ -n "$line" ]; do
    normalized="${line%$'\r'}"
    normalized="${normalized//‐/-}"
    normalized="${normalized//‑/-}"
    normalized="${normalized//‒/-}"
    normalized="${normalized//–/-}"
    normalized="${normalized//—/-}"
    normalized="${normalized//−/-}"
    if [[ "$normalized" =~ $match_pattern ]]; then
      found_version="${BASH_REMATCH[1]}"
      date_text="${BASH_REMATCH[5]}"
      if [ "$found_version" = "$expected_version" ] && normalize_history_date "$date_text"; then
        HISTORY_CHANGELOG_DATE="$HISTORY_NORMALIZED_DATE"
        return 0
      fi
    fi
  done < "$file"
  return 1
}

detect_history_release_date() {
  local directory="$1"
  local version="$2"
  local file=""
  local detected=""

  HISTORY_DETECTED_DATE=""
  while IFS= read -r -d '' file; do
    if extract_history_date_from_changelog "$file" "$version"; then
      if [ -z "$detected" ]; then
        detected="$HISTORY_CHANGELOG_DATE"
      elif [ "$detected" != "$HISTORY_CHANGELOG_DATE" ]; then
        return 1
      fi
    fi
  done < <(find "$directory" -mindepth 1 -maxdepth 1 -type f -iname 'CHANGELOG*' -print0)

  if [ -n "$detected" ]; then
    HISTORY_DETECTED_DATE="$detected"
    return 0
  fi
  return 1
}

reset_history_releases() {
  HISTORY_RELEASE_VERSIONS=()
  HISTORY_RELEASE_DIRECTORIES=()
  HISTORY_RELEASE_DATES=()
  HISTORY_RELEASE_NEEDS_GITIGNORE=()
  HISTORY_RELEASE_COUNT=0
  HISTORY_CONFLICT_DIRECTORIES=()
  HISTORY_CONFLICT_FOLDER_VERSIONS=()
  HISTORY_CONFLICT_CONTENT_VERSIONS=()
  HISTORY_CONFLICT_COUNT=0
  HISTORY_SKIPPED_DIRECTORIES=()
  HISTORY_SKIPPED_COUNT=0
  HISTORY_GITIGNORE_CONTENT=""
  HISTORY_ADD_GITIGNORE=false
}

history_release_index() {
  local version="$1"
  local index=0

  while [ "$index" -lt "$HISTORY_RELEASE_COUNT" ]; do
    if [ "${HISTORY_RELEASE_VERSIONS[$index]}" = "$version" ]; then
      printf '%s' "$index"
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

history_add_release() {
  local version="$1"
  local directory="$2"
  local date="${3:-}"

  valid_release_version "$version" || return 1
  [ -d "$directory" ] || return 1
  if history_release_index "$version" >/dev/null 2>&1; then
    return 2
  fi

  HISTORY_RELEASE_VERSIONS[$HISTORY_RELEASE_COUNT]="$version"
  HISTORY_RELEASE_DIRECTORIES[$HISTORY_RELEASE_COUNT]="$directory"
  HISTORY_RELEASE_DATES[$HISTORY_RELEASE_COUNT]="$date"
  if [ -e "$directory/.gitignore" ] || [ -L "$directory/.gitignore" ]; then
    HISTORY_RELEASE_NEEDS_GITIGNORE[$HISTORY_RELEASE_COUNT]="no"
  else
    HISTORY_RELEASE_NEEDS_GITIGNORE[$HISTORY_RELEASE_COUNT]="yes"
  fi
  HISTORY_RELEASE_COUNT=$((HISTORY_RELEASE_COUNT + 1))
  return 0
}

history_sort_releases() {
  local index=1
  local position=0
  local key_version=""
  local key_directory=""
  local key_date=""
  local key_gitignore=""
  local should_shift=false

  while [ "$index" -lt "$HISTORY_RELEASE_COUNT" ]; do
    key_version="${HISTORY_RELEASE_VERSIONS[$index]}"
    key_directory="${HISTORY_RELEASE_DIRECTORIES[$index]}"
    key_date="${HISTORY_RELEASE_DATES[$index]}"
    key_gitignore="${HISTORY_RELEASE_NEEDS_GITIGNORE[$index]}"
    position="$index"

    while [ "$position" -gt 0 ]; do
      compare_semver "$key_version" "${HISTORY_RELEASE_VERSIONS[$((position - 1))]}"
      should_shift=false
      if [ "$SEMVER_COMPARISON" -lt 0 ]; then
        should_shift=true
      elif [ "$SEMVER_COMPARISON" -eq 0 ] &&
           [[ "$key_version" < "${HISTORY_RELEASE_VERSIONS[$((position - 1))]}" ]]; then
        should_shift=true
      fi
      [ "$should_shift" = true ] || break

      HISTORY_RELEASE_VERSIONS[$position]="${HISTORY_RELEASE_VERSIONS[$((position - 1))]}"
      HISTORY_RELEASE_DIRECTORIES[$position]="${HISTORY_RELEASE_DIRECTORIES[$((position - 1))]}"
      HISTORY_RELEASE_DATES[$position]="${HISTORY_RELEASE_DATES[$((position - 1))]}"
      HISTORY_RELEASE_NEEDS_GITIGNORE[$position]="${HISTORY_RELEASE_NEEDS_GITIGNORE[$((position - 1))]}"
      position=$((position - 1))
    done

    HISTORY_RELEASE_VERSIONS[$position]="$key_version"
    HISTORY_RELEASE_DIRECTORIES[$position]="$key_directory"
    HISTORY_RELEASE_DATES[$position]="$key_date"
    HISTORY_RELEASE_NEEDS_GITIGNORE[$position]="$key_gitignore"
    index=$((index + 1))
  done
}

history_scan_parent_directory() {
  local parent="$1"
  local directory=""
  local name=""
  local folder_version=""
  local content_version=""
  local chosen_version=""
  local date=""

  while IFS= read -r -d '' directory; do
    name="$(basename "$directory")"
    folder_version=""
    content_version=""
    chosen_version=""
    date=""

    if extract_version_from_directory_name "$name"; then
      folder_version="$HISTORY_DIRECTORY_VERSION"
    fi
    if detect_release_version_from_contents "$directory"; then
      content_version="$HISTORY_CONTENT_VERSION"
    fi

    if [ -n "$folder_version" ] && [ -n "$content_version" ] &&
       [ "$folder_version" != "$content_version" ]; then
      HISTORY_CONFLICT_DIRECTORIES[$HISTORY_CONFLICT_COUNT]="$directory"
      HISTORY_CONFLICT_FOLDER_VERSIONS[$HISTORY_CONFLICT_COUNT]="$folder_version"
      HISTORY_CONFLICT_CONTENT_VERSIONS[$HISTORY_CONFLICT_COUNT]="$content_version"
      HISTORY_CONFLICT_COUNT=$((HISTORY_CONFLICT_COUNT + 1))
      continue
    fi

    if [ -n "$folder_version" ]; then
      chosen_version="$folder_version"
    else
      chosen_version="$content_version"
    fi

    if [ -z "$chosen_version" ]; then
      HISTORY_SKIPPED_DIRECTORIES[$HISTORY_SKIPPED_COUNT]="$directory"
      HISTORY_SKIPPED_COUNT=$((HISTORY_SKIPPED_COUNT + 1))
      continue
    fi

    if detect_history_release_date "$directory" "$chosen_version"; then
      date="$HISTORY_DETECTED_DATE"
    fi
    if ! history_add_release "$chosen_version" "$directory" "$date"; then
      HISTORY_SKIPPED_DIRECTORIES[$HISTORY_SKIPPED_COUNT]="$directory"
      HISTORY_SKIPPED_COUNT=$((HISTORY_SKIPPED_COUNT + 1))
    fi
  done < <(find "$parent" -mindepth 1 -maxdepth 1 -type d -print0)
}

history_sensitive_name() {
  local name_lc=""

  name_lc="$(lowercase "$1")"
  case "$name_lc" in
    .env.example|.env.sample|.env.template|.env.defaults)
      return 1
      ;;
    .env|.env.*|.netrc|.npmrc|.pypirc|.git-credentials|credentials|credentials.json|id_rsa|id_dsa|id_ecdsa|id_ed25519|*.pem|*.p12|*.pfx|*.key|*.kdbx|*.ppk)
      return 0
      ;;
  esac
  return 1
}

history_contains_private_key_header() {
  local file="$1"
  local first_content_line=""

  [ -f "$file" ] || return 1

  while IFS= read -r first_content_line || [ -n "$first_content_line" ]; do
    first_content_line="${first_content_line%$'\r'}"
    [ -n "$first_content_line" ] || continue

    case "$first_content_line" in
      '-----BEGIN PRIVATE KEY-----'|\
      '-----BEGIN ENCRYPTED PRIVATE KEY-----'|\
      '-----BEGIN OPENSSH PRIVATE KEY-----'|\
      '-----BEGIN RSA PRIVATE KEY-----'|\
      '-----BEGIN DSA PRIVATE KEY-----'|\
      '-----BEGIN EC PRIVATE KEY-----'|\
      '-----BEGIN SSH2 PRIVATE KEY-----'|\
      '-----BEGIN SSH2 ENCRYPTED PRIVATE KEY-----'|\
      '-----BEGIN PGP PRIVATE KEY BLOCK-----'|\
      PuTTY-User-Key-File-2:*|\
      PuTTY-User-Key-File-3:*)
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  done < "$file"

  return 1
}

history_scan_risks() {
  local index=0
  local version=""
  local directory=""
  local file=""
  local relative=""
  local size=0
  local sensitive_reason=""

  HISTORY_SENSITIVE_FILES=()
  HISTORY_SENSITIVE_REASONS=()
  HISTORY_SENSITIVE_COUNT=0
  HISTORY_LARGE_FILES=()
  HISTORY_LARGE_COUNT=0

  advanced_info \
    "Checking $HISTORY_RELEASE_COUNT release snapshot(s) for sensitive or oversized files..." \
    "正在检查 $HISTORY_RELEASE_COUNT 个版本快照中是否包含敏感文件或超大文件……"
  while [ "$index" -lt "$HISTORY_RELEASE_COUNT" ]; do
    version="${HISTORY_RELEASE_VERSIONS[$index]}"
    directory="${HISTORY_RELEASE_DIRECTORIES[$index]}"
    advanced_muted \
      "[$((index + 1))/$HISTORY_RELEASE_COUNT] Scanning release $version..." \
      "[$((index + 1))/$HISTORY_RELEASE_COUNT] 正在检查版本 ${version}……"
    while IFS= read -r -d '' file; do
      relative="${file#"$directory"/}"
      [ "$(basename "$file")" != ".DS_Store" ] || continue
      size="$(file_size_bytes "$file" 2>/dev/null || printf '0')"
      if [ "$size" -gt "$HISTORY_MAX_FILE_BYTES" ] 2>/dev/null; then
        HISTORY_LARGE_FILES[$HISTORY_LARGE_COUNT]="$version: $relative ($size bytes)"
        HISTORY_LARGE_COUNT=$((HISTORY_LARGE_COUNT + 1))
      fi
      sensitive_reason=""
      if history_sensitive_name "$(basename "$file")"; then
        sensitive_reason="sensitive-name"
      elif history_contains_private_key_header "$file"; then
        sensitive_reason="private-key-header"
      fi
      if [ -n "$sensitive_reason" ]; then
        HISTORY_SENSITIVE_FILES[$HISTORY_SENSITIVE_COUNT]="$version: $relative"
        HISTORY_SENSITIVE_REASONS[$HISTORY_SENSITIVE_COUNT]="$sensitive_reason"
        HISTORY_SENSITIVE_COUNT=$((HISTORY_SENSITIVE_COUNT + 1))
      fi
    done < <(
      find "$directory" \
        \( -name .git -prune \) -o \
        \( -type f -print0 \)
    )
    index=$((index + 1))
  done
  advanced_success \
    "Safety scan completed for all release snapshots." \
    "所有版本快照的文件安全检查已完成。"
}

history_collect_gitignore_content() {
  local line=""
  local first=true

  HISTORY_GITIGNORE_CONTENT=""
  advanced_muted \
    "Paste the .gitignore rules below, one rule per line." \
    "请逐行粘贴要写入 .gitignore 的规则。"
  advanced_muted \
    "Enter :done on a line by itself when finished, or :cancel to continue without adding one." \
    "全部输入完成后，请另起一行输入 :done；如果不想添加，请输入 :cancel。"

  while true; do
    printf '> '
    IFS= read -r line || return 1
    case "$line" in
      :done)
        break
        ;;
      :cancel)
        HISTORY_GITIGNORE_CONTENT=""
        return 1
        ;;
    esac
    if [ "$first" = true ]; then
      HISTORY_GITIGNORE_CONTENT="$line"
      first=false
    else
      HISTORY_GITIGNORE_CONTENT="$HISTORY_GITIGNORE_CONTENT
$line"
    fi
  done

  [ "$first" = false ]
}

history_resolve_version_conflicts() {
  local index=0
  local choice=""
  local version=""
  local date=""

  while [ "$index" -lt "$HISTORY_CONFLICT_COUNT" ]; do
    advanced_heading "Version conflict" "同一版本文件夹中出现了两个版本号"
    advanced_muted \
      "Folder: ${HISTORY_CONFLICT_DIRECTORIES[$index]}" \
      "文件夹：${HISTORY_CONFLICT_DIRECTORIES[$index]}"
    advanced_muted \
      "Folder name says ${HISTORY_CONFLICT_FOLDER_VERSIONS[$index]}, but its files say ${HISTORY_CONFLICT_CONTENT_VERSIONS[$index]}." \
      "从文件夹名称识别到 ${HISTORY_CONFLICT_FOLDER_VERSIONS[$index]}，从文件夹内容识别到 ${HISTORY_CONFLICT_CONTENT_VERSIONS[$index]}。"
    if [ "$ADVANCED_LANGUAGE" = "en" ]; then
      printf '  1) Use the folder-name version (recommended)\n'
      printf '  2) Use the version found inside the folder\n'
      printf '  0) Skip this folder\n'
    else
      printf '  1) 采用文件夹名称中的版本号（推荐）\n'
      printf '  2) 采用文件夹内容中的版本号\n'
      printf '  0) 跳过这个文件夹\n'
    fi

    while true; do
      choice="$(advanced_prompt_value "Choose" "选择" "1")" || return 1
      case "$choice" in
        1)
          version="${HISTORY_CONFLICT_FOLDER_VERSIONS[$index]}"
          break
          ;;
        2)
          version="${HISTORY_CONFLICT_CONTENT_VERSIONS[$index]}"
          break
          ;;
        0)
          version=""
          break
          ;;
        *)
          advanced_warn "Enter a number from the list." "请输入列表中的序号。"
          ;;
      esac
    done

    if [ -n "$version" ]; then
      date=""
      if detect_history_release_date "${HISTORY_CONFLICT_DIRECTORIES[$index]}" "$version"; then
        date="$HISTORY_DETECTED_DATE"
      fi
      if ! history_add_release "$version" "${HISTORY_CONFLICT_DIRECTORIES[$index]}" "$date"; then
        advanced_warn \
          "Version $version is already in the release list, so this folder was skipped." \
          "版本 $version 已经在列表中，这个重复文件夹不会加入。"
      fi
    fi
    index=$((index + 1))
  done
}

history_add_manual_releases() {
  local default_answer="no"
  local input=""
  local directory=""
  local suggested=""
  local version=""
  local date=""

  if [ "$HISTORY_RELEASE_COUNT" -eq 0 ]; then
    default_answer="yes"
  fi

  while advanced_prompt_yes_no \
    "Add a release folder manually?" \
    "还要手动添加其他版本文件夹吗？" \
    "$default_answer"; do
    while true; do
      input="$(advanced_prompt_value "Release folder" "版本文件夹")" || return 1
      if normalize_history_directory_input "$input"; then
        directory="$HISTORY_NORMALIZED_DIRECTORY"
        break
      fi
      advanced_warn "That folder could not be opened." "无法打开这个文件夹。"
    done

    suggested=""
    if extract_version_from_directory_name "$(basename "$directory")"; then
      suggested="$HISTORY_DIRECTORY_VERSION"
    elif detect_release_version_from_contents "$directory"; then
      suggested="$HISTORY_CONTENT_VERSION"
    fi

    while true; do
      version="$(advanced_prompt_value "Release version" "版本号" "$suggested")" || return 1
      version="${version#v}"
      version="${version#V}"
      if valid_release_version "$version"; then
        break
      fi
      advanced_warn \
        "Use a semantic version such as 1.2.3 or 2.0.0-beta.1." \
        "请输入类似 1.2.3 或 2.0.0-beta.1 的语义化版本号。"
    done

    date=""
    if detect_history_release_date "$directory" "$version"; then
      date="$HISTORY_DETECTED_DATE"
    fi
    if history_add_release "$version" "$directory" "$date"; then
      advanced_success "Added release $version." "版本 ${version} 已加入列表。"
    else
      advanced_warn \
        "Version $version is already listed; the duplicate was not added." \
        "版本 $version 已存在，没有重复添加。"
    fi
    default_answer="no"
  done
}

history_show_release_plan() {
  local index=0
  local page=0
  local page_count=""
  local start=0
  local end=0
  local label=""
  local navigation_status=0
  local date_label=""
  local gitignore_label=""

  advanced_heading "Release plan" "确认要重建的版本与顺序"
  page_count="$(paged_choice_page_count "$HISTORY_RELEASE_COUNT")"
  while true; do
    start=$((page * PAGED_CHOICE_PAGE_SIZE))
    end=$((start + PAGED_CHOICE_PAGE_SIZE))
    [ "$end" -le "$HISTORY_RELEASE_COUNT" ] || end="$HISTORY_RELEASE_COUNT"
    print_paged_page_status "$page" "$HISTORY_RELEASE_COUNT" "$ADVANCED_LANGUAGE"

    index="$start"
    while [ "$index" -lt "$end" ]; do
      date_label="${HISTORY_RELEASE_DATES[$index]}"
      if [ -z "$date_label" ]; then
        if [ "$ADVANCED_LANGUAGE" = "en" ]; then
          date_label="import time"
        else
          date_label="导入时间"
        fi
      fi
      gitignore_label=""
      if [ "${HISTORY_RELEASE_NEEDS_GITIGNORE[$index]}" = "yes" ]; then
        if [ "$ADVANCED_LANGUAGE" = "en" ]; then
          gitignore_label="; no .gitignore"
        else
          gitignore_label="；缺少 .gitignore"
        fi
      fi
      label="$(paged_choice_label "$((index - start))")" || return 1
      printf '  %s) %s  [%s%s]\n' \
        "$label" \
        "Release ${HISTORY_RELEASE_VERSIONS[$index]}" \
        "$date_label" \
        "$gitignore_label"
      printf '     %s\n' "${HISTORY_RELEASE_DIRECTORIES[$index]}"
      index=$((index + 1))
    done

    [ "$page_count" -gt 1 ] || return 0
    navigation_status=0
    advanced_paged_review_navigation "$page" "$HISTORY_RELEASE_COUNT" || navigation_status=$?
    if [ "$navigation_status" -eq 2 ]; then
      return 0
    elif [ "$navigation_status" -ne 0 ]; then
      return 1
    fi
    page="$PAGED_CHOICE_PAGE"
    printf '\n'
  done
}

history_offer_missing_gitignore() {
  local index=0
  local missing_count=0

  while [ "$index" -lt "$HISTORY_RELEASE_COUNT" ]; do
    if [ "${HISTORY_RELEASE_NEEDS_GITIGNORE[$index]}" = "yes" ]; then
      missing_count=$((missing_count + 1))
    fi
    index=$((index + 1))
  done

  [ "$missing_count" -gt 0 ] || return 0
  advanced_heading "Missing .gitignore" "部分版本没有 .gitignore"
  advanced_muted \
    "$missing_count release(s) in the reviewed plan have no root .gitignore." \
    "刚才列出的版本中，有 $missing_count 个版本的根目录缺少 .gitignore。"
  advanced_muted \
    "You can supply one shared file for only those missing releases. Existing .gitignore files will not be replaced." \
    "你可以输入一份通用规则，脚本只会把它补到缺失的版本中，不会覆盖已经存在的 .gitignore。"
  if advanced_prompt_yes_no \
    "Add .gitignore content to the missing releases?" \
    "为缺失版本补充 .gitignore 内容？" \
    "yes"; then
    if history_collect_gitignore_content; then
      HISTORY_ADD_GITIGNORE=true
      advanced_success \
        "The supplied .gitignore will be added to missing snapshots." \
        "重建时会为缺失的版本补上这份 .gitignore。"
    else
      HISTORY_ADD_GITIGNORE=false
      advanced_warn \
        "No .gitignore content will be added." \
        "不会补充 .gitignore 内容。"
    fi
  fi
}

history_show_paginated_list() {
  local kind="$1"
  local count=0
  local page=0
  local page_count=""
  local start=0
  local end=0
  local index=0
  local label=""
  local item=""
  local reason=""
  local navigation_status=0

  if [ "$kind" = "large" ]; then
    count="$HISTORY_LARGE_COUNT"
  elif [ "$kind" = "sensitive" ]; then
    count="$HISTORY_SENSITIVE_COUNT"
  elif [ "$kind" = "skipped" ]; then
    count="$HISTORY_SKIPPED_COUNT"
  else
    return 1
  fi

  page_count="$(paged_choice_page_count "$count")"
  while true; do
    start=$((page * PAGED_CHOICE_PAGE_SIZE))
    end=$((start + PAGED_CHOICE_PAGE_SIZE))
    [ "$end" -le "$count" ] || end="$count"
    print_paged_page_status "$page" "$count" "$ADVANCED_LANGUAGE"

    index="$start"
    while [ "$index" -lt "$end" ]; do
      case "$kind" in
        large)
          item="${HISTORY_LARGE_FILES[$index]}"
          ;;
        sensitive)
          item="${HISTORY_SENSITIVE_FILES[$index]}"
          reason="${HISTORY_SENSITIVE_REASONS[$index]:-sensitive-name}"
          if [ "$ADVANCED_LANGUAGE" = "en" ]; then
            if [ "$reason" = "private-key-header" ]; then
              item="$item — Reason: the file begins with a recognized private-key header."
            else
              item="$item — Reason: this filename commonly stores credentials, private configuration, or key material."
            fi
          else
            if [ "$reason" = "private-key-header" ]; then
              item="$item —— 原因：文件开头符合常见私钥格式。"
            else
              item="$item —— 原因：这个文件名通常用于保存凭据、私人配置或密钥材料。"
            fi
          fi
          ;;
        skipped)
          item="${HISTORY_SKIPPED_DIRECTORIES[$index]}"
          ;;
      esac
      label="$(paged_choice_label "$((index - start))")" || return 1
      printf '  %s) %s\n' "$label" "$item"
      index=$((index + 1))
    done

    [ "$page_count" -gt 1 ] || return 0
    navigation_status=0
    advanced_paged_review_navigation "$page" "$count" || navigation_status=$?
    if [ "$navigation_status" -eq 2 ]; then
      return 0
    elif [ "$navigation_status" -ne 0 ]; then
      return 1
    fi
    page="$PAGED_CHOICE_PAGE"
    printf '\n'
  done
}

history_review_risks() {
  history_scan_risks

  if [ "$HISTORY_LARGE_COUNT" -gt 0 ]; then
    advanced_heading "Files too large for a normal GitHub push" "发现 GitHub 无法直接接收的大文件"
    history_show_paginated_list large || return 1
    advanced_error \
      "Remove or redesign these files before rebuilding history. No temporary repository was created." \
      "请先从存档中移除这些文件，或改用适合大文件的方案。脚本尚未创建临时仓库。"
    return 1
  fi

  if [ "$HISTORY_SENSITIVE_COUNT" -gt 0 ]; then
    advanced_heading "Files that need a publication check" "发现需要确认是否可以公开的文件"
    history_show_paginated_list sensitive || return 1
    advanced_muted \
      "Each item shows why it was flagged. Complete snapshots include these files, so confirm only after checking that they are safe to publish." \
      "每一项后面都说明了触发检查的原因。完整快照会原样包含这些文件，请逐项确认它们可以上传到 GitHub。"
    if ! advanced_prompt_yes_no \
      "Include these files and continue?" \
      "已经检查完毕，仍然包含这些文件并继续吗？" \
      "no"; then
      advanced_warn "Import stopped before any repository was created." "操作已停止；尚未创建临时仓库，也没有修改远端。"
      return 1
    fi
  fi
  return 0
}

advanced_verify_key_matches_username() {
  local private_key="$1"
  local expected_username="$2"

  advanced_info "Verifying the exact GitHub account..." "正在核对这把密钥对应的 GitHub 账号……"
  if ! identify_key_username "$private_key"; then
    advanced_error \
      "GitHub did not accept this account's key." \
      "GitHub 无法使用这把密钥完成身份验证。"
    if [ -n "${SSH_VERIFICATION_OUTPUT:-}" ]; then
      muted "${SSH_VERIFICATION_OUTPUT##*$'\n'}"
    fi
    return 1
  fi
  if [ "$(lowercase "$VERIFIED_GITHUB_USERNAME")" != "$(lowercase "$expected_username")" ]; then
    advanced_error \
      "This key authenticates as $VERIFIED_GITHUB_USERNAME, not $expected_username." \
      "该密钥实际属于 ${VERIFIED_GITHUB_USERNAME}，而不是 ${expected_username}。"
    return 1
  fi
  advanced_success \
    "Verified GitHub account: $VERIFIED_GITHUB_USERNAME" \
    "已确认 GitHub 账号：$VERIFIED_GITHUB_USERNAME"
}

advanced_add_account() {
  local username=""
  local email=""
  local default_email=""

  while true; do
    username="$(advanced_prompt_value "GitHub username" "GitHub 用户名")" || return 1
    username="$(lowercase "$username")"
    if valid_github_username "$username"; then
      break
    fi
    advanced_warn \
      "GitHub usernames normally contain only letters, numbers, and hyphens." \
      "GitHub 用户名通常只包含字母、数字和连字符。"
  done

  default_email="$(default_email_for_username "$username")"
  while true; do
    email="$(advanced_prompt_value "Commit email" "提交邮箱" "$default_email")" || return 1
    if valid_email "$email"; then
      break
    fi
    advanced_warn "The email format was not recognized." "邮箱格式无法识别。"
  done

  if ! check_saved_account_identity "$username" "$email"; then
    return 1
  fi

  add_or_update_account "$username" "$email"
  write_accounts_to_private_config
  BOUND_USERNAME="$username"
  BOUND_EMAIL="$email"
  BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
  BOUND_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
  advanced_success \
    "Saved account $username and its commit email in private/config.txt." \
    "已把账号 $username 和提交邮箱保存到 private/config.txt。"
}

advanced_select_account_for_history() {
  local owner="$1"
  local index=""
  local email=""

  if index="$(account_index "$owner" 2>/dev/null)"; then
    BOUND_USERNAME="${ACCOUNT_USERNAMES[$index]}"
    BOUND_EMAIL="${ACCOUNT_EMAILS[$index]}"
  else
    advanced_info \
      "The destination repository belongs to $owner, but that account is not saved yet. To prevent accounts from being mixed, only account $owner can be used." \
      "目标仓库属于 ${owner}，但这个账号尚未保存。为避免多个账号相互串用，这里只能使用账号 ${owner}。"
    email="$(default_email_for_username "$owner")"
    while true; do
      email="$(advanced_prompt_value "Commit email" "提交邮箱" "$email")" || return 1
      if valid_email "$email"; then
        break
      fi
      advanced_warn "The email format was not recognized." "邮箱格式无法识别，请重新输入。"
    done
    check_saved_account_identity "$owner" "$email" || return 1
    add_or_update_account "$owner" "$email"
    write_accounts_to_private_config
    BOUND_USERNAME="$owner"
    BOUND_EMAIL="$email"
    BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
    BOUND_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
    advanced_success \
      "Saved repository owner $owner and its commit email in private/config.txt." \
      "已把仓库所属账号 ${owner} 及其提交邮箱保存到 private/config.txt。"
    return 0
  fi

  check_saved_account_identity "$BOUND_USERNAME" "$BOUND_EMAIL" || return 1
  BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
  BOUND_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
  return 0
}

advanced_verify_repository_access() {
  local target="$1"
  local GIT_ROOT="$SCRIPT_DIRECTORY"
  local output=""
  local detail=""

  require_repository_account_match || return 1
  while true; do
    advanced_info \
      "Checking ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME} with the SSH key verified for its owner, $BOUND_USERNAME. This does not upload or change the repository." \
      "正在使用已确认为仓库所属账号 ${BOUND_USERNAME} 的 SSH 密钥，检查 ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}；这一步不会上传或修改仓库。"
    output="$(run_git_with_identity "$BOUND_IDENTITY_FILE" ls-remote "$target" HEAD 2>&1)" && {
      advanced_success \
        "The repository responded to the SSH key verified for account $BOUND_USERNAME. Upload permission will be confirmed when git push runs." \
        "仓库已响应账号 ${BOUND_USERNAME} 的已验证 SSH 密钥。实际上传权限将在执行 git push 时得到最终确认。"
      return 0
    }
    advanced_error \
      "Account $BOUND_USERNAME cannot currently access ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}." \
      "账号 $BOUND_USERNAME 当前无法访问 ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}。"
    detail="${output##*$'\n'}"
    if [ -n "$detail" ]; then
      advanced_muted "Git result: $detail" "Git 返回信息：$detail"
    fi
    advanced_muted \
      "Make sure the repository exists and this account has access: https://github.com/new" \
      "请确认仓库已经创建，且该账号拥有访问权限：https://github.com/new"
    if ! advanced_prompt_yes_no \
      "Run the same read-only access check again?" \
      "要再次执行同一项只读访问检查吗？" \
      "yes"; then
      return 1
    fi
  done
}

advanced_prepare_history_destination() {
  local input=""
  local remote_url=""
  local selection_status=0

  advanced_heading "Destination repository" "选择接收重建历史的仓库"
  advanced_muted \
    "Paste owner/repository, a GitHub page URL, HTTPS URL, or SSH URL." \
    "可以粘贴 owner/repository、GitHub 网页地址、HTTPS 或 SSH 地址。"
  while true; do
    input="$(advanced_prompt_value "Repository" "仓库地址")" || return 1
    if parse_repository_input "$input"; then
      break
    fi
    advanced_warn "That GitHub repository address was not recognized." "未能从输入内容中识别出 GitHub 仓库，请检查后重试。"
  done
  CURRENT_REPOSITORY_OWNER="$REPOSITORY_OWNER"
  CURRENT_REPOSITORY_NAME="$REPOSITORY_NAME"

  advanced_select_account_for_history \
    "$CURRENT_REPOSITORY_OWNER" || selection_status=$?
  if [ "$selection_status" -ne 0 ]; then
    return "$selection_status"
  fi
  remote_url="git@${BOUND_SSH_ALIAS}:${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}.git"
  advanced_verify_repository_access "$remote_url" || return 1
  HISTORY_REMOTE_URL="$remote_url"
}

history_safe_temporary_path() {
  local path="$1"
  local kind="$2"
  local base="${TMPDIR:-/tmp}"

  base="${base%/}"
  [ -n "$path" ] || return 1
  [ "$path" != "/" ] || return 1
  [ "$path" != "${HOME:-}" ] || return 1
  case "$path" in
    "$base/github-auto-${kind}."*)
      return 0
      ;;
  esac
  return 1
}

history_temporary_base() {
  local base="${TMPDIR:-/tmp}"

  printf '%s' "${base%/}"
}

history_remove_temporary_directory() {
  local path="$1"
  local kind="$2"

  history_safe_temporary_path "$path" "$kind" || return 1
  rm -rf "$path"
}

history_prepare_snapshot_copy() {
  local source_directory="$1"
  local snapshot_directory=""
  local unwanted=""

  snapshot_directory="$(mktemp -d "$(history_temporary_base)/github-auto-snapshot.XXXXXX")" || return 1
  if ! cp -Rp "$source_directory/." "$snapshot_directory/"; then
    history_remove_temporary_directory "$snapshot_directory" snapshot || true
    return 1
  fi

  chmod -R u+w "$snapshot_directory" 2>/dev/null || true
  while IFS= read -r -d '' unwanted; do
    rm -rf "$unwanted"
  done < <(
    find "$snapshot_directory" \
      \( -name .git -print0 -prune \) -o \
      \( -name .DS_Store -print0 \)
  )
  HISTORY_SNAPSHOT_DIRECTORY="$snapshot_directory"
}

history_replace_worktree_snapshot() {
  local work_directory="$1"
  local source_directory="$2"
  local entry=""

  [ -f "$work_directory/.git/github-auto-history-workspace" ] || return 1
  history_prepare_snapshot_copy "$source_directory" || return 1

  while IFS= read -r -d '' entry; do
    chmod -R u+w "$entry" 2>/dev/null || true
    rm -rf "$entry"
  done < <(find "$work_directory" -mindepth 1 -maxdepth 1 ! -name .git -print0)

  if ! cp -Rp "$HISTORY_SNAPSHOT_DIRECTORY/." "$work_directory/"; then
    history_remove_temporary_directory "$HISTORY_SNAPSHOT_DIRECTORY" snapshot || true
    return 1
  fi
  history_remove_temporary_directory "$HISTORY_SNAPSHOT_DIRECTORY" snapshot || return 1
}

history_build_repository() {
  local index=0
  local version=""
  local source_directory=""
  local release_date=""
  local commit_date=""
  local work_directory=""
  local short_commit=""
  local expected_tree=""
  local commit_message=""
  local GIT_ROOT=""

  if [ "$HISTORY_COMMITS_CONFIRMED" != true ]; then
    advanced_error \
      "History construction cannot create commits until the listed commit messages are confirmed." \
      "尚未确认刚才列出的提交说明，不能开始创建历史提交。"
    return 1
  fi
  HISTORY_COMMITS_CONFIRMED=false

  require_repository_account_match || return 1
  work_directory="$(mktemp -d "$(history_temporary_base)/github-auto-history.XXXXXX")" || return 1
  HISTORY_WORK_DIRECTORY="$work_directory"
  GIT_ROOT="$work_directory"

  if ! git -C "$work_directory" init -q; then
    return 1
  fi
  : > "$work_directory/.git/github-auto-history-workspace"
  git -C "$work_directory" symbolic-ref HEAD refs/heads/main || return 1
  git -C "$work_directory" config --local user.name "$BOUND_USERNAME" || return 1
  git -C "$work_directory" config --local user.email "$BOUND_EMAIL" || return 1
  git -C "$work_directory" config --local github-auto.username "$BOUND_USERNAME" || return 1
  git -C "$work_directory" config --local github-auto.ssh-alias "$BOUND_SSH_ALIAS" || return 1
  git -C "$work_directory" config --local github-auto.identity-file "$BOUND_IDENTITY_FILE" || return 1
  git -C "$work_directory" remote add origin "$HISTORY_REMOTE_URL" || return 1

  while [ "$index" -lt "$HISTORY_RELEASE_COUNT" ]; do
    version="${HISTORY_RELEASE_VERSIONS[$index]}"
    source_directory="${HISTORY_RELEASE_DIRECTORIES[$index]}"
    release_date="${HISTORY_RELEASE_DATES[$index]}"
    advanced_info \
      "[$((index + 1))/$HISTORY_RELEASE_COUNT] Building complete snapshot and commit for release $version..." \
      "[$((index + 1))/$HISTORY_RELEASE_COUNT] 正在整理版本 ${version} 的完整快照并创建提交……"

    if ! history_replace_worktree_snapshot "$work_directory" "$source_directory"; then
      return 1
    fi
    if [ "${HISTORY_RELEASE_NEEDS_GITIGNORE[$index]}" = "yes" ] &&
       [ "$HISTORY_ADD_GITIGNORE" = true ] &&
       [ ! -e "$work_directory/.gitignore" ] &&
       [ ! -L "$work_directory/.gitignore" ]; then
      printf '%s\n' "$HISTORY_GITIGNORE_CONTENT" > "$work_directory/.gitignore" || return 1
    fi

    git -C "$work_directory" add -A -f || return 1
    expected_tree="$(git -C "$work_directory" write-tree 2>/dev/null)" || return 1
    commit_message="Release $version"
    commit_date="$(history_commit_date_for_release "$release_date")"
    if [ -n "$commit_date" ]; then
      if ! GIT_AUTHOR_NAME="$BOUND_USERNAME" GIT_AUTHOR_EMAIL="$BOUND_EMAIL" \
        GIT_COMMITTER_NAME="$BOUND_USERNAME" GIT_COMMITTER_EMAIL="$BOUND_EMAIL" \
        GIT_AUTHOR_DATE="$commit_date" GIT_COMMITTER_DATE="$commit_date" \
        git -C "$work_directory" commit --cleanup=verbatim --allow-empty -q -m "$commit_message"; then
        return 1
      fi
    elif ! GIT_AUTHOR_NAME="$BOUND_USERNAME" GIT_AUTHOR_EMAIL="$BOUND_EMAIL" \
      GIT_COMMITTER_NAME="$BOUND_USERNAME" GIT_COMMITTER_EMAIL="$BOUND_EMAIL" \
      git -C "$work_directory" commit --cleanup=verbatim --allow-empty -q -m "$commit_message"; then
      return 1
    fi
    if [ "$(git -C "$work_directory" show -s --format='%T' HEAD 2>/dev/null || true)" != "$expected_tree" ] ||
       [ "$(git -C "$work_directory" show -s --format='%B' HEAD 2>/dev/null || true)" != "$commit_message" ] ||
       [ "$(git -C "$work_directory" show -s --format='%an <%ae>' HEAD 2>/dev/null || true)" != "$BOUND_USERNAME <$BOUND_EMAIL>" ] ||
       [ "$(git -C "$work_directory" show -s --format='%cn <%ce>' HEAD 2>/dev/null || true)" != "$BOUND_USERNAME <$BOUND_EMAIL>" ]; then
      advanced_error \
        "The release commit did not exactly match its confirmed files, message, or account identity. History construction stopped before upload." \
        "刚刚生成的版本提交与确认过的文件、提交说明或账号身份不完全一致。历史重建已停止，不会继续上传。"
      return 1
    fi

    short_commit="$(git -C "$work_directory" rev-parse --short HEAD)"
    advanced_success \
      "Release $version created at $short_commit." \
      "版本 ${version} 已生成提交 ${short_commit}。"
    index=$((index + 1))
  done
  return 0
}

history_commit_date_for_release() {
  local release_date="$1"

  if [ "$HISTORY_REBUILD_DATES" = true ] && [ -n "$release_date" ]; then
    printf '%sT12:00:00 +0000' "$release_date"
  fi
}

HISTORY_REMOTE_MAIN_OID=""

history_read_remote_main() {
  local output=""

  HISTORY_REMOTE_MAIN_OID=""
  output="$(run_git_with_identity "$BOUND_IDENTITY_FILE" ls-remote --heads origin refs/heads/main 2>/dev/null)" || return 1
  HISTORY_REMOTE_MAIN_OID="$(printf '%s\n' "$output" | awk '$2 == "refs/heads/main" { print $1; exit }')"
}

history_push_main_branch() {
  local initial_oid="$HISTORY_REMOTE_MAIN_OID"

  if [ -z "$initial_oid" ]; then
    advanced_info \
      "The remote has no main branch. A normal push will create it without overwriting another branch." \
      "远端目前没有 main 分支。脚本会正常新建 main，不会覆盖已有分支。"
    advanced_info \
      "Uploading rebuilt main. Git transfer progress will appear below." \
      "正在上传重建后的 main；下方会实时显示 Git 传输进度。"
    run_git_with_identity "$BOUND_IDENTITY_FILE" push --progress -u origin main:main
    return
  fi

  advanced_heading "Remote main already has history" "远端的 main 分支已有提交记录"
  advanced_muted \
    "Replacing main will make the rebuilt releases the new main history. Other remote branches are not changed." \
    "继续后，重建的版本记录会取代现有的 main 历史；其他远端分支不会受到影响。"
  advanced_muted \
    "No backup branch will be created. Anyone using the old main history will need to resynchronize." \
    "脚本不会额外创建备份分支。已经拉取过旧 main 的协作者需要重新同步本地仓库。"
  advanced_muted "Current remote main: $initial_oid" "当前远端 main：$initial_oid"
  if ! advanced_prompt_yes_no \
    "Replace remote main with the rebuilt history?" \
    "确认用重建后的历史替换远端 main 吗？" \
    "no"; then
    return 2
  fi

  advanced_info \
    "Uploading rebuilt main with the confirmed exact lease. Git transfer progress will appear below." \
    "正在按照刚才确认的准确远端状态上传重建后的 main；下方会实时显示 Git 传输进度。"
  run_git_with_identity "$BOUND_IDENTITY_FILE" push --progress -u \
    "--force-with-lease=refs/heads/main:$initial_oid" \
    origin main:main
}

history_publish_repository() {
  local GIT_ROOT="$HISTORY_WORK_DIRECTORY"
  local push_status=0

  require_repository_account_match || return 1
  advanced_info "Reading the latest remote state..." "正在确认远端仓库是否发生变化……"
  history_read_remote_main || return 1

  history_push_main_branch || push_status=$?
  if [ "$push_status" -eq 2 ]; then
    advanced_warn \
      "No remote changes were made. The rebuilt repository remains available locally." \
      "没有更改远端；重建仓库仍保留在本地。"
    return 2
  elif [ "$push_status" -ne 0 ]; then
    advanced_error \
      "The main branch was not uploaded. No unprotected force push was attempted." \
      "main 分支未上传；脚本没有执行普通强制推送，远端内容保持不变。"
    return 1
  fi

  return 0
}

history_directory_is_release_source() {
  local directory="$1"
  local index=0

  while [ "$index" -lt "$HISTORY_RELEASE_COUNT" ]; do
    if [ "$directory" -ef "${HISTORY_RELEASE_DIRECTORIES[$index]}" ]; then
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

history_link_working_directory() (
  local target="$1"
  local existing_root=""
  local current_branch=""
  local current_head=""
  local rebuilt_head=""
  local has_commits=false
  local needs_reset=true
  local histories_diverged=false
  local launcher_file="$target/g.sh"

  if existing_root="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)"; then
    existing_root="$({ cd "$existing_root" 2>/dev/null && pwd -P; } || return 1)"
    if [ ! "$existing_root" -ef "$target" ]; then
      advanced_error \
        "The selected folder is inside another Git repository whose root is $existing_root." \
        "所选文件夹位于另一个 Git 仓库中；该仓库的根目录是 ${existing_root}。"
      return 1
    fi
  else
    check_before_git_init "$target" || return 1
    advanced_info \
      "This existing working directory has no Git metadata, so git init will create it without changing project files." \
      "这个现有工作目录还没有 Git 记录；接下来会执行 git init，但不会改动任何项目文件。"
    git -C "$target" init -q || return 1
  fi

  GIT_ROOT="$target"
  SCRIPT_DIRECTORY="$target"
  SCRIPT_NAME="g.sh"
  acquire_workflow_lock || return 1
  install_workflow_cleanup_traps
  if git_operation_in_progress; then
    advanced_error \
      "A Git operation is unfinished in this working directory. Finish or cancel it before linking rebuilt history." \
      "这个工作目录中还有未完成的 Git 操作。请先完成或取消，再衔接重建历史。"
    return 1
  fi

  current_branch="$(git -C "$target" branch --show-current 2>/dev/null || true)"
  if git -C "$target" rev-parse --verify HEAD >/dev/null 2>&1; then
    has_commits=true
    current_head="$(git -C "$target" rev-parse HEAD)"
    if [ -z "$current_branch" ]; then
      advanced_error \
        "The working directory is in detached HEAD state. Switch to its working branch before linking rebuilt history." \
        "当前工作目录处于 detached HEAD 状态。请先切换到日常使用的分支，再衔接重建历史。"
      return 1
    fi
  fi

  if [ "$current_branch" != "main" ] &&
     git -C "$target" show-ref --verify --quiet refs/heads/main; then
    advanced_error \
      "This repository already has a different main branch. Switch to the intended branch and retry." \
      "当前仓库已经存在另一条 main 分支。请先切换到需要继续使用的分支，再重试。"
    return 1
  fi

  if [ -e "$launcher_file" ] && ! launcher_is_managed "$launcher_file"; then
    advanced_muted \
      "The existing g.sh was not created by git-auto and must be replaced before this project can use the central workflow." \
      "当前 g.sh 不是由 git-auto 创建的；需要替换后，这个项目才能使用中央流程。"
    if ! advanced_prompt_yes_no \
      "Replace the existing g.sh with the lightweight launcher?" \
      "要用轻量启动器替换现有 g.sh 吗？" \
      "yes"; then
      return 1
    fi
  fi

  rebuilt_head="$(git -C "$HISTORY_WORK_DIRECTORY" rev-parse refs/heads/main)" || return 1
  advanced_info \
    "Connecting this working directory to the rebuilt local history without changing its project files..." \
    "正在把当前工作目录衔接到本机重建历史；现有项目文件不会被改动……"
  git -C "$target" fetch -q "$HISTORY_WORK_DIRECTORY" \
    refs/heads/main:refs/git-auto/rebuilt-main || return 1
  trap 'git -C "$target" update-ref -d refs/git-auto/rebuilt-main >/dev/null 2>&1 || true; cleanup_workflow_runtime' EXIT

  if [ "$has_commits" = true ]; then
    if git -C "$target" merge-base --is-ancestor refs/git-auto/rebuilt-main HEAD; then
      needs_reset=false
    elif ! git -C "$target" merge-base --is-ancestor HEAD refs/git-auto/rebuilt-main; then
      histories_diverged=true
    fi
  fi

  if [ "$histories_diverged" = true ]; then
    advanced_heading "Reconnect the existing local history" "衔接现有本地记录"
    advanced_muted "Current local commit: $current_head" "当前本地提交：$current_head"
    advanced_muted "Rebuilt main commit: $rebuilt_head" "重建后的 main 提交：$rebuilt_head"
    advanced_muted \
      "The two histories are different. Reconnecting keeps every working-directory file, moves the current branch to rebuilt main, and changes staged files back to ordinary uncommitted changes." \
      "两套提交记录并不相连。继续后会保留工作目录中的全部文件，把当前分支改接到重建后的 main，并将已经暂存的改动恢复为普通未提交改动。"
    if ! advanced_prompt_yes_no \
      "Reconnect this working directory to rebuilt main now?" \
      "现在把这个工作目录衔接到重建后的 main 吗？" \
      "yes"; then
      advanced_warn \
        "The remote history remains published, but this working directory was not changed." \
        "重建历史已经上传，但没有修改这个工作目录。"
      return 2
    fi
  fi

  if [ "$needs_reset" = true ]; then
    git -C "$target" reset --mixed refs/git-auto/rebuilt-main >/dev/null || return 1
  fi
  current_branch="$(git -C "$target" branch --show-current 2>/dev/null || true)"
  if [ "$current_branch" != "main" ]; then
    git -C "$target" branch -M main || return 1
  fi

  save_project_binding || return 1
  write_project_launcher "$target" || return 1
  git -C "$target" update-ref refs/remotes/origin/main "$rebuilt_head" || return 1
  git -C "$target" config --local branch.main.remote origin || return 1
  git -C "$target" config --local branch.main.merge refs/heads/main || return 1
  return 0
)

history_prepare_working_directory() {
  local default_directory="$SCRIPT_DIRECTORY"
  local input=""
  local target=""
  local link_status=0

  advanced_heading "Prepare the current working directory" "衔接当前工作目录"
  advanced_muted \
    "The normal working directory is expected to contain the current project files and may be non-empty. No file will be copied over, deleted, or replaced." \
    "日常工作目录通常已经包含当前项目文件，也可以是非空目录。脚本不会复制覆盖、删除或替换其中的任何文件。"
  advanced_muted \
    "Git will connect that directory to the rebuilt main history. Differences from the latest historical release remain as ordinary uncommitted changes for the next ./g.sh run." \
    "脚本只会让该目录衔接重建后的 main 历史；相对最后一个历史版本的文件差异会保留为普通未提交改动，之后可直接运行 ./g.sh。"
  if ! advanced_prompt_yes_no \
    "Connect the current working directory now?" \
    "现在衔接日常工作目录吗？" \
    "yes"; then
    advanced_warn \
      "The remote history remains published. This working directory was not changed." \
      "重建历史已经上传；当前工作目录没有发生变化。"
    return 0
  fi

  if [ "$default_directory" -ef "$ENGINE_DIRECTORY" ]; then
    default_directory=""
  fi
  while true; do
    input="$(advanced_prompt_value \
      "Existing working directory" \
      "现有工作目录" \
      "$default_directory")" || return 1
    if ! normalize_history_directory_input "$input"; then
      advanced_warn \
        "Choose the existing folder that contains the current project files." \
        "请选择已经包含当前项目文件的现有文件夹。"
      continue
    fi
    target="$HISTORY_NORMALIZED_DIRECTORY"
    if [ "$target" -ef "$ENGINE_DIRECTORY" ]; then
      advanced_warn \
        "The central git-auto folder cannot also be this project's working directory." \
        "git-auto 中央程序文件夹不能同时作为这个项目的工作目录。"
      continue
    fi
    if history_directory_is_release_source "$target"; then
      advanced_warn \
        "Choose the active project folder, not one of the read-only historical release folders." \
        "请选择持续开发使用的项目文件夹，不要选择只读的历史版本存档。"
      continue
    fi
    break
  done

  history_link_working_directory "$target" || link_status=$?
  if [ "$link_status" -eq 2 ]; then
    return 0
  elif [ "$link_status" -ne 0 ]; then
    advanced_error \
      "The working directory could not be linked completely. Its project files were not overwritten; the temporary rebuilt repository was kept for inspection." \
      "工作目录未能完整衔接。现有项目文件没有被覆盖；重建后的临时仓库已保留，便于检查。"
    return 1
  fi

  advanced_success \
    "Working directory linked to rebuilt main: $target" \
    "工作目录已衔接到重建后的 main：$target"
  advanced_muted \
    "Continue there with: cd \"$target\" && ./g.sh" \
    "以后进入该目录并运行：cd \"$target\" && ./g.sh"
  advanced_muted \
    "Any current file differences remain uncommitted and will be handled by the normal ./g.sh flow." \
    "当前文件与最后一个历史版本之间的差异仍保持未提交状态，后续由普通 ./g.sh 流程处理。"
}

run_historical_release_import() {
  local input=""
  local parent=""
  local index=0
  local choice=""
  local destination_status=0
  local publish_status=0

  reset_history_releases
  HISTORY_WORK_DIRECTORY=""
  HISTORY_REBUILD_DATES=true
  HISTORY_COMMITS_CONFIRMED=false

  advanced_heading "Rebuild Git history from historical releases" "用历史版本文件夹重建 Git 历史"
  advanced_muted \
    "Use this when complete release snapshots exist as folders but no useful Git history exists." \
    "如果各个历史版本只保存在独立文件夹里、没有可用的 Git 提交记录，可以使用这个功能。"
  advanced_muted \
    "The source folders stay read-only. Each release becomes one complete snapshot commit in semantic-version order." \
    "脚本不会改动这些存档，而是在临时仓库中按语义化版本从旧到新生成完整快照提交。"
  advanced_muted \
    ".git entries and .DS_Store files are excluded. Other hidden and ignored files are included after a safety review." \
    "每一层的 .git 和 .DS_Store 都会自动排除；其他隐藏文件和被忽略文件会在安全检查后保留。"
  advanced_muted \
    "Nothing is uploaded until the rebuilt log is shown and you explicitly approve the remote action." \
    "完成重建后会先展示提交顺序和结果；只有你明确确认，脚本才会上传。"
  if ! advanced_prompt_yes_no "Start the guided import?" "开始检查这些历史版本吗？" "yes"; then
    return 0
  fi

  advanced_heading "Historical release folders" "选择历史版本所在位置"
  advanced_muted \
    "Enter or drag in the parent folder whose immediate subfolders contain the releases." \
    "请输入或直接拖入父文件夹。脚本会把其中的直接子文件夹分别视为候选版本。"
  while true; do
    input="$(advanced_prompt_value "Parent folder" "父文件夹")" || return 1
    if normalize_history_directory_input "$input"; then
      parent="$HISTORY_NORMALIZED_DIRECTORY"
      break
    fi
    advanced_warn "That folder could not be opened." "无法打开这个文件夹。"
  done

  advanced_info "Scanning release folders..." "正在识别版本号和发布日期……"
  history_scan_parent_directory "$parent"
  history_resolve_version_conflicts || return 1

  if [ "$HISTORY_SKIPPED_COUNT" -gt 0 ]; then
    advanced_warn \
      "$HISTORY_SKIPPED_COUNT folder(s) had no usable unique version and were skipped." \
      "有 $HISTORY_SKIPPED_COUNT 个子文件夹未识别出唯一版本号，因此没有自动加入列表。"
    history_show_paginated_list skipped || return 1
  fi

  history_add_manual_releases || return 1
  if [ "$HISTORY_RELEASE_COUNT" -eq 0 ]; then
    advanced_error "No release folders were selected." "没有找到可导入的版本文件夹。"
    return 1
  fi

  history_sort_releases
  history_show_release_plan
  if ! advanced_prompt_yes_no \
    "Use this order and these versions?" \
    "以上版本号和排列顺序是否正确？" \
    "yes"; then
    advanced_warn "Import canceled before any files were copied." "导入已取消；尚未复制文件，也没有修改远端。"
    return 0
  fi

  history_offer_missing_gitignore
  history_review_risks || return 1
  if advanced_prompt_yes_no \
    "Use detected release dates for the reconstructed commit timestamps?" \
    "是否使用识别到的发布日期重建提交时间？" \
    "yes" \
    "Choose Yes: Assign each reliable detected release date to its matching commit.
Choose No: Do not assign historical dates; each commit keeps the local system time that Git records automatically when creating it." \
    "选择“是”：把识别到的可靠发布日期写入对应提交。
选择“否”：不写入历史日期；每个提交保留 Git 创建它时自动记录的本机时间。"; then
    HISTORY_REBUILD_DATES=true
  else
    HISTORY_REBUILD_DATES=false
  fi

  advanced_prepare_history_destination || destination_status=$?
  if [ "$destination_status" -eq 2 ]; then
    return 0
  elif [ "$destination_status" -ne 0 ]; then
    return 1
  fi

  advanced_heading "Review the temporary history construction" "核对即将创建的临时历史"
  advanced_muted \
    "$HISTORY_RELEASE_COUNT release commit(s) will be created on main in a new temporary repository." \
    "脚本将在一个全新的临时 Git 仓库中创建 $HISTORY_RELEASE_COUNT 个版本提交，并统一使用 main 分支。"
  github_target_summary \
    advanced \
    "$BOUND_USERNAME" \
    "$CURRENT_REPOSITORY_OWNER" \
    "$CURRENT_REPOSITORY_NAME"
  if [ "$HISTORY_REBUILD_DATES" = true ]; then
    advanced_muted \
      "Commit dates: each reliable detected release date is assigned; for a release without one, Git records the local system time at the moment that reconstructed commit is created." \
      "提交时间：有可靠发布日期的版本使用该日期；其余版本保留 Git 创建提交时自动记录的本机时间。"
  else
    advanced_muted \
      "Commit dates: no historical dates are assigned; Git records the local system time at the moment each reconstructed commit is created." \
      "提交时间：不写入历史日期；每个提交保留 Git 创建它时自动记录的本机时间。"
  fi
  if ! advanced_prompt_yes_no \
    "Create every listed Release X.Y.Z commit in the temporary repository now, without uploading?" \
    "确认按刚才列出的说明创建全部 Release X.Y.Z 提交，并暂不上传吗？" \
    "yes"; then
    return 0
  fi
  HISTORY_COMMITS_CONFIRMED=true

  if ! history_build_repository; then
    advanced_error "History construction stopped." "未能完成历史重建。"
    if [ -n "$HISTORY_WORK_DIRECTORY" ]; then
      advanced_muted \
        "The temporary workspace was kept for inspection: $HISTORY_WORK_DIRECTORY" \
        "临时仓库已保留，可以在这里检查：$HISTORY_WORK_DIRECTORY"
    fi
    return 1
  fi

  advanced_heading "Rebuilt history" "历史重建完成"
  git -C "$HISTORY_WORK_DIRECTORY" --no-pager log --oneline --reverse
  if [ "$HISTORY_REBUILD_DATES" = true ]; then
    advanced_muted \
      "These newly reconstructed commits preserve snapshot order and reliable detected release dates, but cannot restore other missing original commit metadata." \
      "这些提交由版本快照重新生成，能够还原文件变化顺序和识别到的可靠发布日期，但无法恢复其他已经遗失的原始提交信息。"
  else
    advanced_muted \
      "These newly reconstructed commits preserve snapshot order. No historical dates were assigned, so Git recorded the local system time at the moment each commit was created; missing original commit metadata cannot be restored." \
      "这些提交由版本快照重新生成，能够还原文件变化顺序。此次没有写入历史日期，每个提交保留了 Git 创建它时自动记录的本机时间；已经遗失的原始提交信息无法恢复。"
  fi

  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    printf '  1) Upload this history to GitHub\n'
    printf '  2) Keep the temporary repository without uploading\n'
    printf '  0) Delete the temporary repository and cancel\n'
  else
    printf '  1) 确认无误，上传到 GitHub\n'
    printf '  2) 暂不上传，保留临时仓库\n'
    printf '  0) 取消并删除临时仓库\n'
  fi
  while true; do
    choice="$(advanced_prompt_value "Choose" "选择" "1")" || return 1
    case "$choice" in
      1)
        break
        ;;
      2)
        advanced_success \
          "Temporary repository kept at: $HISTORY_WORK_DIRECTORY" \
          "临时仓库已保留：$HISTORY_WORK_DIRECTORY"
        return 0
        ;;
      0)
        history_remove_temporary_directory "$HISTORY_WORK_DIRECTORY" history || true
        HISTORY_WORK_DIRECTORY=""
        advanced_success "Temporary repository deleted. No remote changes were made." "临时仓库已删除，没有修改远端仓库。"
        return 0
        ;;
      *)
        advanced_warn "Enter a number from the list." "请输入列表中的序号。"
        ;;
    esac
  done

  history_publish_repository || publish_status=$?
  if [ "$publish_status" -ne 0 ]; then
    advanced_muted \
      "Temporary repository kept at: $HISTORY_WORK_DIRECTORY" \
      "临时仓库已保留：$HISTORY_WORK_DIRECTORY"
    return "$publish_status"
  fi

  if ! history_prepare_working_directory; then
    advanced_muted \
      "Temporary repository kept at: $HISTORY_WORK_DIRECTORY" \
      "临时仓库已保留：$HISTORY_WORK_DIRECTORY"
    return 1
  fi

  advanced_success \
    "Historical releases were uploaded successfully." \
    "历史版本已按顺序重建并上传。"
  history_remove_temporary_directory "$HISTORY_WORK_DIRECTORY" history || true
  HISTORY_WORK_DIRECTORY=""
  return 0
}

run_advanced_menu() {
  local choice=""

  ADVANCED_LANGUAGE="$UI_LANGUAGE"

  while true; do
    advanced_heading "Advanced features" "高级功能"
    if [ "$ADVANCED_LANGUAGE" = "en" ]; then
      printf '  1) Rebuild Git history from historical release folders\n'
      printf '  2) Discover and import GitHub accounts through SSH\n'
      printf '  3) Verify saved account SSH keys with GitHub\n'
      printf '  4) Verify the current project with GitHub\n'
      printf '  0) Return\n'
    else
      printf '  1) 用历史版本文件夹重建 Git 历史\n'
      printf '  2) 通过 SSH 识别并导入现有 GitHub 账号\n'
      printf '  3) 联网核对已保存账号的 SSH 密钥\n'
      printf '  4) 联网核对当前项目\n'
      printf '  0) 返回\n'
    fi
    choice="$(advanced_prompt_value "Choose" "选择" "1")" || return 1
    case "$choice" in
      1)
        run_historical_release_import || true
        advanced_pause
        ;;
      2)
        import_existing_accounts_online || true
        advanced_pause
        ;;
      3)
        check_private_accounts || true
        advanced_pause
        ;;
      4)
        verify_current_project_online || true
        advanced_pause
        ;;
      0)
        return 0
        ;;
      *)
        advanced_warn "Enter a number from the list." "请输入列表中的序号。"
        ;;
    esac
  done
}
