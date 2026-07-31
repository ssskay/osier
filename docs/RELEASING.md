# Releasing Osier

How a version of Osier goes from working tree to a signed, notarized DMG on
[github.com/ssskay/osier/releases](https://github.com/ssskay/osier/releases).

## One-time setup

1. **Signing identity** — `Developer ID Application: Sara Kay (AH785WYH3F)` must be in the
   login keychain. `Scripts/dev-codesign.sh` reads the pinned identity from
   `.osw-codesign-identity` (gitignored) for day-to-day dev builds.
2. **Notary credentials** — stored once under the keychain profile `AC_NOTARY` (shared with
   Sara's other notarized apps, so it may already exist):
   ```sh
   xcrun notarytool history --keychain-profile AC_NOTARY   # already set up?
   xcrun notarytool store-credentials AC_NOTARY \
     --apple-id <apple-id> --team-id AH785WYH3F --password <app-specific-password>
   ```
3. **gh CLI** — `brew install gh && gh auth login` as `ssskay`.
4. **Rust + both Apple targets** — the autocorrect dylib is built for arm64 *and* x86_64 and
   `lipo`'d together, so even an arm64-only release needs the Intel target:
   ```sh
   rustup target add aarch64-apple-darwin x86_64-apple-darwin
   ```
5. **xcpretty** — the build pipes into it, so a missing binary fails the whole pipeline. It's
   in the `Gemfile`, but `notarize_app.sh` invokes it bare rather than through `bundle exec`,
   so it has to be on `PATH`:
   ```sh
   gem install --user-install xcpretty
   export PATH="$(ruby -e 'puts Gem.user_dir')/bin:$PATH"   # add to ~/.zshrc
   ```
6. **A UTF-8 locale** — Ruby takes its default encoding from the locale. With `LANG`/`LC_ALL`
   unset (common in non-interactive shells and CI) it falls back to US-ASCII and xcpretty dies
   with `invalid byte sequence in US-ASCII`. `notarize_app.sh` sets a UTF-8 default itself, but
   set it in your shell too: `export LANG=en_US.UTF-8`.
7. **A stable Xcode** — `notarize_app.sh` refuses beta toolchains (see the comment there).

Items 2 and 4–6 are enforced by the preflight block at the top of `notarize_app.sh`, which
fails in about two seconds with the exact fix rather than after a 15-minute build.

8. **Sparkle keypair** — done. `SUPublicEDKey` in
   `OpenSuperWhisper/OpenSuperWhisper-Info.plist` is Osier's own, generated with Sparkle
   2.9.4 `bin/generate_keys`; the private half is in the login keychain (item
   *"Private key for signing Sparkle updates"*) and is backed up offline.
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
