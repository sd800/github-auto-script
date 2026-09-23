# -----------------------------------------------------------------------------
# Flexible GitHub repository input
# -----------------------------------------------------------------------------

REPOSITORY_OWNER=""
REPOSITORY_NAME=""
REPOSITORY_INPUT_HOST=""

github_host_or_alias() {
  local host="$1"
  local host_without_port=""
  local saved_alias=""
  local saved_username=""
  local project_root=""

  host_without_port="${host%%:*}"
  case "$(lowercase "$host_without_port")" in
    github.com|www.github.com|ssh.github.com)
      return 0
      ;;
  esac

  if ssh_alias_is_github "$host_without_port"; then
    return 0
  fi

  if [ -n "${GIT_ROOT:-}" ]; then
    project_root="$(git -C "$GIT_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$project_root" ] && [ "$project_root" -ef "$GIT_ROOT" ]; then
      saved_alias="$(git -C "$GIT_ROOT" config --local --get github-auto.ssh-alias 2>/dev/null || true)"
      saved_username="$(git -C "$GIT_ROOT" config --local --get github-auto.username 2>/dev/null || true)"
      if [ -n "$saved_username" ] &&
         [ "$(lowercase "$saved_alias")" = "$(lowercase "$host_without_port")" ]; then
        return 0
      fi
    fi
  fi

  return 1
}

strip_command_prefix() {
  local value="$1"
  local value_lc

  value_lc="$(lowercase "$value")"
  case "$value_lc" in
    'git clone '*)
      value="${value#* }"
      value="${value#* }"
      ;;
    'gh repo clone '*)
      value="${value#* }"
      value="${value#* }"
      value="${value#* }"
      ;;
  esac

  printf '%s' "$value"
}

