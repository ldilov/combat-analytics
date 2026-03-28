# Tasks: Midnight 12.0.1 Compliance Overhaul

**Input**: Design documents from `/specs/001-midnight-compliance-overhaul/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Not explicitly requested in the feature specification. Tests are omitted. Manual regression matrix defined in the requirements document serves as the acceptance test framework.

**Organization**: Tasks are grouped by user story. US1 (correctness) is the critical foundation — all other stories depend on it.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- WoW addon flat structure: all Lua modules at repository root
- UI modules in `UI/` subdirectory
- Seed data in `seed/generated/`
- No build step — files loaded directly by WoW client

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Schema version bump, new enum definitions, and timeline event schema that all user stories depend on.

- [x] T001 Add ProvenanceSource enum (`state`, `damage_meter`, `visible_unit`, `inspect`, `loss_of_control`, `spell_diminish`, `estimated`, `legacy_import`) to Constants.lua
- [x] T002 Add SessionConfidence enum (`STATE_PLUS_DAMAGE_METER`, `DAMAGE_METER_ONLY`, `VISIBLE_CC_ONLY`, `PARTIAL_ROSTER`, `ESTIMATED`, `LEGACY_CLEU_IMPORT`) replacing ANALYSIS_CONFIDENCE in Constants.lua
- [x] T003 Add TimelineLane enum (`player_cast`, `visible_aura`, `cc_received`, `dr_update`, `kill_window`, `death`, `match_state`, `inspect`, `dm_checkpoint`, `dm_spell`, `dm_enemy_spell`) to Constants.lua
- [x] T004 Add CAPTURE_QUALITY values for timeline and roster (`TIMELINE_OK`, `ROSTER_OK`) to Constants.lua
- [x] T005 Bump SCHEMA_VERSION from 5 to 6 in Constants.lua

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Schema migration and core data model changes that MUST be complete before ANY user story implementation.

**CRITICAL**: No user story work can begin until this phase is complete.

- [x] T006 Write v5→v6 migration function in CombatStore.lua: add `timelineEvents = {}` and `provenance = {}` to all existing sessions
- [x] T007 In the v5→v6 migration, map old ANALYSIS_CONFIDENCE labels to new SessionConfidence labels (`FULL_RAW`/`ENRICHED` → `LEGACY_CLEU_IMPORT`, `RESTRICTED_RAW` → `STATE_PLUS_DAMAGE_METER`, `DEGRADED` → `DAMAGE_METER_ONLY`, `PARTIAL_ROSTER` → `PARTIAL_ROSTER`, `UNKNOWN` → `ESTIMATED`) in CombatStore.lua
- [x] T008 In the v5→v6 migration, add `fieldConfidence = {}` to all existing arena slot records, inferring initial confidence from existing data (prepSpecId → "prep", pvpTalents → "inspect", guid → "visible") in CombatStore.lua
- [x] T009 In the v5→v6 migration, initialize new aggregate buckets (`openers = {}`, `matchupMemory = {}`, `duelSeries = {}`) in CombatStore.lua
- [x] T010 Update `CreateSession()` in CombatTracker.lua to initialize `timelineEvents = {}` and `provenance = {}` on new sessions
- [x] T011 Update `CreateSession()` in CombatTracker.lua to use the new SessionConfidence enum for `captureQuality.confidence` field

**Checkpoint**: Foundation ready — schema migration works, new sessions have timelineEvents/provenance fields. Old sessions load without error.

---

## Phase 3: User Story 1 — Trustworthy Combat Sessions Without CLEU (Priority: P1) MVP

**Goal**: Remove all CLEU runtime dependencies. Every session correctly identifies context, enemies, spells using only sanctioned APIs. All persisted fields carry provenance.

**Independent Test**: Enter arena (2v2, 3v3, Solo Shuffle), duel (accepted and canceled), and dummy combat. Verify sessions finalize with correct totals and provenance, no CLEU calls, no runtime errors.

### Implementation for User Story 1

#### Step 1: Delete CLEU code paths

- [x] T012 [US1] Grep all references to `HandleCombatLogEvent`, `NormalizeCombatLogEvent`, and `HandleNormalizedEvent` across all files to identify all callers and consumers in the codebase
- [x] T013 [US1] Delete `NormalizeCombatLogEvent()` function (CombatTracker.lua ~line 590) — no production caller exists
- [x] T014 [US1] Delete `HandleCombatLogEvent()` function (CombatTracker.lua ~line 1839) — no active event registration
- [x] T015 [US1] Gate `HandleNormalizedEvent()` (CombatTracker.lua ~line 1183) behind a `CA_DEV_CLEU` development-only flag that is never set in production. Extract stats aggregation consumers into standalone functions that can be called from timeline producers.
- [x] T016 [US1] Remove `HandleCombatLogEvent(eventRecord)` from ArenaRoundTracker.lua (~line 561) and remove the call site in CombatTracker.lua (~line 1253)
- [x] T017 [US1] Remove CLEU event ingestion from SpellAttributionPipeline.lua (~line 202-264): delete the `HandleCombatLogEvent(session, eventRecord)` function and the call site in CombatTracker.lua (~line 1260)
- [x] T018 [US1] Remove `AccumulateEvidence(session, eventRecord)` from SessionClassifier.lua (~line 567) and `ShouldStartNewSession(currentSession, eventRecord)` (~line 792) — replace with state-only classification

#### Step 2: Build Timeline Producer System

- [x] T019 [US1] Create TimelineProducer.lua as a new module: define the producer registry, `AppendTimelineEvent(session, event)` function, and the TimelineEvent table schema per data-model.md
- [x] T020 [US1] Implement PlayerCastProducer in TimelineProducer.lua: handle `UNIT_SPELLCAST_SUCCEEDED`, classify spells as offensive/defensive/trinket/cooldown using SeedSpellIntelligence, emit `player_cast` lane events with `source = "state"`, `confidence = "confirmed"`
- [x] T021 [US1] Implement VisibleAuraProducer in TimelineProducer.lua: handle `UNIT_AURA`, emit `visible_aura` lane events for applied/removed/refreshed with `source = "visible_unit"`, manage aura window open/close pairs
- [x] T022 [US1] Implement CCReceivedProducer in TimelineProducer.lua: handle `LOSS_OF_CONTROL_ADDED/REMOVED`, `PLAYER_CONTROL_LOST/CHANGED`, emit `cc_received` lane events with `source = "loss_of_control"`, meta includes drCategory and duration
- [x] T023 [US1] Implement DRUpdateProducer in TimelineProducer.lua: handle `UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED`, emit `dr_update` lane events with `source = "spell_diminish"` for visible arena units
- [x] T024 [US1] Implement MatchStateProducer in TimelineProducer.lua: handle `PVP_MATCH_*`, `DUEL_*`, `PLAYER_REGEN_DISABLED/ENABLED`, emit `match_state` lane events for combat_start, combat_end, round_start, round_end, duel_start, duel_end
- [x] T025 [US1] Implement InspectProducer in TimelineProducer.lua: handle `INSPECT_READY`, emit `inspect` lane events with `source = "inspect"`, meta includes pvpTalents and talentImportString
- [x] T026 [US1] Implement DamageMeterCheckpointProducer in TimelineProducer.lua: handle `DAMAGE_METER_COMBAT_SESSION_UPDATED` and `DAMAGE_METER_CURRENT_SESSION_UPDATED`, emit `dm_checkpoint` lane events

#### Step 3: Wire producers to event router

- [x] T027 [US1] Register all TimelineProducer handlers in Events.lua: map each sanctioned event to its corresponding producer function, following the existing TRACKER_EVENT_MAP pattern
- [x] T028 [US1] Wire `UNIT_SPELLCAST_SUCCEEDED` handler in Events.lua to call TimelineProducer.PlayerCastProducer and also update spell stats aggregation (castCount, intervals) directly from the event data
- [x] T029 [US1] Wire `UNIT_AURA` handler in Events.lua to call TimelineProducer.VisibleAuraProducer and also update aura stats (uptime, stacks, procs) from the event data
- [x] T030 [US1] Wire CC/LOC event handlers in Events.lua to call TimelineProducer.CCReceivedProducer

#### Step 4: Rewire SessionClassifier for state-only detection

- [x] T031 [US1] Refactor SessionClassifier.lua: make `ResolveContextFromState()` the sole production path for context detection — remove all event-record-based context inference
- [x] T032 [US1] Refactor duel detection in SessionClassifier.lua: use `DUEL_REQUESTED`/`DUEL_INBOUNDS`/`DUEL_FINISHED` events exclusively. Add 30-second timeout on pending duel state to prevent stale state.
- [x] T033 [US1] Refactor dummy detection in SessionClassifier.lua: use creature ID from `SeedDummyCatalog` + `UnitClassification("target")` check. Remove event-based dummy scoring.
- [x] T034 [US1] Ensure duel session is created only on `DUEL_INBOUNDS` (not `DUEL_REQUESTED`) in CombatTracker.lua — canceled duel requests must produce zero stored sessions

#### Step 5: Stabilize session lifecycle

- [x] T035 [US1] Add configurable DamageMeter stabilization delay (default 1.5s) to CombatTracker.lua: after PLAYER_REGEN_ENABLED, wait for DM data to settle before finalizing
- [x] T036 [US1] Verify idempotent finalization in CombatTracker.lua `FinalizeSession()`: ensure multiple finalize triggers for the same session are safe (existing `state == "active"` check)
- [x] T037 [US1] Add re-entrant safety for /reload during combat in CombatTracker.lua: on `PLAYER_LOGIN`/`ADDON_LOADED`, check for stale active sessions and finalize or discard cleanly
- [x] T038 [US1] Ensure no duplicate sessions: add guard in `CreateSession()` that prevents creating a new session while an active session exists for the same context without finalizing the old one first

#### Step 6: Arena identity and slot confidence

- [x] T039 [US1] Add `fieldConfidence` table to `ensureSlot()` in ArenaRoundTracker.lua (~line 125): initialize all field confidence values as nil
- [x] T040 [US1] Update `CapturePrepSpecs()` in ArenaRoundTracker.lua (~line 307): set `fieldConfidence.spec = "prep"`, `fieldConfidence.class = "prep"` when prep data populates slot fields
- [x] T041 [US1] Update `ARENA_OPPONENT_UPDATE` handler in ArenaRoundTracker.lua: set `fieldConfidence.guid = "visible"`, `fieldConfidence.name = "visible"`, `fieldConfidence.class = "visible"` when unit becomes visible
- [x] T042 [US1] Update `INSPECT_READY` handler in ArenaRoundTracker.lua (~line 474): set `fieldConfidence.pvpTalents = "inspect"`, `fieldConfidence.talentImportString = "inspect"`, `fieldConfidence.spec = "inspect"` (upgrade from prep)
- [x] T043 [US1] Add `learnedAt` timestamp tracking to `fieldConfidence` in ArenaRoundTracker.lua: record server timestamp when each field is first populated
- [x] T044 [US1] Add `round.completionState` field (`"complete"` | `"partial_leaver"` | `"partial_disconnect"`) to ArenaRoundTracker.lua, set on round end based on roster completeness

#### Step 7: Attribution from DamageMeter only

- [x] T045 [US1] Refactor SpellAttributionPipeline.lua to remove all CLEU event processing. Keep only the `MergeDamageMeterAttribution()` and `MergeDamageMeterSource()` paths for building attribution from C_DamageMeter data
- [x] T046 [US1] Add `source` field (ProvenanceSource) to each `SourceAttribution` record in SpellAttributionPipeline.lua — set to `"damage_meter"` for DM-sourced data
- [x] T047 [US1] Update pet/summon ownership tracking in SpellAttributionPipeline.lua: derive from UNIT_SPELLCAST_SUCCEEDED events (visible player pet casts) instead of CLEU SPELL_SUMMON events

#### Step 8: DamageMeter Death Recap support

- [x] T048 [US1] Add Death Recap category detection in DamageMeterService.lua: check for `Enum.DamageMeterType.DeathRecap` availability, wrap in pcall for graceful fallback
- [x] T049 [US1] Implement `CollectDeathRecapSnapshot()` in DamageMeterService.lua: extract death recap spell rows from DM API when available, return structured data with per-spell amounts and sources
- [x] T050 [US1] Merge Death Recap rows into session timelineEvents as `dm_enemy_spell` lane events during DM import in DamageMeterService.lua, with `source = "damage_meter"`, meta includes sourceGuid/sourceName/sourceClassFile

#### Step 9: Arena results and rating

- [x] T051 [US1] Verify arena result resolution in CombatTracker.lua `HandlePvpMatchComplete()` uses PvP match state APIs only (already correct per research — confirm no regression)
- [x] T052 [US1] Add explicit `ratingSnapshot.missingReason` field in CombatTracker.lua when `GetPVPActiveMatchPersonalRatedInfo()` returns no data — store "api_unavailable" or "not_rated" instead of nil

#### Step 10: Provenance tagging at finalization

- [x] T053 [US1] In CombatTracker.lua `FinalizeSession()`, populate `session.provenance` map: tag each non-trivial field with its ProvenanceSource (totals → "damage_meter", opener → "state", arena → "state", attribution → "damage_meter")
- [x] T054 [US1] In CombatTracker.lua `FinalizeSession()`, resolve `session.captureQuality.confidence` using the new SessionConfidence enum based on available data (DM import success + state tracking completeness + roster completeness)
- [x] T055 [US1] In CombatTracker.lua, extract opener sequence from `session.timelineEvents` (first 5 `player_cast` lane events) instead of from rawEvents ring buffer
- [x] T056 [US1] In CombatTracker.lua, extract death analysis from `session.timelineEvents` (last damage/CC events before death marker) instead of from rawEvents

#### Step 11: DM spell row integration into timeline

- [x] T057 [US1] In DamageMeterService.lua `ImportSession()`, after merging DM spell rows, emit `dm_spell` timeline events for player spell totals with `source = "damage_meter"`
- [x] T058 [US1] In DamageMeterService.lua `ImportSession()`, emit `dm_enemy_spell` timeline events for enemy damage spell rows with per-source metadata

#### Step 12: Cleanup legacy references

- [x] T059 [US1] Remove or update all CLEU-centric comments and naming across CombatTracker.lua, SpellAttributionPipeline.lua, ArenaRoundTracker.lua, and SessionClassifier.lua — replace with provenance-aware terminology
- [x] T060 [US1] Update trace keys in CombatTracker.lua to describe actual sources (`state`, `damage_meter`, `visible_unit`, `inspect`, `loc`, `dr`) instead of CLEU-era names

**Checkpoint**: US1 complete — arena (2v2, 3v3, Solo Shuffle), duel (accepted/canceled), and dummy sessions all create correct sessions with provenance. No CLEU runtime calls. Old sessions load without error. This is the MVP.

---

## Phase 4: User Story 2 — Visually Rich PvP Dashboard (Priority: P1)

**Goal**: Every page has a primary visual. Shared chart primitives. Summary, History, and Detail pages overhauled. All remaining pages get visual treatment.

**Independent Test**: Open each of the 12+ top-level pages and verify each has a primary graphic element above text, a compact takeaway, and a confidence indicator.

### Implementation for User Story 2

#### Step 1: Build chart primitives

- [x] T061 [US2] Create `Sparkline` widget in UI/Widgets.lua: renders a compact dot+line trend using the RatingView pattern (WHITE8x8 textures + vertex coloring), accepts data points array + color + width/height
- [x] T062 [P] [US2] Create `SegmentedBar` widget in UI/Widgets.lua: multi-segment colored bar (e.g., damage/healing/taken split), accepts segments array with {value, color, label}
- [x] T063 [P] [US2] Create `MirroredDeltaBar` widget in UI/Widgets.lua: two-sided bar comparing two values (left vs right), accepts leftValue, rightValue, leftColor, rightColor, label
- [x] T064 [P] [US2] Create `HeatGrid` widget in UI/Widgets.lua: N x M grid of colored cells, accepts rows/cols/data matrix + color ramp function + optional labels
- [x] T065 [P] [US2] Create `TimelineLane` widget in UI/Widgets.lua: single horizontal lane with positioned event markers/bars, accepts events array with {t, duration?, color, tooltip}, total duration, lane height
- [x] T066 [P] [US2] Create `Gauge` widget in UI/Widgets.lua: linear gauge (horizontal bar with value marker + fill), accepts value, min, max, thresholds, color
- [x] T067 [P] [US2] Create `ConfidencePill` widget in UI/Widgets.lua: provenance-aware colored pill extending CreatePill — maps SessionConfidence enum to color + label + tooltip with provenance detail
- [x] T068 [P] [US2] Create `MiniLegend` widget in UI/Widgets.lua: compact horizontal color legend strip, accepts entries array with {color, label}
- [x] T069 [P] [US2] Create `DeltaBadge` widget in UI/Widgets.lua: +/- delta indicator with green (positive) / red (negative) color coding, accepts delta value and format string

#### Step 2: Core page overhauls (P0 pages)

- [x] T070 [US2] Overhaul UI/SummaryView.lua: add hero scorecards (result pill, context chip, duration, ConfidencePill), output split SegmentedBar (damage/healing/taken), top-5 spell contribution bars using CreateSpellRow, and a one-line fight-story strip derived from timelineEvents
- [x] T071 [US2] Overhaul UI/CombatHistoryView.lua: add 20-session Sparkline at top, per-row context chips (arena/duel/dummy), per-row mini MetricBars for duration/confidence/pressure, and context filter toggle buttons (arena-only, duel-only, dummy-only)
- [x] T072 [US2] Overhaul UI/CombatDetailView.lua: replace CLEU-dependent timeline with multi-lane sanctioned timeline using TimelineLane widgets — lanes for player_cast, visible_aura, cc_received, kill_window, death, match_state. Graceful fallback when timelineEvents is empty (show legacy rawEvents if available, or "limited data" message)

#### Step 3: Remaining page visuals (P1 pages)

- [x] T073 [P] [US2] Overhaul UI/OpponentStatsView.lua: replace text dump with top-opponent bar chart (MetricBar), win/loss heat strip (HeatGrid or colored row), last-arena roster cards using CreateSlotRow with ConfidencePill, unresolved-roster warning chip
- [x] T074 [P] [US2] Overhaul UI/ClassSpecView.lua: add class-grouped win-rate bars (MetricBar per class header), spec heat-grid (HeatGrid with fights/WR/pressure/taken columns), click-through affordance to MatchupDetailView
- [x] T075 [P] [US2] Overhaul UI/MatchupDetailView.lua: add MirroredDeltaBars (player avg vs matchup baseline for pressure/damage/CC/deaths), MMR-band trend Sparklines, best-build DeltaBadge, threat/archetype pills
- [x] T076 [P] [US2] Overhaul UI/DummyBenchmarkView.lua: add sustained damage trend Sparkline over time, opener trend Sparkline, consistency band (best/median/worst using SegmentedBar or MirroredDeltaBar), rotation-gap summary Gauge
- [x] T077 [P] [US2] Overhaul UI/SuggestionsView.lua: replace paragraph-heavy layout with ranked issue stack using InsightCard + severity MetricBars, add ConfidencePills per insight, compact fight-story strip, category filter buttons (offense/defense/CC/matchup/consistency)
- [x] T078 [P] [US2] Overhaul UI/CounterGuideView.lua: add threat Gauge per enemy spec, common enemy spell icon row using CreateSpellRow, recommended answer cards, personal WR ConfidencePill, build-aware note strip
- [x] T079 [P] [US2] Overhaul UI/BuildComparatorView.lua: add MirroredDeltaBars for each metric comparison, metric win counter badge ("Build A leads 5/7 metrics"), low-sample DeltaBadge indicator, matchup/spec filter chips using CreatePill
- [x] T080 [P] [US2] Overhaul UI/CleanupView.lua: add sessions-by-context SegmentedBar, storage pressure MetricBar, legacy data footprint indicator, delete-preview panel showing impact before user confirms
- [x] T081 [P] [US2] Add ConfidencePill provenance indicator to UI/RatingView.lua for each session data point on the rating chart
- [x] T082 [P] [US2] Add source legend and provenance ConfidencePill per lane in UI/ReplayView.lua

**Checkpoint**: US2 complete — all 12+ pages have primary graphics above text. Shared chart primitives used consistently. Confidence indicators visible on data-dependent pages.

---

## Phase 5: User Story 3 — Arena Prep Scouting and Between-Round Adaptation (Priority: P2)

**Goal**: Before gates open, show enemy specs, comp archetype, historical WR, and notes. Between Solo Shuffle rounds, show adaptation insights.

**Independent Test**: Enter arena queue, verify scout card appears during prep with enemy specs, comp, and WR data. In Solo Shuffle, verify adaptation card updates between rounds.

### Implementation for User Story 3

- [x] T083 [US3] Create ArenaScoutService.lua: implement `BuildScoutCard(matchRecord, prepOpponents, aggregates)` that computes enemy specs/roles, comp archetype classification (from SeedSpecArchetypes), player's historical WR per spec (from aggregates.specs), and "watch for" notes per spec (from SeedSpellIntelligence threat spells)
- [x] T084 [US3] In ArenaScoutService.lua, implement `BuildAdaptationCard(previousRoundSession, currentPrepState)` for Solo Shuffle between-round advice: extract last-round death cause, highest-pressure slot, healer pressure assessment from the previous round's timelineEvents and slot pressure metrics
- [x] T085 [US3] In ArenaScoutService.lua, implement inspect enrichment: when INSPECT_READY fires during prep, merge inspected PvP talents and build strings into the scout card with `confidence = "inspect"`
- [x] T086 [US3] Create UI/ArenaScoutView.lua: render the scout card as a floating overlay during arena prep — show enemy spec icons/names/roles, comp archetype pill, WR bar per spec, "watch for" notes. Use CreateSlotRow, ConfidencePill, MetricBar from Widgets.lua
- [x] T087 [US3] In UI/ArenaScoutView.lua, add adaptation card panel for Solo Shuffle between-round state: show death cause, pressure source, and matchup reminder using InsightCard widgets
- [x] T088 [US3] Wire ArenaScoutService to CombatTracker.lua: call `BuildScoutCard()` on `ARENA_PREP_OPPONENT_SPECIALIZATIONS` event, show/hide ArenaScoutView during prep phase, hide on PVP_MATCH_ACTIVE
- [x] T089 [US3] Wire adaptation card to ArenaRoundTracker.lua: call `BuildAdaptationCard()` on round end (after session finalization), display between rounds in Solo Shuffle
- [x] T090 [US3] Handle "no prior matches" gracefully in ArenaScoutService.lua: when aggregates have zero sessions for a spec, show "no prior data" text instead of empty or zero WR

**Checkpoint**: US3 complete — scout card appears during prep, adaptation card updates between Solo Shuffle rounds.

---

## Phase 6: User Story 4 — Trade Ledger and Death Recap Analysis (Priority: P2)

**Goal**: Chronological trade ledger showing offensive/defensive/trinket/CC/death sequence per round or duel. Death recap with provenance.

**Independent Test**: Complete arena rounds and duels, verify trade ledger renders chronological trade entries. Deaths explained with provenance.

### Implementation for User Story 4

- [x] T091 [US4] Create TradeLedgerService.lua: implement `BuildTradeLedger(session)` that scans `session.timelineEvents` and classifies each significant event into a TradeLedgerEntry (offensive, defensive, trinket, cc_received, kill_window, death) using SeedSpellIntelligence for spell classification
- [x] T092 [US4] In TradeLedgerService.lua, implement `BuildDeathRecap(session)` that merges `dm_enemy_spell` timeline events (Death Recap rows) with `cc_received` events, last defensive usage, and match state to produce a death explanation with per-field provenance
- [x] T093 [US4] In TradeLedgerService.lua, handle Death Recap unavailability: when no `dm_enemy_spell` events exist, fall back to CC/defensive state only and tag the recap with `confidence = "partial"`
- [x] T094 [US4] Create UI/TradeLedgerView.lua: render trade ledger as a vertical timeline of trade entries — each entry shows timestamp, category icon/color, spell name, target, and outcome. Use TimelineLane for the visual strip and CreateSpellRow for entry details
- [x] T095 [US4] In UI/TradeLedgerView.lua, add death recap card at the bottom when player died — show killing blow, CC state, last defensive, and provenance ConfidencePill
- [x] T096 [US4] Wire TradeLedgerView into UI/CombatDetailView.lua or as a sub-panel: display trade ledger when a finalized session is selected, alongside the multi-lane timeline

**Checkpoint**: US4 complete — trade ledger and death recap render for arena and duel sessions.

---

## Phase 7: User Story 5 — CC & DR Coaching (Priority: P2)

**Goal**: Coaching insights on CC chains, DR waste, and trinket timing from native LOC/DR data.

**Independent Test**: Complete arena sessions with CC interactions, verify CC coach highlights DR waste, late trinkets, and chain analysis.

### Implementation for User Story 5

- [x] T097 [US5] Create CCCoachService.lua: implement `AnalyzeCCChains(session)` that scans `cc_received` and `dr_update` timeline events to identify CC chain lengths per DR category, compute DR waste (successive CC on same category at diminished level), and measure trinket timing relative to CC start
- [x] T098 [US5] In CCCoachService.lua, implement `IdentifyHealerCCWindows(session)` that correlates `cc_received` events on the player with `kill_window` timeline events to detect when healer CC opened kill attempts
- [x] T099 [US5] In CCCoachService.lua, implement `GenerateCCInsights(session)` that produces coaching suggestions: "trinketed at full DR — save for fresh CC", "overlapping CC on same DR category — spread families", "healer CC opened kill window but no burst followed"
- [x] T100 [US5] Integrate CC coaching into SuggestionEngine.lua: add new suggestion reason codes for DR waste, late trinket, and missed CC-to-kill conversion. Wire CCCoachService results into the suggestion generation pipeline
- [x] T101 [US5] Display CC insights in UI/SuggestionsView.lua: show CC-specific InsightCards with DR category labels, chain duration, and trinket timing data

**Checkpoint**: US5 complete — CC coaching insights appear in suggestions for sessions with CC data.

---

## Phase 8: User Story 6 — Opener Lab (Priority: P2)

**Goal**: Aggregate first 3-5 player casts by matchup/spec/build and rank by win rate, pressure, and conversion.

**Independent Test**: Accumulate 10+ sessions, verify opener lab ranks openers by win rate with statistically meaningful differences.

### Implementation for User Story 6

- [x] T102 [US6] Create OpenerLabService.lua: implement `AggregateOpeners(sessions, filters)` that extracts the first 3-5 `player_cast` timeline events from each session, groups by opener spell sequence hash + matchup key (opponent specId) + build hash
- [x] T103 [US6] In OpenerLabService.lua, implement `RankOpeners(openerGroups)` that computes win rate, average pressure score, average opener damage, and kill-window conversion rate per opener group. Require minimum 3 samples for ranking.
- [x] T104 [US6] In OpenerLabService.lua, implement `UpdateOpenerAggregates(session)` called at session finalization to incrementally update `db.aggregates.openers[matchupKey]` with new opener data
- [x] T105 [US6] Add opener lab UI section to UI/SuggestionsView.lua or a dedicated panel: show ranked openers as rows with spell icons, WR MetricBar, sample count DeltaBadge, and matchup/build filter chips
- [x] T106 [US6] Handle insufficient data in OpenerLabService.lua: when < 10 sessions for a matchup, show "not enough data (N sessions)" instead of unreliable rankings

**Checkpoint**: US6 complete — opener lab ranks openers for matchups with sufficient data.

---

## Phase 9: User Story 7 — Duel Lab and Practice Planning (Priority: P3)

**Goal**: Track duel set scores and adaptation trends. Generate concrete practice plans from weak areas.

**Independent Test**: Complete 5+ duels vs same opponent, verify duel lab shows set score and trend. Review weak areas, verify practice suggestions.

### Implementation for User Story 7

- [x] T107 [US7] Create DuelLabService.lua: implement `GroupDuelsByOpponent(sessions)` that groups duel sessions by opponent name or GUID, computes set score (wins/losses), average duration, opener success rate, first-major-go timing, and adaptation trend (improving or declining WR over time)
- [x] T108 [US7] In DuelLabService.lua, implement `UpdateDuelSeriesAggregates(session)` called at duel session finalization to update `db.aggregates.duelSeries[opponentKey]`
- [x] T109 [US7] Add duel lab section to existing UI (UI/CombatHistoryView.lua duel filter or a sub-panel): show per-opponent cards with set score, Sparkline for adaptation trend, opener success MetricBar
- [x] T110 [US7] Create PracticePlannerService.lua: implement `GeneratePracticePlan(aggregates, recentSessions)` that identifies weak areas (poor WR vs spec, low opener conversion, bad trinket timing, inconsistent dummy DPS) and generates PracticeSuggestion entries
- [x] T111 [US7] In PracticePlannerService.lua, generate concrete actions: "10 opener reps on dummy", "5 duels vs spec X", "review last 3 losses vs comp Y", "improve trinket timing in stun chains" — each linked to a specific weak area with evidence
- [x] T112 [US7] Add practice plan display to UI/SuggestionsView.lua: show practice suggestions as actionable InsightCards with category/severity, linking to relevant sessions or matchups

**Checkpoint**: US7 complete — duel lab tracks opponent series, practice planner suggests concrete actions.

---

## Phase 10: User Story 8 — Matchup Memory and Personalized Counter Advice (Priority: P3)

**Goal**: Build per-spec/per-comp memory cards from the player's own history with death patterns, timing norms, and best builds.

**Independent Test**: Accumulate 15+ sessions vs a spec, verify matchup memory card shows personalized patterns and best build.

### Implementation for User Story 8

- [x] T113 [US8] Create MatchupMemoryService.lua: implement `BuildMatchupMemoryCard(specId, sessions)` that analyzes stored sessions for a spec to compute common death patterns, average first-go timing, best-performing build hash, average healer pressure, and top danger spells
- [x] T114 [US8] In MatchupMemoryService.lua, implement `UpdateMatchupMemory(session)` called at session finalization to incrementally update `db.aggregates.matchupMemory[specId]`
- [x] T115 [US8] In MatchupMemoryService.lua, handle insufficient data: when < 15 sessions, return partial card with "building your matchup profile — N more games needed" and fall back to generic archetype advice from SeedSpecArchetypes
- [x] T116 [US8] Add dummy rotation consistency analysis to Utils/Metrics.lua: compute gap histogram (time between casts), proc-window conversion rate, opener variance band (best/worst/median opener damage), and best-vs-median comparison per build hash
- [x] T117 [US8] Update UI/DummyBenchmarkView.lua to display rotation consistency data: show gap histogram as a SegmentedBar, opener variance as MirroredDeltaBar (best vs median), and per-build comparison MetricBars
- [x] T118 [US8] Integrate matchup memory into UI/CounterGuideView.lua: when player faces a spec with 15+ stored sessions, replace generic advice with personalized MatchupMemoryCard data. Show death pattern, timing norm, best build DeltaBadge, and danger spell icons.
- [x] T119 [US8] Add build filter to matchup memory: allow filtering by current build hash so advice reflects the player's current talent configuration

**Checkpoint**: US8 complete — personalized matchup memory cards and dummy consistency analysis available.

---

## Phase 11: Polish & Cross-Cutting Concerns

**Purpose**: Confidence label cleanup, diagnostic tooling, and final validation across all stories.

- [x] T120 Replace all remaining references to old ANALYSIS_CONFIDENCE enum values in UI text strings across all view files (SummaryView, HistoryView, DetailView, etc.) with new SessionConfidence labels in Constants.lua
- [x] T121 Validate schema migration with mixed-version datasets in CombatStore.lua: load a database with v2, v3, v4, v5, and v6 sessions, verify all UI pages render without error
- [x] T122 Implement one-session diagnostic export in CombatTracker.lua: `/ca debug export` slash command that dumps session core fields, match/round identity, slot confidence, DM session IDs, timeline event counts by lane, and provenance map to chat or a SavedVariable export key
- [x] T123 Add manual regression matrix as a hidden developer page or slash command: checklist for arena (2v2 skirmish, 3v3 rated, Solo Shuffle, inspect failure), duel (accepted, canceled, to-the-death), dummy (single target, repeated pulls), general (reload during prep, logout after match, legacy DB)
- [x] T124 [P] Verify chart widget consistency across all pages: confirm Sparkline, SegmentedBar, MirroredDeltaBar, HeatGrid, TimelineLane, Gauge, ConfidencePill, MiniLegend, DeltaBadge share sizing, color semantics, and legend formatting
- [x] T125 [P] Review all pcall-wrapped API calls across ArenaRoundTracker.lua, DamageMeterService.lua, SnapshotService.lua: ensure Death Recap, Enemy Damage Taken, and inspect APIs fail gracefully with provenance indication
- [x] T126 Update CombatAnalytics.toc to include new files in correct load order: TimelineProducer.lua (after Events.lua), ArenaScoutService.lua, TradeLedgerService.lua, CCCoachService.lua, OpenerLabService.lua, DuelLabService.lua, MatchupMemoryService.lua, PracticePlannerService.lua, UI/ArenaScoutView.lua, UI/TradeLedgerView.lua

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 (enums must exist before migration references them)
- **US1 (Phase 3)**: Depends on Phase 2 — BLOCKS all other user stories
- **US2 (Phase 4)**: Depends on US1 (needs timelineEvents for Detail page, provenance for ConfidencePill)
- **US3 (Phase 5)**: Depends on US1 (needs stable arena identity and slot confidence)
- **US4 (Phase 6)**: Depends on US1 (needs timelineEvents and DM Death Recap integration)
- **US5 (Phase 7)**: Depends on US1 (needs cc_received and dr_update timeline events)
- **US6 (Phase 8)**: Depends on US1 (needs player_cast timeline events and opener extraction)
- **US7 (Phase 9)**: Depends on US1 + US6 (needs opener data from US6 for practice planning)
- **US8 (Phase 10)**: Depends on US1 (needs session data and aggregates)
- **Polish (Phase 11)**: Depends on all desired user stories being complete

### User Story Dependencies

- **US1 (P1)**: Foundation — blocks all others
- **US2 (P1)**: Depends on US1 only. Chart primitives (T061-T069) can start once US1 T010-T011 are done (session schema ready)
- **US3 (P2)**: Depends on US1 only (arena identity + slot confidence)
- **US4 (P2)**: Depends on US1 only (timeline events + DM Death Recap)
- **US5 (P2)**: Depends on US1 only (CC/DR timeline events)
- **US6 (P2)**: Depends on US1 only (player_cast timeline events)
- **US7 (P3)**: Depends on US1 + US6 (opener data for practice planner)
- **US8 (P3)**: Depends on US1 only (session aggregates)

### Within User Story 1 (Critical Path)

```
T012 (grep references) → T013-T018 (delete CLEU) → T019-T026 (build producers) → T027-T030 (wire to router)
                                                          ↓
