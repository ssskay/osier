#!/bin/bash
#
# Renders the Osier app icon from the same parametric mark the app draws at runtime
# (OpenSuperWhisper/Brand/SpeakingStrand.swift) and writes OpenSuperWhisper/AppIcon.icns.
#
# There is no baked artwork anywhere in this repo except the .icns this produces. Change the
# mark and re-run this; the icon follows. The generated .icns IS committed, so a normal build
# never needs Swift-on-the-fly.
#
#   Scripts/make-appicon.sh            # regenerate OpenSuperWhisper/AppIcon.icns
#   Scripts/make-appicon.sh --preview  # also drop a 1024 PNG in docs/rebrand/ for review
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="$ROOT/OpenSuperWhisper/AppIcon.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PREVIEW=false
[[ "${1:-}" == "--preview" ]] && PREVIEW=true

echo "Building icon renderer…"

# The mark and the palette are compiled from the app's own sources — that is the point, and it
# means the icon cannot drift from what the app draws. The only edit is stripping the trailing
# `#Preview` block: the preview macro needs an app target's tooling and won't build into a
# plain command-line binary.
sed '/^#Preview/,$d' "$ROOT/OpenSuperWhisper/Brand/SpeakingStrand.swift" > "$WORK/SpeakingStrand.swift"
cp "$ROOT/OpenSuperWhisper/Brand/OsierTheme.swift" "$WORK/OsierTheme.swift"

cat > "$WORK/main.swift" <<'SWIFT'
import AppKit
import SwiftUI

/// One icon tile: the mark on a wicker-cream rounded square.
///
/// Willow greens only — no rust. Rust means "recording" everywhere else in the app, and an icon
/// sitting in the Dock is not recording; spending the colour here would cost it its meaning.
struct AppIconTile: View {
    let px: CGFloat

    var body: some View {
        ZStack {
            // macOS icons leave breathing room around the rounded square rather than bleeding to
            // the canvas edge, and the corner radius is ~22.37% of the square's side.
            let inset = px * 0.098
            let side = px - inset * 2

            RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
                .fill(LinearGradient(
                    colors: [Osier.cream, Osier.wicker],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.18), radius: px * 0.012, x: 0, y: px * 0.008)

            // The mark's share of the tile. At 0.62 it read as a small badge floating in a large
            // cream field and got lost at Dock size. 0.78 fills the tile the way a macOS app icon
            // is meant to, and — because SpeakingStrand sizes every stroke as a fraction of its
            // frame — it thickens the strands in absolute pixels too, which is what buys back
            // legibility at 32px. Past ~0.80 the ring starts to crowd the rounded square's edge.
            SpeakingStrand(state: .idle, ring: Osier.leaf, strand: Osier.leaf)
                .frame(width: side * 0.78, height: side * 0.78)
        }
        .frame(width: px, height: px)
    }
}

@MainActor
func render(_ px: Int, to path: String) {
    let renderer = ImageRenderer(content: AppIconTile(px: CGFloat(px)).environment(\.colorScheme, .light))
    renderer.scale = 1
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("render failed at \(px)px\n".data(using: .utf8)!)
        exit(1)
    }
    try! png.write(to: URL(fileURLWithPath: path))
}

MainActor.assumeIsolated {
    let outDir = CommandLine.arguments[1]

    // The ten entries `iconutil` expects for a macOS iconset.
    let tiles: [(Int, String)] = [
        (16, "icon_16x16"), (32, "icon_16x16@2x"),
        (32, "icon_32x32"), (64, "icon_32x32@2x"),
        (128, "icon_128x128"), (256, "icon_128x128@2x"),
        (256, "icon_256x256"), (512, "icon_256x256@2x"),
        (512, "icon_512x512"), (1024, "icon_512x512@2x"),
    ]
    for (px, name) in tiles {
        render(px, to: "\(outDir)/\(name).png")
    }
}
SWIFT

# The icon is drawn light-appearance regardless of the machine's setting: an app icon is a fixed
# asset, and Osier's dark variants would otherwise leak in on a machine set to dark mode and make
# the committed .icns depend on who ran the script.
swiftc -O -o "$WORK/render" \
    "$WORK/OsierTheme.swift" "$WORK/SpeakingStrand.swift" "$WORK/main.swift" \
    > "$WORK/compile.log" 2>&1 || { echo "Renderer failed to build:"; cat "$WORK/compile.log"; exit 1; }

echo "Rendering tiles…"
mkdir -p "$WORK/Osier.iconset"
"$WORK/render" "$WORK/Osier.iconset"

echo "Packing AppIcon.icns…"
iconutil -c icns "$WORK/Osier.iconset" -o "$OUT"

if $PREVIEW; then
    mkdir -p "$ROOT/docs/rebrand"
    cp "$WORK/Osier.iconset/icon_512x512@2x.png" "$ROOT/docs/rebrand/appicon-1024.png"
    echo "Preview: docs/rebrand/appicon-1024.png"
fi

echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"
