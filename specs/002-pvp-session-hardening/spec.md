# Feature Specification: Midnight PvP Session Reliability Hardening

**Feature Branch**: `002-pvp-session-hardening`
**Created**: 2026-03-28
**Status**: Draft
**Input**: User description: "Harden PvP session capture reliability on WoW Midnight without CLEU: fix wrong/missing opponent identity, fix wrong Damage Meter session matching, fix stale finalization order, and fix rated snapshot timing race."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Correct Primary Opponent After Arena Match (Priority: P1)

After an arena match (rated 2v2, 3v3, or Solo Shuffle), the player opens the Combat History tab and sees the correct enemy player listed as the primary opponent for that session. The opponent name, class, and specialization match the actual enemy the player fought, not a random slot or placeholder.

**Why this priority**: Wrong opponent identity is the most visible and most frequently reported failure. Every downstream feature (matchup memory, coaching suggestions, win-rate tracking, strategy cards) depends on correct opponent identity. When the wrong opponent is shown, the player loses trust in the entire addon.

**Independent Test**: Can be fully tested by completing a rated arena match and verifying the session's primary opponent name/class/spec in the History tab. Delivers immediate value by making match history trustworthy.

**Acceptance Scenarios**:

1. **Given** a rated 3v3 arena match where three enemy players are visible during the prep phase, **When** the match concludes and the session is finalized, **Then** the session's primary opponent is the enemy who dealt the most damage to the player (not simply the first visible slot or the last-seen slot).

2. **Given** a Solo Shuffle match with six consecutive rounds where the same three enemies appear but the highest-pressure enemy changes between rounds, **When** each round's session is finalized, **Then** the primary opponent for each round reflects that round's actual highest-pressure enemy, not the opponent from the previous round carried over by inertia.

3. **Given** an arena match where the previously identified primary opponent and the actual highest-pressure enemy have nearly identical pressure scores (within 15% of each other), **When** the session is finalized, **Then** the system retains the previously identified opponent rather than flapping to a marginally higher scorer, providing stable identity across rounds.

4. **Given** an arena match where one enemy was briefly visible but then their unit token dropped (e.g., stealth, line-of-sight), **When** the session is finalized, **Then** the system still considers that enemy's damage contribution to the player and does not simply ignore them because they became invisible.

5. **Given** an arena match where no enemy meaningfully damages the player (e.g., the match ends in under 5 seconds), **When** the session is finalized, **Then** the system falls back to the most recently visible enemy slot rather than showing "Unknown", and the selection strategy is recorded as a deterministic fallback.

---

### User Story 2 - Correct Damage Meter Session Imported (Priority: P1)

After any PvP session (arena, duel, world PvP), the addon imports the correct historical Damage Meter session from the game client. The imported damage totals, spell breakdowns, and enemy source data correspond to the actual combat encounter, not a stale or adjacent session from a different fight.

**Why this priority**: Damage Meter import is the primary sanctioned data source on Midnight (CLEU is forbidden). If the wrong session is imported, all damage totals, spell breakdowns, pressure scores, and coaching suggestions are wrong. This is an equally critical failure mode to wrong opponent identity.

**Independent Test**: Can be fully tested by completing two back-to-back arena rounds with different opponents and verifying each session's damage totals and enemy source data match the correct round. Delivers value by ensuring all numeric analytics are accurate.

**Acceptance Scenarios**:

1. **Given** two consecutive arena rounds (Solo Shuffle) with similar duration and similar total damage, **When** the addon selects a Damage Meter candidate for the second round, **Then** the candidate whose enemy source GUIDs overlap the known arena roster for that round scores higher than a candidate from the first round whose GUIDs do not overlap.

2. **Given** a duel followed immediately by a world PvP encounter, **When** the addon selects a Damage Meter candidate for the duel session, **Then** the candidate with exactly one enemy source is preferred over a candidate with multiple enemy sources, matching the expected duel context.

3. **Given** a candidate Damage Meter session that has zero GUID overlap with the addon's known enemy roster, **When** the candidate is scored, **Then** the candidate receives an explicit penalty that makes it less likely to be selected, even if its duration and damage totals look superficially reasonable.

