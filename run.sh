#!/bin/zsh

JUST_BUILD=false
if [[ "$1" == "build" ]]; then
    JUST_BUILD=true
fi

# Patch FluidAudio's vocabulary rescorer to prefer longer matching spans
# (keyword boosting quality, e.g. "My-Monkey" matched as one term). Idempotent;
# fails loudly if the target moved (so a FluidAudio bump can't silently skip it).
apply_fluidaudio_patches() {
    local checkout="SourcePackages/checkouts/FluidAudio"
    local patch_file="patches/fluidaudio-vocabulary-rescorer.patch"
    local target="$checkout/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/CustomVocabulary/Rescorer/VocabularyRescorer+TokenRescoring.swift"

    if [[ ! -f "$patch_file" ]]; then
        echo "Missing FluidAudio patch: $patch_file"
        exit 1
    fi

    if [[ ! -f "$target" ]]; then
        echo "Missing FluidAudio source checkout: $target"
        exit 1
    fi

    if grep -q "Prefer longer spans" "$target"; then
        echo "FluidAudio vocabulary rescorer patch already applied."
        return
    fi

    echo "Applying FluidAudio vocabulary rescorer patch..."
    patch --silent --forward -d "$checkout" -p1 < "$patch_file"
    if [[ $? -ne 0 ]] && ! grep -q "Prefer longer spans" "$target"; then
        echo "Failed to apply FluidAudio vocabulary rescorer patch."
        exit 1
    fi
}

# Configure libwhisper
echo "Configuring libwhisper..."
cmake -G Xcode -B libwhisper/build -S libwhisper
if [[ $? -ne 0 ]]; then
    echo "CMake configuration failed!"
    exit 1
fi

./Scripts/fetch-sherpa.sh

echo "Building autocorrect-swift..."
mkdir -p build
cargo build -p autocorrect-swift --release --target aarch64-apple-darwin --manifest-path=asian-autocorrect/Cargo.toml
cp ./asian-autocorrect/target/aarch64-apple-darwin/release/libautocorrect_swift.dylib ./build/libautocorrect_swift.dylib
install_name_tool -id "@rpath/libautocorrect_swift.dylib" ./build/libautocorrect_swift.dylib
codesign --force --sign - ./build/libautocorrect_swift.dylib
if [[ $? -ne 0 ]]; then
    echo "Cargo build failed!"
    exit 1
fi

echo "Copying libomp.dylib..."
cp /opt/homebrew/opt/libomp/lib/libomp.dylib ./build/libomp.dylib
install_name_tool -id "@rpath/libomp.dylib" ./build/libomp.dylib
codesign --force --sign - ./build/libomp.dylib

echo "Copying libonnxruntime.dylib..."
cp vendor/onnxruntime/libonnxruntime.1.24.4.dylib ./build/libonnxruntime.1.24.4.dylib
ln -sf libonnxruntime.1.24.4.dylib ./build/libonnxruntime.dylib
codesign --force --sign - ./build/libonnxruntime.1.24.4.dylib

# Resolve Swift packages so the FluidAudio checkout exists, then patch it.
echo "Resolving Swift packages..."
RESOLVE_OUTPUT=$(xcodebuild -resolvePackageDependencies -scheme OpenSuperWhisper -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages -skipPackagePluginValidation -skipMacroValidation 2>&1)
if [[ $? -ne 0 ]]; then
    echo "$RESOLVE_OUTPUT"
    echo "Swift package resolution failed!"
    exit 1
fi

apply_fluidaudio_patches

# Build the app
echo "Building OpenSuperWhisper..."
BUILD_OUTPUT=$(xcodebuild -scheme OpenSuperWhisper -configuration Debug -jobs 8 -derivedDataPath build -quiet -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -UseModernBuildSystem=YES -clonedSourcePackagesDirPath SourcePackages -skipUnavailableActions CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO OTHER_CODE_SIGN_FLAGS="--entitlements OpenSuperWhisper/OpenSuperWhisper.entitlements" build 2>&1)

# sudo gem install xcpretty
if command -v xcpretty &> /dev/null
then
    echo "$BUILD_OUTPUT" | xcpretty --simple --color
else
    echo "$BUILD_OUTPUT"
fi

# Check if build output contains BUILD FAILED or if the command failed
if [[ $? -eq 0 ]] && [[ ! "$BUILD_OUTPUT" =~ "BUILD FAILED" ]]; then
    echo "Building successful!"
    # Re-sign with a stable identity so macOS keeps granted TCC permissions
    # across rebuilds (no-op / ad-hoc fallback when no identity is available).
    "$(dirname "$0")/Scripts/dev-codesign.sh" "./Build/Build/Products/Debug/Osier.app" || true
    if $JUST_BUILD; then
        exit 0
    fi
    echo "Starting the app..."
    # Remove quarantine attribute if exists
    xattr -d com.apple.quarantine ./Build/Build/Products/Debug/Osier.app 2>/dev/null || true

    # One instance at a time: `open` would just activate an already-running copy instead of
    # launching the build we just made, and two copies register the same global hotkeys.
    if pgrep -x Osier > /dev/null; then
        echo "Quitting the running Osier first..."
        pkill -x Osier
        for _ in {1..30}; do
            pgrep -x Osier > /dev/null || break
            sleep 0.1
        done
    fi

    # Launch through LaunchServices (`open`) — NOT by exec'ing the binary directly.
    #
    # A GUI app exec'd from a shell inherits Terminal as its TCC *responsible process*, so
    # macOS checks Terminal's Accessibility grant instead of Osier's. The app's own toggle
    # can be ON in System Settings and it still can't paste into the focused field, with no
    # error anywhere — it just silently isn't trusted. `open` makes Osier responsible for
    # itself, so its own grant is the one that counts. (#tcc-responsible-process)
    #
    # --stdout/--stderr keep the app's output in this window, exactly as before; -W blocks
    # until it quits, and the trap makes Ctrl-C here stop the app like it used to.
    APP_TTY="$(tty 2>/dev/null)"
    [[ -c "$APP_TTY" ]] || APP_TTY=/dev/stdout
    trap 'pkill -x Osier 2>/dev/null' INT TERM
    open -W --stdout "$APP_TTY" --stderr "$APP_TTY" ./Build/Build/Products/Debug/Osier.app
else
    echo "Build failed!"
    exit 1
fi 