parse_repository_input() {
  local original="$1"
  local value=""
  local value_lc=""
  local scheme=""
  local authority=""
  local host=""
  local path=""
  local owner=""
  local remainder=""
  local repo=""

  REPOSITORY_OWNER=""
  REPOSITORY_NAME=""
  REPOSITORY_INPUT_HOST=""

  value="$(trim "$original")"
  value="$(strip_optional_quotes "$value")"
  value="$(strip_command_prefix "$value")"
  value="$(trim "$value")"
  [ -n "$value" ] || return 1

  value="${value%%\?*}"
  value="${value%%\#*}"
  while [ "${value%/}" != "$value" ]; do
    value="${value%/}"
  done
  value_lc="$(lowercase "$value")"

  if [[ "$value" == git@*:* ]] && [[ "$value" != *://* ]]; then
    host="${value#git@}"
    host="${host%%:*}"
    path="${value#*:}"
    github_host_or_alias "$host" || return 1
  elif [[ "$value_lc" == ssh://* ]] ||
       [[ "$value_lc" == git+ssh://* ]]; then
    scheme="${value%%://*}"
    value="${value#*://}"
    authority="${value%%/*}"
    [ "$authority" != "$value" ] || return 1
    host="${authority##*@}"
    host="${host%%:*}"
    path="${value#*/}"
    github_host_or_alias "$host" || return 1
  elif [[ "$value_lc" == http://* ]] ||
       [[ "$value_lc" == https://* ]] ||
       [[ "$value_lc" == git://* ]]; then
    value="${value#*://}"
    authority="${value%%/*}"
    [ "$authority" != "$value" ] || return 1
    host="${authority##*@}"
    host="${host%%:*}"
    path="${value#*/}"
    case "$(lowercase "$host")" in
      github.com|www.github.com)
        ;;
      *)
        return 1
        ;;
    esac
  else
    case "$value_lc" in
      github.com/*|www.github.com/*)
        host="${value%%/*}"
        path="${value#*/}"
        ;;
      *)
        path="$value"
        ;;
    esac
  fi

  path="${path#/}"
  owner="${path%%/*}"
  remainder="${path#*/}"
  [ "$remainder" != "$path" ] || return 1
  repo="${remainder%%/*}"

  case "$(lowercase "$repo")" in
    *.git)
      repo="${repo%.*}"
      ;;
  esac

  [ -n "$owner" ] && [ -n "$repo" ] || return 1
  [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || return 1
  [[ "$repo" =~ ^[A-Za-z0-9._-]+$ ]] || return 1

  REPOSITORY_OWNER="$owner"
  REPOSITORY_NAME="$repo"
  REPOSITORY_INPUT_HOST="$host"
  return 0
}

prompt_repository() {
  local input=""

  heading "Identify the GitHub repository" "指定对应的 GitHub 仓库"
  muted \
    "Paste owner/repository, a GitHub page URL, an HTTPS URL, or an SSH URL." \
    "可以粘贴 owner/repository、GitHub 网页地址、HTTPS 地址或 SSH 地址。"

  while true; do
    input="$(ui_prompt_value "Repository address" "仓库地址")" || return 1
    if parse_repository_input "$input"; then
      return 0
    fi
    warn \
      "That GitHub repository was not recognized. Check the address and paste it again." \
      "没有识别出 GitHub 仓库，请检查地址后重新粘贴。"
  done
}

# -----------------------------------------------------------------------------
# Release version discovery
# -----------------------------------------------------------------------------

SEMVER_PATTERN='[0-9]+(\.[0-9]+){1,3}(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?'
STRICT_SEMVER_PATTERN='[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?'
SEMVER_COMPARISON=0
RELEASE_VERSION=""
VERSION_SOURCE=""
VERSION_POSITION=""
VERSION_LOOKUP_LIMIT_SECONDS="${VERSION_LOOKUP_LIMIT_SECONDS:-5}"
VERSION_LOOKUP_DEADLINE=0

is_common_package_placeholder_version() {
  case "$1" in
    0.0.0|0.0.1|0.1.0|1.0.0)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

release_version_eligible_for_commit() {
  local relative_path="$1"
  local source_kind="$2"
  local current_version="$3"
  local previous_file=""
  local previous_object=""
  local previous_version=""
  local proposed_object=""

  [ -n "${WORKFLOW_EXPECTED_STAGED_TREE:-}" ] || return 1
  proposed_object="$(
    git --literal-pathspecs -C "$GIT_ROOT" ls-tree "$WORKFLOW_EXPECTED_STAGED_TREE" \
      -- "$relative_path" 2>/dev/null |
      awk 'NR == 1 { print $3 }'
  )"
  [ -n "$proposed_object" ] || return 1
  git -C "$GIT_ROOT" rev-parse --verify HEAD >/dev/null 2>&1 || return 0
  previous_object="$(
    git --literal-pathspecs -C "$GIT_ROOT" ls-tree HEAD \
      -- "$relative_path" 2>/dev/null |
      awk 'NR == 1 { print $3 }'
  )"
  [ -n "$previous_object" ] || return 0
  previous_file="$(safe_mktemp_file "${TMPDIR:-/tmp}" "previous-version")" || return 1
  if ! git -C "$GIT_ROOT" cat-file blob "$previous_object" > "$previous_file"; then
    rm -f "$previous_file"
    return 1
  fi
  case "$source_kind" in
    package)
      previous_version="$(get_package_version_from_file "$previous_file" || true)"
      ;;
    metadata)
      previous_version="$(extract_version_from_metadata_file "$previous_file" "$relative_path" || true)"
      ;;
    changelog)
      previous_version="$(
        extract_version_from_changelog "$previous_file" >/dev/null 2>&1 &&
          printf '%s' "$CHANGELOG_EXTRACTED_VERSION"
      )"
      ;;
    version-file)
      previous_version="$(extract_version_from_version_file "$previous_file" || true)"
      ;;
    *)
      rm -f "$previous_file"
      return 1
      ;;
  esac
  rm -f "$previous_file"
  if [ "$current_version" != "$previous_version" ]; then
    return 0
  fi
  if [ "$source_kind" = package ] &&
     is_common_package_placeholder_version "$current_version"; then
    return 1
  fi
  return 0
}

version_lookup_has_time() {
  [ "$SECONDS" -lt "$VERSION_LOOKUP_DEADLINE" ]
}

strip_leading_zeroes() {
  local value="$1"

  while [ "${value#0}" != "$value" ] && [ "${#value}" -gt 1 ]; do
    value="${value#0}"
  done
  printf '%s' "$value"
}