T031-T034 (classifier) → T035-T038 (lifecycle) → T039-T044 (arena slots) → T045-T047 (attribution)
                                                          ↓
T048-T050 (DM Death Recap) → T051-T052 (results/rating) → T053-T058 (provenance + DM timeline) → T059-T060 (cleanup)
```

### Parallel Opportunities

Once US1 is complete, these user stories can run in parallel:

```
US2 (chart widgets + page visuals)  ─┐
US3 (arena scout)                    ─┤── All can start in parallel after US1
US4 (trade ledger)                   ─┤
US5 (CC coach)                       ─┤
US6 (opener lab)                     ─┘

US7 (duel lab + practice) ── After US6
US8 (matchup memory)      ── After US1
```

Within US2, chart primitive tasks (T061-T069) are all parallelizable (different widget functions in same file, no dependencies between them). Page overhaul tasks (T073-T082) are all parallelizable (different files).

---

## Parallel Example: User Story 2 (Chart Primitives)

```
# Launch all chart widget tasks together (different functions, same file but independent):
T062 [P] Create SegmentedBar in UI/Widgets.lua
T063 [P] Create MirroredDeltaBar in UI/Widgets.lua
T064 [P] Create HeatGrid in UI/Widgets.lua
T065 [P] Create TimelineLane in UI/Widgets.lua
T066 [P] Create Gauge in UI/Widgets.lua
T067 [P] Create ConfidencePill in UI/Widgets.lua
T068 [P] Create MiniLegend in UI/Widgets.lua
T069 [P] Create DeltaBadge in UI/Widgets.lua

