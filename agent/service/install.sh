#!/usr/bin/env bash
# Installs the privileged half of the workbench on a jailbroken device.
#
# Run as root ON the device (or over SSH). It is idempotent: reinstalling
# replaces the daemon and reloads the launchd job in place.
#
#   sh agent/service/install.sh [prefix]
#
# `prefix` defaults to the jailbreak root the device reports:
#   - RootHide / rootless:  `jbroot` when the bootstrap ships one, else /var/jb
#   - rootful:              empty prefix
# TrollStore installs land in the app container and are not covered here.
set -euo pipefail

# RootHide randomizes the jailbreak root, so `/var/jb` is a convenience path at
# best and often does not exist at all. Ask the bootstrap first: a binary that
# hardcodes /var/jb works on Dopamine and silently fails on RootHide.
detect_prefix() {
  local given="${1:-}"
  if [ -n "$given" ]; then printf '%s' "$given"; return; fi
  if command -v jbroot >/dev/null 2>&1; then jbroot; return; fi
  if [ -d /var/jb ]; then printf '%s' /var/jb; return; fi
  printf '%s' ""
}

PREFIX="$(detect_prefix "${1:-}")"
if [ -z "$PREFIX" ] && [ -n "${JBROOT:-}" ]; then PREFIX="$JBROOT"; fi

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

# The binary is what runs, so the binary is what is checked: a Makefile that lost
# its _CODESIGN_FLAGS, or a signer that dropped a key, is invisible in the source
# plist. Both checks are fatal - installing an unentitled daemon produces a
# service that starts, answers nothing, and looks like a wiring bug.
if command -v python3 >/dev/null 2>&1; then
  python3 "$HERE/check-entitlements.py" "$HERE/agentd" || {
    echo "the daemon does not carry the entitlements it needs; refusing to install" >&2
    exit 1
  }
else
  echo "python3 not found: skipping the entitlement check on the built binary" >&2
fi

mkdir -p "$PREFIX/usr/libexec" "$PREFIX/Library/LaunchDaemons" "$STATE"
install -m 0755 "$HERE/agentd" "$DAEMON"
install -m 0644 "$HERE/layout/Library/LaunchDaemons/$LABEL.plist" "$PLIST"
chown root:wheel "$DAEMON" "$PLIST" 2>/dev/null || true

# The allowlist is only created once: an owner's edits must survive an upgrade.
if [ ! -f "$STATE/allowlist.json" ]; then
  install -m 0644 "$HERE/allowlist.json" "$STATE/allowlist.json"
fi
touch "$STATE/agentd.log" && chown mobile:mobile "$STATE/agentd.log"

# RootHide keeps a trust cache of what may run with these entitlements. Adding
# the daemon is what makes it start on a device where AMFI still checks; when
# jbctl is absent (Dopamine, rootful) this is a no-op.
if command -v jbctl >/dev/null 2>&1; then
  jbctl trustcache add "$DAEMON" || {
    echo "jbctl trustcache add failed; the daemon may be killed on launch" >&2
  }
else
  echo "jbctl not found: no trust cache entry added (fine on non-RootHide setups)" >&2
fi

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

echo "next: open the app, choose an app in the chat composer, and ask the agent to probe it"
