# SPEC-BASKETS — column adoption, baskets, vocab wiring

**Status:** proposed, awaiting review. 2026-07-28.
**Scope:** four phases, one commit each. Nothing here touches the network.
**Governs:** `SPEC.md` §7 non-goals still apply; this doc adds the archive-side features
that §7 didn't contemplate. Where they conflict, this doc wins for these four phases only.

---

## 0. Ground truth (verified, not assumed)

Read from the live DB and the vocab dir on 2026-07-28, before writing a line of this:

```
recordings.sqlite   11,313,152 bytes   11,789 rows
backup              recordings.sqlite.backup-20260728-103949  (81,920 bytes)
grdb_migrations     v1, v2_add_status, v3_add_source_context, v4_add_model_used, v5_add_was_fallback
extra columns       source TEXT, legacy_id TEXT, import_flags TEXT   (present, NOT in grdb_migrations)
```

| `source` | rows |
|---|---|
| `willow` | 11,693 |
| `osier` | 96 |
| **NULL** | **8** |

| `import_flags` | rows |
|---|---|
| NULL / empty | 10,363 |
| `["too_short"]` | 1,317 |
| `["empty","too_short"]` | 98 |
| `["repetition_loop","too_short"]` | 8 |
| `["repetition_loop"]` | 7 |
| `["empty"]` | 4 |

**Three things in there change the design, so they're called out up front:**

1. **8 rows have `source` NULL.** A literal `WHERE source = 'osier'` filter drops them
   silently. Everywhere this spec says "Osier-only", the predicate is
   **`source IS NOT 'willow'`** (SQLite `IS NOT` is NULL-safe, so NULL rows are kept).
   That's the fail-safe direction: an untagged row is far more likely to be a native take
   the import script didn't stamp than a Willow row that lost its tag. No backfill —
   nothing invented, per your rule 4.
2. **`too_short` is a real flag on 1,423 rows**, and you only named `repetition_loop` and
   `empty` as exclusions. Spec follows your list: only `repetition_loop` and `empty` are
   excluded from clustering and tf-idf. `too_short` rows go through the normal path and
   will overwhelmingly land as loose strands on their own merit — which is the correct
   outcome and doesn't need a special case.
3. **The vocab work is not greenfield.** `Models/CustomDictionary.swift` already exists
   (replacement rules + `boostTerms` + `promptBoost` + `AutoDictionary` auto-learning), it's
   wired into all four engines, and `Settings.initialPrompt` is already an editable field
   fed into `WhisperEngine` at `WhisperEngine.swift:156-162`. Phase 4 **extends** that
   machinery rather than building a parallel one. Details in §5.

Also relevant: **the working tree is already dirty** — 31 modified/untracked files from the
notch/dictionary/signing work. Every commit in this plan uses path-scoped `git add` listing
only the files that phase touched. Your existing work is never swept into my commits.

Backup noted and left alone: `~/Library/Application Support/me.sarakay.osier/recordings.sqlite.backup-20260728-103949`.

---

## 1. Conventions this spec obeys

- **Migrations are additive and column-guarded**, exactly like `v3_add_source_context`
  (`Recording.swift:150-158`): read `db.columns(in:)`, add only what's absent. Every new
  migration is a no-op on your machine for columns that already exist.
- **Column naming.** `source`, `legacy_id`, `import_flags` already exist in snake_case
  because the import script wrote them; they get Swift properties `source`, `legacyId`,
  `importFlags` with explicit `CodingKeys` raw values mapping to the snake_case names.
  **Columns I create are camelCase** (`basketId`, `isUserNamed`, `createdAt`) to match the
  app's own convention (`sourceAppName`, `wasFallback`) and keep Codable synthesis free.
  You wrote `basket_id` / `is_user_named` in the brief — say the word if you'd rather I
  match the import script's style instead of the app's.
- **Logging** via `os.Logger`. `Diag.swift:17` currently uses the pre-rebrand subsystem
  `fr.my-monkey.opensuperwhisper`; new code uses `me.sarakay.osier` with categories
  `baskets`, `embedding`, `backfill`, `vocab`. I am not retitling `Diag` in these phases —
  that's a separate sweep.
- **No network.** No `URLSession`, no new dependency. `NaturalLanguage` is an OS framework
  and runs entirely on-device. Enforced by a test that greps the new sources for
  `URLSession|dataTask|http` and fails on a hit.

