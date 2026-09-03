#!/usr/bin/env bash
# Hermetic tests for record-release.sh: a fake `lunar` records the argv it was
# called with instead of talking to a Hub. Run from anywhere; needs bash + git.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/record-release.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/lunar" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_LUNAR_ARGS"
env | grep '^LUNAR_HUB_' | sort > "$FAKE_LUNAR_ENV"
SH
chmod +x "$work/bin/lunar"

fails=0
pass() { echo "ok   $1"; }
flunk() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else flunk "$1 -- [$2]"; fi; }

full_sha=0123456789abcdef0123456789abcdef01234567

# run <case-dir> [VAR=value ...]: a tag-push of v1.2.3 on my-org/my-service with
# Hub settings exported by a previous step; overrides layer on top.
run() {
  local d=$1; shift
  mkdir -p "$d"
  : > "$d/out"; : > "$d/args"; : > "$d/env"
  env -i PATH="$work/bin:/usr/bin:/bin" HOME="$work" \
    FAKE_LUNAR_ARGS="$d/args" FAKE_LUNAR_ENV="$d/env" GITHUB_OUTPUT="$d/out" \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=my-org/my-service \
    GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.2.3 GITHUB_SHA=$full_sha GITHUB_ACTOR=octocat GITHUB_RUN_ID=123 \
    LUNAR_HUB_HOST=hub.example.com LUNAR_HUB_TOKEN=exported-token LUNAR_HUB_GRPC_PORT=443 LUNAR_HUB_HTTP_PORT=443 \
    INPUT_TIMESTAMP=2026-09-03T12:00:00Z \
    "$@" bash "$script" > "$d/stdout" 2> "$d/stderr"
  echo $? > "$d/rc"
}
rc() { cat "$1/rc"; }
args() { tr '\n' ' ' < "$1/args"; }
out() { grep "^$2=" "$1/out" | tail -1 | cut -d= -f2-; }

# 1. tag push, all defaults
c="$work/defaults"; run "$c"
check "defaults: exits 0" "[ \"$(rc "$c")\" = 0 ]"
check "defaults: exact lunar collect argv" "[ \"$(args "$c")\" = 'collect --component github.com/my-org/my-service --sha $full_sha .release.tag v1.2.3 .release.sha $full_sha .release.timestamp 2026-09-03T12:00:00Z .release.author octocat .release.workflow_run https://github.com/my-org/my-service/actions/runs/123 ' ]"
check "defaults: outputs" "[ \"$(out "$c" component)\" = github.com/my-org/my-service ] && [ \"$(out "$c" sha)\" = $full_sha ] && [ \"$(out "$c" path)\" = .release ]"
check "defaults: exported hub env passed through" "grep -q '^LUNAR_HUB_HOST=hub.example.com$' \"$c/env\" && grep -q '^LUNAR_HUB_TOKEN=exported-token$' \"$c/env\""
check "defaults: summary line" "grep -q 'Recorded release v1.2.3 for github.com/my-org/my-service@0123456789ab under .release' \"$c/stdout\""

# 2. everything explicit, nested under an artifact
other=fedcba9876543210fedcba9876543210fedcba98
c="$work/explicit"; run "$c" INPUT_COMPONENT=github.com/acme/api INPUT_TAG=api-v2.0.0 INPUT_VERSION=2.0.0 INPUT_IMAGE=ghcr.io/acme/api:2.0.0 INPUT_SHA=$other INPUT_AUTHOR=release-bot INPUT_WORKFLOW_RUN=https://ci.example.com/run/9 INPUT_ARTIFACT=api LUNAR_COMPONENT_ID=github.com/ignored/me
check "explicit: exact argv incl. version/image under .release.api" "[ \"$(args "$c")\" = 'collect --component github.com/acme/api --sha $other .release.api.tag api-v2.0.0 .release.api.sha $other .release.api.timestamp 2026-09-03T12:00:00Z .release.api.author release-bot .release.api.workflow_run https://ci.example.com/run/9 .release.api.version 2.0.0 .release.api.image ghcr.io/acme/api:2.0.0 ' ]"
check "explicit: path output" "[ \"$(out "$c" path)\" = .release.api ]"

# 3. component fallbacks
c="$work/compid"; run "$c" LUNAR_COMPONENT_ID=github.com/acme/from-env
check "component: LUNAR_COMPONENT_ID used when input empty" "grep -qx 'github.com/acme/from-env' \"$c/args\""
c="$work/ghes"; run "$c" GITHUB_SERVER_URL=https://ghes.example.com
check "component: GHES host derived from server URL" "grep -qx 'ghes.example.com/my-org/my-service' \"$c/args\""