compare_numeric_strings() {
  local left
  local right

  left="$(strip_leading_zeroes "$1")"
  right="$(strip_leading_zeroes "$2")"

  if [ "${#left}" -gt "${#right}" ]; then
    SEMVER_COMPARISON=1
  elif [ "${#left}" -lt "${#right}" ]; then
    SEMVER_COMPARISON=-1
  elif [[ "$left" > "$right" ]]; then
    SEMVER_COMPARISON=1
  elif [[ "$left" < "$right" ]]; then
    SEMVER_COMPARISON=-1
  else
    SEMVER_COMPARISON=0
  fi
}

compare_prerelease_identifier() {
  local left="$1"
  local right="$2"
  local left_numeric=false
  local right_numeric=false

  [[ "$left" =~ ^[0-9]+$ ]] && left_numeric=true
  [[ "$right" =~ ^[0-9]+$ ]] && right_numeric=true

  if [ "$left_numeric" = true ] && [ "$right_numeric" = true ]; then
    compare_numeric_strings "$left" "$right"
  elif [ "$left_numeric" = true ]; then
    SEMVER_COMPARISON=-1
  elif [ "$right_numeric" = true ]; then
    SEMVER_COMPARISON=1
  elif [[ "$left" > "$right" ]]; then
    SEMVER_COMPARISON=1
  elif [[ "$left" < "$right" ]]; then
    SEMVER_COMPARISON=-1
  else
    SEMVER_COMPARISON=0
  fi
}

compare_semver() {
  local left="${1%%+*}"
  local right="${2%%+*}"
  local left_core="$left"
  local right_core="$right"
  local left_pre=""
  local right_pre=""
  local left_parts=()
  local right_parts=()
  local left_pre_parts=()
  local right_pre_parts=()
  local count=0
  local index=0
  local left_value="0"
  local right_value="0"

  if [[ "$left" == *-* ]]; then
    left_core="${left%%-*}"
    left_pre="${left#*-}"
  fi
  if [[ "$right" == *-* ]]; then
    right_core="${right%%-*}"
    right_pre="${right#*-}"
  fi

  IFS='.' read -r -a left_parts <<< "$left_core"
  IFS='.' read -r -a right_parts <<< "$right_core"
  count="${#left_parts[@]}"
  if [ "${#right_parts[@]}" -gt "$count" ]; then
    count="${#right_parts[@]}"
  fi

  index=0
  while [ "$index" -lt "$count" ]; do
    left_value="${left_parts[$index]:-0}"
    right_value="${right_parts[$index]:-0}"
    compare_numeric_strings "$left_value" "$right_value"
    if [ "$SEMVER_COMPARISON" -ne 0 ]; then
      return
    fi
    index=$((index + 1))
  done

  if [ -z "$left_pre" ] && [ -z "$right_pre" ]; then
    SEMVER_COMPARISON=0
    return
  elif [ -z "$left_pre" ]; then
    SEMVER_COMPARISON=1
    return
  elif [ -z "$right_pre" ]; then
    SEMVER_COMPARISON=-1
    return
  fi

  IFS='.' read -r -a left_pre_parts <<< "$left_pre"
  IFS='.' read -r -a right_pre_parts <<< "$right_pre"
  count="${#left_pre_parts[@]}"
  if [ "${#right_pre_parts[@]}" -gt "$count" ]; then
    count="${#right_pre_parts[@]}"
  fi

  index=0
  while [ "$index" -lt "$count" ]; do
    if [ "$index" -ge "${#left_pre_parts[@]}" ]; then
      SEMVER_COMPARISON=-1
      return
    fi
    if [ "$index" -ge "${#right_pre_parts[@]}" ]; then
      SEMVER_COMPARISON=1
      return
    fi
    compare_prerelease_identifier "${left_pre_parts[$index]}" "${right_pre_parts[$index]}"
    if [ "$SEMVER_COMPARISON" -ne 0 ]; then
      return
    fi
    index=$((index + 1))
  done

  SEMVER_COMPARISON=0
}

valid_release_version() {
  [[ "$1" =~ ^${STRICT_SEMVER_PATTERN}$ ]]
}

