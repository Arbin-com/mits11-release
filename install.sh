#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install.sh [stable|latest|alpha|nightly|VERSION] [--auth auto|app|pat] [--silent|--non-interactive] [--no-browser-open]
Examples:
  install.sh
  install.sh alpha
  install.sh 5.0.1
  install.sh nightly
  install.sh --silent
  install.sh --auth app
  install.sh --auth pat
  install.sh 5.0.1 --non-interactive
EOF
}

TARGET=""
SILENT_FLAG=""
AUTH_MODE="auto"
NO_BROWSER_OPEN=0
while [ $# -gt 0 ]; do
  case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
  --silent|--non-interactive)
    SILENT_FLAG="--silent"
    ;;
  --auth)
    if [ $# -lt 2 ]; then
      echo "--auth requires a value: auto, app, or pat" >&2
      usage
      exit 1
    fi
    case "$2" in
      auto|app|pat)
        AUTH_MODE="$2"
        ;;
      *)
        echo "Invalid auth mode: $2" >&2
        usage
        exit 1
        ;;
    esac
    shift
    ;;
  --no-browser-open)
    NO_BROWSER_OPEN=1
    ;;
  *)
    if [ -z "$TARGET" ]; then
      TARGET="$1"
    else
      echo "Unexpected argument: $1" >&2
      usage
      exit 1
    fi
    ;;
  esac
  shift
done

if [[ -n "$TARGET" ]] && [[ ! "$TARGET" =~ ^(stable|latest|alpha|nightly|[0-9]+\.[0-9]+\.[0-9]+([\-+][^[:space:]]+)?)$ ]]; then
  echo "Invalid target: $TARGET" >&2
  usage
  exit 1
fi

BASE_URL="https://arbin-com.github.io/mits11-release"
GITHUB_APP_CLIENT_ID="Iv23liqzeRmAZM7t6ZU1"
GITHUB_AUTH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
AUTH_KIND=""
MITS11_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mits11"
MITS11_APP_TOKEN_FILE="$MITS11_CONFIG_DIR/github-app-auth.json"

DOWNLOADER=""
if command -v curl >/dev/null 2>&1; then
  DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
  DOWNLOADER="wget"
else
  echo "Either curl or wget is required but neither is installed" >&2
  exit 1
fi

if ! command -v unzip >/dev/null 2>&1; then
  echo "unzip is required but not installed" >&2
  exit 1
fi

HAS_JQ=false
if command -v jq >/dev/null 2>&1; then
  HAS_JQ=true
fi

download() {
  local url="$1"
  local out="${2:-}"
  if [ "$DOWNLOADER" = "curl" ]; then
    if [ -n "$out" ]; then
      curl -fsSL -o "$out" "$url"
    else
      curl -fsSL "$url"
    fi
  else
    if [ -n "$out" ]; then
      wget -q -O "$out" "$url"
    else
      wget -q -O - "$url"
    fi
  fi
}

