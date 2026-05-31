#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd "$(dirname "$0")" && pwd)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-hook-wrapper-test.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

fake_emacsclient="$tmp_dir/emacsclient"
cat >"$fake_emacsclient" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CODEX_HOOK_WRAPPER_TEST_ARGS"
while [ "$#" -gt 0 ]; do
  if [ "$1" = "response-file" ]; then
    printf 'ok' >"$2"
    exit 0
  fi
  shift
done
echo "missing response-file argument" >&2
exit 99
SCRIPT
chmod +x "$fake_emacsclient"

if output=$(printf '{}\n' | env -u CODEX_BUFFER_NAME \
  "$repo_dir/bin/codex-hook-wrapper" PreToolUse \
  --emacsclient "$fake_emacsclient" 2>&1); then
  if [ -n "$output" ]; then
    printf 'Expected no output without CODEX_BUFFER_NAME, got: %s\n' "$output" >&2
    exit 1
  fi
else
  status=$?
  printf 'Expected success without CODEX_BUFFER_NAME, got exit %s: %s\n' \
    "$status" "$output" >&2
  exit 1
fi

args_file="$tmp_dir/args"
output=$(printf '{}\n' | CODEX_BUFFER_NAME='*codex:/tmp/project*' \
  CODEX_HOOK_WRAPPER_TEST_ARGS="$args_file" \
  "$repo_dir/bin/codex-hook-wrapper" Stop \
  --emacsclient "$fake_emacsclient" 2>&1)

if [ "$output" != "ok" ]; then
  printf 'Expected response output from emacsclient, got: %s\n' "$output" >&2
  exit 1
fi

if ! grep -qx '\*codex:/tmp/project\*' "$args_file"; then
  printf 'Expected CODEX_BUFFER_NAME to be forwarded to emacsclient\n' >&2
  exit 1
fi
