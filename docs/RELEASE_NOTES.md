# CombatAnalytics — Release Notes

> All changes since **release/1.0** (`3a36c67`) through **HEAD** (`862b096`), in reverse chronological order.

---

## [Unreleased] — 2026-03-21

### Benchmarking Intelligence Phase

This phase adds defensive-economy metrics, kill-window analysis, comp classification, and new aggregate buckets that power coaching insights based on build efficiency and matchup patterns.

#### New Features

**Defensive Economy Tracking** (`CombatTracker.lua`)
- Tracks enemy major defensives in real time via CLEU aura events (`enemyActiveDefensives` runtime map)
- Detects player defensive overlap — increments `defensiveOverlapCount` each time a second defensive is applied while one is already active
- **Greed death detection**: on player death, checks whether any major defensive (`SPELL_TAXONOMY.majorDefensive`) was available but unused; increments `greedDeaths`
- **Burst waste detection**: tracks casts of major offensive spells that land during periods of low enemy health or no CC opportunity; increments `burstWasteCount`

**Kill Window Tracking** (`CombatTracker.lua`)
- Listens to `ARENA_CROWD_CONTROL_SPELL_UPDATE` (Branch B handler) to detect when the enemy healer falls under crowd control
- Opens a kill window (`killWindowOpen = true`) when healer CC starts; closes and records it on CC expiry or healer death
- `killWindowConversions` counts how many windows ended with an enemy death during the CC
- Arena-only: guarded by `session.context == CONTEXT.ARENA`

**Comp Archetype Classifier** (`CompArchetypeClassifier.lua`, NEW)
- `ClassifyComp(specIds)` matches an array of spec IDs against `SeedCompArchetypes.archetypes` (first-match, priority-ordered)
- Recognises 4 three-vs-three archetypes (Jungle, WMP, RMP, Godcomp) and 3 two-vs-two archetypes (Hunter/X, Rogue/Healer, Double DPS)
- Falls back to `"unknown"` for unrecognised compositions
- Result written to `session.arena.compArchetype` in `FinalizeSession`

**Five New Derived Metrics** (`Utils/Metrics.lua`)
- `greedDeathRate` — greed deaths ÷ total deaths
- `defensiveOverlapRate` — overlap events ÷ total defensive activations
- `burstWasteRate` — wasted casts ÷ total major-offensive casts
- `killWindowConversionRate` — converted windows ÷ total kill windows opened
- `drWasteRate` — CC applications that hit immune DR tier ÷ total CC applications (uses accurate per-application counter, not a heuristic)

**New Aggregate Bucket: `matchupArchetypes`** (`CombatStore.lua`)
- Keyed by `compArchetype` string
- Fields per bucket: `archetype`, `fights`, `wins`, `losses`, `totalGreedDeaths`, `totalBurstWaste`, `totalKillWindows`, `totalKillWindowConversions`

**Build Confidence Score** (`CombatStore.lua`)
- After each session, build buckets now update: `confidenceScore = math.min(1.0, fights / 30) * winRate`
- Reaches full confidence at 30 fights; reflects both sample size and actual win rate

**Weighted Win Rate Helpers** (`CombatStore.lua`)
- `local computeWeightedWinRate(sessions, filterFn, windowSize, decay)` — exponential decay, newest session weight = 1.0, each older session multiplied by `decay` (default 0.9)
- `CombatStore:GetOverallWeightedWinRate()` — weighted rate across all sessions (window 30)
- `CombatStore:GetBuildWeightedWinRate(buildHash)` — same, filtered to a single build; no SavedVariables writes

**New Seed Files**
- `seed/Maps.lua` — 14 arena maps (with `losRating`, `objectiveType`) and 11 battleground maps (with `objectiveType`, `isBG`); exposed via `StaticPvpData.MAPS` / `GetMapInfo(mapId)`
- `seed/CompArchetypes.lua` — 8 named comp archetypes (first-match priority) used by `CompArchetypeClassifier`
- `seed/MetricThresholds.lua` — 6 metric score bands (`pressureScore`, `burstScore`, etc.) with `minSamples` configuration (`build=10`, `matchup=5`, `weighted=30`)

