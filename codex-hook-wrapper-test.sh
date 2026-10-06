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
  "$repo_dir/bin/codex-hook-wrapper" PermissionRequest \
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
  CODEX_HOOK_ANSWER_TYPES='PermissionRequest Stop' \
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

# Answered hooks bound their wait for Emacs and send their send time.
if ! grep -qx -- '--timeout=5' "$tmp_dir/args" \
  || ! grep -qx 'sent-at' "$tmp_dir/args"; then
  printf 'Expected answered hook to pass --timeout=5 and sent-at\n' >&2
  exit 1
fi

# A stalled server must not hold up hooks Codex need not wait for.
stalled_emacsclient="$tmp_dir/stalled-emacsclient"
cat >"$stalled_emacsclient" <<'SCRIPT'
#!/usr/bin/env bash
sleep 2
printf '%s\n' "$@" >"$CODEX_HOOK_WRAPPER_TEST_ARGS"
SCRIPT
chmod +x "$stalled_emacsclient"

for hook in Stop PreToolUse PostToolUse UserPromptSubmit SessionStart \
  PreCompact PostCompact; do
  args_file="$tmp_dir/args-background-$hook"
  start=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  output=$(printf '{}\n' | CODEX_BUFFER_NAME='*codex:/tmp/project*' \
    CODEX_HOOK_WRAPPER_TEST_ARGS="$args_file" \
    TMPDIR="$tmp_dir" \
    "$repo_dir/bin/codex-hook-wrapper" "$hook" \
    --emacsclient "$stalled_emacsclient" 2>&1)
  elapsed=$(perl -MTime::HiRes=time -e "printf '%.3f', time - $start")
  if [ -n "$output" ]; then
    printf 'Expected no output from background %s hook, got: %s\n' \
      "$hook" "$output" >&2
    exit 1
  fi
  if perl -e "exit($elapsed < 1 ? 1 : 0)"; then
    printf 'Expected background %s hook to return at once, took %ss\n' \
      "$hook" "$elapsed" >&2
    exit 1
  fi
done

for _ in $(seq 1 50); do
  [ -f "$tmp_dir/args-background-PostCompact" ] && break
  sleep 0.1
done
for hook in Stop PreToolUse PostToolUse UserPromptSubmit SessionStart \
  PreCompact PostCompact; do
  args_file="$tmp_dir/args-background-$hook"
  if ! grep -qx -- '--timeout=10' "$args_file" \
    || ! grep -qx "$hook" "$args_file" \
    || ! grep -qx 'sent-at' "$args_file"; then
    printf 'Expected background %s hook to reach emacsclient with --timeout=10 and sent-at\n' \
      "$hook" >&2
    exit 1
  fi
done
sleep 0.5
if ls "$tmp_dir" | grep -q '^codex-hook-'; then
  printf 'Expected background hooks to remove their temporary files\n' >&2
  exit 1
fi

# An answer hook that Emacs does not answer in time must give Codex no
# decision (exit 1), so Codex falls back to its own approval prompt, rather
# than the denial that exit 2 means.
timing_out_emacsclient="$tmp_dir/timing-out-emacsclient"
cat >"$timing_out_emacsclient" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$CODEX_HOOK_WRAPPER_TEST_ARGS"
printf '\nServer not responding; timed out after 2 seconds' >&2
exit 1
SCRIPT
chmod +x "$timing_out_emacsclient"

args_file="$tmp_dir/args-timeout"
if output=$(printf '{}\n' | CODEX_BUFFER_NAME='*codex:/tmp/project*' \
  CODEX_HOOK_WRAPPER_TEST_ARGS="$args_file" \
  CODEX_HOOK_ANSWER_TIMEOUT=2 \
  "$repo_dir/bin/codex-hook-wrapper" PermissionRequest \
  --emacsclient "$timing_out_emacsclient" 2>/dev/null); then
  printf 'Expected timed-out PermissionRequest to fail without a decision\n' >&2
  exit 1
else
  status=$?
  if [ "$status" -ne 1 ] || [ -n "$output" ]; then
    printf 'Expected timed-out PermissionRequest exit 1 and no output, got %s: %s\n' \
      "$status" "$output" >&2
    exit 1
  fi
fi
if [ "$(grep -cx -- '--timeout=2' "$args_file")" -ne 1 ]; then
  printf 'Expected exactly one emacsclient attempt with --timeout=2\n' >&2
  exit 1
fi
