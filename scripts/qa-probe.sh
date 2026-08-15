#!/bin/zsh
set -euo pipefail
LOG="$HOME/Library/Logs/CleanAlephaMac98.log"
echo "=== QA probe $(date '+%Y-%m-%d %H:%M:%S') ==="

echo "-- log exists --"
if [[ -f "$LOG" ]]; then
  echo "log $LOG ($(wc -c < "$LOG") bytes)"
else
  echo "log missing (ok until first scan of 1.1.5+)"
fi

echo "-- browsers --"
ps -axo pid=,rss=,command= | awk '
  BEGIN{IGNORECASE=1}
  /Safari\.app\/Contents\/MacOS\/Safari/ && !/WebKit/ {print "Safari RSS_KB="$2" pid="$1}
  /Google Chrome\.app\/Contents\/MacOS\/Google Chrome/ && !/Helper/ {print "Chrome RSS_KB="$2" pid="$1" cmd="$0}
'

echo "-- osascript Safari 2s --"
START=$(python3 -c 'import time; print(time.time())')
osascript -e 'with timeout of 2 seconds
if application "Safari" is running then
  tell application "Safari"
    return (count of tabs of window 1) as text
  end tell
end if
return "not-running"
end timeout' 2>"/tmp/qa-safari.err" || true
python3 -c "import time; print('safari_s', round(time.time()-float('$START'), 3))"
if [[ -s /tmp/qa-safari.err ]]; then echo "safari_err $(tr '\n' ' ' < /tmp/qa-safari.err)"; fi

echo "-- osascript Chrome 2s --"
START=$(python3 -c 'import time; print(time.time())')
osascript -e 'with timeout of 2 seconds
if application "Google Chrome" is running then
  tell application "Google Chrome"
    return (count of windows) as text
  end tell
end if
return "not-running"
end timeout' 2>"/tmp/qa-chrome.err" || true
python3 -c "import time; print('chrome_s', round(time.time()-float('$START'), 3))"
if [[ -s /tmp/qa-chrome.err ]]; then echo "chrome_err $(tr '\n' ' ' < /tmp/qa-chrome.err)"; fi

echo "-- defaults --"
defaults read com.alepha98.CleanAlephaMac98 cam98.module 2>/dev/null || echo "module ?"
defaults read com.alepha98.CleanAlephaMac98 cam98.language 2>/dev/null || echo "language ?"

echo "-- binary --"
APP="$HOME/Applications/CleanAlephaMac98.app/Contents/MacOS/CleanAlephaMac98"
if [[ -x "$APP" ]]; then
  file "$APP"
  defaults read "$HOME/Applications/CleanAlephaMac98.app/Contents/Info.plist" CFBundleShortVersionString
else
  echo "app missing"
fi

echo "-- last log lines --"
tail -30 "$LOG" 2>/dev/null || true
echo "=== probe done ==="
