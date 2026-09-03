#!/usr/bin/env bash
# Record a release against a component's commit with one `lunar collect`.
# Inputs arrive as INPUT_* (mapped in action.yml); GitHub context via GITHUB_*.
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }
: "${GITHUB_OUTPUT:=/dev/null}"

lunar="${INPUT_LUNAR_PATH:-lunar}"
command -v "$lunar" >/dev/null 2>&1 \
  || fail "lunar CLI not found ('$lunar'); add an earthly/lunar-actions/install step before this one, or set lunar-path"

# Hub connection: explicit inputs win over whatever the install step exported.
[ -z "${INPUT_HUB_TOKEN:-}" ] || echo "::add-mask::$INPUT_HUB_TOKEN"
export LUNAR_HUB_HOST="${INPUT_HUB_HOST:-${LUNAR_HUB_HOST:-}}"
export LUNAR_HUB_TOKEN="${INPUT_HUB_TOKEN:-${LUNAR_HUB_TOKEN:-}}"
export LUNAR_HUB_GRPC_PORT="${INPUT_HUB_GRPC_PORT:-${LUNAR_HUB_GRPC_PORT:-443}}"
export LUNAR_HUB_HTTP_PORT="${INPUT_HUB_HTTP_PORT:-${LUNAR_HUB_HTTP_PORT:-443}}"
{ [ -n "$LUNAR_HUB_HOST" ] && [ -n "$LUNAR_HUB_TOKEN" ]; } \
  || fail "Hub connection not configured: pass hub-host and hub-token here, or to the install step with export-env: true"

# Component: input, else $LUNAR_COMPONENT_ID, else <server host>/<owner>/<repo>.
component="${INPUT_COMPONENT:-${LUNAR_COMPONENT_ID:-}}"
if [ -z "$component" ]; then
  host="${GITHUB_SERVER_URL:-https://github.com}"
  host="${host#*://}"
  host="${host%%/*}"
  [ -n "${GITHUB_REPOSITORY:-}" ] || fail "component not given and GITHUB_REPOSITORY is unset"
  component="$host/$GITHUB_REPOSITORY"
fi

# Tag: input, else the pushed tag.
tag="${INPUT_TAG:-}"
if [ -z "$tag" ] && [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then tag="${GITHUB_REF_NAME:-}"; fi
[ -n "$tag" ] || fail "tag not given and this run is not a tag push (ref_type=${GITHUB_REF_TYPE:-unset}); set the tag input"

# SHA: input, else the triggering commit. With a checkout present, resolve short
# SHAs and tag objects to the commit; the Hub only accepts a full lowercase SHA.
sha="${INPUT_SHA:-${GITHUB_SHA:-}}"
[ -n "$sha" ] || fail "sha not given and GITHUB_SHA is unset"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if peeled=$(git rev-parse --verify --quiet "${sha}^{commit}" 2>/dev/null); then sha="$peeled"; fi
fi
sha=$(printf '%s' "$sha" | tr '[:upper:]' '[:lower:]')
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fail "sha '$sha' must be a full 40-character commit SHA"

author="${INPUT_AUTHOR:-${GITHUB_ACTOR:-}}"
timestamp="${INPUT_TIMESTAMP:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
run_url="${INPUT_WORKFLOW_RUN:-}"
if [ -z "$run_url" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
  run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID"
fi

path=".release"
if [ -n "${INPUT_ARTIFACT:-}" ]; then
  [[ "$INPUT_ARTIFACT" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
    || fail "artifact '$INPUT_ARTIFACT' may only contain letters, digits, '-' and '_' (it becomes a JSON key)"
  path=".release.$INPUT_ARTIFACT"
fi

# Plain string values: no --json, so nothing needs escaping and jq is not required.
args=(
  "$path.tag" "$tag"
  "$path.sha" "$sha"
  "$path.timestamp" "$timestamp"
)
[ -z "$author" ] || args+=("$path.author" "$author")
[ -z "$run_url" ] || args+=("$path.workflow_run" "$run_url")
[ -z "${INPUT_VERSION:-}" ] || args+=("$path.version" "$INPUT_VERSION")
[ -z "${INPUT_IMAGE:-}" ] || args+=("$path.image" "$INPUT_IMAGE")

"$lunar" collect --component "$component" --sha "$sha" "${args[@]}"

{
  echo "component=$component"
  echo "sha=$sha"
  echo "path=$path"
} >> "$GITHUB_OUTPUT"
echo "Recorded release $tag for $component@${sha:0:12} under $path"
