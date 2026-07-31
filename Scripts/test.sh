#!/bin/zsh
#
# Runs the unit tests — and re-signs the app afterwards, which is the whole reason this
# script exists.
#
# `xcodebuild test` builds the app bundle as the test host with CODE_SIGNING_ALLOWED=NO and
# then LAUNCHES it. That launch is an unsigned copy of me.sarakay.osier, so macOS records a
# TCC identity that doesn't match the stable one `dev-codesign.sh` produces — and the next
# real run has to ask for Accessibility all over again. Re-signing at the end puts the
# stable identity back before anything else runs the app.
#
# Usage:
#   ./Scripts/test.sh                                  # whole unit-test target
#   ./Scripts/test.sh CustomDictionaryBoostTermsTests  # one class (or Class/testMethod)

REPO="${0:A:h:h}"
cd "$REPO" || exit 1

TARGET="OpenSuperWhisperTests"
ONLY="-only-testing:$TARGET"
if [[ -n "$1" ]]; then
    ONLY="-only-testing:$TARGET/$1"
fi

echo "Running $ONLY"
xcodebuild test \
    -scheme Osier \
    -configuration Debug \
    -derivedDataPath build \
    -destination 'platform=macOS,arch=arm64' \
    -clonedSourcePackagesDirPath SourcePackages \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    "$ONLY" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO 2>&1 \
    | grep -E "^Test case|Test suite '.*' (passed|failed)|error:|\*\* TEST"
STATUS=${pipestatus[1]}

# Always re-sign, pass or fail: the unsigned test-host launch has already happened by now.
echo
"$REPO/Scripts/dev-codesign.sh" "./Build/Build/Products/Debug/Osier.app" || true

exit $STATUS
