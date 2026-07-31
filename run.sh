#!/bin/zsh
#
# Build and run Osier.
#
#   ./run.sh          build, then launch
#   ./run.sh build    build only
#   ./run.sh -v       build verbosely (stream everything to the terminal)
#
# Quiet by default: each step prints one line, and all the tool output goes to
# build/last-build.log. The log is dumped automatically if a step fails, so nothing is lost —
# it just isn't in your face when things are working.

set -o pipefail

JUST_BUILD=false
VERBOSE=false
for arg in "$@"; do
    case "$arg" in
        build) JUST_BUILD=true ;;
        -v|--verbose) VERBOSE=true ;;
    esac
done

APP="./Build/Build/Products/Debug/Osier.app"
LOG="build/last-build.log"

mkdir -p build
: > "$LOG"

# Runs one build step. Its output goes to the log; the terminal gets a single line. On failure
# the tail of the log is printed, because the whole point of hiding output is that you still get
# it exactly when you need it.
step() {
    local label="$1"; shift
    if $VERBOSE; then
        print "▸ $label"
        "$@" 2>&1 | tee -a "$LOG"
        local status=$?
        [[ $status -eq 0 ]] || { print "$label failed."; exit 1; }
        return 0
    fi

    print -n "  $label… "
    if "$@" >> "$LOG" 2>&1; then
        print "ok"
    else
        print "failed"
        print ""
        print "── $label ── last 40 lines of $LOG:"
        tail -40 "$LOG"
        print ""
        print "Full log: $LOG"
        exit 1
    fi
}

# Patch FluidAudio's vocabulary rescorer to prefer longer matching spans
# (keyword boosting quality, e.g. "My-Monkey" matched as one term). Idempotent;
# fails loudly if the target moved (so a FluidAudio bump can't silently skip it).
apply_fluidaudio_patches() {
    local checkout="SourcePackages/checkouts/FluidAudio"
    local patch_file="patches/fluidaudio-vocabulary-rescorer.patch"
    local target="$checkout/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/CustomVocabulary/Rescorer/VocabularyRescorer+TokenRescoring.swift"

    if [[ ! -f "$patch_file" ]]; then
        print "Missing FluidAudio patch: $patch_file"
        return 1
    fi

    if [[ ! -f "$target" ]]; then
        print "Missing FluidAudio source checkout: $target"
        return 1
    fi

    if grep -q "Prefer longer spans" "$target"; then
        print "FluidAudio vocabulary rescorer patch already applied."
        return 0
    fi

    print "Applying FluidAudio vocabulary rescorer patch..."
    patch --silent --forward -d "$checkout" -p1 < "$patch_file"
    if [[ $? -ne 0 ]] && ! grep -q "Prefer longer spans" "$target"; then
        print "Failed to apply FluidAudio vocabulary rescorer patch."
        return 1
    fi
}

build_autocorrect() {
    cargo build -p autocorrect-swift --release --target aarch64-apple-darwin \
        --manifest-path=asian-autocorrect/Cargo.toml || return 1
    cp ./asian-autocorrect/target/aarch64-apple-darwin/release/libautocorrect_swift.dylib \
        ./build/libautocorrect_swift.dylib || return 1
    install_name_tool -id "@rpath/libautocorrect_swift.dylib" ./build/libautocorrect_swift.dylib || return 1
    codesign --force --sign - ./build/libautocorrect_swift.dylib
}

copy_dylibs() {
    # `cp -f`, not plain cp: these sources are mode 444, so a previous run leaves a read-only
    # copy behind and the next plain `cp` fails with EACCES. -f unlinks the destination and
    # retries. The old script ignored the exit status here and silently carried on with the
    # stale dylib.
    cp -f /opt/homebrew/opt/libomp/lib/libomp.dylib ./build/libomp.dylib || return 1
    chmod u+w ./build/libomp.dylib || return 1
    install_name_tool -id "@rpath/libomp.dylib" ./build/libomp.dylib || return 1
    codesign --force --sign - ./build/libomp.dylib || return 1

    cp -f vendor/onnxruntime/libonnxruntime.1.24.4.dylib ./build/libonnxruntime.1.24.4.dylib || return 1
    chmod u+w ./build/libonnxruntime.1.24.4.dylib || return 1
    ln -sf libonnxruntime.1.24.4.dylib ./build/libonnxruntime.dylib || return 1
    codesign --force --sign - ./build/libonnxruntime.1.24.4.dylib
}

resolve_packages() {
    xcodebuild -resolvePackageDependencies -scheme Osier -derivedDataPath build \
        -clonedSourcePackagesDirPath SourcePackages \
        -skipPackagePluginValidation -skipMacroValidation
}

# xcodebuild exits 0 on some failures it reports only in its output, so the log is checked for
# BUILD FAILED as well as the exit status.
build_app() {
    xcodebuild -scheme Osier -configuration Debug -jobs 8 -derivedDataPath build \
        -quiet -destination 'platform=macOS,arch=arm64' \
        -skipPackagePluginValidation -skipMacroValidation -UseModernBuildSystem=YES \
        -clonedSourcePackagesDirPath SourcePackages -skipUnavailableActions \
        CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
        OTHER_CODE_SIGN_FLAGS="--entitlements OpenSuperWhisper/OpenSuperWhisper.entitlements" \
        build || return 1
    ! grep -q "BUILD FAILED" "$LOG"
}

print "Building Osier…"

step "libwhisper"        cmake -G Xcode -B libwhisper/build -S libwhisper
step "sherpa-onnx"       ./Scripts/fetch-sherpa.sh
step "autocorrect-swift" build_autocorrect
step "dylibs"            copy_dylibs
step "swift packages"    resolve_packages
step "fluidaudio patch"  apply_fluidaudio_patches
step "compiling"         build_app

# Re-sign with a stable identity so macOS keeps granted TCC permissions across rebuilds
# (no-op / ad-hoc fallback when no identity is available).
step "codesign"          "$(dirname "$0")/Scripts/dev-codesign.sh" "$APP"

if $JUST_BUILD; then
    print "Built: $APP"
    exit 0
fi

print "Launching…"

# Remove quarantine attribute if exists
xattr -d com.apple.quarantine "$APP" 2>/dev/null || true

# One instance at a time: `open` would just activate an already-running copy instead of
# launching the build we just made, and two copies register the same global hotkeys.
if pgrep -x Osier > /dev/null; then
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
open -W --stdout "$APP_TTY" --stderr "$APP_TTY" "$APP"
