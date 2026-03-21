# CombatAnalytics — Release Notes

---

## [1.2] — 2026-03-21

### Counter Guide & Minimap

A full graphical rework of the Counter Guide tab, minimap button fixes, and the Blizzard Settings panel registered at startup.

### New in v1.2

#### Counter Guide rework

* Replaced the plain-text counter list with a fully graphical right-hand panel
* **Spec header** — 40×40 spec icon, class-coloured spec name, archetype and range bucket sub-line
* **Threat bar** — colour-coded red/gold/green bar derived from your historical win rate vs the spec; shows `?` with no data
* **Win-rate bar** — your personal W/L record and fight count vs the spec
* **DR-family pills** — colour-coded pill badges per CC family (Stun, Poly, Root, Fear, Silence, Disorient, …)
* **Spell icon grid** — top spells seen from this spec with spell icon, name, damage total, and hit count
* **Counter strategy cards** — curated tips merged with static seed data from `SeedCounterTips.lua`
* **Interrupt priority** — ordered kick targets from seed data
* **Safe offensive windows** — when to go aggressive from seed data
* **murlok.io global win rate** — shown when seed data carries a live win rate

#### Counter seed data pipeline

* `seed/generated/SeedCounterTips.lua` — curated tips, interrupt priority, safe windows, and murlok.io win rates per spec
* `scripts/fetch_counter_data.py` — fetches live murlok.io win-rate data and regenerates the Lua seed file
* `.github/workflows/update-seed-data.yml` — weekly auto-refresh every Monday 06:00 UTC; commits updated seed files back to `main`

#### Minimap button

* Minimap button is now **shown by default** (previously off by default)
* `/ca minimap` **toggles** visibility with a confirmation message (previously only hid)
* **Toggle Minimap** button added to the in-game Settings panel
* Settings panel now registered with the Blizzard `Settings` API at **startup** — appears in `ESC → Settings → Addons → CombatAnalytics` without needing `/ca settings` first

#### Rating backfill

* At `PVP_MATCH_INACTIVE`, the addon now backfills `ratingSnapshot` from `GetPVPActiveMatchPersonalRatedInfo()` and falls back to `scoreInfo.rating + ratingChange` from the scoreboard when needed

### Fixes

* `hideElements` — WoW UI objects are `userdata`, not `table`; the type check always failed silently, causing old canvas elements to accumulate on re-select
* CC-family DR pills — `guide.ccFamilies` is an array of `{spellId, family}` objects; `pairs()` was returning integer indices instead of family name strings; now correctly extracts unique family strings (same pattern as `SuggestionsView`)
* Spell icon grid — `yPos` was mutated inside the grid loop, causing rows after the first to compound their y-offset; fixed by capturing `spellGridTop` before the loop
* Same ccFamilies extraction fix applied to `MatchupDetailView`

---

## [1.1] — 2026-03-21

### Benchmarking Intelligence Phase

This release sharpens coaching insights with better defensive-economy tracking, kill-window analysis, composition classification, and stronger aggregate signals for build and matchup performance.

### New in v1.1

#### Defensive economy and survivability

* Real-time tracking of enemy major defensives
* Defensive overlap detection when multiple defensives are layered unnecessarily
* Greed-death detection when a major defensive was available but unused
* Burst-waste detection for major offensive cooldowns spent into weak kill conditions

#### Kill-window analysis

* Tracks healer crowd control in arena
* Opens and closes kill windows automatically during healer CC
* Records whether each kill window converted into an enemy death
* Adds conversion metrics for coaching review

#### Composition intelligence

* New **CompArchetypeClassifier** for common 2v2 and 3v3 comps
* Recognizes archetypes such as **Jungle, WMP, RMP, Godcomp, Hunter/X, Rogue/Healer,** and **Double DPS**
* Stores the detected archetype on arena sessions for downstream aggregation

#### New derived metrics

* `greedDeathRate`
* `defensiveOverlapRate`
* `burstWasteRate`
* `killWindowConversionRate`
* `drWasteRate`

#### Aggregates and build confidence

* New `matchupArchetypes` aggregate bucket for archetype-level performance tracking
* Build buckets now compute a **confidence score** based on sample size and win rate
* Added exponentially decayed **weighted win rate** helpers for overall and per-build analysis

#### New seed and data tooling

* Added seeded PvP map metadata
* Added seeded comp archetype definitions
* Added seeded metric thresholds with minimum sample requirements
* Added Battle.net API scripts for fetching raw data and generating spec baseline seed files

#### Schema and data model

* Schema updated from **v4 → v5**
* Added new survival counters and kill-window session fields
* Added transient runtime session state with safe persistence cleanup
* Migration stubs added for backward compatibility

#### Spell intelligence updates

* Major defensives now carry cooldown metadata
* PvP Trinket flagged explicitly
* Demon Hunter spell entries cleaned up
* Spell lookup optimized for direct local access

### Fixes

* Removed Midnight taint risk caused by reading restricted aura fields
* Fixed `ns.CombatStore` nil crash during weighted win rate setup
* Reduced greed-death scan overhead by iterating only major defensives
* Replaced DR waste heuristic with accurate immune-tier counting
* Corrected `burstWasteRate` denominator source
* Hardened migration for sessions missing survival data
* Fixed script output naming, melee spec classification, and file loading safety

### Compatibility and platform notes

* Updated event flow for **WoW Midnight** compatibility
* Guarded `Unit*` API usage against secret-value restrictions
* Added `ADDON_ACTION_BLOCKED` diagnostics
* Prevented `NotifyInspect` calls during combat

### Notable recent platform work included

* Post-match score harvesting
* Live rating capture
* Arena CC tracking
* OnUpdate throttling
* Rating progression
* Time-under-CC survivability scoring
* Death cause attribution
* Opponent spell-frequency tracking
* MMR-band win rates
* Build effectiveness matrix
* Strategy engine and pre-match advisories
* Interrupt analytics, pressure scoring, and TTK estimation
* Rating charts, matchup drill-downs, replay timeline, strategy cards, and history filtering
* Session export, wargame detection, party sync, opener tracking, expanded archetypes, enriched spell intelligence, ring buffer protection, and modular event routing

### Highlights

* Better coaching signals around **defensive discipline**, **cooldown efficiency**, and **kill conversion**
* Stronger matchup intelligence through **comp archetypes** and **weighted build evaluation**
* Safer persistence and migration with **Schema v5**
* Improved compatibility with **WoW Midnight** runtime restrictions


## [1.0] — Base Release (`3a36c67`)

Initial public release. Core pipeline, 8-tab UI, session schema v2, and seed data.

---

