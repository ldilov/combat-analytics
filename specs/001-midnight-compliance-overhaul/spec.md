# Feature Specification: Midnight 12.0.1 Compliance Overhaul

**Feature Branch**: `001-midnight-compliance-overhaul`
**Created**: 2026-03-28
**Status**: Draft
**Input**: User description: "Midnight 12.0.1 compliance overhaul — remove CLEU dependency, sanctioned timeline model, visual standardization, new PvP features"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Trustworthy Combat Sessions Without CLEU (Priority: P1)

As a PvP player using CombatAnalytics in WoW Midnight (12.0.1), I want the addon to capture accurate combat data using only sanctioned APIs so that my session history, damage totals, and fight summaries are reliable and never depend on the restricted COMBAT_LOG_EVENT_UNFILTERED event.

**Why this priority**: This is the foundational correctness requirement. Without removing the CLEU runtime dependency and rebuilding data collection around stateful PvP APIs and C_DamageMeter, every downstream feature — analytics, UI, coaching — is built on an unreliable foundation. The addon currently has CLEU-era assumptions baked into CombatTracker, SpellAttributionPipeline, ArenaRoundTracker, and SessionClassifier even though the event router already avoids registering CLEU.

**Independent Test**: Can be fully tested by entering arena, duel, and dummy combat and verifying that sessions finalize with correct totals and no runtime errors, even when C_CombatLog.IsCombatLogRestricted() returns true. Delivers the core value of a reliable PvP analytics addon on Midnight.

**Acceptance Scenarios**:

1. **Given** the addon is loaded in WoW Midnight 12.0.1, **When** CLEU is restricted at runtime, **Then** no production code path attempts to register or read COMBAT_LOG_EVENT_UNFILTERED and all session data is collected from stateful APIs and Damage Meter.
2. **Given** a player enters a 2v2 skirmish arena, **When** the match completes, **Then** one session is persisted with correct damage/healing totals sourced from C_DamageMeter and match state APIs, and every persisted field carries a provenance tag.
3. **Given** a player accepts a duel, **When** the duel finishes, **Then** exactly one session is created with correct opponent identity, result, and duration — no duplicate or phantom sessions.
4. **Given** a player attacks a training dummy, **When** combat ends, **Then** a dummy session is stored with correct dummy identification, and no non-dummy NPC is misclassified.
5. **Given** the addon is loaded with a legacy SavedVariables database from a pre-Midnight schema, **When** the UI opens, **Then** old sessions remain viewable and new sessions use the updated timeline/provenance model without data corruption.

---

### User Story 2 - Visually Rich PvP Dashboard (Priority: P1)

As a PvP player reviewing my combat performance, I want every page in the addon to present information visually with charts, bars, and indicators so that I can understand my performance at a glance without reading walls of text.

**Why this priority**: The current addon has several text-heavy pages (Opponent, Suggestions, Cleanup, parts of Matchup and Specs). The UI gap undermines the value of the analytics engine. Visual standardization is P1 because it directly affects whether users can extract value from the data the addon collects.

**Independent Test**: Can be tested by opening each of the 12+ top-level pages and confirming each has a primary graphic element above the fold, a compact text takeaway, and a confidence/provenance indicator where applicable.

**Acceptance Scenarios**:

1. **Given** the Summary page is opened after a fight, **When** the user views it, **Then** hero scorecards, an output split bar (damage/healing/taken), top-spell contribution bars, and a fight-story strip are visible — the fight is understandable in under 5 seconds.
2. **Given** the History page shows recent sessions, **When** the user scans the list, **Then** each row includes a results sparkline, context chips, and mini-bars for duration and confidence — trends are scannable without opening each session.
3. **Given** the Detail page is opened for a session captured in Midnight-safe mode, **When** rawEvents are empty, **Then** a multi-lane sanctioned timeline renders player casts, aura windows, CC received, and match-state markers from the new timeline model.
4. **Given** any top-level page is opened (Summary, History, Detail, Opponent, Specs, Matchup, Dummy, Rating, Insights, Counters, Builds, Cleanup), **When** data is available, **Then** that page contains at least one graphic element above text content.

