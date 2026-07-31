#!/bin/bash
set -e

# Release script for Osier (ssskay/osier).
# Builds, signs, notarizes, tags, and publishes a GitHub release via the gh CLI.
#
# Usage: ./make_release.sh <version> "<code-sign-identity>" [arch]
#   arch: arm64 (default) or x86_64
#
# Prereqs (one-time, documented in docs/RELEASING.md):
#   - gh auth login (as ssskay)
#   - notarytool credentials stored under keychain profile "AC_NOTARY"
#   - Osier's own Sparkle Ed25519 keypair (SUPublicEDKey in Info.plist must be
#     YOURS, not upstream's, before shipping an appcast feed)

REPO="ssskay/osier"
NEW_VERSION="${1}"
CODE_SIGN_IDENTITY="${2}"
ARCH="${3:-arm64}"

if [[ -z "$NEW_VERSION" || -z "$CODE_SIGN_IDENTITY" ]]; then
    echo "Usage: $0 <version> \"<code-sign-identity>\" [arm64|x86_64]"
    echo "Example: $0 1.0.0 \"Developer ID Application: Sara Kay (AH785WYH3F)\""
    exit 1
fi

if ! command -v gh >/dev/null; then
    echo "❌ gh CLI not found (brew install gh; gh auth login)"; exit 1
fi

# Refuse to ship while upstream's Sparkle key is still in Info.plist.
if grep -q "ECQpCBVVumUKoBjgcDPSlmllYiWlSAUFGh5WycBhCA0=" OpenSuperWhisper/OpenSuperWhisper-Info.plist; then
    echo "⚠️  Info.plist still carries UPSTREAM's SUPublicEDKey."
    echo "   Fine while no SUFeedURL is set, but generate Osier's own keypair before"
    echo "   enabling auto-updates (see docs/RELEASING.md)."
fi

echo "🚀 Osier v${NEW_VERSION} (${ARCH}) → github.com/${REPO}"

# Bump versions in the Xcode project
sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = ${NEW_VERSION}/g" OpenSuperWhisper.xcodeproj/project.pbxproj
CURRENT_PROJECT_VERSION=$(grep -o 'CURRENT_PROJECT_VERSION = [0-9]*' OpenSuperWhisper.xcodeproj/project.pbxproj | head -1 | grep -o '[0-9]*')
NEW_PROJECT_VERSION=$((CURRENT_PROJECT_VERSION + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*/CURRENT_PROJECT_VERSION = ${NEW_PROJECT_VERSION}/g" OpenSuperWhisper.xcodeproj/project.pbxproj
echo "📝 MARKETING_VERSION=${NEW_VERSION}, CURRENT_PROJECT_VERSION=${NEW_PROJECT_VERSION}"

# Clean and build (notarize_app.sh builds, signs, notarizes, staples → Osier-${ARCH}.dmg)
rm -rf build
rm -f "Osier-${ARCH}.dmg" "Osier-${ARCH}.dmg.sha256" Osier.app.dSYM.zip
chmod +x ./notarize_app.sh
./notarize_app.sh "${CODE_SIGN_IDENTITY}" "${ARCH}"

DMG_PATH="./Osier-${ARCH}.dmg"
[[ -f "$DMG_PATH" ]] || { echo "❌ DMG not found at $DMG_PATH"; exit 1; }

# dSYM
DSYM_PATH="./build/Build/Products/Release/Osier.app.dSYM"
DSYM_ZIP=""
if [[ -d "$DSYM_PATH" ]]; then
    ditto -c -k --keepParent "$DSYM_PATH" Osier.app.dSYM.zip
    DSYM_ZIP="Osier.app.dSYM.zip"
    echo "📦 dSYM zipped"
fi

shasum -a 256 "$DMG_PATH" | tee "${DMG_PATH}.sha256"

# Commit bump, tag, push
git add OpenSuperWhisper.xcodeproj/project.pbxproj
git commit -m "Bump version to ${NEW_VERSION}" || echo "No version changes to commit"
git tag -a "v${NEW_VERSION}" -m "Release v${NEW_VERSION}"
git push origin HEAD "v${NEW_VERSION}"

# GitHub release
gh release create "v${NEW_VERSION}" --repo "$REPO" \
    --title "Osier v${NEW_VERSION}" \
    --generate-notes \
    "$DMG_PATH" "${DMG_PATH}.sha256" ${DSYM_ZIP:+"$DSYM_ZIP"}

echo ""
echo "🎉 https://github.com/${REPO}/releases/tag/v${NEW_VERSION}"
echo ""
echo "📋 Next (see docs/RELEASING.md):"
echo "   - If auto-update is live: sign the DMG with sparkle's sign_update and append"
echo "     an entry to appcast.xml (arm64) / appcast-x86_64.xml (intel), commit + push."