# Then launch all page overhauls together (different files):
T073 [P] Overhaul OpponentStatsView.lua
T074 [P] Overhaul ClassSpecView.lua
T075 [P] Overhaul MatchupDetailView.lua
T076 [P] Overhaul DummyBenchmarkView.lua
T077 [P] Overhaul SuggestionsView.lua
T078 [P] Overhaul CounterGuideView.lua
T079 [P] Overhaul BuildComparatorView.lua
T080 [P] Overhaul CleanupView.lua
T081 [P] Add confidence to RatingView.lua
T082 [P] Add provenance to ReplayView.lua
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001-T005)
2. Complete Phase 2: Foundational (T006-T011)
3. Complete Phase 3: User Story 1 (T012-T060)
4. **STOP and VALIDATE**: Run the manual regression matrix:
   - 2v2 skirmish → match key created, one session, correct result
   - 3v3 rated → match + rating snapshots, roster stable
   - Solo Shuffle → one match, multiple rounds, correct indices, adaptation card
   - Accepted duel → single session, correct opponent
   - Canceled duel → zero sessions
   - Dummy pull → correct classification, benchmark stored
   - /reload during prep → no corruption
   - Legacy DB → old sessions viewable
5. MVP delivered: reliable Midnight-safe PvP analytics

### Incremental Delivery

1. Setup + Foundational + US1 → **MVP: Correct sessions with provenance**
2. Add US2 → **Visual dashboard: all pages have graphics**
3. Add US3 + US4 + US5 + US6 (parallel) → **PvP features: scout, trade ledger, CC coach, opener lab**
4. Add US7 + US8 → **Advanced: duel lab, matchup memory, practice planner**
5. Polish → **Diagnostic export, regression tooling, final cleanup**

### Single-Developer Sequential Strategy

1. Phase 1 + 2 (setup): ~1 session
2. US1 (correctness): largest block — 49 tasks, sequential dependency chain
3. US2 (visuals): 22 tasks, highly parallelizable within
4. US3-US6 (features): 24 tasks, can interleave
5. US7-US8 (advanced): 13 tasks
6. Polish: 7 tasks

---

## Notes

- [P] tasks = different files or independent functions, no dependencies
- [Story] label maps task to specific user story for traceability
- US1 is the critical path — no shortcuts. Every downstream feature depends on correct sessions.
- WoW addon has no build step — verify correctness by loading in-game
- All restricted API calls must be pcall-wrapped for Midnight safety
- Commit after each logical step group within a user story
- Stop at any checkpoint to validate independently