---

### User Story 3 - Arena Prep Scouting and Between-Round Adaptation (Priority: P2)

As an arena player, I want to see enemy spec/comp information, my historical win rate, and tactical notes before gates open and between Solo Shuffle rounds so that I can plan my strategy using data I have already collected.

**Why this priority**: Arena prep scouting and between-round adaptation are the highest-value new features because they directly impact real-time competitive decision-making. They depend on stable arena identity (P1 correctness) being correct first.

**Independent Test**: Can be tested by entering arena queue, observing the scout card during prep phase, and verifying it shows enemy specs, comp archetype, and personal win-rate data. Between Solo Shuffle rounds, the adaptation card should update with last-round insights.

**Acceptance Scenarios**:

1. **Given** a player joins a rated 3v3 arena, **When** the prep phase starts (before gates open), **Then** a scout card appears showing enemy specs, roles, likely comp archetype, the player's historical win rate vs those specs, and "watch for" notes per spec.
2. **Given** a Solo Shuffle match is in progress, **When** a round ends and the next round's prep begins, **Then** an adaptation card shows what killed the player last round, which enemy slot applied most pressure, and one matchup reminder.
3. **Given** inspect data becomes available during prep, **When** PvP talents or build strings are obtained, **Then** the scout card enriches with the inspected data and marks those fields as "inspect-confirmed."
4. **Given** the player has no historical data against a spec, **When** the scout card renders, **Then** it shows "no prior matches" rather than fabricating a win rate.

---

### User Story 4 - Trade Ledger and Death Recap Analysis (Priority: P2)

As a PvP player analyzing a loss, I want a chronological trade ledger showing who pressed offensive/defensive cooldowns first, when trinkets were used, when CC was received, and how the death happened so that I can identify what went wrong.

**Why this priority**: Understanding the sequence of trades is the core analytical value proposition for PvP improvement. This requires the sanctioned timeline model (P1 correctness) to be in place and accurate.

**Independent Test**: Can be tested by completing an arena round or duel, opening the session detail, and verifying the trade ledger renders chronological entries for offensives, defensives, trinket uses, CC received, kill windows, and death context.

**Acceptance Scenarios**:

1. **Given** a completed arena round, **When** the trade ledger is opened, **Then** it displays a chronological sequence of the player's major offensives, defensives, trinket usage, CC received, and kill-window markers.
2. **Given** the player died during a round, **When** the death recap coach card is rendered, **Then** it merges CC state, recent defensive usage, and match state to explain the death with provenance — and never with fabricated enemy timelines.
3. **Given** Death Recap spell rows are unavailable from C_DamageMeter, **When** the death recap card renders, **Then** it falls back gracefully to CC/defensive state only and indicates limited data provenance.
4. **Given** a duel ends, **When** the trade ledger is viewed, **Then** the ledger shows the same chronological trade sequence appropriate for a 1v1 context.

---

### User Story 5 - CC & DR Coaching (Priority: P2)

As a PvP player, I want coaching insights on my crowd control chains, diminishing returns usage, and trinket timing so that I can identify when I wasted DR, trinketed too late, or missed a kill window due to poor CC coordination.

**Why this priority**: CC management is one of the highest-skill areas in WoW PvP. Native DR and LOC APIs in Midnight provide rich CC data that the addon can leverage without CLEU.

**Independent Test**: Can be tested by completing arena sessions with CC interactions, then reviewing CC coach insights that highlight DR waste, late trinkets, and overlong chains.

**Acceptance Scenarios**:

1. **Given** a completed arena session with CC interactions, **When** the CC coach card renders, **Then** it shows CC chain lengths, DR category waste, and trinket timing relative to CC duration.
2. **Given** a session where the player trinketed a full-DR stun, **When** coaching insights generate, **Then** a suggestion highlights the DR waste and recommends saving trinket for fresh CC.
3. **Given** a healer was CC'd and a kill window opened, **When** the trade ledger and CC coach analyze the round, **Then** the addon identifies the healer-CC-to-kill-attempt correlation.

