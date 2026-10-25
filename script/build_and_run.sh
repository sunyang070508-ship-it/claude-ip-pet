#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-run}"
case "$mode" in run|--verify|--debug|--logs|--telemetry) ;; *) echo "usage: $0 [--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;; esac
pkill -x ClaudeIPPet >/dev/null 2>&1 || true
./build.sh
app="$PWD/dist/Claude IP 桌宠.app"
if [ "$mode" = --debug ]; then
  exec lldb -- "$app/Contents/MacOS/ClaudeIPPet"
fi
open -n "$app"
case "$mode" in
  --verify) for attempt in 1 2 3 4 5; do pgrep -x ClaudeIPPet >/dev/null && exit 0; sleep 1; done; exit 1 ;;
  --logs) exec tail -f "$HOME/Library/Logs/ClaudeIPPet.log" ;;
  --telemetry) exec /usr/bin/log stream --info --style compact --predicate 'process == "ClaudeIPPet"' ;;
esac