---

## 2. Phase 1 — column adoption + graceful missing audio

### 2.1 Migration `v6_adopt_import_columns`

```swift
migrator.registerMigration("v6_adopt_import_columns") { db in
    let names = try db.columns(in: Recording.databaseTableName).map(\.name)
    for column in ["source", "legacy_id", "import_flags"] where !names.contains(column) {
        try db.alter(table: Recording.databaseTableName) { $0.add(column: column, .text) }
    }
}
```

No-op on your machine (all three exist), creates them on a fresh install so the schema is
one thing regardless of how you got there. All three nullable — NULL means "unknown", never
backfilled.

### 2.2 `Recording` gains three read-mostly fields

```swift
var source: String? = nil          // "osier" | "willow" | nil
var legacyId: String? = nil        // Willow's row id, opaque
var importFlags: String? = nil     // JSON array text, e.g. ["repetition_loop"]
```

Added to `CodingKeys` (with raw values `"legacy_id"`, `"import_flags"`) and to `Columns`.
Defaults are `nil` so every existing `Recording(...)` call site — `DictationPipeline`,
file-drop import, `persistFailedRecording` — keeps compiling untouched.

Derived helpers on `Recording`:

```swift
var isImported: Bool          { source == "willow" }
var isOsierNative: Bool       { source != "willow" }        // NULL counts as native
var parsedImportFlags: [String]                              // [] when NULL/garbage
var isFlaggedJunk: Bool       { flags contains "repetition_loop" || "empty" }
```

`parsedImportFlags` decodes defensively: bad JSON logs once at `.debug` and returns `[]`
rather than throwing into a list row.

### 2.3 Missing audio fails gracefully

`Recording.url` points into the recordings dir; imported rows name `.opus` files that were
never copied. Today `RecordingRow` (`ContentView.swift:1159-1174`) shows a play button for
any non-pending, non-failed row, and `AudioRecorder.playRecording(url:)` gets a dead path.

- `Recording.audioFileExists` → `FileManager.default.fileExists(atPath: url.path)`.
- `RecordingRow` gets `@State private var hasAudio = true`, resolved once in `.task` (off
  the render path — no `fileExists` call per redraw, and only for rows that actually
  scroll into view).
- **Play button:** hidden when `!hasAudio`. Hidden, not disabled — a permanently greyed
  control on 11,693 of 11,789 rows is visual noise in an app whose whole point is being
  barely visible.
- **Regenerate (↻ and the model picker):** also hidden when `!hasAudio`. Regeneration
  re-transcribes the file; without audio it can only fail. This is the one behavior change
  beyond "hide play" and it's required by the same fact.
- **Copy text / delete:** unchanged. Delete already tolerates a missing file
  (`try? FileManager.default.removeItem`).
- No badge, no "audio missing" label. The absence of the button is the message.

### 2.4 Osier-only stats and eval

`fetchStats()` (`Recording.swift:218`) is the lifetime header — **left counting everything**,
per your rule 3.

New, separate: `fetchAccuracyCorpus()` / any future eval query filters
`AND source IS NOT 'willow'`. To make that impossible to forget, the predicate lives in one
place:

```swift
extension Recording {
    /// Rows produced by *this* app's models. Willow rows are another model's output and
    /// would poison any accuracy or model-comparison metric. NULL source counts as Osier
    /// (see SPEC-BASKETS §0.1) — the import stamped 'willow' explicitly.
    static let osierOnly = SQLExpression.literal("source IS NOT 'willow'")
}
```

`wasFallback` is `NOT NULL DEFAULT 0` in the schema, so imported rows read `false`, not
NULL — meaning "false" there is really "unknown". Any code that reasons about fallback rate
must scope to `osierOnly` for that reason alone; `modelUsed`, `sourceAppName`,
`sourceWindowTitle`, `sourceURL` are genuinely NULL and render as absent (the existing
`sourceLabel` at `ContentView.swift:924` already returns nil-and-hides).

### 2.5 Tests

`RecordingImportColumnsTests` — `parsedImportFlags` on valid JSON / NULL / malformed;
`isFlaggedJunk` for each observed flag combination; `isOsierNative` for `"osier"`,
`"willow"`, NULL.

**Commit 1:** `feat(archive): adopt import columns; hide playback for transcript-only rows`

---

## 3. Phase 2 — baskets engine + backfill

### 3.1 Shape