---

### User Story 6 - Opener Lab (Priority: P2)

As a PvP player, I want to see which opening sequences have historically led to wins across different matchups and builds so that I can optimize my opener for each situation.

**Why this priority**: Openers set the pace of arena matches. Aggregating first 3-5 casts by matchup, spec, and build provides actionable data with relatively low complexity.

**Independent Test**: Can be tested by accumulating 10+ sessions and viewing the opener lab, verifying it ranks openers by win rate, pressure, and damage for the player's spec/matchup combinations.

**Acceptance Scenarios**:

1. **Given** 10+ arena sessions are stored for a spec matchup, **When** the opener lab is opened, **Then** it aggregates the first 3-5 player casts and ranks openers by win rate, pressure, and conversion.
2. **Given** the player uses different builds, **When** the opener lab filters by build hash, **Then** openers are separated by build and compared.
3. **Given** insufficient data for a matchup, **When** the opener lab renders, **Then** it shows "not enough data" with a sample count rather than unreliable rankings.

---

### User Story 7 - Duel Lab and Practice Planning (Priority: P3)

As a player who regularly duels specific opponents or practices on dummies, I want to track my set score, adaptation trends, rotation consistency, and receive suggested practice routines so that I can improve systematically.

**Why this priority**: Duel and dummy practice features add depth but are not core to the competitive arena workflow. They build on the corrected session lifecycle and visual framework from earlier priorities.

**Independent Test**: Can be tested by completing multiple duels against the same opponent and multiple dummy pulls, then reviewing duel lab stats (set score, adaptation trend) and dummy consistency charts (gap histogram, variance band).

**Acceptance Scenarios**:

1. **Given** 5+ duels against the same opponent, **When** the duel lab is opened, **Then** it groups sessions by opponent and shows set score, average duration, opener success, and adaptation trend.
2. **Given** multiple dummy pulls over several days, **When** the dummy benchmarks page is viewed, **Then** trend lines for sustained damage and openers show improvement over time, with a consistency band (best/median/worst).
3. **Given** weak areas identified from recent sessions, **When** the practice planner generates suggestions, **Then** it produces concrete actions like "10 opener reps on dummy" or "review last 3 losses vs comp Y."
4. **Given** a duel request is sent but canceled before acceptance, **When** checking stored sessions, **Then** no session was persisted for the canceled duel.

---

### User Story 8 - Matchup Memory and Personalized Counter Advice (Priority: P3)

As a PvP player facing a familiar spec or comp, I want personalized matchup memory cards built from my own history showing common death patterns, danger windows, and best-performing builds so that counter advice is specific to my playstyle.

**Why this priority**: Personalized matchup memory elevates the addon from generic advice to tailored coaching. It depends on sufficient historical data and stable aggregate infrastructure.

**Independent Test**: Can be tested by accumulating 15+ sessions against a specific spec, then viewing the matchup memory card with personal death patterns, first-go timing norms, and best-build recommendations.

**Acceptance Scenarios**:

1. **Given** 15+ sessions against a specific spec, **When** the matchup memory card renders, **Then** it shows the player's common death pattern, first-go timing norm, best-performing build, and average healer pressure for that matchup.
2. **Given** insufficient data for a spec matchup, **When** the counter guide renders, **Then** it falls back to generic archetype advice and clearly indicates "building your matchup profile — N more games needed."
3. **Given** the player's build has changed, **When** viewing matchup memory, **Then** results are filterable by build so that advice reflects current talent configuration.

---

### Edge Cases