**Battle.net API Scripts** (`scripts/`)
- `fetch_blizzard_data.py` — authenticates via client-credentials OAuth, fetches spec/class/spell data, saves JSON to `data/raw/`
- `generate_seed_from_api.py` — reads raw JSON, emits `SeedSpecBaseline.lua` with win-rate and population baselines per spec; safe file loading, correct `MELEE_SPEC_IDS` set
- `scripts/requirements.txt`, `scripts/README.md` — dependency list and usage guide

**Schema v5** (`Constants.lua`, `CombatStore.lua`)
- `SCHEMA_VERSION` bumped `4 → 5`
- New `session.survival` fields: `greedDeaths`, `defensiveOverlapCount`, `burstWasteCount`
- New top-level session fields: `killWindows[]` (array of `{openedAt, closedAt, converted}`), `killWindowConversions`
- `session._runtime` transient subtable (never persisted); nilled before `PersistSession`
- Migration handler stubs all new fields to `0`/`{}` for existing sessions; `closedAt = nil` sentinel documents windows still open at match end

**Spell Intelligence Extensions** (`seed/generated/SeedSpellIntelligence.lua`)
- All 43 `isMajorDefensive = true` entries now carry `cooldownSeconds`
- `[42292]` (PvP Trinket) has `isPvPTrinket = true`
- Demon Hunter entries consolidated into a contiguous block
- `GetSpellInfo(spellId)` now closes over the `spellIntelligence` local directly (O(1), no redundant copy table)

#### Bug Fixes

- **Taint warning** (`CombatTracker.lua`): removed boolean test on `isHelpful` aura field — WoW Midnight marks this as a secret boolean for certain units, triggering a taint warning; field is no longer read
- **`ns.CombatStore` nil crash** (`CombatStore.lua`): `ComputeWeightedWinRate` was assigned to `ns.CombatStore` at module level, before `ns.Addon:RegisterModule` ran; fixed by assigning to the local `CombatStore` table via method syntax
- **Greed death loop performance** (`CombatTracker.lua`): loop now iterates `SPELL_TAXONOMY.majorDefensive` (~25 entries) instead of the full `SPELL_INTELLIGENCE` table (~80+ entries) with a per-entry filter
- **DR waste heuristic** (`Utils/Metrics.lua`): previous formula `math.max(0, apps - 3)` overcounted when DR reset mid-session; replaced with an accurate `wastedApplications` counter incremented in `computeCCDRState` at the immune tier
- **`burstWasteRate` denominator** (`Utils/Metrics.lua`): was reading a local variable; now correctly reads `session.metrics.majorOffensiveCount`
- **Migration nil guard** (`CombatStore.lua`): migration unconditionally stubs `session.survival` (was skipping sessions where the subtable was absent)
- **Script fixes** (`scripts/`): renamed output file to `SeedSpecBaseline.lua`, corrected `MELEE_SPEC_IDS` membership, added safe file loading

---

## [Roadmap v3] — Feature/Roadmap-V3 Merge

Merged `feature/roadmap-v3` into `main`. Post-merge taint and API-compatibility patches applied.

### Highlights

**Midnight API Compatibility**
- Removed `COMBAT_LOG_EVENT_UNFILTERED` from frame-level event registration — forbidden for addon frames in WoW Midnight; CLEU now flows exclusively through the normalised `HandleNormalizedEvent` pipeline
- All `Unit*` APIs (health, aura, name queries on arena units) guarded against Midnight secret-value restrictions
- `ADDON_ACTION_BLOCKED` diagnostics added; `NotifyInspect` blocked during combat

**Schema v4**
- `comps` aggregate bucket added
- New session field stubs for CC, rating, score data

**UI Additions**
- Expanded build-comparison panel in Matchup Detail view
- Fixed Rating view filter-key mismatches causing empty chart

**New Specs**
- Demon Hunter Devourer spec added to seed data
- Runtime DR enrichment via `C_SpellDiminish`

---

## [Roadmap v2] — Feature/Roadmap-V2 Merge

Merged `feature/roadmap-v2` into `main`. Full PvP coaching platform delivered across five phases.