```
BasketEngine (actor)
├── EmbeddingProvider (protocol)      ← swappable, stubbed in tests
│   └── NLSentenceEmbeddingProvider   ← NaturalLanguage, on-device
├── BasketStore (GRDB)                ← baskets, embeddings, membership
├── BasketAssigner                    ← pure: (vector, candidates, context) → decision
├── LooseStrandSweeper                ← pure-ish: [vector] → components ≥ 5
├── BasketNamer                       ← pure: tf-idf + vocab hints → name
└── BasketBackfill                    ← cancellable, idempotent, progress-reporting
```

`BasketAssigner`, `LooseStrandSweeper` and `BasketNamer` take plain values and return plain
values — no DB, no NL, no actor. That's what makes the threshold logic testable, which is
the test you asked for.

### 3.2 Embeddings

```swift
protocol EmbeddingProvider: Sendable {
    var identifier: String { get }   // "nl-sentence-en-v1" — stamped on every stored vector
    var dimension: Int { get }
    func embed(_ text: String) -> [Float]?   // L2-normalized, or nil if unembeddable
}
```

`NLSentenceEmbeddingProvider` wraps `NLEmbedding.sentenceEmbedding(for: .english)`
(macOS 11+, fully local, zero new dependencies).

- Returns nil when the model is unavailable, the text is empty, or fewer than
  `minimumWordsToEmbed` words. Nil ⇒ the take stays loose. Never an error path.
- Long takes: `NLEmbedding`'s sentence vectors degrade on long input, so text over
  `sentenceChunkCharacters` is split with `NLTokenizer(unit: .sentence)`, each chunk
  embedded, and the vectors averaged then re-normalized.
- Vectors are L2-normalized at creation, so **cosine similarity is a dot product** — one
  `vDSP_dotpr` call, and the backfill's bulk scoring becomes a `cblas_sgemm`.

Stored in their own table so `recordings` stays clean and the cache is disposable:

```sql
CREATE TABLE recordingEmbeddings (
  recordingId TEXT PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
  provider    TEXT NOT NULL,      -- identifier; a provider swap invalidates by mismatch
  dimension   INTEGER NOT NULL,
  vector      BLOB NOT NULL       -- dimension × Float32, little-endian
);
```

At 512 dims × 11,789 rows this is ~24 MB. Rows whose `provider` doesn't match the active
provider are ignored and recomputed — that's the swap path.

### 3.3 Schema

```sql
CREATE TABLE baskets (
  id           TEXT PRIMARY KEY,
  name         TEXT NOT NULL,
  createdAt    DATETIME NOT NULL,
  isUserNamed  BOOLEAN NOT NULL DEFAULT 0,
  centroid     BLOB,              -- running mean, normalized; recomputable
  memberCount  INTEGER NOT NULL DEFAULT 0,
  lastTouched  DATETIME NOT NULL  -- drives the candidate window
);
ALTER TABLE recordings ADD COLUMN basketId TEXT;   -- NULL = loose strand
CREATE INDEX recordings_on_basketId ON recordings(basketId);
```

Migration `v7_add_baskets`, guarded the same way. `centroid` and `memberCount` are a cache —
`BasketStore.recomputeCentroid(_:)` rebuilds either from members at any time.

