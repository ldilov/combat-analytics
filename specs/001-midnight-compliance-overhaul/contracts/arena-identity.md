# Contract: Arena Identity System

**Version**: 1.0 | **Date**: 2026-03-28

## Overview

Defines the identity contracts for arena matches, rounds, and enemy slots — ensuring stability across Solo Shuffle rounds, visibility changes, and inspect timing races.

## Match Identity

### matchKey Generation
```
matchKey = "player={playerGuid}|map={mapId}|ctx={context}|sub={subcontext}|joined={joinedAt}"
```

- **Created**: On first arena signal (`PLAYER_JOINED_PVP_MATCH` or `ARENA_PREP_OPPONENT_SPECIALIZATIONS`)
- **Immutable**: Once created, matchKey never changes for the duration of the lobby
- **Unique**: The `joinedAt` timestamp guarantees uniqueness even for same-map back-to-back queues

### Match Lifecycle
```
[none] → "prep" → "active" → "complete"
```

- **prep**: Created from join/prep events. Slots begin populating.
- **active**: `PVP_MATCH_ACTIVE` fired. Combat may begin.
- **complete**: `PVP_MATCH_COMPLETE` fired. Result resolved.

### Guarantees
1. All rounds in one Solo Shuffle lobby share one matchKey
2. Leaving one lobby and entering another creates a new matchKey (different `joinedAt`)
3. Match state transitions are monotonic (prep → active → complete)
4. `/reload` during prep: match shell survives if SavedVariables persisted, or resets cleanly on next prep event

## Round Identity

### roundKey Generation
```
roundKey = "{matchKey}|round={roundIndex}|roster={rosterSignature}"
```

Where:
```
rosterSignature = sorted( "{slot}:{guid or '?'}:{prepSpecId or 0}:{classFile or '?'}" for each slot )
```

- **Created**: At round start (first combat in a new round context)
- **Recomputed**: At round end with full roster data (GUID resolution may improve)
- **Round index**: 1-based, incremented per round within the match

### Guarantees
1. Solo Shuffle produces one session per round with correct round index
2. Round indices increment monotonically (1, 2, 3, ...)
3. Roster signature is deterministic (sorted by slot number)
4. Incomplete rosters use "?" placeholders — signature still stable

## Slot Identity

### Slot Population Order
1. **Prep phase**: `ARENA_PREP_OPPONENT_SPECIALIZATIONS` → fills `prepSpecId`, `prepSpecName`, `prepRole`, `prepClassFile`
2. **Visibility**: `ARENA_OPPONENT_UPDATE` with `reason = "seen"` → fills `guid`, `name`, `className`, `classFile`, `healthMax`
3. **Inspect**: `INSPECT_READY` (out-of-combat only) → fills `pvpTalents`, `talentImportString`
4. **DR updates**: `UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED` → fills `drState`
5. **Pressure**: DamageMeter post-combat import → fills pressure metrics

### Field-Level Confidence
Each field tracks HOW it was learned:

| Field | Possible Sources | Best Confidence |
|-------|-----------------|-----------------|
| specId | prep, visible, inspect | inspect > visible > prep |
| guid | visible, inspect | visible (direct observation) |
| name | visible, inspect | visible |
| class | prep, visible, inspect | inspect > visible > prep |
| pvpTalents | inspect only | inspect |
| talentImportString | inspect only | inspect |
| pressure | damage_meter, visible_unit, estimated | damage_meter > visible_unit |

### Slot Stability Guarantees
1. Slot identity does not change when visibility changes (stealth/vanish)
2. `lastUpdateReason = "unseen"` from `ARENA_OPPONENT_UPDATE` does NOT clear slot data
3. GUID-to-slot mapping is permanent once established within a round
4. Unresolved GUIDs are staged separately, never overwrite confirmed slot data
5. Inspect failure marks fields as "unavailable" — never silently treats missing data as confirmed

## Subcontext Resolution

| Condition | Subcontext |
|-----------|------------|
| `ApiCompat.IsSoloShuffle()` | `SOLO_SHUFFLE` |
| `IsRatedArena() and not SoloShuffle` | `RATED_ARENA` |
| `IsWargame()` | `WARGAME` |
| `IsSkirmish()` | `SKIRMISH` |
| `IsBrawl()` | `BRAWL` |
| `else (arena but unresolved)` | `UNKNOWN_ARENA` |

- Subcontext MUST NOT silently fall back to `RATED_ARENA` when unknown
- `UNKNOWN_ARENA` is an explicit honest state