4. **Given** a candidate Damage Meter session whose duration differs from the combat session by more than 15 seconds, **When** the candidate is scored, **Then** the candidate receives an additional duration-mismatch penalty.

5. **Given** an arena session where the addon's expected bracket size is 3 (3v3), **When** candidates are evaluated, **Then** a candidate with exactly 3 enemy sources receives a context-fit bonus, while a candidate with 1 or 5 enemy sources does not.

---

### User Story 3 - Downstream Analytics Use Hardened Opponent Data (Priority: P2)

When the session is finalized, all downstream analytics (metrics computation, coaching suggestions, classifier sync, matchup memory) operate on the hardened and evidence-enriched opponent identity, not on a placeholder or stale first-hit target.

**Why this priority**: Even if opponent selection is improved, the benefit is lost if downstream systems read the opponent data before the hardened selection is applied. Correct ordering ensures the entire analytics pipeline benefits from improved identity.

**Independent Test**: Can be tested by completing an arena match, then inspecting the session's metrics, suggestions, and matchup data to confirm they reference the same opponent shown in the History tab. Delivers value by ensuring coaching recommendations and win-rate data are based on the right opponent.

**Acceptance Scenarios**:

1. **Given** an arena session where the arena round tracker identifies a different primary opponent than the initial placeholder (first-hit target), **When** the session is finalized, **Then** the metrics (pressure score, burst score, survivability) are computed against the hardened primary opponent, not the placeholder.

2. **Given** an arena session, **When** coaching suggestions are generated, **Then** the suggestions reference the same opponent that appears in the History tab and in the session's primary opponent field.

3. **Given** an arena session where the session classifier syncs identity from the primary opponent, **When** classifier sync runs, **Then** it uses the arena-exported opponent (from the round tracker) rather than the initial target-based placeholder.

---

### User Story 4 - Rated Snapshot Survives Late Session Creation (Priority: P2)

When the player enters a rated arena match, the pre-match rating snapshot (personal rating, best season rating, games played/won) is captured and persisted on the session even if the combat session is created after the match-active event fires.

**Why this priority**: Rating progression tracking is a core feature for competitive players. Missing the "before" snapshot means the addon cannot compute rating deltas after the match, which makes the rating chart and progression tracking unreliable.

**Independent Test**: Can be tested by entering a rated arena match (where the match-active event fires before the combat session starts) and verifying the session contains a valid rating snapshot with personal rating data. Delivers value by making rating progression tracking reliable.

**Acceptance Scenarios**:

1. **Given** a rated arena match where the match-active event fires before the combat session is created, **When** the combat session is eventually created (e.g., on first damage event), **Then** the session inherits the rating snapshot that was captured at match-active time.

2. **Given** a rated arena match where the session already exists when the match-active event fires, **When** the rating snapshot is captured, **Then** the session's before-match rating is populated directly as before (no regression).

3. **Given** an unrated arena match, **When** the session is finalized, **Then** the session carries a rating snapshot with a missing-reason of "not rated" rather than a nil or absent field.

4. **Given** a rated arena match where the rating data source is temporarily unavailable, **When** the snapshot is attempted, **Then** the session carries a rating snapshot with a missing-reason of "API unavailable" rather than silently omitting the field.

---

### User Story 5 - Selection Diagnostics Are Inspectable (Priority: P3)

When the addon selects a primary opponent or imports a Damage Meter session, diagnostic information about why that choice was made is persisted on the session. This allows the addon developer and advanced users to inspect and debug heuristic misfires after the fact, without needing live trace logs.

**Why this priority**: Even with improved heuristics, edge cases will still produce wrong results. Persisted diagnostics reduce the feedback loop for identifying and fixing misfires from "reproduce the exact scenario with trace logging enabled" to "inspect the stored session data."

**Independent Test**: Can be tested by completing an arena match, then examining the session's saved data (via debug export or SavedVariables inspection) to confirm selection diagnostics are present. Delivers value by making the addon self-diagnosing.

**Acceptance Scenarios**:

