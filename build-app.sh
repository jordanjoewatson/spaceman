#!/usr/bin/env bash
# Assemble Spaceman.app from the SwiftPM build product.
#
#   ./build-app.sh                     build + sign (all plugins)
#   ./build-app.sh --run               build + sign + launch
#   ./build-app.sh --bin-only          skip the .app bundle (dev builds)
#   ./build-app.sh --list              what's available
#   ./build-app.sh --plugins launcher  only these
#   ./build-app.sh --without launcher  everything except these
#   ./build-app.sh --core-only         no plugins at all
#   ./build-app.sh --zip               also write Spaceman.zip
#   ./build-app.sh --notarize          zip, notarize, staple (Developer ID)
#
# Plugins are selected at build time: Package.swift reads SPACEMAN_PLUGINS /
# SPACEMAN_WITHOUT / SPACEMAN_CORE_ONLY and only compiles the selected targets,
# so an excluded plugin's code isn't in the binary at all. To check what a
# binary carries: ./Spaceman.app/Contents/MacOS/Spaceman -plugins
#
# The app moves windows through the Accessibility API, which is the one
# permission it needs. Signing:
#
#   SPACEMAN_SIGN_ID     codesign identity. Unset: pick Developer ID Application
#                        if present, else Apple Development, else ad-hoc ("-").
#   SPACEMAN_NOTARY_PROFILE
#                        notarytool keychain profile, for --notarize.
#
# Git distribution needs a *Developer ID Application* certificate from a paid
# Apple Developer account, then notarization. An Apple Development identity is
# fine on your own Mac (stable Accessibility grant) but Gatekeeper will block
# it for anyone else who downloads the binary.
#
#   ./build-app.sh --zip                  signed .app + zip
#   ./build-app.sh --notarize             zip, submit, staple (needs profile)
set -euo pipefail

cd "$(dirname "$0")"

RUN=0
BIN_ONLY=0
PLUGINS=""
WITHOUT=""
CORE_ONLY=0
MAKE_ZIP=0
NOTARIZE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run)       RUN=1; shift ;;
        --bin-only)  BIN_ONLY=1; shift ;;
        --core-only) CORE_ONLY=1; shift ;;
        --zip)       MAKE_ZIP=1; shift ;;
        --notarize)  NOTARIZE=1; MAKE_ZIP=1; shift ;;
        --plugins)   PLUGINS="${2:?--plugins needs a comma-separated list}"; shift 2 ;;
        --without)   WITHOUT="${2:?--without needs a comma-separated list}"; shift 2 ;;
        --list)
            echo "available plugins:"
            for d in Plugins/*/; do echo "  $(basename "$d")"; done
            exit 0
            ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[[ -n "$PLUGINS" ]] && export SPACEMAN_PLUGINS="$PLUGINS"
[[ -n "$WITHOUT" ]] && export SPACEMAN_WITHOUT="$WITHOUT"
[[ $CORE_ONLY -eq 1 ]] && export SPACEMAN_CORE_ONLY=1

# Switching the plugin set changes the target graph, and SwiftPM can leave a
# deselected plugin's stale module in .build — which then fails the link with
# undefined symbols rather than vanishing quietly. Detect the switch and clean
# once, so a changed selection always builds from scratch.
SELECTION="${SPACEMAN_PLUGINS:-all}|${SPACEMAN_WITHOUT:-}|${SPACEMAN_CORE_ONLY:-0}"
STAMP=".build/.plugin-selection"
if [[ -f "$STAMP" ]] && [[ "$(cat "$STAMP")" != "$SELECTION" ]]; then
    echo "==> plugin selection changed; cleaning build products"
    swift package clean
fi

echo "==> building (release)"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/Spaceman"
[[ -x "$BIN" ]] || { echo "build produced no binary at $BIN" >&2; exit 1; }

mkdir -p .build
echo "$SELECTION" > "$STAMP"

if [[ $BIN_ONLY -eq 1 ]]; then
    echo "==> done (binary only): $BIN"
    echo "    plugins: $("$BIN" -plugins | paste -sd ', ' - || true)"
    exit 0
fi

# Prefer an explicit identity, then Developer ID (distributable), then
# Apple Development (this Mac only), then ad-hoc.
pick_sign_id() {
    if [[ -n "${SPACEMAN_SIGN_ID:-}" ]]; then
        printf '%s\n' "$SPACEMAN_SIGN_ID"
        return
    fi
    local identities
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    local id
    id="$(printf '%s\n' "$identities" | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
    if [[ -n "$id" ]]; then
        printf '%s\n' "$id"
        return
    fi
    id="$(printf '%s\n' "$identities" | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)"
    if [[ -n "$id" ]]; then
        printf '%s\n' "$id"
        return
    fi
    printf '%s\n' "-"
}

APP="Spaceman.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
SIGN_ID="$(pick_sign_id)"

echo "==> stopping any running instance"
# A running process keeps executing the binary image it started with, and `open`
# activates an existing instance instead of relaunching. Without this, a rebuild
# appears to have no effect at all.
pkill -f "Contents/MacOS/Spaceman" 2>/dev/null || true

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$BIN" "$MACOS/Spaceman"

echo "==> building AppIcon.icns"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size               Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png"    >/dev/null
    sips -z $((size*2)) $((size*2))   Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
cp Resources/AppIcon.png "$RES/AppIcon.png"
rm -rf "$(dirname "$ICONSET")"

# One source of truth: Sources/SpacemanCore/AppVersion.swift
MARKETING="$(sed -n 's/^    public static let marketing = "\([^"]*\)".*/\1/p' \
    Sources/SpacemanCore/AppVersion.swift)"
