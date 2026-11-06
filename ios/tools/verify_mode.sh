#!/bin/sh
# Runs a mode on the simulator against OnAir's built-in test signal and reports what the decoder really produced.
# Usage: verify_mode.sh "<mode name>" <page> [seconds] [source] [--freq MHz --bw MHz]    Prints the last status line and writes a screenshot to ios/build/verify/.
set -u
MODE=$1; PAGE=${2:-mode}; SECS=${3:-25}; SRC=${4:-test}; shift 4 2>/dev/null || shift $#
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SIM=304F6404-088D-4278-9828-87B7B475812B
mkdir -p "$ROOT/build/verify"
NAME=$(printf '%s' "$MODE" | tr -c 'A-Za-z0-9' '_')
xcrun simctl boot "$SIM" 2>/dev/null
xcrun simctl install "$SIM" "$ROOT/build/dd/Build/Products/Debug-iphonesimulator/OnAir.app"
xcrun simctl launch --terminate-running-process "$SIM" net.rizos.onair --mode "$MODE" --source "$SRC" --page "$PAGE" "$@" --start >/dev/null
sleep "$SECS"
xcrun simctl io "$SIM" screenshot --type=png "$ROOT/build/verify/$NAME.png" >/dev/null 2>&1
xcrun simctl spawn "$SIM" log show --last 8s --predicate 'process == "OnAir" AND eventMessage CONTAINS "OnAirVerify"' --style compact 2>/dev/null | grep -a 'OnAirVerify running' | tail -1 | sed 's/.*OnAirVerify/OnAirVerify/'
xcrun simctl terminate "$SIM" net.rizos.onair 2>/dev/null