looks_like_date() {
  local value
  local value_lc
  local month_pattern

  value="$(trim "$1")"
  value="${value#\(}"
  value="${value%\)}"
  value="$(trim "$value")"
  value_lc="$(lowercase "$value")"

  if [[ "$value" =~ ^[0-9]{4}[-./][0-9]{1,2}[-./][0-9]{1,2}$ ]] ||
     [[ "$value" =~ ^[0-9]{1,2}[-./][0-9]{1,2}[-./][0-9]{2,4}$ ]] ||
     [[ "$value" =~ ^[0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日$ ]]; then
    return 0
  fi

  month_pattern='(jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|jun(e)?|jul(y)?|aug(ust)?|sep(t|tember)?|oct(ober)?|nov(ember)?|dec(ember)?)\.?'
  if [[ "$value_lc" =~ $month_pattern ]] &&
     [[ "$value_lc" =~ [0-9]{4} ]] &&
     [[ "$value_lc" =~ [0-9]{1,2} ]]; then
    return 0
  fi

  return 1
}

file_size_bytes() {
  local file="$1"

  if stat -f '%z' "$file" >/dev/null 2>&1; then
    stat -f '%z' "$file"
  else
    stat -c '%s' "$file"
  fi
}

extract_version_from_changelog() {
  local file="$1"
  local size=""
  local line=""
  local normalized=""
  local version=""
  local date_text=""
  local match_pattern=""
  local entries=()
  local count=0
  local last=0

  CHANGELOG_EXTRACTED_VERSION=""
  CHANGELOG_POSITION=""
  CHANGELOG_ENTRY_COUNT=0

  [ -f "$file" ] || return 1
  size="$(file_size_bytes "$file" 2>/dev/null || printf '0')"
  if [ "$size" -gt 1048576 ] 2>/dev/null; then
    return 1
  fi

  match_pattern="^[[:space:]]*#{0,6}[[:space:]]*\\[?[vV]?(${SEMVER_PATTERN})\\]?[[:space:]]*-[[:space:]]*(.+)$"

  while IFS= read -r line || [ -n "$line" ]; do
    normalized="${line%$'\r'}"
    normalized="${normalized//‐/-}"
    normalized="${normalized//‑/-}"
    normalized="${normalized//‒/-}"
    normalized="${normalized//–/-}"
    normalized="${normalized//—/-}"
    normalized="${normalized//−/-}"
    normalized="$(printf '%s' "$normalized" | sed -E 's/[[:space:]]+#+[[:space:]]*$//')"

    if [[ "$normalized" =~ $match_pattern ]]; then
      version="${BASH_REMATCH[1]}"
      date_text="${BASH_REMATCH[5]}"
      if looks_like_date "$date_text"; then
        entries[$count]="$version"
        count=$((count + 1))
      fi
    fi
  done < "$file"

  CHANGELOG_ENTRY_COUNT="$count"
  if [ "$count" -eq 0 ]; then
    return 1
  fi
  if [ "$count" -eq 1 ]; then
    CHANGELOG_EXTRACTED_VERSION="${entries[0]}"
    CHANGELOG_POSITION="single"
    return 0
  fi

  compare_semver "${entries[0]}" "${entries[1]}"
  if [ "$SEMVER_COMPARISON" -gt 0 ]; then
    CHANGELOG_EXTRACTED_VERSION="${entries[0]}"
    CHANGELOG_POSITION="top"
    return 0
  fi

  last=$((count - 1))
  compare_semver "${entries[$last]}" "${entries[$((last - 1))]}"
  if [ "$SEMVER_COMPARISON" -gt 0 ]; then
    CHANGELOG_EXTRACTED_VERSION="${entries[$last]}"
    CHANGELOG_POSITION="bottom"
    return 0
  fi

  return 2
}

get_json_version_from_file() {
  local file="$1"
  local version=""

  [ -f "$file" ] || return 1

  if command_exists node; then
    version="$(
      node -e '
        const fs = require("fs");
        try {
          const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version;
          if (typeof value === "string") process.stdout.write(value.trim());
        } catch (_) { process.exit(1); }
      ' "$file" 2>/dev/null
    )" || true
  elif command_exists python3; then
    version="$(
      python3 -c '
import json, sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8")).get("version", "")
    print(value.strip() if isinstance(value, str) else "", end="")
except Exception:
    raise SystemExit(1)
' "$file" 2>/dev/null
    )" || true
  elif command_exists jq; then
    version="$(jq -r '.version // empty' "$file" 2>/dev/null)" || true
  else
    version="$(
      sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*$/\1/p' "$file" |
        sed -n '1p'
    )"
  fi

  if valid_release_version "$version"; then
    printf '%s' "$version"
    return 0
  fi
  return 1
}