1. **Given** an arena session that has been finalized, **When** the session's primary opponent selection metadata is inspected, **Then** it contains a strategy label (e.g., "highest score", "preferred GUID sticky"), the selected slot index, the final score, per-component evidence (damage to player, death recap contribution, identity bias, visibility bias), and the preferred GUID that was considered.

2. **Given** a Damage Meter import that selected a historical candidate, **When** the session's import metadata is inspected, **Then** it contains the opponent fit score and enemy source count for the selected candidate.

3. **Given** a session where no pressure evidence was available (e.g., attribution data was empty), **When** the opponent selection falls back to visibility/recency, **Then** the selection strategy label reflects the fallback (e.g., "latest visible" or "no visible slot") rather than appearing as a confident score-based selection.

---

### Edge Cases

- **All arena slots have zero pressure evidence**: When no attribution data and no death recap events are present, the system falls back to visibility, then recency, then lowest slot index as a deterministic tie-breaker, and records the fallback strategy on the session.

- **No Damage Meter candidate sessions exist**: When the game client provides no historical Damage Meter sessions for import, the existing cached-snapshot and current-session fallback paths continue to operate, now with the additional opponent fit diagnostics recorded.

- **Same enemy GUID appears in multiple arena slots**: In edge cases from unit-token reuse, the GUID-to-slot lookup uses the indexed mapping first, then falls back to a linear scan, returning the first matching slot.

- **Player's own GUID appears in an arena slot**: During arena transition states, a slot may temporarily contain the local player's GUID. The selection explicitly excludes any slot whose GUID matches the local player.

- **Session has no attribution data at all**: When attribution is absent (empty or not computed), pressure hydration safely skips the attribution step, slot scores remain at zero, and selection proceeds on visibility/recency fallback.

- **Duration mismatch scoring with zero-duration session**: The duration mismatch penalty only applies when the combat session has a non-zero duration, preventing false penalization of brand-new or instant sessions.

- **Duel where player untargets opponent before combat**: The pending duel metadata (opponent name from the duel-requested event) is persisted on the session and used as a last-resort fallback for opponent name resolution.

- **Rating snapshot capture when API returns no data**: The system records a specific missing-reason rather than leaving the rating snapshot absent. Downstream systems check for the missing-reason field to distinguish "no data available" from "data was never requested."

- **Solo Shuffle with stealth-heavy composition**: Some enemies may never be visible via unit tokens. Their damage contribution is still captured through attribution data (from the Damage Meter import), so they participate in pressure scoring even without visibility.

- **Extremely short arena round (under 5 seconds)**: When the round ends before meaningful pressure data accumulates, the system degrades to visibility/recency selection and records the fallback. No error is produced.

## Requirements *(mandatory)*

### Functional Requirements

#### Arena Opponent Selection

- **FR-001**: The system MUST rebuild arena slot pressure scores from post-session evidence (incoming enemy damage attribution and death recap timeline data) before exporting arena state to the session.

- **FR-002**: The system MUST reset all derived selection fields (damage-to-player, kill participation, selection score, selection evidence) at the start of each pressure rebuild to prevent stale values from previous exports or partial state transitions.

- **FR-003**: The system MUST hydrate each arena slot's incoming-damage pressure from the session's enemy-source attribution data, mapping each enemy source GUID to its corresponding arena slot and accumulating damage totals.

- **FR-004**: The system MUST hydrate each arena slot's kill participation from death-recap timeline events, mapping the source GUID of lethal or near-lethal damage contributors to their corresponding arena slots.

- **FR-005**: The system MUST apply an identity-stickiness bias to any arena slot whose GUID matches the session's previously identified primary opponent or identity opponent, stabilizing selection when pressure scores are close.

- **FR-006**: The system MUST compute a composite pressure score per slot using weighted components: incoming damage to the player (highest weight), outgoing damage from the player (medium weight), crowd-control on the player (lower weight), and kill participation (lower weight).

- **FR-007**: The system MUST select the primary enemy using a stable ranking policy: highest composite selection score first, then visible slots over hidden, then most recently seen, then lowest slot index as a deterministic tie-breaker.

