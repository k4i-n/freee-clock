#!/bin/bash
# Builds `freee` (freee.swift), runs its selftest, and installs it as the always-on menu bar app
# (launchd job local.freee-clock.bar, which also schedules the weekday clock in/out), plus the
# `freee` command in ~/.local/bin. Removes the jobs of the older Python version.
# Usage: install.sh [uninstall]. Safe to re-run any time: a countdown cut off by the restart is re-planned.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
AGENTS=~/Library/LaunchAgents
LOG=~/Library/Logs/freee-clock.log
DOMAIN=gui/$(id -u)
LABEL=local.freee-clock.bar
OLD=(local.freee-clock.in local.freee-clock.out)  # Python version: separate launchd runs per clock in/out

for label in "${OLD[@]}"; do  # killing one mid-run would lose that clock in/out
  if launchctl print "$DOMAIN/$label" 2>/dev/null | grep -q "state = running"; then
    echo "$label (old version) is in progress; rerun after it finishes" >&2
    exit 1
  fi
done

if [ "${1:-}" = uninstall ]; then
  for label in "$LABEL" "${OLD[@]}"; do
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    rm -f "$AGENTS/$label.plist"
  done
  rm -f ~/.local/bin/freee
  echo "removed the menu bar app and ~/.local/bin/freee"
  exit 0
fi

# build aside and gate on the selftest before touching the running app; rename rather than
# overwrite, since overwriting a running binary in place gets it killed by code signing
if [ "$HERE/freee.swift" -nt "$HERE/freee" ]; then
  swiftc -O "$HERE/freee.swift" -o "$HERE/freee.new"
  "$HERE/freee.new" selftest >/dev/null || { echo "selftest failed, not installed: $HERE/freee.new selftest" >&2; exit 1; }
  mv "$HERE/freee.new" "$HERE/freee"
  echo "built freee, selftest passed"
fi

for label in "$LABEL" "${OLD[@]}"; do
  launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
done
for label in "${OLD[@]}"; do rm -f "$AGENTS/$label.plist"; done
pkill -x freee-bar || true  # menu helper of the Python version, outside launchd

cat > "$AGENTS/$LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$HERE/freee</string><string>bar</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
plutil -lint -s "$AGENTS/$LABEL.plist"
for try in 1 2 3 4 5; do  # bootout finishes asynchronously; bootstrap can fail for a moment after it
  launchctl bootstrap "$DOMAIN" "$AGENTS/$LABEL.plist" 2>/dev/null && break
  [ "$try" = 5 ] && { echo "could not load $LABEL" >&2; exit 1; }
  sleep 1
done

ln -sf "$HERE/freee" ~/.local/bin/freee
echo "loaded $LABEL (menu bar app; sign-in and clock times under its Settings)"
echo "\`freee\` linked in ~/.local/bin; log: $LOG"
