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

args_file="$tmp_dir/args-socket"
output=$(printf '{}\n' | CODEX_BUFFER_NAME='*codex:/tmp/project*' \
  CODEX_HOOK_WRAPPER_TEST_ARGS="$args_file" \
  CODEX_EMACSCLIENT_SOCKET_DIR='/real/tmp/emacs501' \
  "$repo_dir/bin/codex-hook-wrapper" Stop \
  --emacsclient "$fake_emacsclient" \
  --socket-name server 2>&1)

if [ "$output" != "ok" ]; then
  printf 'Expected response output from emacsclient, got: %s\n' "$output" >&2
  exit 1
fi

if ! grep -qx -- '--socket-name' "$args_file" \
  || ! grep -qx '/real/tmp/emacs501/server' "$args_file"; then
  printf 'Expected relative socket name to resolve against socket dir\n' >&2
  exit 1
fi

refusing_emacsclient="$tmp_dir/refusing-emacsclient"
cat >"$refusing_emacsclient" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "emacsclient: can't connect to /tmp/emacs501/server: Connection refused" >&2
exit 1
SCRIPT
chmod +x "$refusing_emacsclient"

if output=$(printf '{}\n' | CODEX_BUFFER_NAME='*codex:/tmp/project*' \
  CODEX_HOOK_DISPATCH_ATTEMPTS=1 \
  "$repo_dir/bin/codex-hook-wrapper" PreToolUse \
  --emacsclient "$refusing_emacsclient" 2>&1); then
  if [ -n "$output" ]; then
    printf 'Expected PreToolUse dispatch failure to fail open quietly, got: %s\n' "$output" >&2
    exit 1
  fi
else
  status=$?
  printf 'Expected PreToolUse dispatch failure to fail open, got exit %s: %s\n' \
    "$status" "$output" >&2
  exit 1
fi

if output=$(printf '{}\n' | CODEX_BUFFER_NAME='*codex:/tmp/project*' \
  CODEX_HOOK_DISPATCH_ATTEMPTS=1 \
  "$repo_dir/bin/codex-hook-wrapper" PermissionRequest \
  --emacsclient "$refusing_emacsclient" 2>&1); then
  printf 'Expected PermissionRequest dispatch failure to fail closed\n' >&2
  exit 1
else
  status=$?
  if [ "$status" -ne 2 ]; then
    printf 'Expected PermissionRequest dispatch failure exit 2, got %s: %s\n' \
      "$status" "$output" >&2
    exit 1
  fi
fi