- What happens when the player /reloads during arena prep? The current match shell must survive or reset cleanly without corrupting the SavedVariables database.
- What happens when a player logs out mid-match? The partially finalized session must persist validly and not corrupt subsequent sessions on next login.
- What happens when C_DamageMeter returns zero sessions for a completed fight? The session should finalize with explicit "damage_meter_unavailable" provenance and degrade gracefully rather than showing false zeros.
- What happens when arena slot visibility changes mid-round (e.g., stealth/vanish)? Slot identity must remain stable — the roster signature must not change just because a unit token became unavailable.
- What happens when Solo Shuffle ends early due to a leaver? The addon must handle partial matches, persisting completed rounds and marking incomplete rounds appropriately.
- What happens when the player duels near training dummies? The session classifier must not misidentify a duel opponent as a training dummy or vice versa.
- What happens when two matches queue back-to-back with no delay? Match identity must reset cleanly; the previous match's data must not bleed into the new match.
- What happens when inspect fails or times out during arena prep? The scout card should show prep-sourced data and mark inspect fields as "unavailable," never silently treating missing inspect data as confirmed.
- What happens when the SavedVariables database contains sessions from multiple schema versions? Schema migration must handle mixed-version data, keeping old sessions viewable while adding new fields to new sessions.
- What happens when Damage Meter categories (Enemy Damage Taken, Death Recap) are unavailable in the current client build? Features depending on those categories must fall back gracefully and indicate limited provenance rather than crashing or showing fabricated data.

## Requirements *(mandatory)*

### Functional Requirements

#### A. Correctness — Foundation

- **FR-001**: System MUST NOT register, call, or rely on `COMBAT_LOG_EVENT_UNFILTERED` for any production data collection. Legacy CLEU-only functions must be removed or fenced behind a non-loaded development-only flag.
- **FR-002**: System MUST derive all session analytics exclusively from stateful PvP APIs and Damage Meter APIs. The sanctioned source list is: `PLAYER_REGEN_DISABLED/ENABLED`, `PVP_MATCH_*`, `DUEL_*`, `ARENA_PREP_OPPONENT_SPECIALIZATIONS`, `ARENA_OPPONENT_UPDATE`, `UNIT_SPELLCAST_SUCCEEDED`, `UNIT_AURA`, `UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED`, `LOSS_OF_CONTROL_*`, `PLAYER_CONTROL_*`, `DAMAGE_METER_*` events, and `C_DamageMeter.*` APIs.
- **FR-003**: System MUST replace the CLEU-shaped `rawEvents` model with a sanctioned timeline schema. Each timeline event must carry: timestamp offset, lane classification (player_cast, visible_aura, cc_received, kill_window, match_state, inspect, dm_checkpoint), spell/ability reference, provenance source, and confidence level (confirmed, partial, or estimated).
- **FR-004**: System MUST produce timeline entries from these sources: player casts via `UNIT_SPELLCAST_SUCCEEDED`, aura windows via `UNIT_AURA`, CC/LOC windows via native PvP APIs, arena round markers from match/round state, Damage Meter import milestones, and inspect completion markers.
- **FR-005**: Sessions MUST start from `PLAYER_REGEN_DISABLED` plus resolved context and MUST NOT finalize until a configurable Damage Meter stabilization delay has elapsed. Finalization must be idempotent and safe if multiple state events fire close together.
- **FR-006**: System MUST NOT create duplicate sessions for a single combat encounter (duel, round, or dummy pull).
- **FR-007**: Arena match identity MUST be established before combat from queue/match/prep signals and MUST remain stable across all rounds in Solo Shuffle and other multi-round formats.
- **FR-008**: Arena round identity MUST be keyed by match key + round index + finalized roster signature. Prep specs seed the roster; visible arena-unit data refines without destroying round continuity.
- **FR-009**: Arena slot records MUST track field-level confidence: prep-only, visible-confirmed, inspect-confirmed, or imported/post-combat-only.
- **FR-010**: Arena results (win/loss/draw) MUST be resolved from PvP match state APIs, not inferred from damage. Rated sessions MUST store before/after rating snapshots when exposed by the client; when unavailable, store an explicit missing-reason.
- **FR-011**: Duel sessions MUST be driven by `DUEL_*` state events. Canceled or expired duel requests MUST NOT create stored sessions. Duel-to-the-death MUST be stored as a distinct subcontext.
- **FR-012**: Training dummy sessions MUST require combat start plus positive dummy identification by creature ID or seeded name. Non-dummy NPCs MUST never be misclassified as dummy practice.
- **FR-013**: Player spell usage MUST come from `UNIT_SPELLCAST_SUCCEEDED`, player-unit aura windows, and Damage Meter spell rows. Enemy spell usage MUST only be stored when exposed through sanctioned APIs (Enemy Damage Taken rows, Death Recap rows, visible CC/LOC APIs, inspect-derived metadata).
- **FR-014**: System MUST NOT create hidden-looking enemy cast timelines from unavailable data. Estimated enemy spell data may support coaching text but MUST be visually distinct from confirmed spell data.
- **FR-015**: Every persisted field that is not trivially derived MUST carry a provenance source from the provenance enum: `state`, `damage_meter`, `visible_unit`, `inspect`, `loss_of_control`, `spell_diminish`, `estimated`, `legacy_import`.
- **FR-016**: System MUST be re-entrant safe during login, reload, match transitions, and logout. A /reload during arena prep or combat MUST NOT corrupt match identity or SavedVariables.

