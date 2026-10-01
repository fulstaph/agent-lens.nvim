#!/bin/sh
# Run every headless Lua test in its own Neovim process.
# tests/live_preview.lua is a fixture driven by tests/live-preview.test.mjs.
set -u
cd "$(dirname "$0")/.." || exit 1
status=0
for test in tests/*.lua; do
  [ "$test" = tests/live_preview.lua ] && continue
  if output=$(nvim --headless -u NONE -l "$test" 2>&1); then
    echo "PASS $test"
  else
    echo "FAIL $test"
    echo "$output" | sed 's/^/    /'
    status=1
  fi
done
exit $status