get_package_version() {
  get_json_version_from_file "$GIT_ROOT/package.json"
}

get_package_version_from_file() {
  get_json_version_from_file "$1"
}

extract_version_from_metadata_file() {
  local file="$1"
  local name="${2##*/}"
  local version=""
  local sections=""

  [ -f "$file" ] || return 1
  case "$(lowercase "$name")" in
    manifest.json|manifest.webmanifest|composer.json|deno.json|bower.json)
      get_json_version_from_file "$file"
      return
      ;;
    pyproject.toml)
      sections='pyproject'
      ;;
    cargo.toml)
      sections='cargo'
      ;;
    pubspec.yaml)
      version="$(awk '
        /^version[[:space:]]*:/ {
          value=$0
          sub(/^version[[:space:]]*:[[:space:]]*/, "", value)
          sub(/[[:space:]]+#.*$/, "", value)
          sub(/^"/, "", value)
          sub(/"$/, "", value)
          sub(/^\047/, "", value)
          sub(/\047$/, "", value)
          print value
          exit
        }
      ' "$file")"
      ;;
    *)
      return 1
      ;;
  esac

  if [ -n "$sections" ]; then
    version="$(awk -v kind="$sections" '
      /^[[:space:]]*\[/ {
        section=$0
        gsub(/[[:space:]]/, "", section)
      }
      ((kind == "pyproject" && (section == "[project]" || section == "[tool.poetry]")) ||
       (kind == "cargo" && section == "[package]")) &&
      /^[[:space:]]*version[[:space:]]*=/ {
        value=$0
        sub(/^[^=]*=[[:space:]]*/, "", value)
        if (value ~ /^"/) {
          sub(/^"/, "", value)
          sub(/".*$/, "", value)
        } else if (value ~ /^\047/) {
          sub(/^\047/, "", value)
          sub(/\047.*$/, "", value)
        }
        print value
        exit
      }
    ' "$file")"
  fi
  if valid_release_version "$version"; then
    printf '%s' "$version"
    return 0
  fi
  return 1
}

resolve_root_metadata_files() {
  local changed_only="${1:-no}"
  local file=""
  local version=""

  for file in \
    "$GIT_ROOT/manifest.json" \
    "$GIT_ROOT/manifest.webmanifest" \
    "$GIT_ROOT/pyproject.toml" \
    "$GIT_ROOT/Cargo.toml" \
    "$GIT_ROOT/composer.json" \
    "$GIT_ROOT/pubspec.yaml" \
    "$GIT_ROOT/deno.json" \
    "$GIT_ROOT/bower.json"; do
    if version="$(extract_version_from_metadata_file "$file" "$file")"; then
      if [ "$changed_only" = yes ] &&
         ! release_version_eligible_for_commit "${file#"$GIT_ROOT"/}" metadata "$version"; then
        continue
      fi
      RELEASE_VERSION="$version"
      VERSION_SOURCE="${file#"$GIT_ROOT"/}"
      VERSION_POSITION="metadata"
      return 0
    fi
  done
  return 1
}

resolve_highest_changelog_from_stream() {
  local changed_only="${1:-no}"
  local file=""
  local best_version=""
  local best_file=""
  local best_position=""
  local best_relative=""
  local relative=""
  local choose=false
  local status=0

  while IFS= read -r file; do
    if ! version_lookup_has_time; then
      return 124
    fi
    [ -f "$file" ] || continue
    relative="${file#"$GIT_ROOT"/}"
    if extract_version_from_changelog "$file"; then
      if [ "$changed_only" = yes ] &&
         ! release_version_eligible_for_commit "$relative" changelog "$CHANGELOG_EXTRACTED_VERSION"; then
        continue
      fi
      choose=false
      if [ -z "$best_version" ]; then
        choose=true
      else
        compare_semver "$CHANGELOG_EXTRACTED_VERSION" "$best_version"
        if [ "$SEMVER_COMPARISON" -gt 0 ]; then
          choose=true
        elif [ "$SEMVER_COMPARISON" -eq 0 ] && [[ "$relative" < "$best_relative" ]]; then
          choose=true
        fi
      fi
      if [ "$choose" = true ]; then
        best_version="$CHANGELOG_EXTRACTED_VERSION"
        best_file="$file"
        best_position="$CHANGELOG_POSITION"
        best_relative="$relative"
      fi
    else
      status=$?
      if [ "$status" -eq 2 ]; then
        warn \
          "Skipped a file with ambiguous version order: ${file#"$GIT_ROOT"/}" \
          "已跳过版本顺序不明确的文件：${file#"$GIT_ROOT"/}"
      fi
    fi
  done

  if [ -n "$best_version" ]; then
    RELEASE_VERSION="$best_version"
    VERSION_SOURCE="${best_file#"$GIT_ROOT"/}"
    VERSION_POSITION="$best_position"
    return 0
  fi
  return 1
}

resolve_root_changelogs() {
  local changed_only="${1:-no}"
  local temporary=""
  local status=0
  local file=""

  temporary="$(safe_mktemp_file "${TMPDIR:-/tmp}" "changelogs")" || return 1
  for file in "$GIT_ROOT"/*; do
    if ! version_lookup_has_time; then
      rm -f "$temporary"
      return 124
    fi
    [ -f "$file" ] || continue
    case "$(lowercase "${file##*/}")" in
      changelog*) printf '%s\n' "$file" >> "$temporary" ;;
    esac
  done
  LC_ALL=C sort -o "$temporary" "$temporary"
  status=0
  resolve_highest_changelog_from_stream "$changed_only" < "$temporary" || status=$?
  rm -f "$temporary"
  return "$status"
}

extract_version_from_version_file() {
  local file="$1"
  local size=""
  local text=""
  local version=""

  [ -f "$file" ] || return 1
  size="$(file_size_bytes "$file" 2>/dev/null || printf '0')"
  if [ "$size" -gt 1048576 ] 2>/dev/null; then
    return 1
  fi

  text="$(sed -n '1,80p' "$file")"
  version="$(
    printf '%s\n' "$text" |
      sed -nE "s/.*([vV]ersion|[rR]elease)[[:space:]]*[:=—–-]?[[:space:]]*[vV]?(${SEMVER_PATTERN}).*/\\2/p" |
      sed -n '1p'
  )"
  if [ -z "$version" ]; then
    version="$(
      printf '%s\n' "$text" |
        sed -nE "s/^[[:space:]]*[vV]?(${SEMVER_PATTERN})[[:space:]]*$/\\1/p" |
        sed -n '1p'
    )"
  fi

  if valid_release_version "$version"; then
    printf '%s' "$version"
    return 0
  fi
  return 1
}

