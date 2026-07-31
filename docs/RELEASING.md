# Releasing Osier

How a version of Osier goes from working tree to a signed, notarized DMG on
[github.com/ssskay/osier/releases](https://github.com/ssskay/osier/releases).

## One-time setup

1. **Signing identity** — `Developer ID Application: Sara Kay (AH785WYH3F)` must be in the
   login keychain. `Scripts/dev-codesign.sh` reads the pinned identity from
   `.osw-codesign-identity` (gitignored) for day-to-day dev builds.
2. **Notary credentials** — stored once under the keychain profile `osw-notary`:
   ```sh
   xcrun notarytool store-credentials osw-notary \
     --apple-id <apple-id> --team-id AH785WYH3F --password <app-specific-password>
   ```
3. **gh CLI** — `brew install gh && gh auth login` as `ssskay`.
4. **Sparkle keypair** — done. `SUPublicEDKey` in
   `OpenSuperWhisper/OpenSuperWhisper-Info.plist` is Osier's own, generated with Sparkle
   2.9.4 `bin/generate_keys`; the private half is in the login keychain (item
   *"Private key for signing Sparkle updates"*). **Back it up** — losing it means no
   existing install can ever verify an update again:
   ```sh
   ./bin/generate_keys -x sparkle-private-key.txt   # then store it somewhere safe, offline
   ```
   The key stays inert until a feed exists. When publishing one, add `SUFeedURL`
   (`https://raw.githubusercontent.com/ssskay/osier/main/appcast.xml`, or the
   `appcast-x86_64.xml` variant for Intel builds) — and make sure the appcast entries are
   signed with *this* key, not upstream's.

## Cutting a release

```sh
./make_release.sh 1.0.0 "Developer ID Application: Sara Kay (AH785WYH3F)"          # arm64
./make_release.sh 1.0.0 "Developer ID Application: Sara Kay (AH785WYH3F)" x86_64   # Intel
```

The script bumps `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, runs `notarize_app.sh`
(build → sign → notarize → staple → `Osier-<arch>.dmg`), commits the bump, tags
`v<version>`, pushes, and publishes the GitHub release with the DMG, its SHA-256, and the
dSYM. Build releases with a **stable** Xcode — `notarize_app.sh` refuses beta toolchains.

## Appcast (only once Sparkle is live)

For each shipped DMG:

```sh
./bin/sign_update Osier-arm64.dmg     # prints edSignature + length
```

Append an `<item>` to `appcast.xml` (arm64) / `appcast-x86_64.xml` (Intel) with the release
URL, `sparkle:edSignature`, and `length`, then commit and push. Keep the two arch feeds
separate so the variants never offer each other's downloads.

## Sanity checklist

- [ ] `spctl -a -t open --context context:primary-signature -v Osier-*.dmg` → accepted
- [ ] Fresh-machine install: drag to /Applications, first launch grants mic + accessibility
- [ ] `gh release view v<version> --repo ssskay/osier` shows all assets
- [ ] If feeds are live: appcast entry signature verifies with *Osier's* key
