#!/bin/bash
# Builds DeskCat.app next to this script.
#   ./build.sh            build only
#   ./build.sh --install  build, then copy into Applications (so Spotlight/Launchpad find it) and open it
set -euo pipefail
cd "$(dirname "$0")"

APP=DeskCat.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library DeskCat.swift -o "$APP/Contents/MacOS/DeskCat"

# App icon, drawn from her own sprite.
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$APP/Contents/MacOS/DeskCat" --iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DeskCat</string>
    <key>CFBundleIdentifier</key><string>local.deskcat</string>
    <key>CFBundleName</key><string>DeskCat</string>
    <key>CFBundleDisplayName</key><string>DeskCat</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST=/Applications
    [[ -w "$DEST" ]] || DEST="$HOME/Applications"
    mkdir -p "$DEST"
    # Quit any running copy so the new one takes over.
    pkill -f "DeskCat.app/Contents/MacOS/DeskCat" 2>/dev/null || true
    sleep 0.5
    rm -rf "$DEST/$APP"
    cp -R "$APP" "$DEST/"
    echo "Installed $DEST/$APP"
    open "$DEST/$APP"
fi
