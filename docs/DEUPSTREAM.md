# DEUPSTREAM — repoint Osier's operational links away from upstream

**Status:** written 2026-07-29. Blocked on the GitHub repo existing (see §0).

Osier is a hard fork of `my-monkeys/OpenSuperWhisper`. The *attribution* is already correct
and must stay. What's wrong is the **operational** wiring: seven places still point at
upstream's infrastructure, so the app checks their releases, solicits money for their
ko-fi, and files feedback into their issue tracker.

---

## 0. Prerequisite — Osier has no repo of its own

`git remote -v` currently reads:

```
origin  https://github.com/my-monkeys/OpenSuperWhisper.git
```

Nothing here can be finished until that changes. Run, from the repo root:

```bash
gh repo create ssskay/osier --private --source=. --remote=upstream-osier --push=false
git remote rename origin upstream
git remote rename upstream-osier origin
git remote -v          # origin → ssskay/osier, upstream → my-monkeys
git push -u origin rebrand/wicker
```

Keeping `upstream` as a named remote is deliberate — the 7/27 decision was a detached repo
*with* an upstream remote for cherry-picks. This preserves that.

Start `--private`. Going public is a separate decision with its own checklist (see the
`repo-hygiene` skill), and `.construct/` only stopped being tracked today.

**If the repo name is not `ssskay/osier`, change it here first — everything below uses it.**

---

## 1. The functional bug — fix this one first

`OpenSuperWhisper/Utils/UpdateChecker.swift:26`

```swift
static let repo = "my-monkeys/OpenSuperWhisper"   // ← polls THEIR releases
```

→ `static let repo = "ssskay/osier"`

This is not cosmetic. `fetchReleases()` hits
`api.github.com/repos/<repo>/releases`, and `releasesURL` sends the user to that repo's
releases page. As written, when upstream ships a version Osier will report an update is
available and offer someone else's DMG — one which no longer matches this codebase at all.

Until Osier has published a release, `fetchReleases()` will return an empty array against
the new repo. That is the correct behaviour: no releases, no update prompt. Confirm the
empty case renders as "you're up to date" rather than an error in `UpdatesView`.

---

## 2. Settings links

`OpenSuperWhisper/Settings.swift`

| Line | Now | Change to |
|---|---|---|
| 1293 | `my-monkeys/OpenSuperWhisper/issues/new` | `ssskay/osier/issues/new` |
| 1303 | `my-monkeys/OpenSuperWhisper/releases` | `ssskay/osier/releases` |
| 1415 | `https://ko-fi.com/mymonkey` | **see below** |
| 1431 | `my-monkeys/OpenSuperWhisper` (repo link) | `ssskay/osier` |
| 1445 | `my-monkeys/OpenSuperWhisper` (star link) | `ssskay/osier` |

`OpenSuperWhisper/RemoteSettingsSection.swift:107` — `my-monkeys/OpenSuperWhisper/issues`
→ `ssskay/osier/issues`.

### The "Support us" row is a decision, not a swap

Line 1415 opens upstream's ko-fi. Leaving it is the worst of the three options — the app
solicits donations on behalf of a project it is no longer. Pick one:

- **Remove the row.** Cleanest for a personal tool nobody's being asked to fund. Delete the
  `Button` block at 1414–1429; the sidebar footer closes up on its own.
- **Repoint it** at your own ko-fi/GitHub Sponsors and reword to "Support Osier".
- **Keep upstream's, relabelled** "Support OpenSuperWhisper" — honest, but odd in an app
  that isn't it.

Default if unspecified: **remove the row.**

---

## 3. Update feed and appcast

`OpenSuperWhisper/OpenSuperWhisper-Info.plist:38` points `SUFeedURL` at
`raw.githubusercontent.com/my-monkeys/OpenSuperWhisper/master/appcast.xml`. The comment
above it says Sparkle is disarmed on purpose — verify that's still true. If it is, **delete
the key** rather than repointing it; a disarmed feed pointing at a live foreign appcast is
a loaded footgun. If Sparkle is live, repoint to Osier's own appcast.

`appcast.xml` and `appcast-x86_64.xml` are upstream's release history — versions 0.9.6
through 0.9.9, with download URLs into their releases. They describe builds that aren't
this app. Truncate both to an empty `<channel>` with Osier's title, and let
`make_release.sh` append real entries. Do not hand-edit upstream's entries into Osier URLs;
those artifacts don't exist.

---

## 4. Version number — flag, don't decide

`CFBundleShortVersionString` is `0.9.9`, inherited from upstream. Osier has diverged
substantially and its version number currently claims to be a build of a different app.
Worth resetting, but it interacts with the update checker's comparison logic and with any
DMG you've already produced, so it's Sara's call:

- `0.1.0` — honest for a personal tool that hasn't shipped
- `1.0.0` — if the first DMG is the real release
- leave `0.9.9` — no work, but permanently confusing

Not changing it in this pass unless told to.

---

## 5. What must NOT change

1. `LICENSE` — byte-identical to upstream's, `Copyright (c) 2024 OpenSuperWhisper` intact.
2. `Readme.md` §"Credits — this is a hard fork" — the Starmel → my-monkeys → Osier chain,
   and the line directing *upstream* bug reports upstream. This is the MIT obligation and
   it is already correct.
3. `Bridge.h`, `libwhisper/`, `vendor/` — third-party, untouched.

The distinction this whole document turns on: **credit upstream in prose, never in
infrastructure.** Attribution belongs in the README and LICENSE. Update endpoints, issue
trackers and donation links belong to whoever ships the binary.

---

## 6. Also noted, out of scope

`Diag.swift:17` still uses the subsystem `fr.my-monkey.opensuperwhisper` for os_log. Real,
but it's a separate rename sweep (`SPEC-BASKETS.md` §1 already flagged it). Not in this
commit.

---

## Verification

```bash
grep -rn "my-monkey\|mymonkey" --include="*.swift" --include="*.plist" --include="*.xml" . \
  | grep -v vendor | grep -v SourcePackages
```

Should return only `Readme.md` credits and `LICENSE`. Anything in a `.swift` or `.plist`
after this pass is a miss.

Commit message: `fix: point update checks, feedback and support at Osier's own repo`