#### B. Correctness — Confidence and Migration

- **FR-017**: System MUST replace CLEU-centric confidence labels with provenance-centric labels: `state_plus_damage_meter`, `damage_meter_only`, `visible_cc_only`, `partial_roster`, `estimated`, `legacy_cleu_import`.
- **FR-018**: Arena slot records MUST persist when each field was learned, which API produced it, and whether it is confirmed or provisional.
- **FR-019**: SavedVariables migrations MUST preserve existing sessions while adding new timeline, provenance, and confidence fields. Old sessions MUST remain viewable. Mixed-schema datasets MUST NOT crash any UI view.
- **FR-020**: System MUST provide a one-session diagnostic export containing: session core fields, match/round identity, slot confidence, import candidate scoring, chosen Damage Meter session IDs, and timeline event counts by source.

#### C. UI — Visual Standards

- **FR-021**: Every top-level page MUST contain at least one primary graphic element above text content, one compact written takeaway, and one confidence/provenance indicator when the page depends on limited data.
- **FR-022**: System MUST provide reusable chart widget primitives: Sparkline, SegmentedBar, MirroredDeltaBar, HeatGrid, TimelineLane, Gauge, ConfidencePill, MiniLegend, and DeltaBadge. All charts MUST share consistent sizing, legends, and color semantics.
- **FR-023**: Summary page MUST display hero scorecards (result, context, duration, confidence), an output split bar (damage/healing/taken), top-spell contribution bars, and a one-line fight-story strip.
- **FR-024**: History page MUST display a recent-results sparkline, context chips per row, mini-bars for duration/confidence/pressure/result per row, and context-filter toggles (arena-only, duel-only, dummy-only).
- **FR-025**: Detail page MUST render a multi-lane sanctioned timeline with lanes for player casts, visible aura windows, CC received, kill windows, death markers, and match-state markers. The view MUST degrade gracefully when rawEvents are empty.

#### D. UI — Page-Level Visuals

- **FR-026**: Opponent Analysis page MUST show top-opponent bar charts, win/loss heat strip, last-arena roster cards with slot confidence, and unresolved-roster warning chips.
- **FR-027**: Class/Spec page MUST use class-grouped win-rate bars, a spec heat-grid (fights, win rate, average pressure, average damage taken), and clear click-through affordance to Matchup Detail.
- **FR-028**: Matchup Detail page MUST show mirrored bars (player average vs matchup baseline), MMR-band trend strips, best-build badge, and threat/archetype pills.
- **FR-029**: Dummy Benchmarks page MUST add trend lines for sustained damage and openers over time, consistency bands (best/median/worst), and rotation-gap summary graphics.
- **FR-030**: Insights page MUST render a ranked issue stack with severity bars, confidence pills, a compact fight-story strip, and category filters (offense/defense/CC/matchup/consistency).
- **FR-031**: Counter Guide page MUST show threat gauge, common enemy spell icons, recommended answer cards, and personal win-rate confidence chip.
- **FR-032**: Build Comparator page MUST use mirrored delta bars, a metric win counter, low-sample indicator, and matchup/spec filter chips.
- **FR-033**: Cleanup page MUST show sessions-by-context distribution, storage pressure bars, and a preview of deletion impact before the user confirms.

