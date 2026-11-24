#!/usr/bin/env bash
# Installs the privileged half of the workbench on a jailbroken device.
#
# Run as root ON the device (or over SSH). It is idempotent: reinstalling
# replaces the daemon and reloads the launchd job in place.
#
#   sh agent/service/install.sh [prefix]
#
# `prefix` defaults to /var/jb on rootless jailbreaks (Dopamine, palera1n
# rootless) and to nothing on rootful ones (checkra1n, unc0ver). TrollStore
# installs land in the app container and are not covered here.
set -euo pipefail

PREFIX="${1:-}"
if [ -z "$PREFIX" ] && [ -d /var/jb ]; then PREFIX=/var/jb; fi

LABEL=io.github.ccch1mneyyy.dshgo.agentd
DAEMON="$PREFIX/usr/libexec/dsh-go-agentd"
PLIST="$PREFIX/Library/LaunchDaemons/$LABEL.plist"
STATE=/var/mobile/Library/DshGoAgent

HERE="$(cd "$(dirname "$0")" && pwd -P)"

if [ "$(id -u)" != "0" ]; then
  echo "run as root: sudo sh $0" >&2
  exit 1
fi

if [ ! -f "$HERE/agentd" ]; then
  echo "build first: cd agent/service && make; the binary lands in .theos/obj" >&2
  exit 1
fi

mkdir -p "$PREFIX/usr/libexec" "$PREFIX/Library/LaunchDaemons" "$STATE"
install -m 0755 "$HERE/agentd" "$DAEMON"
install -m 0644 "$HERE/layout/Library/LaunchDaemons/$LABEL.plist" "$PLIST"

# The allowlist is only created once: an owner's edits must survive an upgrade.
if [ ! -f "$STATE/allowlist.json" ]; then
  install -m 0644 "$HERE/allowlist.json" "$STATE/allowlist.json"
fi
touch "$STATE/agentd.log" && chown mobile:mobile "$STATE/agentd.log"

launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
sleep 1
launchctl print "system/$LABEL" >/dev/null 2>&1 || {
  echo "the job did not stay up; see $STATE/agentd.log" >&2
  exit 1
}

echo "installed $DAEMON"
echo "service: $LABEL (Mach: $LABEL)"
echo "state:   $STATE"