download_or_fail() {
  local url="$1"
  local out="${2:-}"
  if ! download "$url" "$out"; then
    echo "Failed to download $url" >&2
    if [[ "$url" == https://github.com/*/releases/download/* || "$url" == https://api.github.com/repos/*/releases/* ]]; then
      echo "This looks like a GitHub release download. If the repository is private, use --auth app or --auth pat, or set GH_TOKEN/GITHUB_TOKEN." >&2
    fi
    exit 1
  fi
}

urlencode() {
  local value="$1"
  local encoded=""
  local i char
  for ((i = 0; i < ${#value}; i++)); do
    char="${value:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-]) encoded+="$char" ;;
      *)
        printf -v encoded '%s%%%02X' "$encoded" "'$char"
        ;;
    esac
  done
  printf '%s' "$encoded"
}

form_encode() {
  local encoded=""
  while [ $# -gt 1 ]; do
    if [ -n "$encoded" ]; then
      encoded+="&"
    fi
    encoded+="$(urlencode "$1")=$(urlencode "$2")"
    shift 2
  done
  printf '%s' "$encoded"
}

json_get_string() {
  local json
  json="$(normalize_json "$1")"
  if [[ $json =~ \"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

json_get_number() {
  local json
  json="$(normalize_json "$1")"
  if [[ $json =~ \"$2\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

parse_github_release_url() {
  local source_url="$1"
  if [[ "$source_url" =~ ^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/]+)$ ]]; then
    printf '%s\t%s\t%s\t%s\n' \
      "${BASH_REMATCH[1]}" \
      "${BASH_REMATCH[2]}" \
      "${BASH_REMATCH[3]}" \
      "${BASH_REMATCH[4]}"
    return 0
  fi
  return 1
}

github_api_get() {
  local url="$1"
  resolve_github_auth

  if [ "$DOWNLOADER" = "curl" ]; then
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_AUTH_TOKEN" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url"
  else
    wget -q -O - \
      --header="Accept: application/vnd.github+json" \
      --header="Authorization: Bearer $GITHUB_AUTH_TOKEN" \
      --header="X-GitHub-Api-Version: 2022-11-28" \
      "$url"
  fi
}

resolve_github_asset_api_url_from_metadata() {
  local owner="$1"
  local repo="$2"
  local tag="$3"
  local asset_name="$4"
  local response asset_url

  response="$(github_api_get "https://api.github.com/repos/$owner/$repo/releases/tags/$tag")"
  if [ "$HAS_JQ" = true ]; then
    asset_url="$(echo "$response" | jq -r --arg asset_name "$asset_name" '.assets[] | select(.name == $asset_name) | .url' | head -n 1)"
  else
    local normalized asset_block
    normalized="$(normalize_json "$response")"
    asset_block="$(echo "$normalized" | grep -oE '\{[^{}]*"name"[[:space:]]*:[[:space:]]*"[^"]+"[^{}]*"url"[[:space:]]*:[[:space:]]*"https://api\.github\.com/repos/[^"]+/releases/assets/[0-9]+"[^{}]*\}' | grep "\"name\":\"$asset_name\"" | head -n 1 || true)"
    if [ -n "$asset_block" ]; then
      asset_url="$(json_get_string "$asset_block" "url" || true)"
    else
      asset_url=""
    fi
  fi

  if [ -z "$asset_url" ]; then
    echo "Failed to resolve GitHub release asset URL for $owner/$repo tag $tag asset $asset_name" >&2
    echo "Authentication may be missing, expired, or the release asset name may no longer match the manifest." >&2
    exit 1
  fi
  printf '%s' "$asset_url"
}

populate_github_metadata_from_url_if_needed() {
  if [ -n "${github_asset_api_url:-}" ] || [ -z "${url:-}" ]; then
    return 0
  fi

  local parsed_url
  parsed_url="$(parse_github_release_url "$url" || true)"
  if [ -z "$parsed_url" ]; then
    return 0
  fi

  IFS=$'\t' read -r github_owner github_repo github_tag github_asset <<< "$parsed_url"
}

require_pat_token() {
  if [ -n "${GITHUB_AUTH_TOKEN:-}" ]; then
    AUTH_KIND="pat"
    return 0
  fi

  if [ -n "$SILENT_FLAG" ] || [ ! -r /dev/tty ]; then
    echo "GH_TOKEN or GITHUB_TOKEN is required for authenticated downloads in non-interactive mode" >&2
    exit 1
  fi

  printf "GitHub personal access token: " >/dev/tty
  stty -echo </dev/tty
  IFS= read -r GITHUB_AUTH_TOKEN </dev/tty
  stty echo </dev/tty
  printf "\n" >/dev/tty

  GITHUB_AUTH_TOKEN="$(echo "$GITHUB_AUTH_TOKEN" | tr -d '[:space:]')"
  if [ -z "$GITHUB_AUTH_TOKEN" ]; then
    echo "A GitHub personal access token is required" >&2
    exit 1
  fi
  AUTH_KIND="pat"
}

github_post_form() {
  local url="$1"
  shift
  local body
  body="$(form_encode "$@")"

  if [ "$DOWNLOADER" = "curl" ]; then
    curl -fsSL \
      -X POST \
      -H "Accept: application/json" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data "$body" \
      "$url"
  else
    wget -q -O - \
      --method=POST \
      --header="Accept: application/json" \
      --header="Content-Type: application/x-www-form-urlencoded" \
      --body-data="$body" \
      "$url"
  fi
}

load_app_token_cache() {
  APP_ACCESS_TOKEN=""
  APP_REFRESH_TOKEN=""
  APP_ACCESS_TOKEN_EXPIRES_AT=0
  APP_REFRESH_TOKEN_EXPIRES_AT=0

  if [ ! -f "$MITS11_APP_TOKEN_FILE" ]; then
    return 1
  fi

  local cache_json
  cache_json="$(cat "$MITS11_APP_TOKEN_FILE")"

  if [ "$HAS_JQ" = true ]; then
    APP_ACCESS_TOKEN="$(echo "$cache_json" | jq -r '.access_token // empty')"
    APP_REFRESH_TOKEN="$(echo "$cache_json" | jq -r '.refresh_token // empty')"
    APP_ACCESS_TOKEN_EXPIRES_AT="$(echo "$cache_json" | jq -r '.access_token_expires_at // 0')"
    APP_REFRESH_TOKEN_EXPIRES_AT="$(echo "$cache_json" | jq -r '.refresh_token_expires_at // 0')"
  else
    APP_ACCESS_TOKEN="$(json_get_string "$cache_json" "access_token" || true)"
    APP_REFRESH_TOKEN="$(json_get_string "$cache_json" "refresh_token" || true)"
    APP_ACCESS_TOKEN_EXPIRES_AT="$(json_get_number "$cache_json" "access_token_expires_at" || printf '0')"
    APP_REFRESH_TOKEN_EXPIRES_AT="$(json_get_number "$cache_json" "refresh_token_expires_at" || printf '0')"
  fi

  [ -n "$APP_ACCESS_TOKEN" ]
}

save_app_token_cache() {
  local access_token="$1"
  local refresh_token="$2"
  local expires_in="$3"
  local refresh_expires_in="$4"
  local now
  now="$(date +%s)"
  local access_expires_at=$((now + expires_in - 60))
  local refresh_expires_at=$((now + refresh_expires_in - 300))

  mkdir -p "$MITS11_CONFIG_DIR"
  chmod 700 "$MITS11_CONFIG_DIR" 2>/dev/null || true
  printf '{\n  "access_token": "%s",\n  "refresh_token": "%s",\n  "access_token_expires_at": %s,\n  "refresh_token_expires_at": %s\n}\n' \
    "$(json_escape "$access_token")" \
    "$(json_escape "$refresh_token")" \
    "$access_expires_at" \
    "$refresh_expires_at" > "$MITS11_APP_TOKEN_FILE"
  chmod 600 "$MITS11_APP_TOKEN_FILE" 2>/dev/null || true
}

is_epoch_in_future() {
  local epoch="${1:-0}"
  local now
  now="$(date +%s)"
  [ "$epoch" -gt "$now" ]
}

open_browser_if_possible() {
  local url="$1"
  if [ "$NO_BROWSER_OPEN" = "1" ]; then
    return 0
  fi
  if [ "$os" = "osx" ] && command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 || true
  elif [ "$os" = "linux" ] && command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 || true
  fi
}

refresh_app_access_token() {
  if ! load_app_token_cache || [ -z "$APP_REFRESH_TOKEN" ] || ! is_epoch_in_future "${APP_REFRESH_TOKEN_EXPIRES_AT:-0}"; then
    return 1
  fi

  local response
  if ! response="$(github_post_form "https://github.com/login/oauth/access_token" \
    client_id "$GITHUB_APP_CLIENT_ID" \
    grant_type "refresh_token" \
    refresh_token "$APP_REFRESH_TOKEN")"; then
    return 1
  fi

  local error access_token refresh_token expires_in refresh_expires_in
  error="$(json_get_string "$response" "error" || true)"
  if [ -n "$error" ]; then
    return 1
  fi

  access_token="$(json_get_string "$response" "access_token" || true)"
  refresh_token="$(json_get_string "$response" "refresh_token" || true)"
  expires_in="$(json_get_number "$response" "expires_in" || printf '0')"
  refresh_expires_in="$(json_get_number "$response" "refresh_token_expires_in" || printf '0')"

  if [ -z "$access_token" ] || [ -z "$refresh_token" ] || [ "$expires_in" -le 0 ] || [ "$refresh_expires_in" -le 0 ]; then
    return 1
  fi

  save_app_token_cache "$access_token" "$refresh_token" "$expires_in" "$refresh_expires_in"
  GITHUB_AUTH_TOKEN="$access_token"
  AUTH_KIND="app"
  return 0
}

start_device_flow() {
  local response device_code user_code verification_uri interval expires_in
  response="$(github_post_form "https://github.com/login/device/code" client_id "$GITHUB_APP_CLIENT_ID")"
  device_code="$(json_get_string "$response" "device_code" || true)"
  user_code="$(json_get_string "$response" "user_code" || true)"
  verification_uri="$(json_get_string "$response" "verification_uri" || true)"
  interval="$(json_get_number "$response" "interval" || printf '5')"
  expires_in="$(json_get_number "$response" "expires_in" || printf '900')"

  if [ -z "$device_code" ] || [ -z "$user_code" ] || [ -z "$verification_uri" ]; then
    echo "Failed to start GitHub device flow" >&2
    exit 1
  fi

  echo "Authenticate with GitHub to download private release assets."
  echo "Open: $verification_uri"
  echo "Code: $user_code"
  open_browser_if_possible "$verification_uri"

  local started_at now response_token error access_token refresh_token token_expires_in refresh_expires_in
  started_at="$(date +%s)"
  while true; do
    response_token="$(github_post_form "https://github.com/login/oauth/access_token" \
      client_id "$GITHUB_APP_CLIENT_ID" \
      device_code "$device_code" \
      grant_type "urn:ietf:params:oauth:grant-type:device_code")"
    error="$(json_get_string "$response_token" "error" || true)"

    if [ -z "$error" ]; then
      access_token="$(json_get_string "$response_token" "access_token" || true)"
      refresh_token="$(json_get_string "$response_token" "refresh_token" || true)"
      token_expires_in="$(json_get_number "$response_token" "expires_in" || printf '0')"
      refresh_expires_in="$(json_get_number "$response_token" "refresh_token_expires_in" || printf '0')"
      if [ -z "$access_token" ] || [ -z "$refresh_token" ] || [ "$token_expires_in" -le 0 ] || [ "$refresh_expires_in" -le 0 ]; then
        echo "GitHub device flow returned an incomplete token response" >&2
        exit 1
      fi
      save_app_token_cache "$access_token" "$refresh_token" "$token_expires_in" "$refresh_expires_in"
      GITHUB_AUTH_TOKEN="$access_token"
      AUTH_KIND="app"
      return 0
    fi

    case "$error" in
      authorization_pending)
        sleep "$interval"
        ;;
      slow_down)
        interval=$((interval + 5))
        sleep "$interval"
        ;;
      expired_token|access_denied)
        echo "GitHub device flow failed: $error" >&2
        exit 1
        ;;
      *)
        echo "GitHub device flow failed: $error" >&2
        exit 1
        ;;
    esac

    now="$(date +%s)"
    if [ $((now - started_at)) -ge "$expires_in" ]; then
      echo "GitHub device flow code expired before authentication completed" >&2
      exit 1
    fi
  done
}

use_cached_app_token_if_available() {
  if ! load_app_token_cache; then
    return 1
  fi
  if [ -n "$APP_ACCESS_TOKEN" ] && is_epoch_in_future "${APP_ACCESS_TOKEN_EXPIRES_AT:-0}"; then
    GITHUB_AUTH_TOKEN="$APP_ACCESS_TOKEN"
    AUTH_KIND="app"
    return 0
  fi
  refresh_app_access_token
}

resolve_app_token() {
  if use_cached_app_token_if_available; then
    return 0
  fi

  if [ -n "$SILENT_FLAG" ] || [ ! -r /dev/tty ]; then
    echo "GitHub App authentication requires an interactive terminal or a cached token in non-interactive mode" >&2
    exit 1
  fi

  start_device_flow
}

choose_auth_mode_interactive() {
  local selection
  echo "Authentication required."
  echo "1) GitHub browser login (recommended)"
  echo "2) Personal access token"
  while true; do
    printf "Select [1/2]: " >/dev/tty
    IFS= read -r selection </dev/tty
    case "$selection" in
      1) AUTH_MODE="app"; return 0 ;;
      2) AUTH_MODE="pat"; return 0 ;;
    esac
  done
}

