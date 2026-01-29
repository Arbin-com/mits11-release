#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install.sh [stable|latest|alpha|nightly|VERSION] [--silent|--non-interactive]
Examples:
  install.sh
  install.sh alpha
  install.sh 5.0.1
  install.sh nightly
  install.sh --silent
  install.sh 5.0.1 --non-interactive
EOF
}

TARGET=""
SILENT_FLAG=""
for arg in "$@"; do
  case "$arg" in
  -h|--help)
    usage
    exit 0
    ;;
  --silent|--non-interactive)
    SILENT_FLAG="--silent"
    ;;
  *)
    if [ -z "$TARGET" ]; then
      TARGET="$arg"
    else
      echo "Unexpected argument: $arg" >&2
      usage
      exit 1
    fi
    ;;
  esac
done

if [[ -n "$TARGET" ]] && [[ ! "$TARGET" =~ ^(stable|latest|alpha|nightly|[0-9]+\.[0-9]+\.[0-9]+([\-+][^[:space:]]+)?)$ ]]; then
  echo "Invalid target: $TARGET" >&2
  usage
  exit 1
fi

BASE_URL="https://arbin-com.github.io/mits11-release"

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
    exit 1
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
  if [[ $section =~ \"url\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    url="${BASH_REMATCH[1]}"
  fi
  if [[ $section =~ \"sha256\"[[:space:]]*:[[:space:]]*\"([a-f0-9]{64})\" ]]; then
    checksum="${BASH_REMATCH[1]}"
  fi

  if [ -n "$url" ] && [ -n "$checksum" ]; then
    echo "$url $checksum"
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
else
  manifest_values="$(get_manifest_values "$manifest_json" "$platform" || true)"
  url="$(echo "$manifest_values" | awk '{print $1}')"
  checksum="$(echo "$manifest_values" | awk '{print $2}')"
fi

if [ -z "$url" ] || [ -z "$checksum" ]; then
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
  download_or_fail "$url" "$zip_path"
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
