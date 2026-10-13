#!/bin/bash
# Runs ScreenBlur, rebuilding first if the source has changed.
#   ./run.sh        build if needed, then (re)launch
#   ./run.sh stop   quit the app
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ScreenBlur.app
BIN="$APP/Contents/MacOS/ScreenBlur"

if [ "${1:-}" = "stop" ]; then
    pkill -x ScreenBlur && echo "Stopped." || echo "Not running."
    exit 0
fi

if [ ! -x "$BIN" ] || [ -n "$(find Sources Package.swift build.sh -newer "$BIN" -print -quit)" ]; then
    ./build.sh
fi

pkill -x ScreenBlur 2>/dev/null && sleep 0.5 || true
open "$APP"
echo "ScreenBlur is running. Control-Shift-/ shows the shortcuts; ./run.sh stop quits."