#### E. New PvP Features — Core

- **FR-034**: System MUST display an Arena Prep Scout card before gates open showing enemy specs, roles, likely comp archetype, the player's historical win rate vs those specs, and "watch for" notes. The scout card MUST use only sanctioned sources (prep events, inspect APIs, stored aggregates).
- **FR-035**: System MUST render a Trade Ledger after each arena round or duel showing a chronological sequence of major offensives, defensives, trinket usage, CC received, kill windows, and death context.
- **FR-036**: System MUST provide CC & DR coaching using native DR and LOC data to analyze CC chain length, DR waste, trinket timing, CC received by family, and healer-CC windows that opened kill attempts.
- **FR-037**: System MUST aggregate the first 3-5 player casts per matchup/spec/build in an Opener Lab and rank openers by win rate, pressure, opener damage, and conversion into kill windows.
- **FR-038**: System MUST display a Between-Round Solo Shuffle Adaptation card during prep between rounds showing last-round death cause, highest-pressure enemy slot, healer pressure assessment, and matchup reminders — using only prior-round stored data and current prep state.
- **FR-039**: System MUST provide a Death Recap Coach that merges Death Recap and enemy spell rows from C_DamageMeter (when available) with CC state, defensive usage, and match state. When Death Recap data is unavailable, the feature MUST fall back gracefully with clear provenance indication.

#### F. New PvP Features — Advanced

- **FR-040**: System MUST provide a Duel Lab that groups duel sessions by opponent, showing set score, average duration, opener success, first-major-go timing, and adaptation trend.
- **FR-041**: System MUST provide Dummy Rotation Consistency analysis showing gap histogram, proc-window conversion, opener variance band, and best-vs-median comparison per build.
- **FR-042**: System MUST build personalized Matchup Memory cards from the player's stored history showing common death patterns, first-go timing norms, best-performing builds, and common enemy threat patterns per spec/comp.
- **FR-043**: System MUST generate a Practice Planner with concrete suggested actions (e.g., "10 opener reps on dummy," "5 duels vs spec X," "review last 3 losses vs comp Y") based on identified weak areas.

### Key Entities

