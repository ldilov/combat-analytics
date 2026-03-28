# Implementation Plan: Midnight PvP Session Reliability Hardening

**Branch**: `002-pvp-session-hardening` | **Date**: 2026-03-28 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/002-pvp-session-hardening/spec.md`

## Summary

Harden PvP session capture reliability on Midnight by fixing four failure modes: (1) wrong/missing opponent identity via evidence-based arena slot pressure scoring, (2) wrong Damage Meter session matching via GUID-overlap candidate scoring, (3) stale finalization order that let downstream analytics consume placeholder opponents, and (4) rated snapshot timing race where late session creation missed pre-match rating data. All changes use only sanctioned data paths (C_DamageMeter, C_PvP, visible unit tokens) — no CLEU.

## Technical Context

**Language/Version**: Lua 5.1 (WoW addon dialect)
**Primary Dependencies**: WoW Midnight 12.0.1 API (Interface 120001) — C_DamageMeter, C_PvP, C_SpecializationInfo, UNIT_* events
**Storage**: SavedVariables (CombatAnalyticsDB) — flat Lua table serialized by the game client
**Testing**: Manual in-game testing + `/ca regression` self-test command + `/ca debug export` for post-hoc inspection
**Target Platform**: World of Warcraft Midnight client (Windows/macOS)
**Project Type**: WoW addon (single-player client-side plugin)
**Performance Goals**: All finalization logic completes within a single frame (~16ms budget). No OnUpdate tick usage for scoring.
**Constraints**: No CLEU/CombatLogGetCurrentEventInfo as active data source. All heuristics must tolerate partial/absent data. Memory overhead per session must remain under existing budgets.
**Scale/Scope**: ~34 existing modules, ~12,000 LOC. This feature modifies 3 core files (ArenaRoundTracker.lua, DamageMeterService.lua, CombatTracker.lua). No new files created.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Constitution file is unconfigured (template placeholders only). No project-specific gates are defined.

**Pre-Phase 0 check**: PASSED (no gates to evaluate)
**Post-Phase 1 check**: PASSED (no gates to evaluate)

## Project Structure

### Documentation (this feature)

```text
specs/002-pvp-session-hardening/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output (delta from 001 data model)
├── quickstart.md        # Phase 1 output
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Phase 2 output (created by /speckit.tasks)
```

### Source Code (repository root)

```text
# WoW addon — flat module structure at repo root
ArenaRoundTracker.lua      # MODIFIED: pressure hydration, selection scoring, diagnostics
DamageMeterService.lua     # MODIFIED: opponent fit scoring, GUID-overlap matching
CombatTracker.lua          # MODIFIED: finalization order, rating snapshot inheritance
```

**Structure Decision**: No new files are created. All changes modify existing modules within the established flat addon architecture. The changes are purely behavioral (new/updated methods within existing module tables), not structural.

## Complexity Tracking

No constitution violations to justify — the feature stays within existing architecture and adds no new modules, dependencies, or structural patterns.

## Implementation Phases

### Phase 1: Arena Slot Pressure Hydration (ArenaRoundTracker.lua)

**Goal**: Make primary opponent selection evidence-based instead of visibility-based.

| Step | Description | Requirements |
|------|-------------|-------------|
| 1.1 | Add `findSlotByGuid(round, guid)` helper — maps GUID to slot via indexed lookup then linear scan fallback | FR-003, FR-004 |
| 1.2 | Add `ensureSelectionEvidence(slot)` helper — initializes diagnostic evidence bucket on slot | FR-011 |
| 1.3 | Add `ApplySessionPressure(round, session)` method — resets derived fields, hydrates from attribution + death recap, applies identity bias, computes final scores | FR-001, FR-002, FR-003, FR-004, FR-005, FR-006 |
| 1.4 | Update `GetPrimaryEnemy(preferredGuid)` — stable ranking with score/visibility/recency/slot tiebreakers + sticky preferred GUID rule | FR-007, FR-008, FR-009, FR-010 |
| 1.5 | Update `CopyStateIntoSession(session)` — call ApplySessionPressure before export, enrich primaryOpponent with className/specName, persist selection diagnostics | FR-011, FR-012 |

### Phase 2: Damage Meter Candidate GUID-Overlap Scoring (DamageMeterService.lua)

**Goal**: Make historical session matching roster-aware instead of purely signal/duration-based.

| Step | Description | Requirements |
|------|-------------|-------------|
| 2.1 | Add `collectExpectedOpponentGuids(session)` helper — gathers GUIDs from primaryOpponent, identity, arena slots, live tracker | FR-013 |
| 2.2 | Add `GetOpponentFitScore(session, enemySources)` method — GUID overlap scoring + primary match boost + zero-overlap penalty + context source-count sanity | FR-014, FR-015, FR-016, FR-017 |
| 2.3 | Update `CollectEnemyDamageSnapshotForSession` — return enemySources list alongside existing damage/spell outputs | FR-020 |
| 2.4 | Update `BuildHistoricalSnapshot` scoring — add opponentFitScore + duration mismatch penalty to candidate total | FR-014, FR-015, FR-016, FR-017, FR-018 |
| 2.5 | Update `RecordImportMetadata` — persist opponentFitScore + enemySourceCount on session.import | FR-019 |
| 2.6 | Update all trace/log calls — include opponentFitScore, sourceCount in candidate/selection traces | FR-019 |
| 2.7 | Update all fallback paths (cached snapshot, current session, empty) — include zeroed opponentFitScore/enemySourceCount in metadata | FR-019, FR-031 |

### Phase 3: Finalization Order Fix (CombatTracker.lua)

**Goal**: Ensure arena export runs before downstream analytics.

| Step | Description | Requirements |
|------|-------------|-------------|
| 3.1 | Move `CopyStateIntoSession` call from post-suggestions to pre-classifier-sync position in FinalizeSession | FR-021, FR-022, FR-023, FR-024 |
| 3.2 | Remove the original post-suggestions CopyStateIntoSession block | FR-021 |

### Phase 4: Rating Snapshot Inheritance (CombatTracker.lua)

**Goal**: Ensure pre-match rating survives late session creation.

| Step | Description | Requirements |
|------|-------------|-------------|
| 4.1 | Refactor `HandlePvpMatchActive` — capture preMatchRatingSnapshot into matchRecord.metadata instead of directly into session | FR-025, FR-027 |
| 4.2 | Update `CreateSession` — inherit preMatchRatingSnapshot from matchRecord metadata when present | FR-026, FR-028 |
| 4.3 | Preserve existing direct-session path — when session already exists at PVP_MATCH_ACTIVE time, populate ratingSnapshot directly (no regression) | FR-025 |

### Phase 5: Graceful Degradation Verification

**Goal**: Verify all scoring paths tolerate absent data.

| Step | Description | Requirements |
|------|-------------|-------------|
| 5.1 | Verify ApplySessionPressure handles nil/false attribution and empty timelineEvents | FR-029, FR-030 |
| 5.2 | Verify GetPrimaryEnemy returns sensible fallback + strategy label when all scores are zero | FR-009, FR-010, FR-025, FR-030 |
| 5.3 | Verify GetOpponentFitScore returns 0 when no opponent GUIDs and no enemy sources exist | FR-029 |
| 5.4 | Verify all fallback import paths record diagnostic metadata | FR-031 |

## Dependency Order

```
Phase 1 ──→ Phase 3 ──→ Phase 5
Phase 2 ──→ Phase 3
Phase 4 (independent)
```

- **Phase 1 and Phase 2** can be developed in parallel (different files)
- **Phase 3** depends on Phase 1 (CopyStateIntoSession must exist before reordering)
- **Phase 4** is independent of all other phases
- **Phase 5** runs after all behavioral changes are complete