No foreign key on `recordings.basketId`: adding one to an existing table means a table
rebuild, and this spec is additive-only. Referential integrity is enforced in
`BasketStore.deleteBasket` (nulls its members' `basketId` in the same transaction).

### 3.4 Assignment (live, on take completion)

Hooked into `DictationPipeline.process` after `storeRecording`, as a detached low-priority
task — dictation latency must not move by a millisecond.

```
1. Skip when: flagged junk, empty, or < minimumWordsToEmbed words   → loose
2. vector = provider.embed(text)                          nil       → loose
3. candidates = baskets touched within candidateWindow, capped at
   maxCandidateBaskets by lastTouched desc
4. score(b) = dot(vector, b.centroid)
              + (b.id == previousTake.basketId && gap ≤ recencyWindow ? recencyBonus : 0)
5. best = argmax(score);  best ≥ assignmentThreshold ? assign : loose
6. on assign: update centroid (running mean, renormalized), memberCount, lastTouched
```

**Tuning constants — one enum, no Settings UI, no UserDefaults** (you said hidden; a
constant is honestly hidden, a hidden pref is a pref you forget exists):

```swift
enum BasketTuning {
    static let assignmentThreshold: Float = 0.62   // your starting point
    static let recencyBonus: Float = 0.08          // ≈ 1/8 of the gap to a confident match
    static let recencyWindow: TimeInterval = 600   // 10 min — trains of thought
    static let minimumWordsToEmbed = 4             // median take is ~9s; short stays loose
    static let looseWeaveThreshold: Float = 0.62   // sweep pair similarity
    static let minimumStrandsToWeave = 5           // your ≥5
    static let mergeThreshold: Float = 0.80        // backfill basket-merge pass
    static let candidateWindow: TimeInterval = 60 * 60 * 24 * 30
    static let maxCandidateBaskets = 200
    static let sentenceChunkCharacters = 1_000
}
```

`recencyBonus` at 0.08 is a thumb on the scale, not an override: a take at 0.55 against the
previous basket gets pulled over 0.62; a take at 0.40 does not. That's the "same train of
thought, slightly different words" case, which is the one you described.

**Nothing is force-clustered.** No k-means, no fixed cluster count, no "every take must
belong somewhere". A take below threshold against everything is a loose strand and that's a
correct, permanent answer unless a later sweep finds it company.

### 3.5 Loose-strand sweep

Runs on archive open (debounced — at most once per `sweepMinimumInterval`, 15 min) and at
the end of a backfill.

1. Candidates: loose, unflagged, embeddable takes; **most recent 500** for the incremental
   sweep (all of them during backfill).
2. Pairwise similarity over normalized vectors (500² = 125k dot products — trivial).
3. Union-find over pairs ≥ `looseWeaveThreshold`.
4. Any component with ≥ `minimumStrandsToWeave` members becomes a new basket, named per
   §3.6. Components of 1–4 stay loose.

The 500-row cap is a stated limit, not a silent one: the sweep logs how many loose strands
it looked at and how many it skipped.

### 3.6 Naming

tf-idf over member transcripts against the rest of the corpus.

- Tokens: unigrams and bigrams, lowercased, stopword-filtered (standard English list +
  dictation filler: "okay", "yeah", "like", "just", "actually", "basically", "um", "uh"),
  minimum length 3, digits-only rejected.
- IDF document set: all unflagged takes, both sources — Willow rows are the same person
  talking about the same life, so they make the IDF *better*. (Willow is excluded from
  *accuracy* metrics because it's another model's transcription quality; it is not excluded
  from what the words are about.)
- **Vocab hints:** terms from `vocab/cleanup_vocab.json` `terms[]` with
  `corpus_count ≥ vocabHintMinimumCount` (250 → ~5 terms; 50 → a few dozen; **default 50**)
  get their tf-idf score multiplied by `vocabHintWeight` (1.5). These are your real proper
  nouns — "Chiikawa" (244), "Hopper" (188), "Claude Code" (274) — and they make far better
  basket labels than whatever generic noun happens to be distinctive.
- Name = top 1–3 terms joined by " · ", each rendered through the casing map from Phase 4
  when it has an entry (so "chiikawa" prints "Chiikawa"), else title-cased. Capped at 40
  characters.
- Collision: append " (2)", " (3)".
- **`isUserNamed = 1` is absolute.** Rename sets it, and nothing auto-generated ever
  overwrites a basket carrying it — not renaming, not backfill, not merge. Forever, as you
  said.

### 3.7 Backfill

On-demand from Settings ▸ History, with a progress bar and a Cancel button.

```
Phase A  embed        every unflagged take without a current-provider vector,
                      oldest → newest, batched 200, checkpointed to disk each batch
Phase B  cluster      streaming leader-assignment in timestamp order — the SAME
                      BasketAssigner used live, including the recency bonus, so the
                      backfill produces what the app would have produced had it been
                      running since 2024
Phase C  merge        merge auto-basket pairs with centroid cosine ≥ mergeThreshold
Phase D  prune        auto-baskets with < minimumStrandsToWeave members dissolve;
                      members return to loose
Phase E  sweep        full loose-strand sweep (§3.5, uncapped)
Phase F  name         name every auto-basket (§3.6)
```

Streaming-leader in Phase B rather than a global O(n²) clustering: 11,789 × ≤200 centroids
× 512 dims ≈ 1.2 GFLOP through Accelerate — seconds, not minutes — and, more importantly,
its output is consistent with live assignment instead of being a different algorithm that
disagrees with it forever after.

**Cancellable:** cooperative `Task.isCancelled` check per batch. Cancelling mid-run leaves
completed work (embeddings, assignments) committed and valid; the next run resumes.

**Idempotent:** a re-run reproduces the same end state. Implementation:

- Embeddings: content-addressed by `(recordingId, provider)` — recomputing is a no-op.
- Clustering: Phase B begins by clearing **auto-baskets only** (`isUserNamed = 0`) and
  nulling *their* members' `basketId`. Baskets you renamed, and their membership, survive
  untouched and participate in Phase B as fixed candidates. So: run it twice, get the same
  answer; rename a basket, run it again, keep your name.
- Flagged rows (`repetition_loop`, `empty`) are never embedded, never assigned, never
  counted in tf-idf — and remain fully visible in the archive.

**Success test, stated so it can be checked:** the backfill should surface a recognizable
"hamster system" basket and a "building Osier" basket. If it doesn't, the threshold is
wrong, not the corpus, and `assignmentThreshold` is the first dial.

### 3.8 Tests

`BasketAssignerTests` — a `StubEmbeddingProvider` returns hand-built vectors, so every case
is deterministic and NL never runs in CI:

- similarity 0.61 → loose; 0.63 → assigned (the threshold boundary, both sides)
- 0.61 + previous take 5 min ago in basket A → assigned to A (bonus carries it)
- 0.61 + previous take 11 min ago in basket A → loose (window expired)
- 0.40 + previous take 1 min ago in A → loose (bonus is a thumb, not an override)
- ties broken deterministically (highest score, then oldest basket id)
- 3-word take → loose without embedding
- `repetition_loop` / `empty` flagged take → never assigned
- candidate list respects `candidateWindow` and `maxCandidateBaskets`

`LooseStrandSweepTests` — 4 mutually similar strands → no basket; 5 → one basket; two
disjoint groups of 5 → two baskets; a chain A–B–C at 0.63 each but A–C at 0.30 → one
component (transitive by design, asserted so the behavior is chosen rather than discovered).

`BasketNamerTests` — a term appearing in every basket scores below one appearing in a
single basket; a `cleanup_vocab.json` term wins ties against an equally-frequent non-vocab
term; user-named baskets are never renamed.

`BasketBackfillTests` — in-memory DB, stub provider: run twice, assert identical basket
membership; rename between runs, assert the name and membership survive; cancel mid-run,
assert no partial/corrupt state and that a resumed run completes.

**Commit 2:** `feat(baskets): local topic clustering engine + on-demand backfill`

---

## 4. Phase 3 — baskets UI

Minimal, existing style, invisible until you scroll.

**Chip row** — between the search bar and the stats bar in `ContentView`, hidden entirely
while searching and when zero baskets exist. Horizontal `ScrollView`, chips styled off
`ThemePalette`:

```
[ All 11,789 ]  [ Chiikawa 412 ]  [ hamster system 288 ]  [ building Osier 96 ]  …  [ Loose strands 3,204 ]
```

Tap filters; tap again clears. Selection is view state — not persisted, no new pref. Adds
`basketFilter` to `ContentViewModel.startFreshLoad` / `loadMore` and a matching parameter on
`RecordingStore.fetchRecordings(limit:offset:basketFilter:)`, where the filter is
`.all` / `.basket(UUID)` / `.loose` (`basketId IS NULL`).

**Row tag** — `RecordingRow` shows the basket name as a small secondary-colored capsule next
to the existing `sourceLabel`. Absent when loose. No color coding, no icon.

**Context menu** on the row: `Move to ▸` (baskets by recency, then "New basket…"),
`Remove from basket`. Moving updates both centroids incrementally.

**Basket rename** — double-click a chip, inline text field, commit sets `isUserNamed = 1`.

**Deep-clustering assist** — Settings ▸ History (not the archive chrome; it's a rare
deliberate act, and the archive stays quiet):

- **Copy clustering prompt** → clipboard. Contains **only**: basket id, name, member count,
  top 8 tf-idf terms per basket, and the loose-strand count. Assembled by a dedicated
  function whose only inputs are those fields — transcript bodies are not in scope for it
  and can't leak by accident. A test asserts the generated prompt contains no substring
  from any member transcript.
- **Paste-back box** accepting:
  ```json
  {"ops":[
    {"op":"rename","basket":"<id>","to":"Chiikawa merch"},
    {"op":"merge","baskets":["<id>","<id>"],"into":"Hamster system"}
  ]}
  ```
  Strictly validated (unknown ops rejected, unknown ids rejected, names length-capped and
  stripped of control characters). Shows a plain-language preview — "rename 2, merge 3 into
  1, 412 takes affected" — and applies only on an explicit Apply. Renames and merges set
  `isUserNamed = 1`. Merge unions membership, recomputes the centroid, deletes the emptied
  baskets.
- **UI copy, verbatim:**
  > Osier never sends anything anywhere. This copies basket names and top terms — never
  > your transcripts — to your clipboard, for you to paste into an AI tool yourself. Paste
  > its answer back below.

No new windows, no onboarding, no badges, no notification.

**Commit 3:** `feat(baskets): archive chips, row tags, and the copy-out clustering assist`

---

## 5. Phase 4 — vocabulary wiring

Files stay at `~/Library/Application Support/me.sarakay.osier/vocab/`. **Not committed, not
copied into the repo.** A `.gitignore` entry isn't needed (they're outside the tree) but the
loader path is a constant with a comment saying why they live there.