- **Combat Session**: A single discrete combat encounter (one arena round, one duel, one dummy pull) containing timeline events, spell aggregates, aura data, cooldown data, totals, metrics, and provenance metadata. Linked to a match (for arena) or standalone (for duels/dummies).
- **Timeline Event**: A timestamped record within a session carrying lane classification, spell/ability reference, provenance source, and confidence level. Replaces the legacy rawEvents model.
- **Arena Match**: A lobby-level container grouping multiple rounds (especially for Solo Shuffle). Contains match key, map, bracket, context/subcontext, joined timestamp, and rating snapshots.
- **Arena Round**: A single round within a match, identified by match key + round index + roster signature. Contains per-slot enemy data with field-level confidence.
- **Arena Slot**: A single enemy position in an arena match containing identity (GUID, name, class, spec), prep data, inspect data, DR state, pressure metrics, and per-field confidence tracking.
- **Provenance Record**: Metadata attached to persisted fields indicating which API or source produced the value and whether it is confirmed, partial, or estimated.
- **Damage Meter Snapshot**: A point-in-time capture from C_DamageMeter APIs providing session totals, source breakdowns, and spell rows. Linked to combat sessions via import matching.
- **Matchup Memory Card**: An aggregate record built from the player's history for a specific spec or comp, containing death patterns, timing norms, build effectiveness, and personalized counter advice.
- **Trade Ledger Entry**: A chronological record of a major offensive, defensive, trinket use, CC event, or kill-window marker within a session, used for post-fight analysis.
- **Practice Plan**: A generated set of concrete practice actions derived from identified weak areas, linking to specific matchups, specs, or skills to improve.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The addon produces zero runtime errors related to CLEU access across 100 consecutive arena, duel, and dummy sessions on WoW Midnight 12.0.1.
- **SC-002**: 100% of new combat sessions carry provenance tags on every non-trivial persisted field, allowing a user to determine data origin from the UI.
- **SC-003**: Arena sessions in Solo Shuffle produce exactly one session per round with correct round indices and no round-to-round data leakage across 20 consecutive Solo Shuffle lobbies.
- **SC-004**: Users can understand the latest fight summary in under 5 seconds based on visual elements alone (hero scorecard, output bars, fight story strip) without reading detailed text.
- **SC-005**: All 12+ top-level pages contain at least one primary graphic above text content — zero text-only pages remain.
- **SC-006**: Canceled duel requests produce zero stored sessions across 20 consecutive cancel/accept test cycles.
- **SC-007**: Training dummy sessions achieve 100% correct classification — zero non-dummy NPCs are misidentified as dummies across 50 varied PvE target encounters.
- **SC-008**: Legacy SavedVariables databases (schema v2) load without errors and old sessions remain viewable after migration to the new schema.
- **SC-009**: The Arena Prep Scout card appears within 1 second of the prep phase starting, showing enemy specs and historical win rate data.
- **SC-010**: The Between-Round Adaptation card updates between Solo Shuffle rounds within 2 seconds of the round transition, using only prior-round and prep data.
- **SC-011**: The Trade Ledger renders a complete chronological trade sequence for 95%+ of arena rounds where player cast and CC data is available.
- **SC-012**: The CC & DR Coach identifies trinket timing relative to CC duration and DR waste in sessions where native DR/LOC data is captured.
- **SC-013**: Opener Lab rankings are stable and actionable when 10+ sessions exist for a matchup, showing statistically meaningful win-rate differences between opener patterns.
- **SC-014**: A /reload during arena prep or mid-combat does not corrupt match identity or SavedVariables — the addon recovers cleanly in 100% of reload test cases.
- **SC-015**: Chart widgets (Sparkline, SegmentedBar, MirroredDeltaBar, etc.) maintain consistent sizing, color semantics, and legend formatting across all pages where they appear.

## Assumptions

- The addon targets WoW Midnight 12.0.1 (Interface 120001) exclusively; backward compatibility with pre-Midnight clients is not required for new features.
- `C_DamageMeter` APIs (GetAvailableCombatSessions, GetCombatSessionFromID, GetCombatSessionSourceFromID) are available and functional in the target client version.
- `UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED` and `C_PvP.GetArenaCrowdControlInfo()` remain sanctioned arena-safe sources in 12.0.1.
- Patch 12.0.1 Enemy Damage Taken and Death Recap categories in Damage Meter may not be universally available; features depending on them include graceful fallbacks.
- The existing UI framework (MainFrame with tabbed pages, Widgets.lua theming) provides sufficient infrastructure for new chart primitives without requiring a UI framework replacement.
- Inspect APIs (`NotifyInspect`, `INSPECT_READY`, `C_Traits.GenerateInspectImportString`, `C_SpecializationInfo.GetInspectSelectedPvpTalent`) are available out-of-combat during arena prep.
- The addon's existing seed data (SeedSpecArchetypes, SeedSpellIntelligence, SeedArenaControl, SeedDummyCatalog) is sufficient for comp archetype classification and spell categorization; new seed data may be added incrementally.
- SavedVariables schema migration from v2 to v3 is a one-way migration; downgrading back to v2 is not supported.
- The Damage Meter stabilization delay is configurable but defaults to a reasonable value (1-2 seconds after combat end) to allow final snapshots to settle.
- World PvP session tracking is not the focus of this overhaul; GENERAL and WORLD_PVP contexts are supported at current fidelity but not enhanced.
- Social features (session export, wargame detection, party sync) are explicitly out of scope for this specification and deferred to a future phase.
