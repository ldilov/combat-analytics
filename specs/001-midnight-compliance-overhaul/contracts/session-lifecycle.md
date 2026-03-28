# Contract: Session Lifecycle

**Version**: 1.0 | **Date**: 2026-03-28

## Overview

Defines the state machine and event-driven lifecycle for combat sessions across all contexts (arena, duel, dummy, world PvP, general).

## Session States

```
[none] → "active" → "finalized"
```

- **none → active**: Created on combat start signal
- **active → finalized**: Triggered by combat end + DM stabilization

## Entry Contracts (Session Creation)

### Arena Session
- **Pre-condition**: `PLAYER_JOINED_PVP_MATCH` or `ARENA_PREP_OPPONENT_SPECIALIZATIONS` fired
- **Trigger**: `PLAYER_REGEN_DISABLED` + `SessionClassifier:ResolveContextFromState()` returns ARENA
- **Match shell**: Created before combat (from prep events). Session links to existing match.
- **Guarantee**: One session per round. Match key stable across all rounds.

### Duel Session
- **Pre-condition**: `DUEL_REQUESTED` received
- **Trigger**: `DUEL_INBOUNDS` (confirms duel accepted and started)
- **Canceled duel**: `DUEL_FINISHED` without `DUEL_INBOUNDS` → no session created
- **Guarantee**: Canceled/expired requests produce zero sessions. Pending duel state expires after 30s.

### Dummy Session
- **Pre-condition**: Player enters combat near a training dummy
- **Trigger**: `PLAYER_REGEN_DISABLED` + positive dummy identification (creature ID from `SeedDummyCatalog` or seeded name match)
- **Guarantee**: Non-dummy NPCs never classified as dummy. Classification score threshold: 70.

### General / World PvP Session
- **Trigger**: `PLAYER_REGEN_DISABLED` + state-based classification
- **Guarantee**: No session created without resolved context.

## Exit Contracts (Session Finalization)

### Finalization Triggers (in priority order)
1. `PVP_MATCH_COMPLETE` → sets explicit result, schedules finalize
2. `DUEL_FINISHED` → triggers finalize with duel result
3. `PLAYER_REGEN_ENABLED` → schedules finalize after stabilization delay
4. `DAMAGE_METER_*_UPDATED` → schedules finalize (0.2-0.35s delay)
5. OnUpdate idle timeout → context-specific (duel: 6s, dummy: 2s, world: 8s, general: 3s)

### Finalization Pipeline
1. Close open aura windows
2. Extract opener sequence (first 5 player casts from timelineEvents)
3. Compute death analysis from timeline
4. Capture end timestamp
5. Sanitize totals (guard against secret values)
6. Capture "after" rating snapshot (if rated)
7. Import DamageMeter data (up to 3 retries, 0.75s interval)
8. Sync identity from SessionClassifier
9. Derive result (WIN/LOSS/DRAW/UNKNOWN)
10. Compute metrics (pressure, burst, survivability, rotation consistency)
11. Generate coaching suggestions
12. Export arena round state (if arena context)
13. Resolve data confidence and provenance
14. Persist to SavedVariables

### Finalization Guarantees
- Idempotent: multiple triggers for same session are safe (checks `state == "active"`)
- No data after finalize: totals stop changing after `state = "finalized"`
- Re-entrant safe: reload/login/logout during finalization does not corrupt DB
- DM stabilization: finalization waits for DM import before completing (configurable delay, default 1.5s)

## Invariants

1. At most one session is `"active"` at any time
2. No duplicate sessions for a single combat encounter
3. Every finalized session has a `result` field (may be `UNKNOWN`)
4. Every finalized session has `captureQuality.confidence` set
5. Every finalized session has `provenance` metadata for non-trivial fields
6. Arena sessions always reference a valid `matchKey`