### Phase 1 — Foundational Data

| Task | Change |
|------|--------|
| **1.1** Post-match score harvest | `C_PvP.GetScoreInfo(i)` polled at match end; damage, kills, rating, MMR stored per player |
| **1.2** Live rating capture | `C_PvP.GetPVPActiveMatchPersonalRatedInfo()` polled at combat start and end |
| **1.3** Arena CC tracking | `ARENA_CROWD_CONTROL_SPELL_UPDATE` registered; CC spell/start/duration stored per arena slot |
| **5.1** OnUpdate throttling | `OnUpdate` handler throttled to 0.1 s intervals |
| **5.4** Schema v3 migration | CC, rating, and score fields backfilled with `false` sentinel on existing sessions |

### Phase 2 — Core Analytics

| Task | Change |
|------|--------|
| **2.1** Rating progression | `db.aggregates.ratingProgression[]` — rating/MMR snapshots over time |
| **2.2** Time-under-CC score | Survivability score now incorporates CC uptime |
| **2.3** Death cause attribution | `DeathAnalyzer` module; records last 10 incoming spells and active CC family at moment of death |
| **2.4** Opponent spell frequency | Per-opponent-spec spell-cast aggregates |
| **2.6** Win rate by MMR band | `db.aggregates.mmrBands` bucket |
| **4.5** Build effectiveness matrix | Build↔context win rate cross-table in `CombatStore` |

### Phase 3 — Strategy Engine

| Task | Change |
|------|--------|
| **4.1** StrategyEngine | New `StrategyEngine.lua`; generates ranked strategy cards per matchup |
| **4.2** Trinket timing | Suggestion fires when trinket used with no enemy CC active in prior 3 s |
| **4.3** Spec win rate suggestions | Underperforming spec win rates surface as ranked suggestions |
| **4.4** Pre-match advisory | Advisory text generated from opponent comp and historical matchup data |
| **–** Interrupt analytics | Interrupt cast frequency and success rate per target tracked |
| **–** Pressure / tilt scoring | Composite pressure and tilt index added to `session.metrics` |
| **–** TTK estimate | Time-to-kill estimate based on sustained damage vs target health |

### Phase 4 — UI/UX

| Task | Change |
|------|--------|
| **3.1** Rating chart | New `UI/RatingView.lua` — line chart of rating over time with MMR overlay |
| **3.2** Matchup drill-down | New `UI/MatchupDetailView.lua` — per-opponent-spec stats with build comparison |
| **3.3** Timeline replay | `UI/CombatDetailView.lua` enhanced with scrubable event timeline |
| **3.4** Summary opponent comp | Opponent comp panel in `UI/SummaryView.lua` |
| **3.5** Strategy cards | Strategy cards rendered in `UI/SuggestionsView.lua` |
| **3.6** History filter/sort | Date, result, context, and spec filters in `UI/CombatHistoryView.lua` |
| **3.7** Confidence badges | Capture-quality badges in history rows |
| **–** Counter guide | Spec-specific counter tips in Insights tab |
| **–** Responsive tab layout | Tab strip now wraps cleanly at 10 tabs; Matchup drill-down hidden until data present |

### Phase 5 — Polish / Social

| Task | Change |
|------|--------|
| **6.1** Session export | JSON export of any session via slash command |
| **6.2** Wargame detection | `SessionClassifier` detects wargame context |
| **6.3** Party sync | `PartySyncService` broadcasts session summary to party members |
| **–** Opener sequence | First 5 casts recorded; suboptimal opener suggestion added |
| **–** Spec archetypes | Expanded to 39 specs; CC DR families enriched |
| **–** Spell intelligence | 150+ spells catalogued in `SeedSpellIntelligence` |
| **–** Ring buffer | Raw events capped by ring buffer to prevent unbounded memory growth |
| **–** Modular event router | `Events.lua` refactored to a table-driven dispatch router |

---

## [1.0] — Base Release (`3a36c67`)

Initial public release. Core pipeline, 8-tab UI, session schema v2, and seed data.

---

*Generated from `git log 3a36c67..HEAD` on 2026-03-21.*
