#!/usr/bin/env bash
# Install a pinned Lunar CLI release. Inputs arrive as INPUT_* (mapped in
# action.yml); runner context via the standard RUNNER_* / GITHUB_* variables.
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

: "${GITHUB_OUTPUT:=/dev/null}"
: "${GITHUB_PATH:=/dev/null}"
: "${GITHUB_ENV:=/dev/null}"
base_url="${INPUT_DOWNLOAD_BASE_URL:-https://github.com/earthly/lunar-dist/releases/download}"

[ -n "${INPUT_VERSION:-}" ] || fail "version is required (a lunar-dist tag such as v3.20.0)"
ver="${INPUT_VERSION#v}"
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] \
  || fail "version '$INPUT_VERSION' is not a release tag like v3.20.0 (see https://github.com/earthly/lunar-dist/tags)"
tag="v$ver"

os="${RUNNER_OS:-}"
arch="${RUNNER_ARCH:-}"
if [ -z "$os" ]; then
  case "$(uname -s)" in Linux) os=Linux ;; Darwin) os=macOS ;; *) os=$(uname -s) ;; esac
fi
if [ -z "$arch" ]; then
  case "$(uname -m)" in x86_64 | amd64) arch=X64 ;; aarch64 | arm64) arch=ARM64 ;; *) arch=$(uname -m) ;; esac
fi
case "$os/$arch" in
  Linux/X64) asset=lunar-linux-amd64 ;;
  Linux/ARM64) asset=lunar-linux-arm64 ;;
  macOS/ARM64) asset=lunar-darwin-arm64 ;;
  *) fail "no Lunar CLI binary is published for $os/$arch (lunar-dist ships linux-amd64, linux-arm64 and darwin-arm64)" ;;
esac

dir="${INPUT_INSTALL_DIR:-}"
if [ -z "$dir" ]; then
  cache_root="${RUNNER_TOOL_CACHE:-${RUNNER_TEMP:-}}"
  [ -n "$cache_root" ] || cache_root=$(mktemp -d)
  dir="$cache_root/lunar/$tag/$(printf '%s' "$arch" | tr '[:upper:]' '[:lower:]')"
fi
mkdir -p "$dir"
bin="$dir/lunar"

# First word of `lunar version` is the bare version ("3.20.0 (<commit>)").
reported_version() { "$1" version 2>/dev/null | awk '{print $1}' || true; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# True when no checksum was requested, or the file matches it.
checksum_ok() {
  [ -n "${INPUT_CHECKSUM:-}" ] || return 0
  [ "$(sha256_of "$1")" = "$(printf '%s' "$INPUT_CHECKSUM" | tr '[:upper:]' '[:lower:]')" ]
}

cache_hit=false
if [ -x "$bin" ] && [ "$(reported_version "$bin")" = "$ver" ] && checksum_ok "$bin"; then
  cache_hit=true
else
  url="$base_url/$tag/$asset"
  tmp="$bin.tmp.$$"
  echo "Downloading $url"
  curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp" "$url" \
    || { rm -f "$tmp"; fail "download failed: $url (does that version exist at https://github.com/earthly/lunar-dist/tags?)"; }
  chmod +x "$tmp"
  if ! checksum_ok "$tmp"; then
    got=$(sha256_of "$tmp")
    rm -f "$tmp"
    fail "checksum mismatch for $asset $tag: expected $INPUT_CHECKSUM, got $got"
  fi
  got_ver=$(reported_version "$tmp")
  [ "$got_ver" = "$ver" ] || { rm -f "$tmp"; fail "downloaded binary reports version '${got_ver:-<none>}', expected $ver"; }
  mv -f "$tmp" "$bin"
fi

echo "$dir" >> "$GITHUB_PATH"
{
  echo "lunar-path=$bin"
  echo "version=$tag"
  echo "cache-hit=$cache_hit"
} >> "$GITHUB_OUTPUT"

if [ "${INPUT_EXPORT_ENV:-true}" = "true" ]; then
  if [ -n "${INPUT_HUB_TOKEN:-}" ]; then
    echo "::add-mask::$INPUT_HUB_TOKEN"
    echo "LUNAR_HUB_TOKEN=$INPUT_HUB_TOKEN" >> "$GITHUB_ENV"
  fi
  if [ -n "${INPUT_HUB_HOST:-}" ]; then
    {
      echo "LUNAR_HUB_HOST=$INPUT_HUB_HOST"
      echo "LUNAR_HUB_GRPC_PORT=${INPUT_HUB_GRPC_PORT:-443}"
      echo "LUNAR_HUB_HTTP_PORT=${INPUT_HUB_HTTP_PORT:-443}"
    } >> "$GITHUB_ENV"
  fi
  [ -z "${INPUT_LOG_LEVEL:-}" ] || echo "LUNAR_LOG_LEVEL=$INPUT_LOG_LEVEL" >> "$GITHUB_ENV"
fi

echo "Lunar CLI $tag at $bin (cache-hit=$cache_hit)"
