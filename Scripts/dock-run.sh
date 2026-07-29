#!/bin/zsh
#
# What the "Run Osier" Dock app actually runs. Kept in the repo (not inside the .app) so
# it's version-controlled and so the launcher survives edits to it.
#
# It goes through Terminal rather than running from the app bundle directly for two
# reasons: the build output and Osier's own logs stay visible, exactly like running
# ./run.sh by hand — and a process launched by LaunchServices gets a bare PATH, so
# cmake/cargo/xcodebuild wouldn't be found. Terminal starts a login shell, which has them.

# The repo is wherever this script lives, one level up — so moving the checkout only
# requires re-running make-dock-launcher.sh, and nothing here needs editing.
REPO="${0:A:h:h}"
cd "$REPO" || { echo "Can't find the Osier repo at $REPO"; exit 1; }

echo "Osier — building and running from $REPO"
echo

# One instance at a time. A second copy registers the same global hotkeys, so every press
# fires twice — the #chord-double-fire symptom, but self-inflicted. run.sh guards this too;
# doing it here as well means the old copy isn't holding your hotkeys during the build.
if pgrep -x Osier > /dev/null; then
    echo "Quitting the running Osier first…"
    pkill -x Osier
    for _ in {1..30}; do
        pgrep -x Osier > /dev/null || break
        sleep 0.1
    done
fi

# run.sh builds, signs, and then runs the app in the foreground, printing its logs here.
# Ctrl-C in this window stops Osier, same as always.
exec ./run.sh