### 5.1 `VocabStore`

Loads `whisper_initial_prompt.txt` and `cleanup_vocab.json` at launch and on file-change
(dispatch source on the directory), cached in memory. Every failure is soft: missing file,
bad JSON, wrong shape → log once at `.info`, behave as if empty. Dictation must never break
because a vocab file got mangled.

Two layers, merged at read time:

- `cleanup_vocab.json` — the imported base (yours, 433 casing entries, 428 terms)
- `cleanup_vocab.user.json` — user overrides written by Settings; **merges over** the base
  by lowercased key. A user entry can override or delete (`null` value) a base entry. The
  base file is never written to, so regenerating it from your corpus doesn't clobber edits.

### 5.2 Casing map — the replacer

Not `CustomDictionary.apply`. That function iterates entries in array order with one
`NSRegularExpression` compiled per entry — 433 regex compilations and 433 passes on every
take, and, decisively, **array order can't express "cloud code" beats "cloud"**.

`VocabCasing` instead compiles **one** regex per loaded vocab generation:

- All keys escaped and joined into a single alternation, **sorted by descending key length**
  — regex alternation is first-match-wins at each position, so the longest key at a given
  start position always wins. `cloud code` therefore beats a hypothetical `cloud` entry
  structurally, not by luck of ordering.