- **FR-008**: The system MUST retain the previously preferred opponent GUID when that opponent's score is within a configurable percentage threshold of the best score, preventing identity flapping across back-to-back rounds with nearly tied enemies.

- **FR-009**: The system MUST never select the local player's own GUID as the primary enemy, even in edge cases where unit-token reuse or transition states cause the player's GUID to appear in an arena slot.

- **FR-010**: The system MUST record the selection strategy label (indicating whether the selection was score-based, GUID-sticky, visibility-based, or a fallback) on the session for every primary opponent selection.

- **FR-011**: The system MUST persist per-slot selection evidence (damage-to-player component, death-recap component, identity bias component, visibility bias component) on the session's primary opponent record.

- **FR-012**: The system MUST enrich the exported primary opponent record with all available identity fields: GUID, name, class, specialization ID, specialization name, specialization icon, and pressure score.

#### Damage Meter Candidate Matching

- **FR-013**: The system MUST collect expected opponent GUIDs from all available sources (primary opponent, session identity, arena slots, and live round tracker state) before scoring Damage Meter candidates.

- **FR-014**: The system MUST award a significant score boost to Damage Meter candidates that contain the session's primary opponent GUID among their enemy sources.

- **FR-015**: The system MUST award incremental score credit for each candidate enemy source GUID that overlaps a known opponent GUID, up to a defined cap.

- **FR-016**: The system MUST penalize Damage Meter candidates that have enemy sources but zero GUID overlap with the known opponent roster, actively pushing away obviously wrong candidates.

- **FR-017**: The system MUST evaluate source-count plausibility by combat context: arena candidates are rewarded for matching the expected bracket size, duel candidates are rewarded for having exactly one enemy source, and training-dummy candidates are rewarded for having exactly one source.

- **FR-018**: The system MUST penalize Damage Meter candidates whose duration differs from the combat session duration by more than a configurable threshold (on sessions with non-zero duration).

- **FR-019**: The system MUST persist the opponent fit score and enemy source count on the session's import metadata for post-hoc inspection.

- **FR-020**: The system MUST return the enemy source list alongside the enemy damage snapshot from the Damage Meter collection step, making it available for opponent fit scoring.

#### Finalization Order

- **FR-021**: The system MUST export arena round state (including hardened primary opponent selection) into the session before running classifier identity sync.

- **FR-022**: The system MUST export arena round state before computing session metrics (pressure, burst, survivability, rotation consistency).

- **FR-023**: The system MUST export arena round state before generating coaching suggestions.

- **FR-024**: All downstream analytics (classifier identity sync, metrics, suggestions) MUST consume the arena-exported primary opponent rather than an early placeholder or first-hit target.

#### Rating Snapshot Reliability

- **FR-025**: The system MUST capture the pre-match rating snapshot (personal rating, best season rating, season games played/won, weekly games played/won) at match-active time and store it on the match-level metadata, independent of whether a combat session exists yet.

- **FR-026**: The system MUST propagate the stored rating snapshot from match metadata to the combat session at session-creation time, ensuring late-created sessions inherit the snapshot.

- **FR-027**: The system MUST record a missing-reason on the rating snapshot when the match is unrated or when the rating data source is unavailable, rather than leaving the field absent or nil.

- **FR-028**: The system MUST populate the session's rated-match flag from the rating snapshot metadata at session creation time.

#### Graceful Degradation

- **FR-029**: Every scoring heuristic MUST tolerate the absence of any single input signal (attribution data, death recap, arena slots, opponent GUID, bracket info) by falling back to the next available signal without error.

- **FR-030**: When all pressure evidence is absent, opponent selection MUST fall back to a deterministic policy (visibility, recency, slot index) and MUST record the fallback strategy on the session.

- **FR-031**: When no Damage Meter candidate sessions exist, the existing fallback paths (cached snapshot, current session) MUST continue to operate and MUST record the fallback reason in import diagnostics.

### Key Entities

- **Arena Slot**: Represents one enemy player in an arena match. Key attributes: unique identifier (GUID), player name, class, specialization, visibility state, last-seen time, accumulated pressure score, composite selection score, and structured selection evidence.