version_filename_priority() {
  local name_lc

  name_lc="$(lowercase "$1")"
  case "$name_lc" in
    version)
      printf '0'
      ;;
    version.txt)
      printf '1'
      ;;
    version.md)
      printf '2'
      ;;
    version*)
      printf '3'
      ;;
    *)
      printf '9'
      ;;
  esac
}

resolve_root_version_files() {
  local changed_only="${1:-no}"
  local file=""
  local name=""
  local priority=0
  local version=""

  while [ "$priority" -le 3 ]; do
    for file in "$GIT_ROOT"/*; do
      [ -f "$file" ] || continue
      name="$(basename "$file")"
      case "$(lowercase "$name")" in
        version*)
          ;;
        *)
          continue
          ;;
      esac
      [ "$(version_filename_priority "$name")" = "$priority" ] || continue
      if version="$(extract_version_from_version_file "$file")"; then
        if [ "$changed_only" = yes ] &&
           ! release_version_eligible_for_commit "${file#"$GIT_ROOT"/}" version-file "$version"; then
          continue
        fi
        RELEASE_VERSION="$version"
        VERSION_SOURCE="${file#"$GIT_ROOT"/}"
        VERSION_POSITION="version-file"
        return 0
      fi
    done
    priority=$((priority + 1))
  done
  return 1
}

resolve_direct_child_versions() {
  local changed_only="${1:-no}"
  local candidates=""
  local kind=""
  local file=""
  local name=""
  local version=""
  local position=""
  local priority=0
  local best_priority=9
  local best_version=""
  local best_file=""
  local best_position=""
  local choose=false

  candidates="$(safe_mktemp_file "${TMPDIR:-/tmp}" "child-versions")" || return 1
  if ! version_lookup_has_time; then
    rm -f "$candidates"
    return 124
  fi
  find "$GIT_ROOT" -mindepth 1 -maxdepth 2 \
    \( -type d \( \
      -name .git -o -name node_modules -o -name vendor -o \
      -name .venv -o -name venv -o -name coverage -o \
      -name .cache -o -name __pycache__ \
    \) -prune \) -o \
    \( -mindepth 2 -type f \( \
      -iname 'VERSION*' -o -iname 'CHANGELOG*' -o \
      -name package.json -o -name manifest.json -o \
      -name manifest.webmanifest -o -name pyproject.toml -o \
      -name Cargo.toml -o -name composer.json -o \
      -name pubspec.yaml -o -name deno.json -o \
      -name bower.json \
    \) -print0 \) > "$candidates" 2>/dev/null || {
      rm -f "$candidates"
      return 1
    }
  if ! version_lookup_has_time; then
    rm -f "$candidates"
    return 124
  fi

  for kind in version-file package metadata changelog; do
    best_priority=9
    best_version=""
    best_file=""
    best_position=""
    while IFS= read -r -d '' file; do
      if ! version_lookup_has_time; then
        rm -f "$candidates"
        return 124
      fi
      name="${file##*/}"
      version=""
      position="$kind"
      priority=0
      case "$kind" in
        version-file)
          case "$(lowercase "$name")" in version*) ;; *) continue ;; esac
          priority="$(version_filename_priority "$name")"
          version="$(extract_version_from_version_file "$file" || true)"
          ;;
        package)
          [ "$name" = package.json ] || continue
          version="$(get_json_version_from_file "$file" || true)"
          ;;
        metadata)
          version="$(extract_version_from_metadata_file "$file" "$name" || true)"
          ;;
        changelog)
          case "$(lowercase "$name")" in changelog*) ;; *) continue ;; esac
          if extract_version_from_changelog "$file"; then
            version="$CHANGELOG_EXTRACTED_VERSION"
            position="$CHANGELOG_POSITION"
          fi
          ;;
      esac
      [ -n "$version" ] || continue
      if [ "$changed_only" = yes ] &&
         ! release_version_eligible_for_commit "${file#"$GIT_ROOT"/}" "$kind" "$version"; then
        continue
      fi
      choose=false
      if [ -z "$best_version" ] || [ "$priority" -lt "$best_priority" ]; then
        choose=true
      elif [ "$priority" -eq "$best_priority" ]; then
        compare_semver "$version" "$best_version"
        if [ "$SEMVER_COMPARISON" -gt 0 ] ||
           { [ "$SEMVER_COMPARISON" -eq 0 ] && [[ "$file" < "$best_file" ]]; }; then
          choose=true
        fi
      fi
      if [ "$choose" = true ]; then
        best_priority="$priority"
        best_version="$version"
        best_file="$file"
        best_position="$position"
      fi
    done < "$candidates"
    if [ -n "$best_version" ]; then
      RELEASE_VERSION="$best_version"
      VERSION_SOURCE="${best_file#"$GIT_ROOT"/}"
      VERSION_POSITION="$best_position"
      rm -f "$candidates"
      return 0
    fi
  done
  rm -f "$candidates"
  return 1
}

resolve_release_version() {
  local changed_only="${1:-no}"
  local package_version=""
  local status=0

  RELEASE_VERSION=""
  VERSION_SOURCE=""
  VERSION_POSITION=""

  if resolve_root_version_files "$changed_only"; then
    return 0
  fi

  if package_version="$(get_package_version)" &&
     { [ "$changed_only" != yes ] ||
       release_version_eligible_for_commit "package.json" package "$package_version"; }; then
    RELEASE_VERSION="$package_version"
    VERSION_SOURCE="package.json"
    VERSION_POSITION="package"
    return 0
  fi

  if resolve_root_metadata_files "$changed_only"; then
    return 0
  fi

  VERSION_LOOKUP_DEADLINE=$((SECONDS + VERSION_LOOKUP_LIMIT_SECONDS))
  status=0
  resolve_root_changelogs "$changed_only" || status=$?
  if [ "$status" -eq 0 ]; then
    return 0
  elif [ "$status" -eq 124 ]; then
    return 124
  fi

  status=0
  resolve_direct_child_versions "$changed_only" || status=$?
  if [ "$status" -eq 0 ] || [ "$status" -eq 124 ]; then
    return "$status"
  fi

  return 1
}
