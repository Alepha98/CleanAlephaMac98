#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/CleanAlephaMac98.app"
zsh "$ROOT/packaging/make-app.sh" "$APP"
echo "installed $APP"