resolve_github_auth() {
  case "$AUTH_MODE" in
    pat)
      require_pat_token
      ;;
    app)
      resolve_app_token
      ;;
    auto)
      if [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
        require_pat_token
        return 0
      fi
      if use_cached_app_token_if_available; then
        return 0
      fi
      if [ -n "$SILENT_FLAG" ] || [ ! -r /dev/tty ]; then
        echo "Authentication required. Provide GH_TOKEN/GITHUB_TOKEN or use a cached GitHub App token." >&2
        exit 1
      fi
      choose_auth_mode_interactive
      resolve_github_auth
      ;;
  esac
}

download_github_asset() {
  local url="$1"
  local out="$2"
  resolve_github_auth

  if [ "$DOWNLOADER" = "curl" ]; then
    curl -fsSL \
      -H "Accept: application/octet-stream" \
      -H "Authorization: Bearer $GITHUB_AUTH_TOKEN" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -o "$out" \
      "$url"
  else
    wget -q \
      --header="Accept: application/octet-stream" \
      --header="Authorization: Bearer $GITHUB_AUTH_TOKEN" \
      --header="X-GitHub-Api-Version: 2022-11-28" \
      -O "$out" \
      "$url"
  fi
}

normalize_json() {
  echo "$1" | tr -d '\n\r\t' | sed 's/[[:space:]]\+/ /g'
}