- `\b` boundaries added only where the key's edge character is a word character (same rule
  as `CustomDictionary.isWordCharacter` at line 98, so terms like "C++" still match).
- `.caseInsensitive`. Replacement is the canonical value, inserted verbatim.
- One pass over the text, replacements taken left to right, no re-scanning of replaced
  spans (so `Claude Code` can't be re-matched into something else).

**The "cloud" case, explicitly.** Your map (verified) contains
`cloud code`, `clawed code`, `clod code`, `cloudcode`, `cloud's code` → `Claude Code`
(and `cloud's code` → `Claude Code's`), and **no bare `cloud` key**. So "the cloud is down"
must come through untouched. The spec adds a hard rule on top of that fact:
`VocabCasing` refuses to load any single-word key from the `deniedSoloKeys` set
(`cloud`, `clawed`, `clod`, `claude's`, and anything the user adds), logging the rejection.
If a future regeneration of `cleanup_vocab.json` ever emits a bare `cloud` key, it is
dropped at load, not applied. A test asserts exactly this.

Applied in the transcription post-processing path, **before** the user's `CustomDictionary`
entries at the four existing call sites (`WhisperEngine.swift:243`,
`FluidAudioEngine.swift:114`, `AppleSpeechEngine.swift:185`, `SenseVoiceEngine.swift:52`) —
so a hand-written rule in Settings always gets the last word over the imported map.
Gated by a `vocabCasingEnabled` pref, default **on** (these are corrections, not preferences;
7 of the 433 entries are true mishearing fixes and the rest are pure casing).

### 5.3 Whisper initial prompt

`whisper_initial_prompt.txt` is a 498-byte glossary line. `WhisperEngine` currently joins
`settings.initialPrompt` + dictionary `promptBoost` (line 156-162). It becomes:

```
[ settings.initialPrompt ] + [ vocab glossary file ] + [ dictionary promptBoost ]
```

then truncated. **Order rationale:** your typed `initialPrompt` is a deliberate act and goes
first; the file glossary is next because it's the highest-value bias; `promptBoost` is
already opt-in and least critical, so it's what gets cut. Say the word if you'd rather the
file lead.

**Truncation.** whisper.cpp caps the prompt at `n_text_ctx/2 - 1` = 223 tokens; over that,
tokens are dropped and the parameter silently underperforms. `maxPromptCharacters = 800`
(≈200 tokens at ~4 chars/token — conservative, since proper nouns tokenize badly).
Truncation is **from the end** as you specified, cut back to the last comma or whitespace
boundary before the limit so the prompt never ends mid-word. Logged at `.debug` with the
before/after length when it fires. Your current content — 498 file + boost — fits, so this
only bites once the glossary grows.

Where the boost gate is off, the glossary still applies: the glossary is biasing, not
rescoring, and it's the mechanism that has never over-corrected (unlike `boostTerms`, which
is why `minimumBoostLength` exists).

