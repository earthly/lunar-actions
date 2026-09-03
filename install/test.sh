#!/usr/bin/env bash
# Hermetic tests for install.sh: a fake `lunar` served from a local HTTP server
# stands in for lunar-dist. Run from anywhere; needs bash, curl, python3.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/install.sh"

work=$(mktemp -d)
trap 'kill "${server_pid:-}" 2>/dev/null; rm -rf "$work"' EXIT

# Fake release asset: answers `version` like the real CLI does.
srv="$work/srv"
mkdir -p "$srv/v3.20.0"
cat > "$srv/v3.20.0/lunar-linux-amd64" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "version" ] && echo "3.20.0 (deadbeef)"
SH
chmod +x "$srv/v3.20.0/lunar-linux-amd64"
checksum=$(sha256sum "$srv/v3.20.0/lunar-linux-amd64" | awk '{print $1}')

port=$((20000 + RANDOM % 20000))
python3 -m http.server --bind 127.0.0.1 "$port" --directory "$srv" >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$port/" >/dev/null 2>&1 && break; sleep 0.1; done

fails=0
pass() { echo "ok   $1"; }
flunk() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else flunk "$1 -- [$2]"; fi; }

# run <case-dir> [VAR=value ...]: runs install.sh with a clean env; leaves
# out/path/env files plus stdout/stderr/rc in <case-dir>.
run() {
  local d=$1; shift
  mkdir -p "$d"
  : > "$d/out"; : > "$d/path"; : > "$d/env"
  env -i PATH="$PATH" HOME="$work" \
    RUNNER_OS=Linux RUNNER_ARCH=X64 RUNNER_TOOL_CACHE="$d/toolcache" RUNNER_TEMP="$d/tmp" \
    GITHUB_OUTPUT="$d/out" GITHUB_PATH="$d/path" GITHUB_ENV="$d/env" \
    INPUT_DOWNLOAD_BASE_URL="http://127.0.0.1:$port" INPUT_VERSION=v3.20.0 INPUT_EXPORT_ENV=false \
    "$@" bash "$script" > "$d/stdout" 2> "$d/stderr"
  echo $? > "$d/rc"
}
rc() { cat "$1/rc"; }
out() { grep "^$2=" "$1/out" | tail -1 | cut -d= -f2-; }

# 1. fresh install into the tool cache
c="$work/fresh"; run "$c"
check "fresh: exits 0" "[ \"$(rc "$c")\" = 0 ]"
check "fresh: cache-hit=false" "[ \"$(out "$c" cache-hit)\" = false ]"
check "fresh: version output is the tag" "[ \"$(out "$c" version)\" = v3.20.0 ]"
bin=$(out "$c" lunar-path)
check "fresh: binary lands in tool cache" "[ \"$bin\" = \"$c/toolcache/lunar/v3.20.0/x64/lunar\" ]"
check "fresh: binary is executable and runs" "[ -x \"$bin\" ] && [ \"\$(\"$bin\" version)\" = '3.20.0 (deadbeef)' ]"
check "fresh: dir added to GITHUB_PATH" "[ \"$(cat "$c/path")\" = \"$(dirname "$bin")\" ]"
check "fresh: export-env=false writes nothing" "[ ! -s \"$c/env\" ]"

# 2. second run reuses it
run "$c"
check "rerun: cache-hit=true" "[ \"$(out "$c" cache-hit)\" = true ]"
check "rerun: no download logged" "! grep -q Downloading \"$c/stdout\""

# 3. a stale/garbage cached file is replaced, not reused
echo "garbage" > "$bin"
run "$c"
check "stale cache: replaced" "[ \"$(out "$c" cache-hit)\" = false ] && [ \"\$(\"$bin\" version)\" = '3.20.0 (deadbeef)' ]"

# 4. checksum verification
c="$work/sum-ok"; run "$c" INPUT_CHECKSUM="$checksum"
check "checksum: correct value accepted" "[ \"$(rc "$c")\" = 0 ]"
run "$c" INPUT_CHECKSUM="$(printf '%s' "$checksum" | tr '[:lower:]' '[:upper:]')"
check "checksum: uppercase accepted on a cached binary" "[ \"$(rc "$c")\" = 0 ] && [ \"$(out "$c" cache-hit)\" = true ]"
c="$work/sum-bad"; run "$c" INPUT_CHECKSUM=0000000000000000000000000000000000000000000000000000000000000000 INPUT_INSTALL_DIR="$c/dir"
check "checksum: mismatch fails" "[ \"$(rc "$c")\" != 0 ] && grep -q 'checksum mismatch' \"$c/stderr\""
check "checksum: mismatch leaves no binary behind" "[ ! -e \"$c/dir/lunar\" ]"

# 5. install-dir override
c="$work/dir"; run "$c" INPUT_INSTALL_DIR="$c/custom"
check "install-dir: honoured" "[ \"$(out "$c" lunar-path)\" = \"$c/custom/lunar\" ]"

# 6. version normalisation and validation
c="$work/nov"; run "$c" INPUT_VERSION=3.20.0
check "version: leading v added" "[ \"$(rc "$c")\" = 0 ] && [ \"$(out "$c" version)\" = v3.20.0 ]"
c="$work/badv"; run "$c" INPUT_VERSION=latest
check "version: 'latest' rejected" "[ \"$(rc "$c")\" != 0 ] && grep -q 'not a release tag' \"$c/stderr\""
c="$work/missing"; run "$c" INPUT_VERSION=v9.9.9
check "version: unpublished tag fails with the URL" "[ \"$(rc "$c")\" != 0 ] && grep -q 'download failed: http://127.0.0.1:$port/v9.9.9/lunar-linux-amd64' \"$c/stderr\""

# 7. unsupported platform
c="$work/win"; run "$c" RUNNER_OS=Windows
check "platform: Windows/X64 fails naming the combination" "[ \"$(rc "$c")\" != 0 ] && grep -q 'Windows/X64' \"$c/stderr\""
c="$work/arm"; run "$c" RUNNER_ARCH=ARM64
check "platform: Linux/ARM64 asks for the arm64 asset" "grep -q 'v3.20.0/lunar-linux-arm64' \"$c/stderr\""

# 8. export-env
c="$work/env"; run "$c" INPUT_EXPORT_ENV=true INPUT_HUB_HOST=hub.example.com INPUT_HUB_TOKEN=s3cret INPUT_HUB_GRPC_PORT=8443 INPUT_HUB_HTTP_PORT=443 INPUT_LOG_LEVEL=info
check "export-env: token masked before use" "grep -q '^::add-mask::s3cret$' \"$c/stdout\""
check "export-env: hub settings written" "[ \"$(sort "$c/env" | tr '\n' ' ')\" = 'LUNAR_HUB_GRPC_PORT=8443 LUNAR_HUB_HOST=hub.example.com LUNAR_HUB_HTTP_PORT=443 LUNAR_HUB_TOKEN=s3cret LUNAR_LOG_LEVEL=info ' ]"
c="$work/env-nohost"; run "$c" INPUT_EXPORT_ENV=true INPUT_HUB_GRPC_PORT=443 INPUT_HUB_HTTP_PORT=443
check "export-env: nothing written without host/token" "[ ! -s \"$c/env\" ]"

echo
if [ "$fails" -eq 0 ]; then echo "install.sh: all tests passed"; else echo "install.sh: $fails test(s) FAILED"; exit 1; fi