get_manifest_values() {
  local json="$1"
  local platform="$2"
  json="$(normalize_json "$json")"
  local section=""
  if [[ $json =~ \"$platform\"[[:space:]]*:[[:space:]]*\{([^}]*)\} ]]; then
    section="${BASH_REMATCH[1]}"
  else
    return 1
  fi

  local url=""
  local checksum=""
  local github_asset_api_url=""
  local github_owner=""
  local github_repo=""
  local github_tag=""
  local github_asset=""
  if [[ $section =~ \"url\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    url="${BASH_REMATCH[1]}"
  fi
  if [[ $section =~ \"sha256\"[[:space:]]*:[[:space:]]*\"([a-f0-9]{64})\" ]]; then
    checksum="${BASH_REMATCH[1]}"
  fi
  if [[ $section =~ \"github_asset_api_url\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    github_asset_api_url="${BASH_REMATCH[1]}"
  fi
  if [[ $section =~ \"github_owner\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    github_owner="${BASH_REMATCH[1]}"
  fi
  if [[ $section =~ \"github_repo\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    github_repo="${BASH_REMATCH[1]}"
  fi
  if [[ $section =~ \"github_tag\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    github_tag="${BASH_REMATCH[1]}"
  fi
  if [[ $section =~ \"github_asset\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    github_asset="${BASH_REMATCH[1]}"
  fi

  if { [ -n "$url" ] || [ -n "$github_asset_api_url" ]; } && [ -n "$checksum" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$url" \
      "$checksum" \
      "$github_asset_api_url" \
      "$github_owner" \
      "$github_repo" \
      "$github_tag" \
      "$github_asset"
    return 0
  fi
  return 1
}

case "$(uname -s)" in
  Darwin) os="osx" ;;
  Linux) os="linux" ;;
  *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64|amd64) arch="x64" ;;
  arm64|aarch64) arch="arm64" ;;
  *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

platform="${os}-${arch}"

target="${TARGET:-stable}"
version=""

if [[ "$target" == "stable" || "$target" == "latest" || -z "$target" ]]; then
  version="$(download_or_fail "$BASE_URL/stable")"
elif [[ "$target" == "alpha" ]]; then
  version="$(download_or_fail "$BASE_URL/alpha")"
elif [[ "$target" == "nightly" ]]; then
  version="$(download_or_fail "$BASE_URL/nightly")"
else
  version="$target"
fi

version="$(echo "$version" | tr -d '[:space:]')"
if [ -z "$version" ]; then
  echo "Failed to resolve version for target: $target" >&2
  exit 1
fi

manifest_url="$BASE_URL/$version/manifest.json"
manifest_json="$(download_or_fail "$manifest_url")"

if [ "$HAS_JQ" = true ]; then
  url="$(echo "$manifest_json" | jq -r ".platforms[\"$platform\"].url // empty")"
  checksum="$(echo "$manifest_json" | jq -r ".platforms[\"$platform\"].sha256 // empty")"
  github_asset_api_url="$(echo "$manifest_json" | jq -r ".platforms[\"$platform\"].github_asset_api_url // empty")"
  github_owner="$(echo "$manifest_json" | jq -r ".platforms[\"$platform\"].github_owner // empty")"
  github_repo="$(echo "$manifest_json" | jq -r ".platforms[\"$platform\"].github_repo // empty")"
  github_tag="$(echo "$manifest_json" | jq -r ".platforms[\"$platform\"].github_tag // empty")"
  github_asset="$(echo "$manifest_json" | jq -r ".platforms[\"$platform\"].github_asset // empty")"
else
  manifest_values="$(get_manifest_values "$manifest_json" "$platform" || true)"
  url="$(printf '%s' "$manifest_values" | awk -F '\t' '{print $1}')"
  checksum="$(printf '%s' "$manifest_values" | awk -F '\t' '{print $2}')"
  github_asset_api_url="$(printf '%s' "$manifest_values" | awk -F '\t' '{print $3}')"
  github_owner="$(printf '%s' "$manifest_values" | awk -F '\t' '{print $4}')"
  github_repo="$(printf '%s' "$manifest_values" | awk -F '\t' '{print $5}')"
  github_tag="$(printf '%s' "$manifest_values" | awk -F '\t' '{print $6}')"
  github_asset="$(printf '%s' "$manifest_values" | awk -F '\t' '{print $7}')"
fi

populate_github_metadata_from_url_if_needed

if { [ -z "$url" ] && [ -z "$github_asset_api_url" ]; } || [ -z "$checksum" ]; then
  echo "Platform $platform not found in manifest for version $version" >&2
  exit 1
fi

if [[ ! "$checksum" =~ ^[a-f0-9]{64}$ ]]; then
  echo "Invalid checksum in manifest for $platform" >&2
  exit 1
fi

keep_temp="${MITS11_KEEP_TEMP:-0}"
tmp_dir="$(mktemp -d)"
cache_dir="${MITS11_CACHE_DIR:-${TMPDIR:-/tmp}/mits11-cache}"
mkdir -p "$cache_dir"
zip_path="$cache_dir/mits11-${version}-${platform}.zip"
extract_root="$tmp_dir/extract"
install_success=0

cleanup() {
  if [ "$keep_temp" = "1" ]; then
    return
  fi
  if [ -n "${tmp_dir:-}" ] && [ -d "$tmp_dir" ]; then
    rm -rf "$tmp_dir"
  fi
  if [ "$install_success" = "1" ] && [ -n "${zip_path:-}" ]; then
    rm -f "$zip_path"
  fi
}
trap cleanup EXIT

if [ "$os" = "darwin" ]; then
  if ! command -v shasum >/dev/null 2>&1; then
    echo "shasum is required but not installed" >&2
    exit 1
  fi
  checksum_cmd() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "sha256sum is required but not installed" >&2
    exit 1
  fi
  checksum_cmd() { sha256sum "$1" | cut -d' ' -f1; }
fi

if [ -f "$zip_path" ]; then
  actual="$(checksum_cmd "$zip_path")"
  if [ "$actual" = "$checksum" ]; then
    echo "Using cached package: $zip_path"
  else
    rm -f "$zip_path"
  fi
fi

if [ ! -f "$zip_path" ]; then
  echo "Downloading MITS11 $version ($platform)..."
  if [ -z "$github_asset_api_url" ] && [ -n "${github_owner:-}" ] && [ -n "${github_repo:-}" ] && [ -n "${github_tag:-}" ] && [ -n "${github_asset:-}" ]; then
    github_asset_api_url="$(resolve_github_asset_api_url_from_metadata "$github_owner" "$github_repo" "$github_tag" "$github_asset")"
  fi
  if [ -n "$github_asset_api_url" ]; then
    if ! download_github_asset "$github_asset_api_url" "$zip_path"; then
      echo "Failed to download ${github_owner:-GitHub}/${github_repo:-release} asset ${github_asset:-for $platform}" >&2
      echo "Auth mode: ${AUTH_KIND:-unknown}. If this is a private repository, re-run with --auth app or --auth pat, or refresh your cached GitHub App login." >&2
      exit 1
    fi
  else
    download_or_fail "$url" "$zip_path"
  fi
  actual="$(checksum_cmd "$zip_path")"
  if [ "$actual" != "$checksum" ]; then
    rm -f "$zip_path"
    echo "Checksum verification failed" >&2
    exit 1
  fi
fi

mkdir -p "$extract_root"
unzip -q "$zip_path" -d "$extract_root"

install_script="$(find "$extract_root" -type f -path "*/script/install.sh" | head -n 1)"
if [ -z "$install_script" ]; then
  echo "Installer not found in package" >&2
  exit 1
fi

chmod +x "$install_script"
echo "Running installer..."
installer_args=()
if [ -n "$SILENT_FLAG" ]; then
  installer_args+=("$SILENT_FLAG")
fi
if [ -r /dev/tty ]; then
  "$install_script" "${installer_args[@]}" </dev/tty
else
  "$install_script" "${installer_args[@]}"
fi

install_success=1
echo "Done."
