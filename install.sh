#!/bin/sh

set -eu

TRUSTCTL_RAW_URL="${TRUSTCTL_RAW_URL:-https://raw.githubusercontent.com/luka-zivkovic/trustctl/main/bin/trustctl}"

fail() {
  printf 'trustctl installer: %s\n' "$*" >&2
  exit 1
}

command -v bash >/dev/null 2>&1 || fail "bash is required"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT INT TERM
cli="${tmp_dir}/trustctl"
checksum="${tmp_dir}/trustctl.sha256"

if [ -n "${TRUSTCTL_CLI_PATH:-}" ]; then
  [ -f "$TRUSTCTL_CLI_PATH" ] || fail "TRUSTCTL_CLI_PATH does not exist"
  cp "$TRUSTCTL_CLI_PATH" "$cli"
else
  command -v curl >/dev/null 2>&1 || fail "curl is required"
  curl -fsSL --retry 2 --connect-timeout 10 "$TRUSTCTL_RAW_URL" -o "$cli"
  curl -fsSL --retry 2 --connect-timeout 10 "${TRUSTCTL_RAW_URL}.sha256" -o "$checksum"
  expected="$(awk 'NF { print $1; exit }' "$checksum")"
  [ "${#expected}" -eq 64 ] || fail "invalid trustctl checksum"
  case "$expected" in
    *[!0-9a-fA-F]*|'') fail "invalid trustctl checksum" ;;
  esac
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$cli" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$cli" | awk '{print $1}')"
  else
    fail "sha256sum or shasum is required"
  fi
  [ "$actual" = "$expected" ] || fail "downloaded trustctl checksum did not match"
fi

chmod 755 "$cli"
if [ "$#" -eq 0 ]; then
  set -- install stack
fi
exec bash "$cli" "$@"
