#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LOG="$HOME/Library/Logs/CleanAlephaMac98.log"
BIN=""
if [[ -x "$ROOT/.build/arm64-apple-macosx/release/CleanAlephaMac98" ]]; then
  BIN="$ROOT/.build/arm64-apple-macosx/release/CleanAlephaMac98"
elif [[ -x "$ROOT/.build/apple/Products/Release/CleanAlephaMac98" ]]; then
  BIN="$ROOT/.build/apple/Products/Release/CleanAlephaMac98"
elif [[ -x "$ROOT/.build/release/CleanAlephaMac98" ]]; then
  BIN="$ROOT/.build/release/CleanAlephaMac98"
elif [[ -x "$HOME/Applications/CleanAlephaMac98.app/Contents/MacOS/CleanAlephaMac98" ]]; then
  BIN="$HOME/Applications/CleanAlephaMac98.app/Contents/MacOS/CleanAlephaMac98"
else
  echo "no binary" >&2
  exit 1
fi

echo "=== qa-run $(date '+%Y-%m-%d %H:%M:%S') bin=$BIN ==="
killall -9 CleanAlephaMac98 2>/dev/null || true
mkdir -p "$(dirname "$LOG")"
touch "$LOG"

run_flag() {
  local flag="$1"
  local limit="$2"
  echo "-- $flag (timeout ${limit}s) --"
  local start
  start=$(python3 -c 'import time; print(time.time())')
  set +e
  perl -e "alarm $limit; exec @ARGV" "$BIN" "$flag"
  local st=$?
  set -e
  python3 -c "import time; print('elapsed', round(time.time()-float('$start'), 3), 'status', $st)"
  if [[ $st -ne 0 ]]; then
    echo "FAIL $flag status=$st" >&2
    exit $st
  fi
}

run_flag --qa-pulse 15
run_flag --qa-protect 40
run_flag --qa-startup 25
run_flag --qa-keep 8
run_flag --qa-smart 180

echo "-- last log --"
tail -80 "$LOG"
echo "=== qa-run done ==="
