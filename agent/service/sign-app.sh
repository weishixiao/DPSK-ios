#!/usr/bin/env bash
# Re-signs a built Runner.app for a jailbroken device (TrollStore / RootHide).
#
# The Xcode build signs the app the way Apple expects; that signature cannot
# carry `platform-application`, and without it the app is a sandboxed client that
# RootHide is free to hide and that cannot reach a global Mach service. This
# script signs the *same* build with the jailbreak set in
# Runner.jailbreak.entitlements, so the artifact keeps the app's normal signature
# story and the jailbreak one apart.
#
#   sh agent/service/sign-app.sh app/build/ios/iphoneos/Runner.app [out-dir]
#
# Needs `ldid` (jailbreak device or `brew install ldid`). Produces
# <out-dir>/Runner.app and, when asked, a .tipa TrollStore accepts.
set -euo pipefail

APP="${1:?usage: sign-app.sh <Runner.app> [out-dir]}"
OUT="${2:-$(dirname "$APP")/jailbreak}"
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ENTITLEMENTS="$HERE/Runner.jailbreak.entitlements"

command -v ldid >/dev/null 2>&1 || { echo "ldid not found: install it or run this on the device" >&2; exit 1; }
[ -d "$APP" ] || { echo "no app bundle at $APP" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp -R "$APP" "$WORK/Runner.app"
TARGET="$WORK/Runner.app"

# Sign inside out: a framework or extension whose signature the main binary
# depends on must already be final, otherwise the bundle fails verification.
find "$TARGET" -type f \( -perm -111 -o -name '*.dylib' \) -print0 |
while IFS= read -r -d '' binary; do
  case "$(file -b "$binary" 2>/dev/null || true)" in
    *Mach-O*) ldid -S"$ENTITLEMENTS" "$binary" ;;
  esac
done

MAIN="$TARGET/Runner"
[ -f "$MAIN" ] || MAIN="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$TARGET/Info.plist" 2>/dev/null || echo Runner)"
[ -f "$TARGET/$MAIN" ] || { echo "cannot find the app's main binary" >&2; exit 1; }
ldid -S"$ENTITLEMENTS" "$TARGET/$MAIN"

# Prove it: this is the same check install.sh applies to the daemon, pointed at
# the app, so a mis-signed artifact fails here instead of on the device.
if command -v python3 >/dev/null 2>&1; then
  python3 "$HERE/check-entitlements.py" "$TARGET/$MAIN" \
    --require platform-application \
    --require com.apple.private.security.no-sandbox || {
      echo "the signed app does not carry the jailbreak entitlements" >&2
      exit 1
    }
fi

mkdir -p "$OUT"
rm -rf "$OUT/Runner.app"
cp -R "$TARGET" "$OUT/Runner.app"
echo "signed app: $OUT/Runner.app"

# A .tipa is a zip with the bundle under Payload/ - that is all TrollStore reads.
if [ "${MAKE_TIPA:-1}" = "1" ]; then
  rm -rf "$WORK/Payload" "$OUT/Runner.tipa"
  mkdir -p "$WORK/Payload"
  cp -R "$TARGET" "$WORK/Payload/Runner.app"
  ( cd "$WORK" && zip -qry "$OUT/Runner.tipa" Payload )
  echo "tipa:        $OUT/Runner.tipa"
fi