- **Selection Evidence**: A diagnostic record attached to each arena slot and to the session's primary opponent. Contains per-component breakdowns: damage dealt to the player, death recap contribution, identity stickiness bias, and visibility bias. Enables post-hoc debugging.

- **Damage Meter Candidate**: Represents one historical combat session from the game client's built-in Damage Meter. Key attributes: session identifier, duration, total damage, enemy source list (with GUIDs and amounts), and computed scores (opponent fit, context fit, signal score, total score).

- **Rating Snapshot**: Captures the player's competitive rating state at a point in time. Key attributes: personal rating, best season rating, season games played/won, weekly games played/won, and a missing-reason field for cases where data was unavailable.

- **Import Metadata**: A diagnostic record attached to the session describing how the Damage Meter import was performed. Key attributes: selected candidate identifier, total score, opponent fit score, enemy source count, duration delta, signal score, and final damage source hint.

- **Primary Opponent**: The session-level record identifying who the player fought. Key attributes: GUID, name, class, specialization, pressure score, and a selection sub-record containing strategy label, slot index, final score, per-component evidence, and preferred GUID considered.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In arena sessions where the full enemy roster was visible during prep phase, the correct primary opponent (the enemy who dealt the most damage to the player) is identified in at least 90% of sessions, compared to the previous baseline where selection was essentially arbitrary among visible slots.

- **SC-002**: In back-to-back Solo Shuffle rounds with the same enemy composition but different pressure targets, the primary opponent changes correctly between rounds rather than remaining sticky from round 1. The primary opponent for each round matches the round's actual top damage dealer in at least 85% of rounds.

- **SC-003**: When multiple Damage Meter candidate sessions exist with similar duration and damage, the correct candidate (matching the actual combat encounter's enemy roster) is selected in at least 90% of cases, compared to the previous baseline where selection was fragile for adjacent sessions.

- **SC-004**: Rated arena sessions capture a valid pre-match rating snapshot (with before-match ratings populated) in at least 95% of rated matches, including cases where the combat session is created after the match-active event.

- **SC-005**: Every finalized arena session contains inspectable selection diagnostics: a strategy label, per-component evidence scores, and the preferred GUID considered. Zero sessions should have nil or absent selection metadata.

- **SC-006**: Every finalized session that underwent Damage Meter import contains inspectable import diagnostics: opponent fit score and enemy source count. Zero imported sessions should have nil or absent diagnostic metadata.

- **SC-007**: No session ever shows the local player's own identity as the primary opponent.

- **SC-008**: When all pressure evidence is absent (no attribution, no death recap), the system completes opponent selection without error using deterministic fallback, and the fallback strategy is recorded on the session.

## Assumptions

- The addon operates on the WoW Midnight client (12.0.1+) where combat-log-based ingestion is forbidden in arena and restricted in other PvP contexts. All data must come from sanctioned data paths (built-in Damage Meter, PvP APIs, visible unit tokens).

- The session's enemy-source attribution data (produced from Damage Meter imports) is the primary available signal for "which enemy damaged the player." This data is present for most sessions but may be absent if the Damage Meter import failed entirely.

- Death recap timeline events are available when the player died during the session. These events are not present in sessions where the player survived.

- Arena slot GUIDs are populated from visible arena unit tokens and prep-phase APIs. Slot GUIDs may be partially populated if enemies were never visible (e.g., stealth-heavy compositions).

- The duel-requested event reliably provides the opponent's character name. This name is not restricted and can be used as a display fallback.

- The identity-stickiness threshold and all other scoring weights are initial conservative values that may be tuned based on real-world session data. The specification prescribes the behavior and guarantees, not specific final numeric values.

- Two pressure input fields (outgoing damage from the player and crowd-control on the player) are structurally present but not yet fed by sanctioned Midnight-era data sources. The scoring model includes them to preserve forward compatibility, but the current implementation relies primarily on incoming enemy damage and kill participation.

- The match-level metadata (used for rating snapshot inheritance) persists only for the duration of the current match in memory. It does not need to survive addon reloads or disconnects.

- The Damage Meter candidate pool is bounded by the game client's built-in session retention (typically the most recent handful of sessions). The addon does not control how many candidates are available.
