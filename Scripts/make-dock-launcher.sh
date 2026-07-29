#!/bin/zsh
#
# Builds a tiny "Run Osier.app" whose only job is to open Terminal on Scripts/dock-run.sh —
# i.e. build + launch Osier, with the logs visible — so it can live in the Dock and be
# clicked instead of cd-ing into the repo.
#
#   ./Scripts/make-dock-launcher.sh              → ~/Applications/Run Osier.app
#   ./Scripts/make-dock-launcher.sh /some/dir    → /some/dir/Run Osier.app
#
# Re-run it after moving the repo (the bundle hardcodes the path to dock-run.sh).

set -e

REPO="${0:A:h:h}"
DEST_DIR="${1:-$HOME/Applications}"
APP="$DEST_DIR/Run Osier.app"
RUNNER="$REPO/Scripts/dock-run.sh"

if [[ ! -f "$RUNNER" ]]; then
    echo "Missing $RUNNER"
    exit 1
fi
chmod +x "$RUNNER"

mkdir -p "$DEST_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The bundle executable is a shell script — macOS is happy to exec one, shebang and all.
cat > "$APP/Contents/MacOS/launcher" <<EOF
#!/bin/zsh
open -a Terminal "$RUNNER"
EOF
chmod +x "$APP/Contents/MacOS/launcher"

# LSUIElement: the launcher exits the moment Terminal is up, so keep it out of the Dock's
# running-apps area — the pinned icon is the only thing that should show.
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Run Osier</string>
    <key>CFBundleDisplayName</key>
    <string>Run Osier</string>
    <key>CFBundleIdentifier</key>
    <string>me.sarakay.osier.devlauncher</string>
    <key>CFBundleExecutable</key>
    <string>launcher</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

# Borrow Osier's own icon when there's a build to borrow it from; a generic-icon launcher
# is hard to pick out of a Dock.
ICON="$REPO/Build/Build/Products/Debug/Osier.app/Contents/Resources/AppIcon.icns"
if [[ -f "$ICON" ]]; then
    cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "No built Osier.app yet — the launcher gets the generic app icon."
    echo "Run ./run.sh build, then re-run this script to pick up the real one."
fi

# Ad-hoc signature: nothing here needs entitlements, it just keeps macOS quiet.
codesign --force --sign - "$APP" 2>/dev/null || true

# LaunchServices caches bundle info aggressively; nudge it so the icon/name are current.
touch "$APP"

echo "Created: $APP"
echo "Drag it into your Dock to pin it."