# 4. tag handling
c="$work/branch"; run "$c" GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main
check "tag: branch run without tag input fails" "[ \"$(rc "$c")\" != 0 ] && grep -q 'tag not given' \"$c/stderr\" && [ ! -s \"$c/args\" ]"
c="$work/branch-tag"; run "$c" GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main INPUT_TAG=v9.9.9
check "tag: explicit input works on a branch run" "[ \"$(rc "$c")\" = 0 ] && grep -qx 'v9.9.9' \"$c/args\""

# 5. sha handling
c="$work/short"; run "$c" INPUT_SHA=0123456
check "sha: short sha outside a checkout fails" "[ \"$(rc "$c")\" != 0 ] && grep -q '40-character' \"$c/stderr\""
c="$work/upper"; run "$c" INPUT_SHA="$(printf '%s' "$full_sha" | tr '[:lower:]' '[:upper:]')"
check "sha: uppercase is lowercased" "[ \"$(rc "$c")\" = 0 ] && [ \"$(out "$c" sha)\" = $full_sha ]"
repo="$work/repo"; mkdir -p "$repo"
( cd "$repo" && git init -q && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init && git -c user.name=t -c user.email=t@t tag -a v1.2.3 -m v1.2.3 )
head=$(git -C "$repo" rev-parse HEAD)
c="$work/peel"; ( cd "$repo" && run "$c" INPUT_SHA="$(git rev-parse --short HEAD)" )
check "sha: short sha peeled to the commit inside a checkout" "[ \"$(out "$c" sha)\" = \"$head\" ]"
c="$work/peel-tag"; ( cd "$repo" && run "$c" INPUT_SHA="$(git rev-parse v1.2.3)" )
check "sha: annotated tag object peeled to the commit" "[ \"$(out "$c" sha)\" = \"$head\" ]"

# 6. artifact validation
c="$work/badart"; run "$c" INPUT_ARTIFACT=a.b
check "artifact: dotted name rejected" "[ \"$(rc "$c")\" != 0 ] && grep -q \"artifact 'a.b'\" \"$c/stderr\" && [ ! -s \"$c/args\" ]"

# 7. hub connection
c="$work/hub-in"; run "$c" INPUT_HUB_HOST=other.example.com INPUT_HUB_TOKEN=input-token INPUT_HUB_GRPC_PORT=8443
check "hub: inputs override exported env" "grep -q '^LUNAR_HUB_HOST=other.example.com$' \"$c/env\" && grep -q '^LUNAR_HUB_TOKEN=input-token$' \"$c/env\" && grep -q '^LUNAR_HUB_GRPC_PORT=8443$' \"$c/env\" && grep -q '^LUNAR_HUB_HTTP_PORT=443$' \"$c/env\""
check "hub: input token masked" "grep -q '^::add-mask::input-token$' \"$c/stdout\""
c="$work/hub-ports"; run "$c" LUNAR_HUB_GRPC_PORT= LUNAR_HUB_HTTP_PORT=
check "hub: ports default to 443" "grep -q '^LUNAR_HUB_GRPC_PORT=443$' \"$c/env\" && grep -q '^LUNAR_HUB_HTTP_PORT=443$' \"$c/env\""
c="$work/hub-none"; run "$c" LUNAR_HUB_HOST= LUNAR_HUB_TOKEN=
check "hub: missing host/token fails before calling lunar" "[ \"$(rc "$c")\" != 0 ] && grep -q 'Hub connection not configured' \"$c/stderr\" && [ ! -s \"$c/args\" ]"

# 8. lunar binary resolution
c="$work/nolunar"; run "$c" PATH=/usr/bin:/bin
check "lunar: missing binary points at the install action" "[ \"$(rc "$c")\" != 0 ] && grep -q 'earthly/lunar-actions/install' \"$c/stderr\""
c="$work/lunarpath"; run "$c" PATH=/usr/bin:/bin INPUT_LUNAR_PATH="$work/bin/lunar"
check "lunar: lunar-path input honoured" "[ \"$(rc "$c")\" = 0 ] && [ -s \"$c/args\" ]"

echo
if [ "$fails" -eq 0 ]; then echo "record-release.sh: all tests passed"; else echo "record-release.sh: $fails test(s) FAILED"; exit 1; fi
