#!/usr/bin/env bash
set -euo pipefail

APP="${1:-/Applications/Sleepless.app}"
if [ ! -d "$APP" ]; then
  echo "error: build or install Sleepless.app first: $APP" >&2
  exit 1
fi
APP="$(cd "$APP" && pwd -P)"
EXECUTABLE="$APP/Contents/MacOS/Sleepless"
CLI_DIR="${SLEEPLESS_CLI_DIR:-$HOME/.local/bin}"
CLI="$CLI_DIR/sleepless"

if [ ! -x "$EXECUTABLE" ]; then
  echo "error: build or install Sleepless.app first: $APP" >&2
  exit 1
fi
if [ -e "$CLI" ] || [ -L "$CLI" ]; then
  if [ ! -L "$CLI" ] || [ "$(readlink "$CLI")" != "$EXECUTABLE" ]; then
    echo "error: $CLI already exists; refusing to replace it" >&2
    exit 1
  fi
else
  mkdir -p "$CLI_DIR"
  ln -s "$EXECUTABLE" "$CLI"
fi
echo "Installed $CLI"
case ":$PATH:" in
  *":$CLI_DIR:"*) ;;
  *) echo 'Add to your shell config: export PATH="$HOME/.local/bin:$PATH"' ;;
esac
echo "Usage: sleepless on | off | toggle | status"
