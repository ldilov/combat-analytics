# Tasks: Midnight PvP Session Reliability Hardening

**Branch**: `002-pvp-session-hardening` | **Date**: 2026-03-28
**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)
**Total Tasks**: 22 | **MVP Scope**: US1 + US3 (correct opponent identity + correct finalization order)

## User Story Summary

| Story | Priority | Description | File |
|-------|----------|-------------|------|
| US1 | P1 | Correct primary opponent after arena match | `ArenaRoundTracker.lua` |
| US2 | P1 | Correct Damage Meter session imported | `DamageMeterService.lua` |
| US3 | P2 | Downstream analytics use hardened opponent data | `CombatTracker.lua` |
| US4 | P2 | Rated snapshot survives late session creation | `CombatTracker.lua` |
| US5 | P3 | Selection diagnostics are inspectable | `DamageMeterService.lua` |

## Implementation Strategy

1. **MVP**: US1 + US3 — Evidence-based opponent selection and correct finalization order. Together these make match history trustworthy and eliminate the most visible failure mode.
2. **Next**: US2 — GUID-overlap DM candidate matching. Ensures all damage analytics are based on the correct session.
3. **Then**: US4 — Rating snapshot inheritance. Makes rating progression reliable for competitive players.
4. **Finally**: US5 — Diagnostics completeness. Makes the addon self-diagnosing for future misfire investigation.

**Parallel opportunities**: Phases 3 (US1) and 4 (US2) can be developed simultaneously — different files, no cross-dependencies. Phase 6 (US4) is fully independent and can begin at any time.

---

## Phase 3: User Story 1 — Correct Primary Opponent After Arena Match (P1)

**Story Goal**: After an arena match, the session shows the correct enemy (the one who dealt the most incoming damage to the player) as primary opponent, with stable identity across Solo Shuffle rounds.

**Independent Test**: Complete a rated arena match → open the History tab → verify the primary opponent name, class, and spec match the enemy who dealt the most damage to the player. Stable across back-to-back Solo Shuffle rounds.

### Tasks

- [X] T001 [US1] Add `findSlotByGuid(round, guid)` helper in `ArenaRoundTracker.lua` — maps a GUID to its arena slot via indexed lookup (`round.slotsByGuid`), falls back to linear scan over `round.slots`, returns `nil` safely when no slot matches
- [X] T002 [P] [US1] Add `ensureSelectionEvidence(slot)` helper in `ArenaRoundTracker.lua` — initializes `slot.selectionEvidence = { damageToPlayer=0, deathRecap=0, identityBias=0, visibilityBias=0 }` if the field is absent; idempotent (no-op if already initialized)
- [X] T003 [US1] Add `ApplySessionPressure(round, session)` method in `ArenaRoundTracker.lua` — (1) reset all derived slot fields (`primarySelectionScore`, `selectionEvidence`) to zero; (2) hydrate `damageToPlayer` from `session.attribution.bySource` by calling `findSlotByGuid` for each source GUID; (3) hydrate `deathRecap` contribution from `session.timelineEvents` entries where `lane == "DM_ENEMY_SPELL"` and `eventType == "death_recap"`; (4) apply identity bias: +12 to any slot whose GUID matches `round.preferredOpponentGuid`; (5) apply visibility bias: +1 to currently visible slots; (6) compute final score: `slot.damageToPlayer * 0.45 + slot.killParticipation * 0.10 + identityBias + visibilityBias`; tolerates nil/absent attribution and empty timeline silently
- [X] T004 [US1] Update `GetPrimaryEnemy(preferredGuid)` in `ArenaRoundTracker.lua` — stable ranking policy: highest `primarySelectionScore` → visible over hidden → most recently seen (`lastSeen`) → lowest slot index as deterministic tie-breaker; apply 85% sticky GUID rule: if `preferredGuid`'s slot score ≥ 85% of best slot's score, retain `preferredGuid` and set `strategy = "preferred_guid_sticky"`; exclude any slot whose GUID equals `UnitGUID("player")`; set `selection.strategy` label to one of: `"highest_score"`, `"preferred_guid_sticky"`, `"preferred_guid_only"`, `"latest_visible"`, `"no_visible_slot"`, `"no_round"`
- [X] T005 [US1] Update `CopyStateIntoSession(session)` in `ArenaRoundTracker.lua` — call `ApplySessionPressure(round, session)` before the export loop; enrich the exported `primaryOpponent` with `className` (from `slot.prepClassFile`) and `specName` (from `slot.prepSpecName`); persist full `selection` diagnostics block on `session.primaryOpponent.selection` including `strategy`, `slot`, `score`, `damageToPlayer`, `killParticipation`, `preferredGuid`, and shallow-copied `evidence`

---

## Phase 4: User Story 2 — Correct Damage Meter Session Imported (P1)

