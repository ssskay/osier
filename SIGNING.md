# Code Signing — how Osier keeps its TCC permissions across rebuilds

*Set up 2026-07-28. If macOS starts re-prompting for Microphone/Accessibility after rebuilds, something below has drifted.*

## The facts

| What | Value |
|---|---|
| Bundle ID | `me.sarakay.osier` |
| Signing identity | `Developer ID Application: Sara Kay (AH785WYH3F)` |
| Team ID | `AH785WYH3F` |
| Identity pin file | `.osw-codesign-identity` (gitignored, per-machine) |
| Built app | `build/Build/Products/Debug/Osier.app` |

## Why permissions used to reset every build

TCC (macOS permission database) identifies an app by bundle ID + code signature.
Unsigned/ad-hoc builds get a fresh signature every compile, so every rebuild
looked like a brand-new app. Two bugs caused this:

1. The pbxproj had the upstream fork's `DEVELOPMENT_TEAM = 5C67TFSJ2B` with
   automatic signing — no cert for that team exists here, so signing silently
   fell back.
2. `Scripts/dev-codesign.sh` (the thing that actually signs dev builds — see
   below) fell back to the rotatable Apple Development cert and stripped
   Hardened Runtime.

## How signing works now

**Dev builds (`./run.sh` / `./run.sh build`):** xcodebuild runs with
`CODE_SIGNING_ALLOWED=NO`, then `Scripts/dev-codesign.sh` re-signs the app.
The identity comes from `.osw-codesign-identity`, which pins the Developer ID
cert. The script signs with `--options runtime` so Hardened Runtime survives.

**Release builds (xcodebuild without run.sh, `make_release.sh`):** the pbxproj
now has `CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY = "Developer ID
Application"`, `DEVELOPMENT_TEAM = AH785WYH3F` on the app target, so Xcode
signs correctly on its own.

Entitlements (`OpenSuperWhisper/OpenSuperWhisper.entitlements`) are the minimal
real set: `app-sandbox=false`, `automation.apple-events=true`,
`device.audio-input=true`. Accessibility is **not** an entitlement — it's a
TCC-only grant; stable signing is what makes it stick.

## The build command that signs correctly

```bash
./run.sh build        # build + re-sign, don't launch
./run.sh              # build + re-sign + launch via LaunchServices
```

## Verify a build's signature

```bash
APP=build/Build/Products/Debug/Osier.app
codesign -dv --verbose=4 "$APP"          # want: Identifier=me.sarakay.osier,
                                         #       TeamIdentifier=AH785WYH3F,
                                         #       flags=0x10000(runtime)
codesign --verify --deep --strict "$APP"
codesign -d --entitlements - "$APP"      # want: device.audio-input present
```

`TeamIdentifier=not set` means signing fell back to ad-hoc — check that
`.osw-codesign-identity` exists and the cert is still in the Keychain
(`security find-identity -v -p codesigning`).

## Reset permissions (only when deliberately starting fresh)

```bash
tccutil reset Microphone me.sarakay.osier
tccutil reset Accessibility me.sarakay.osier
```

## Things that will legitimately re-prompt (not bugs)

- macOS **major** version upgrades sometimes re-confirm Accessibility.
- The Developer ID cert expires ~2031; renew and update nothing else
  (same team ⇒ same designated requirement ⇒ grants survive).
- Changing the bundle ID restarts everything. Don't.

## Out of scope

Notarization — only needed so *other people's* Macs open the app without a
Gatekeeper warning. If Osier goes public, that's a separate task using
`notarytool` (`altool` is retired). Local dev and personal use never need it.