BUILD="$(sed -n 's/^    public static let build = \([0-9][0-9]*\).*/\1/p' \
    Sources/SpacemanCore/AppVersion.swift)"
[[ -n "$MARKETING" && -n "$BUILD" ]] || {
    echo "error: could not read marketing/build from AppVersion.swift" >&2
    exit 1
}

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Spaceman</string>
    <key>CFBundleDisplayName</key>       <string>Spaceman</string>
    <key>CFBundleIdentifier</key>        <string>com.spaceman.app</string>
    <key>CFBundleVersion</key>           <string>$BUILD</string>
    <key>CFBundleShortVersionString</key><string>$MARKETING</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleExecutable</key>        <string>Spaceman</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleIconName</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <!-- Menu-bar agent: no Dock icon, no app-switcher entry. -->
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <!-- Custom commands are invoked over a URL scheme, which works from
         Shortcuts, AppleScript, a launcher or `open spaceman://...`. -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>       <string>com.spaceman.app.url</string>
            <key>CFBundleTypeRole</key>      <string>Viewer</string>
            <key>CFBundleURLSchemes</key>    <array><string>spaceman</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> signing (identity: $SIGN_ID)"
SIGN_ARGS=(--force --sign "$SIGN_ID" --options runtime)
# Apple's timestamp server is required for Developer ID / notarization.
# Ad-hoc has no timestamp to attach.
if [[ "$SIGN_ID" != "-" ]]; then
    SIGN_ARGS+=(--timestamp)
else
    SIGN_ARGS+=(--timestamp=none)
fi
codesign "${SIGN_ARGS[@]}" "$APP"

# An ad-hoc signature has no stable identity, so TCC keys the Accessibility
# grant to the binary's cdhash — which changes on every code change. The System
# Settings entry stays visibly ticked while the authorisation inside it points at
# the previous build, so the app re-prompts and looks broken. Warn where it will
# actually be read, at the point it matters.
if [[ "$SIGN_ID" == "-" ]]; then
    echo
    echo "    !! ad-hoc signed: macOS will re-ask for Accessibility after every"
    echo "       code change, even though the checkbox still looks ticked."
    echo "       This Mac: export SPACEMAN_SIGN_ID to your Apple Development identity."
    echo "       Git / other people: you need Developer ID Application + notarization."
    echo "       Meanwhile: tccutil reset Accessibility com.spaceman.app"
elif [[ "$SIGN_ID" == Apple\ Development:* ]]; then
    echo
    echo "    signed with Apple Development — fine on this Mac (stable TCC)."
    echo "    Gatekeeper will block downloads. For git distribution create a"
    echo "    Developer ID Application certificate at developer.apple.com,"
    echo "    then:  export SPACEMAN_SIGN_ID=\"Developer ID Application: …\""
    echo "           ./build-app.sh --notarize"
fi

echo "==> verifying"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

ZIP="${APP%.app}.zip"
if [[ $MAKE_ZIP -eq 1 ]]; then
    echo "==> zipping $ZIP"
    rm -f "$ZIP"
    # ditto preserves the signature and resource forks; zip(1) does not.
    ditto -c -k --keepParent "$APP" "$ZIP"
fi

if [[ $NOTARIZE -eq 1 ]]; then
    PROFILE="${SPACEMAN_NOTARY_PROFILE:-}"
    if [[ -z "$PROFILE" ]]; then
        echo "error: --notarize needs SPACEMAN_NOTARY_PROFILE (a notarytool keychain profile)." >&2
        echo "       xcrun notarytool store-credentials spaceman-notary --apple-id YOU@… --team-id TEAM --password app-specific-password" >&2
        exit 1
    fi
    if [[ "$SIGN_ID" != Developer\ ID\ Application:* ]]; then
        echo "error: notarization requires a Developer ID Application signature, not '$SIGN_ID'." >&2
        exit 1
    fi
    echo "==> notarizing ($PROFILE)"
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    echo "==> stapling"
    xcrun stapler staple "$APP"
    # Re-zip after staple so the ticket is inside the archive people download.
    echo "==> re-zipping stapled $ZIP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
fi

if [[ $RUN -eq 1 ]]; then
    echo
    echo "==> launching"
    open "$APP"
    sleep 1
    if pgrep -f "Contents/MacOS/Spaceman" >/dev/null; then
        echo "    running"
    else
        echo "    FAILED to stay running — try: $PWD/$APP/Contents/MacOS/Spaceman" >&2
    fi
fi

cat <<EOF

==> done: $APP

Run it:            ./build-app.sh --run   (rebuild + restart, recommended)
                   open $APP              (only works if not already running)
Tail its logs:     log stream --predicate 'process == "Spaceman"' --level debug
Or run directly:   SPACEMAN_DEBUG=1 $APP/Contents/MacOS/Spaceman
Plugins inside:    $APP/Contents/MacOS/Spaceman -plugins

First run asks for Accessibility access (System Settings -> Privacy & Security
-> Accessibility). Tiling starts the moment it is granted; no relaunch needed.
EOF
if [[ $MAKE_ZIP -eq 1 ]]; then
    echo "Archive:            $PWD/$ZIP"
fi
