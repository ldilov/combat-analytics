# CombatAnalytics — Release Notes

---

## [Released] — 2026-03-21 - v1.1

## [Released] — 2026-03-21 — v1.1

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

