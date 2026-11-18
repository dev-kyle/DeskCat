#!/bin/bash
# Builds DeskCat.app next to this script.
#   ./build.sh                  build only
#   ./build.sh --install        build, then copy into Applications (so Spotlight/Launchpad find it) and open it
#   ./build.sh --hooks          add Claude Code hooks so she holds up "DONE!" / "APPROVE" signs
#   ./build.sh --remove-hooks   take those hooks back out
# --install and --hooks can be used together.
set -euo pipefail
cd "$(dirname "$0")"

APP=DeskCat.app
INSTALL=0
HOOKS=""
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --hooks) HOOKS=add ;;
        --remove-hooks) HOOKS=remove ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

# Adds (or removes) DeskCat's entries in Claude Code's settings.json, leaving everything else as it was.
claude_hooks() {
    local mode=$1 bin=$2
    local settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
    /usr/bin/python3 - "$mode" "$bin" "$settings" <<'PY'
import json, os, shutil, sys, time
mode, binary, path = sys.argv[1:4]
signs = {"Stop": "DONE!", "PermissionRequest": "APPROVE"}

def ours(entry):
    return any("DeskCat" in h.get("command", "") and "--sign" in h.get("command", "")
               for h in entry.get("hooks", []))

settings = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            text = f.read()
        settings = json.loads(text) if text.strip() else {}
    except ValueError as e:
        sys.exit(f"Couldn't read {path} ({e}). Fix it first; nothing was changed.")
    if not isinstance(settings, dict):
        sys.exit(f"{path} isn't a JSON object; nothing was changed.")

hooks = settings.setdefault("hooks", {})
changed = False
for event, text in signs.items():
    entries = hooks.get(event, [])
    kept = [e for e in entries if not ours(e)]
    if mode == "add":
        cmd = f'"{binary}" --sign "{text}" >/dev/null 2>&1 || true'
        entry = {"hooks": [{"type": "command", "command": cmd, "timeout": 5, "async": True}]}
        if event == "PermissionRequest":
            entry = {"matcher": "*", **entry}
        if [e for e in entries if ours(e)] == [entry]:
            continue
        kept.append(entry)
    if kept != entries:
        changed = True
        if kept:
            hooks[event] = kept
        else:
            hooks.pop(event, None)
if not hooks:
    settings.pop("hooks", None)

if not changed:
    print("Claude hooks already " + ("set up." if mode == "add" else "removed."))
    sys.exit(0)
os.makedirs(os.path.dirname(path), exist_ok=True)
if os.path.exists(path):
    backup = f"{path}.bak-deskcat-{time.strftime('%Y%m%d-%H%M%S')}"
    n = 1
    while os.path.exists(backup):  # never overwrite an earlier backup
        n += 1
        backup = f"{path}.bak-deskcat-{time.strftime('%Y%m%d-%H%M%S')}-{n}"
    shutil.copy2(path, backup)
    print(f"Backed up your settings to {backup}")
with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print(("Added" if mode == "add" else "Removed") + f" DeskCat's Claude hooks in {path}")
if mode == "add":
    print("New Claude Code sessions will pick them up.")
PY
}

# Where an installed copy lives (if any).
installed_app() {
    for d in /Applications "$HOME/Applications"; do
        [[ -d "$d/$APP" ]] && { echo "$d/$APP"; return; }
    done
}

# Hooks only: no need to rebuild.
if [[ -n "$HOOKS" && $INSTALL == 0 ]]; then
    if [[ $HOOKS == remove ]]; then
        claude_hooks remove ""
        exit 0
    fi
    TARGET="$(installed_app)"
    if [[ -z "$TARGET" ]]; then
        echo "DeskCat isn't installed yet. Run: ./build.sh --install --hooks" >&2
        exit 1
    fi
    claude_hooks add "$TARGET/Contents/MacOS/DeskCat"
    exit 0
fi

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

if [[ $INSTALL == 1 ]]; then
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
    case "$HOOKS" in
        add) claude_hooks add "$DEST/$APP/Contents/MacOS/DeskCat" ;;
        remove) claude_hooks remove "" ;;
    esac
fi
