#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$*"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

assert_contains() {
  local file="$1" expected="$2"
  grep -F -- "$expected" "$file" >/dev/null || fail "expected '$expected' in $file"
}

assert_not_exists() {
  [[ ! -e "$1" ]] || fail "expected path not to exist: $1"
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >"${work_dir}/failure.out" 2>&1; then
    fail "expected failure: $label"
  fi
  pass "$label"
}

fixture_bundle() {
  local product="$1" version="$2"
  local dir="${work_dir}/assets/${product}/${version}"
  mkdir -p "$dir"
  {
    printf '# fixture %s %s\n' "$product" "$version"
    printf 'services:\n'
    printf '  web:\n'
    printf '    image: example.invalid/%s:%s\n' "$product" "$version"
  } > "${dir}/compose.yaml"
  printf '%s  compose.yaml\n' "$(sha256_file "${dir}/compose.yaml")" > "${dir}/compose.yaml.sha256"
}

mkdir -p "${work_dir}/fake-bin"
apply_fake_docker="${work_dir}/fake-bin/docker"
apply_fake_curl="${work_dir}/fake-bin/curl"

cat > "$apply_fake_docker" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == "info" ]]; then
  exit 0
fi
if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
  printf 'Docker Compose version v2.30.0\n'
  exit 0
fi
printf '%s\n' "$*" >> "${TRUSTCTL_TEST_DOCKER_LOG:?}"
for argument in "$@"; do
  if [[ -n "${TRUSTCTL_TEST_DOCKER_FAIL_ON:-}" && "$argument" == "$TRUSTCTL_TEST_DOCKER_FAIL_ON" ]]; then
    exit 19
  fi
done
if [[ " $* " == *' ps '* ]]; then
  printf 'NAME STATUS\nfixture running (healthy)\n'
fi
EOF

cat > "$apply_fake_curl" <<'EOF'
#!/usr/bin/env sh
[ -z "${TRUSTCTL_TEST_CURL_LOG:-}" ] || printf '%s\n' "$*" >> "$TRUSTCTL_TEST_CURL_LOG"
[ -z "${TRUSTCTL_TEST_CURL_RESPONSE:-}" ] || printf '%s\n' "$TRUSTCTL_TEST_CURL_RESPONSE"
exit 0
EOF
chmod 755 "$apply_fake_docker" "$apply_fake_curl"

export PATH="${work_dir}/fake-bin:${PATH}"
export TRUSTCTL_TEST_DOCKER_LOG="${work_dir}/docker.log"
export TRUSTCTL_TEST_CURL_LOG="${work_dir}/curl.log"
export TRUSTCTL_TEST_OS=Linux
export TRUSTCTL_ASSET_ROOT="${work_dir}/assets"
export TRUSTCTL_LATEST_COEVAL_VERSION=1.2.3
export TRUSTCTL_LATEST_IRONSIDE_VERSION=1.2.3

fixture_bundle coeval 1.2.3
fixture_bundle ironside 1.2.3
fixture_bundle coeval 1.2.4
fixture_bundle ironside 1.2.4
fixture_bundle coeval 1.2.5
fixture_bundle coeval 2.0.0

[[ "$(sha256_file "${repo_dir}/bin/trustctl")" == "$(awk 'NR == 1 { print $1 }' "${repo_dir}/bin/trustctl.sha256")" ]] \
  || fail "published trustctl checksum is stale"
pass "published CLI checksum matches"

discovery_root="${work_dir}/discovery"
TRUSTCTL_LATEST_COEVAL_VERSION='' \
  TRUSTCTL_TEST_CURL_RESPONSE='{"tag_name":"v2.0.0","draft":false,"prerelease":false}' \
  "${repo_dir}/bin/trustctl" install coeval --root "$discovery_root" --no-start >"${work_dir}/discovery.out"
assert_contains "$discovery_root/coeval/.env" "COEVAL_VERSION=2.0.0"
assert_contains "$TRUSTCTL_TEST_CURL_LOG" "/releases/latest"
pass "default version discovery uses the latest published release endpoint"

install_root="${work_dir}/stack"
"${repo_dir}/bin/trustctl" install stack --root "$install_root" --no-start >"${work_dir}/install.out"
assert_contains "${work_dir}/install.out" "coeval configuration is valid"
assert_contains "${work_dir}/install.out" "ironside configuration is valid"
assert_contains "$install_root/coeval/.env" "COEVAL_VERSION=1.2.3"
assert_contains "$install_root/ironside/.env" "IRONSIDE_VERSION=1.2.3"
assert_contains "$install_root/.trustctl/state.env" "COEVAL_INSTALLED=1"
assert_contains "$install_root/.trustctl/state.env" "IRONSIDE_INSTALLED=1"
[[ -x "$install_root/trustctl" ]] || fail "installed CLI is not executable"
[[ "$(sha256_file "$install_root/coeval/compose.yaml")" == "$(awk 'NR == 1 { print $1 }' "$install_root/.trustctl/managed/coeval-compose.sha256")" ]] \
  || fail "managed Coeval checksum was not recorded"
pass "stack install writes validated, exact-version managed state"

"$install_root/trustctl" doctor --root "$install_root" >"${work_dir}/doctor.out"
assert_contains "${work_dir}/doctor.out" "Docker Engine and Compose v2 are reachable"
assert_contains "${work_dir}/doctor.out" "coeval: managed bundle"
assert_contains "${work_dir}/doctor.out" "ironside: managed bundle"
pass "doctor validates both managed products"