> **Parallel with Phase 3**: All changes are in `DamageMeterService.lua` — no dependency on Phase 3 completion.

**Story Goal**: When importing a Damage Meter historical session, the candidate whose enemy GUIDs most closely match the known arena roster is selected, even when multiple candidates have similar duration and damage totals.

**Independent Test**: Complete two consecutive arena rounds with different opponents → verify each imported session's enemy sources and damage totals correspond to the correct round.

### Tasks

- [X] T006 [P] [US2] Add `collectExpectedOpponentGuids(session)` helper in `DamageMeterService.lua` — gathers GUIDs from: `session.primaryOpponent.guid`, `session.identity.opponentGuid`, all `session.arena.slots[*].guid` entries, and `ArenaRoundTracker:GetSlots()` live state; returns a deduplicated set (keyed table) of all non-nil GUIDs
- [X] T007 [US2] Add `GetOpponentFitScore(session, enemySources)` method in `DamageMeterService.lua` — calls `collectExpectedOpponentGuids(session)`; awards +28 if the session's primary opponent GUID is found among `enemySources`; awards +10 per additional overlapping GUID (capped at +30 total overlap credit); applies -18 penalty when `enemySources` is non-empty but overlap count is zero; applies arena context fit: +10 for exact bracket size match, +6 for off-by-one; applies duel context fit: +14 for single source, -8 for multiple sources; returns 0 cleanly when both GUID set and enemy sources are empty
- [X] T008 [P] [US2] Update `CollectEnemyDamageSnapshotForSession` in `DamageMeterService.lua` — return an `enemySources` list (`array of {guid, amount}` combatSource entries from the `EnemyDamageTaken` meter type) alongside the existing damage snapshot and spell breakdown outputs; callers that ignore the new return value are unaffected
- [X] T009 [US2] Update `BuildHistoricalSnapshot` candidate scoring loop in `DamageMeterService.lua` — call `GetOpponentFitScore(session, candidate.enemySources)` and add the result to each candidate's total score; apply an additional -20 duration mismatch penalty when `math.abs(candidateDuration - sessionDuration) > 15` and `sessionDuration > 0`
- [X] T010 [US2] Update `RecordImportMetadata` in `DamageMeterService.lua` — persist `opponentFitScore` (result of `GetOpponentFitScore` for the selected candidate) and `enemySourceCount` (count of entries in the selected candidate's `enemySources` table) on `session.import`

---

## Phase 5: User Story 3 — Downstream Analytics Use Hardened Opponent Data (P2)

> **Requires Phase 3 (T005 complete)**: `CopyStateIntoSession` must export hardened opponent data before its call site can be moved.

**Story Goal**: Session metrics, coaching suggestions, and classifier identity sync all operate on the evidence-selected primary opponent, not a stale first-hit placeholder.

**Independent Test**: Complete an arena match where the initial first-hit target differs from the highest-pressure enemy → inspect session metrics, suggestions, and matchup data → confirm all reference the same opponent shown in the History tab.

### Tasks

- [X] T011 [US3] Move `ArenaRoundTracker:CopyStateIntoSession(session)` in `FinalizeSession` in `CombatTracker.lua` — reposition the call to run immediately after the Damage Meter import block completes and before: (1) classifier identity sync, (2) `DeriveMetrics`, (3) `GenerateSuggestions`; this ensures all downstream analytics consume the arena-exported opponent
- [X] T012 [US3] Remove the original post-suggestions `CopyStateIntoSession` call in `CombatTracker.lua` — the relocated call from T011 is the single authoritative call site; delete the stale block to prevent double-export

---

## Phase 6: User Story 4 — Rated Snapshot Survives Late Session Creation (P2)

> **Independent**: These changes modify `HandlePvpMatchActive` and `CreateSession` code paths that have no dependency on Phases 3–5.

**Story Goal**: The pre-match rating snapshot (personal rating, season stats, weekly stats) is captured at match-active time and inherited by the combat session even when the session is created after `PVP_MATCH_ACTIVE` fires.

**Independent Test**: Enter a rated arena match where `PVP_MATCH_ACTIVE` fires before the first damage event → verify the resulting session contains `ratingSnapshot.before` with populated personal rating data.

### Tasks

- [X] T013 [P] [US4] Refactor `HandlePvpMatchActive` in `CombatTracker.lua` — capture pre-match rating via `C_PvP.GetPVPActiveMatchPersonalRatedInfo()` into `matchRecord.metadata.preMatchRatingSnapshot`; when data is available: set `isRated=true` and populate `before = { personalRating, bestSeasonRating, seasonPlayed, seasonWon, weeklyPlayed, weeklyWon }`; when API returns nil: set `missingReason="api_unavailable"`; when match is unrated: set `isRated=false` and `missingReason="not_rated"`
- [X] T014 [US4] Update `CreateSession` in `CombatTracker.lua` — when `matchRecord.metadata.preMatchRatingSnapshot` is non-nil at session creation time, inherit `session.isRated` and `session.ratingSnapshot` from the match metadata before returning the new session object
- [X] T015 [P] [US4] Preserve direct-session rating path in `HandlePvpMatchActive` in `CombatTracker.lua` — when `currentSession` already exists at `PVP_MATCH_ACTIVE` time, continue populating `currentSession.isRated` and `currentSession.ratingSnapshot` directly from the match metadata (no regression from existing behavior for sessions created before match-active)

---

## Phase 7: User Story 5 — Selection Diagnostics Are Inspectable (P3)

> **Note**: Core diagnostic structures (`SelectionEvidence`, `OpponentSelection`) are built in Phases 3–4. This phase ensures diagnostic data also reaches trace logs and all fallback code paths.

**Story Goal**: Every finalized session — including those that used fallback paths — contains inspectable evidence for opponent selection and DM import decisions, accessible via `/ca debug export`.

**Independent Test**: Complete an arena match → run `/ca debug export` or inspect `CombatAnalyticsDB` → confirm `session.primaryOpponent.selection` and `session.import.opponentFitScore` are non-nil.

### Tasks

- [X] T016 [P] [US5] Update trace/log calls in `DamageMeterService.lua` — include `opponentFitScore` and `sourceCount` in all candidate evaluation trace lines and in the final selection confirmation trace
- [X] T017 [P] [US5] Update all fallback import paths in `DamageMeterService.lua` — cached-snapshot fallback, current-session fallback, and no-candidate fallback paths must each call `RecordImportMetadata` (or equivalent inline assignment) with `opponentFitScore=0` and `enemySourceCount=0` so that every imported session has non-nil import diagnostics

---

## Final Phase: Polish — Graceful Degradation Verification

**Goal**: Confirm all heuristic code paths tolerate nil/absent input without Lua errors. These are in-code defensive checks — nil guards, safe returns, and fallback strategy label coverage.

### Tasks

- [X] T018 [P] Audit nil guards in `ApplySessionPressure` in `ArenaRoundTracker.lua` — verify that nil `session.attribution`, nil `session.attribution.bySource`, nil `session.timelineEvents`, and empty slot tables each produce zero pressure scores with no Lua error; add guards where absent
- [X] T019 [P] Audit fallback chain in `GetPrimaryEnemy` in `ArenaRoundTracker.lua` — verify that when all slot scores are zero, the fallback sequence (visible → recently seen → lowest slot index) fires and `selection.strategy` is set to `"latest_visible"` or `"no_visible_slot"` (never `"highest_score"` when all scores are zero)
- [X] T020 [P] Audit nil guards in `GetOpponentFitScore` in `DamageMeterService.lua` — verify that an empty opponent GUID set combined with an empty `enemySources` table returns 0 without error; verify the zero-overlap penalty is NOT applied when `enemySources` is empty (penalty only applies to non-empty sources with no matches)
- [X] T021 [P] Audit fallback import path coverage in `DamageMeterService.lua` — verify cached-snapshot path, current-session path, and no-candidate empty path each produce a `session.import` record with valid (non-nil) `opponentFitScore` and `enemySourceCount` fields after T017
- [ ] T022 Run `/ca regression` self-test command in-game and perform manual validation across all PvP contexts: rated 2v2, rated 3v3, Solo Shuffle, duel, battleground, world PvP — confirm no Lua errors in the system log and verify session data is populated correctly for all five user stories

---

## Dependency Graph

```
T001 → T003 → T004 → T005 ──┐
T002 ─────────────────────── │ ──→ T011 → T012
                              │
T006 → T007 ──→ T009 → T010   │
T008 ─────────────────────────┘ (T011 also depends on T009 for full DM-aware export)

T013 → T014
T015 (independent)

T016 (independent)
T017 → T021

T018, T019 (after T003, T004 complete)
T020 (after T007 complete)
T022 (after all implementation complete)
```

**Key sequencing rules:**
- Phase 5 (T011) requires Phase 3 (T005) complete
- Phase 6 (T013–T015) is fully independent — can start any time
- Phase 7 (T016–T017) can be done alongside Phase 4
- Polish phase (T018–T022) runs after all implementation phases

---

## Task Count Summary

| Phase | Story | Tasks | Parallelizable |
|-------|-------|-------|----------------|
| Phase 3 | US1 (P1) | 5 (T001–T005) | T002 |
| Phase 4 | US2 (P1) | 5 (T006–T010) | T006, T008 |
| Phase 5 | US3 (P2) | 2 (T011–T012) | — |
| Phase 6 | US4 (P2) | 3 (T013–T015) | T013, T015 |
| Phase 7 | US5 (P3) | 2 (T016–T017) | T016, T017 |
| Polish | — | 5 (T018–T022) | T018–T021 |
| **Total** | — | **22** | **9** |