### 5.4 Settings ▸ Dictation, "Vocabulary" section

Slots above the existing Custom Dictionary block, matching its style:

- Read-only-ish list of loaded terms — term, corpus count, source badge (imported / yours).
  Searchable, since 428 rows need it. Virtualized list.
- **Add** — term + optional "heard as" variant, written to `cleanup_vocab.user.json`.
- **Remove** — imported terms are tombstoned in the user file (never deleted from the base);
  user terms are deleted outright. A removed imported term shows struck through with an
  Undo, so a mis-tap isn't destructive.
- Footer line: file paths, term counts (`428 imported · 6 yours`), a Reveal in Finder button,
  and "Reload" for hand edits.
- The existing Custom Dictionary section is untouched and keeps working — it's the
  hand-written layer, and it wins over the imported map.

### 5.5 Tests

`VocabCasingTests` — the boundary case first, because it's the one that matters:

| input | expected |
|---|---|
| `the cloud is down` | unchanged |
| `cloudy weather` | unchanged |
| `open cloud code` | `open Claude Code` |
| `Cloud Code is slow` | `Claude Code is slow` |
| `cloudcode` | `Claude Code` |
| `cloud's code broke` | `Claude Code's broke` (map's literal value) |
| `cloud code, cloud code` | both replaced |
| `cloud code.` | `Claude Code.` |
| `Chikawa` / `chikawa's` | `Chiikawa` |
| `github` mid-sentence | `GitHub` |
| a bare `cloud` key injected into the map | rejected at load, `the cloud` unchanged |
| longest-first: map has both `claude` and `claude code` | `claude code` → `Claude Code`, one replacement not two |

`VocabPromptTests` — under budget passes through; over budget truncates from the end at a
comma/whitespace boundary; never emits a partial word; empty inputs yield `nil` not `""`.

`VocabStoreTests` — user file overrides base by lowercased key; `null` tombstones; missing
files, malformed JSON, and a JSON array where an object is expected all degrade to empty
without throwing.

**Commit 4:** `feat(vocab): wire the corpus glossary and casing map into transcription`

---

## 6. What this deliberately does not do

- No re-clustering on every launch. Live assignment + a debounced sweep, nothing else.
- No basket for every take. Loose is a valid permanent state and most short takes stay there.
- No backfill of `wasFallback`, `sourceAppName`, `modelUsed`, or any other NULL. Unknown
  stays unknown.
- No rewrite of `fetchStats()`. The lifetime header keeps counting all 11,789.
- No network call, from any code path, for any reason, including the clustering assist.
- No rebrand work, no `Diag` subsystem rename, no touching the notch. Separate ships.
- No new window, onboarding step, badge, or notification.

## 7. Open questions

1. **Column naming** — camelCase (`basketId`, `isUserNamed`) to match the app, or snake_case
   to match the import script? Spec assumes camelCase.
2. **NULL `source` on 8 rows** — spec treats them as native (`IS NOT 'willow'`). Confirm, or
   tell me they're Willow and I'll flip the predicate.
3. **Prompt order** — your typed `initialPrompt` first, then the file glossary? Or file first?
4. **`vocabHintMinimumCount`** — default 50 (a few dozen terms as label candidates). 250 gives
   ~5 terms and much more conservative names.
5. **Commits** — I'll path-scope `git add` to only the files each phase touches, leaving your
   31 uncommitted files alone. Confirm that's what you want rather than committing the tree
   first.