export TRUSTCTL_LATEST_COEVAL_VERSION=1.2.4
export TRUSTCTL_LATEST_IRONSIDE_VERSION=1.2.3
"$install_root/trustctl" update --check --root "$install_root" >"${work_dir}/check.out"
assert_contains "${work_dir}/check.out" "Coeval update available: 1.2.3 -> 1.2.4"
assert_contains "${work_dir}/check.out" "Ironside 1.2.3 is current."
pass "update check compares independent exact versions"

printf '\n# operator override\n' >> "$install_root/coeval/compose.override.yaml"
before_compose="$(sha256_file "$install_root/coeval/compose.yaml")"
before_env="$(sha256_file "$install_root/coeval/.env")"
before_override="$(sha256_file "$install_root/coeval/compose.override.yaml")"
"$install_root/trustctl" update coeval --root "$install_root" --version 1.2.4 --preflight-only >"${work_dir}/preflight.out"
assert_contains "${work_dir}/preflight.out" "active Compose, version, and containers are unchanged"
[[ "$before_compose" == "$(sha256_file "$install_root/coeval/compose.yaml")" ]] || fail "preflight changed active Compose"
[[ "$before_env" == "$(sha256_file "$install_root/coeval/.env")" ]] || fail "preflight changed active environment"
[[ "$before_override" == "$(sha256_file "$install_root/coeval/compose.override.yaml")" ]] || fail "preflight changed operator override"
assert_contains "$(find "$install_root/.trustctl/history/coeval" -name update.env -print -quit)" "OUTCOME=preflighted"
assert_not_exists "$install_root/.trustctl/update.lock"
pass "preflight pulls and records without changing active state"

"$install_root/trustctl" update coeval --root "$install_root" --version 1.2.4 --backup-confirmed >"${work_dir}/update.out"
assert_contains "${work_dir}/update.out" "coeval updated to 1.2.4"
assert_contains "$install_root/coeval/.env" "COEVAL_VERSION=1.2.4"
assert_contains "$install_root/coeval/compose.yaml" "fixture coeval 1.2.4"
[[ "$before_override" == "$(sha256_file "$install_root/coeval/compose.override.yaml")" ]] || fail "update changed operator override"
grep -l '^OUTCOME=healthy$' "$install_root"/.trustctl/history/coeval/*/update.env >/dev/null \
  || fail "healthy update outcome was not recorded"
assert_not_exists "$install_root/.trustctl/update.lock"
pass "explicit update preserves overrides and reaches healthy state"

expect_failure "downgrades are rejected" \
  "$install_root/trustctl" update coeval --root "$install_root" --version 1.2.3 --backup-confirmed
assert_contains "${work_dir}/failure.out" "refusing to downgrade"

expect_failure "non-interactive update requires backup assertion" \
  "$install_root/trustctl" update coeval --root "$install_root" --version 1.2.5
assert_contains "${work_dir}/failure.out" "requires --backup-confirmed"
assert_contains "$install_root/coeval/.env" "COEVAL_VERSION=1.2.4"
assert_not_exists "$install_root/.trustctl/update.lock"

mkdir "$install_root/.trustctl/update.lock"
expect_failure "concurrent updates are rejected" \
  "$install_root/trustctl" update coeval --root "$install_root" --version 1.2.5 --backup-confirmed
assert_contains "${work_dir}/failure.out" "another trustctl update appears to be active"
rmdir "$install_root/.trustctl/update.lock"

printf '\n# unauthorized managed edit\n' >> "$install_root/coeval/compose.yaml"
expect_failure "managed Compose edits fail closed" \
  "$install_root/trustctl" doctor coeval --root "$install_root"
assert_contains "${work_dir}/failure.out" "compose.yaml was edited"

expect_failure "an unmanaged root is not treated as an empty stack" \
  "${repo_dir}/bin/trustctl" status --root "${work_dir}/missing"
assert_contains "${work_dir}/failure.out" "not a trustctl installation"

expect_failure "public URLs with unsupported paths are rejected" \
  "${repo_dir}/bin/trustctl" install coeval --root "${work_dir}/bad-url" \
    --coeval-version 1.2.3 --coeval-url https://example.test/coeval --no-start
assert_contains "${work_dir}/failure.out" "must be an origin"

bad_assets="${work_dir}/bad-assets"
mkdir -p "$bad_assets/coeval/9.9.9"
cp "${work_dir}/assets/coeval/1.2.3/compose.yaml" "$bad_assets/coeval/9.9.9/compose.yaml"
printf '%064d  compose.yaml\n' 0 > "$bad_assets/coeval/9.9.9/compose.yaml.sha256"
expect_failure "release bundle checksum mismatch fails before install state is written" \
  env TRUSTCTL_ASSET_ROOT="$bad_assets" "${repo_dir}/bin/trustctl" install coeval \
    --root "${work_dir}/bad-install" --coeval-version 9.9.9 --no-start
assert_contains "${work_dir}/failure.out" "checksum mismatch"
assert_not_exists "${work_dir}/bad-install"

TRUSTCTL_CLI_PATH="${repo_dir}/bin/trustctl" sh "${repo_dir}/install.sh" version >"${work_dir}/bootstrap.out"
assert_contains "${work_dir}/bootstrap.out" "trustctl 0.1.0"
pass "bootstrap can execute a locally inspected CLI"

printf '\nAll trustctl tests passed.\n'
