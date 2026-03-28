# Quickstart: Midnight PvP Session Reliability Hardening

**Branch**: `002-pvp-session-hardening` | **Date**: 2026-03-28

## What This Feature Does

Hardens PvP session capture reliability on WoW Midnight by fixing four failure modes:

1. **Wrong/missing opponent identity** → Evidence-based arena slot pressure scoring replaces visibility-based guessing
2. **Wrong Damage Meter session match** → GUID-overlap candidate scoring replaces duration/damage-only matching
3. **Stale finalization order** → Arena export runs before downstream analytics consume opponent data
4. **Rating snapshot timing race** → Pre-match rating stored on match metadata, inherited by late-created sessions

## Key Concepts

### Pressure Score

Each arena slot receives a composite score derived from sanctioned data paths:

```
pressureScore = damageToPlayer * 0.45
              + damageTakenFromPlayer * 0.30
              + ccOnPlayer * 0.15
              + killParticipation * 0.10
```

Plus bias adjustments:
- **Identity bias**: +12 if slot GUID matches the preferred opponent GUID
- **Visibility bias**: +1 if slot is currently visible

Currently only `damageToPlayer` and `killParticipation` are actively fed. Other weights are forward-compatible placeholders.

### Sticky Preferred GUID

When a preferred opponent GUID exists (from a previous round), it is retained if its score is ≥ 85% of the best slot's score. This prevents identity flapping across Solo Shuffle rounds where pressure profiles shift slightly.

### Opponent Fit Score

When matching a Damage Meter historical session to the addon's combat session, candidates are scored by roster GUID overlap:

| Signal | Score |
|--------|-------|
| Primary GUID match | +28 |
| Per-overlap GUID (capped at 3) | +10 each |
| Zero-overlap penalty | -18 |
| Arena bracket exact match | +10 |
| Arena bracket off-by-one | +6 |
| Duel single-source bonus | +14 |
| Duel multi-source penalty | -8 |
| Duration mismatch > 15s | -20 |

### Selection Evidence

Every primary opponent selection is accompanied by a diagnostic record:

```
selection = {
  strategy = "highest_score",       -- why this slot was chosen
  slot     = 3,                     -- which arena slot (1-5)
  score    = 47.2,                  -- final composite score
  evidence = {                      -- per-component breakdown
    damageToPlayer = 35.2,
    deathRecap     = 12.0,
    identityBias   = 0,
    visibilityBias = 1
  }
}
```

Strategy labels: `highest_score`, `preferred_guid_sticky`, `preferred_guid_only`, `latest_visible`, `no_visible_slot`, `no_round`.

## Files Modified

| File | Changes |
|------|---------|
| `ArenaRoundTracker.lua` | Pressure hydration, selection scoring, diagnostics export |
| `DamageMeterService.lua` | Opponent fit scoring, GUID-overlap matching, metadata persistence |
| `CombatTracker.lua` | Finalization order fix, rating snapshot inheritance |

No new files are created. All changes are behavioral modifications within existing modules.

## Data Model Changes

All changes are additive — no schema version bump required. New fields default to `nil` when absent.

### New Embedded Records
- **SelectionEvidence** — Per-component score breakdown on arena slots
- **OpponentSelection** — Strategy + score + evidence on `session.primaryOpponent`
- **PreMatchRatingSnapshot** — Pre-match rating captured on `matchRecord.metadata`
- **RatingBeforeData** — Personal rating, season stats, weekly stats

### Modified Entities
- **ArenaSlot** — gains `primarySelectionScore`, `selectionEvidence`
- **OpponentRecord** — gains `className`, `specName` backfill, `selection` diagnostics
- **ImportMetadata** — gains `opponentFitScore`, `enemySourceCount`
- **MatchMetadata** — gains `preMatchRatingSnapshot`
- **Session** — gains `duelOpponentName`; `isRated`/`ratingSnapshot` population timing changes

## Implementation Phases

```
Phase 1: Arena Slot Pressure Hydration    (ArenaRoundTracker.lua)
Phase 2: DM Candidate GUID-Overlap Scoring (DamageMeterService.lua)
   ↓ (both feed into)
Phase 3: Finalization Order Fix            (CombatTracker.lua)
   ↓
Phase 5: Graceful Degradation Verification

Phase 4: Rating Snapshot Inheritance       (CombatTracker.lua, independent)
```

Phases 1 and 2 can be developed in parallel. Phase 3 depends on Phase 1. Phase 4 is independent.

## Testing

- Manual in-game testing across arena (2v2, 3v3, Solo Shuffle), BG, duel, world PvP
- `/ca regression` self-test command for automated regression checks
- `/ca debug export` for post-hoc session inspection
- Verify graceful degradation: all scoring paths must tolerate nil/absent data

## Constraints

- **No CLEU**: All heuristics use sanctioned data paths only (C_DamageMeter, C_PvP, visible unit tokens)
- **Single-frame budget**: All finalization logic completes within ~16ms
- **No OnUpdate tick**: Scoring runs at finalization time, not per-frame
- **Backward compatible**: Existing sessions in SavedVariables are unaffected
