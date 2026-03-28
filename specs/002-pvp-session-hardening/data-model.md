# Data Model: PvP Session Reliability Hardening (Delta)

**Branch**: `002-pvp-session-hardening` | **Date**: 2026-03-28
**Base**: `001-midnight-compliance-overhaul` data model (schema v6)

This document describes only the **additions and modifications** to the existing data model from feature 001. No schema version bump is required — all changes are additive field additions to existing entities or new embedded sub-records.

---

## Modified Entities

### 1. Arena Slot (additions)

The existing `ArenaSlot` entity (defined in 001 data model) gains two new fields:

```
ArenaSlot {
  -- ... all existing fields preserved ...

  -- NEW: Composite selection score (derived, not persisted to SavedVariables)
  primarySelectionScore : number     -- pressureScore + identityBias + visibilityBias

  -- NEW: Structured diagnostic evidence for primary opponent selection
  selectionEvidence    : SelectionEvidence?
}
```

**Notes**:
- `primarySelectionScore` is computed by `ApplySessionPressure` at finalization time. It is exported to the session but is not independently persisted on the ArenaSlot in SavedVariables.
- `selectionEvidence` is populated alongside the score. It records why each slot received its score.

---

### 2. Selection Evidence (NEW embedded record)

```
SelectionEvidence {
  damageToPlayer    : number   -- contribution from session.attribution.bySource
  deathRecap        : number   -- contribution from death recap timeline events
  identityBias      : number   -- +12 if slot GUID matches preferred opponent GUID, else 0
  visibilityBias    : number   -- +1 if slot is visible, else 0
}
```

**Relationships**:
- Embedded on ArenaSlot during pressure computation
- Shallow-copied to PrimaryOpponent.selection.evidence at export time

---

### 3. Primary Opponent (additions)

The existing `OpponentRecord` entity (referenced as `session.primaryOpponent`) gains new fields:

```
OpponentRecord {
  -- ... all existing fields preserved ...

  -- NEW: className backfill from arena slot prep data
  className          : string?       -- was missing in export; now filled from prepClassFile

  -- NEW: specName backfill from arena slot prep data
  specName           : string?       -- was missing in export; now filled from prepSpecName

  -- NEW: Selection diagnostics block
  selection          : OpponentSelection?
}
```

---

### 4. Opponent Selection (NEW embedded record)

```
OpponentSelection {
  strategy           : string     -- "highest_score" | "preferred_guid_sticky" | "preferred_guid_only"
                                  -- | "latest_visible" | "no_visible_slot" | "no_round"
  slot               : number?    -- 1-5, the slot index of the selected enemy
  score              : number     -- final primarySelectionScore of the selected slot
  damageToPlayer     : number     -- damage dealt to player by selected enemy
  killParticipation  : number     -- kill participation of selected enemy
  preferredGuid      : string?    -- the GUID that was considered for stickiness
  evidence           : SelectionEvidence  -- shallow copy of the slot's evidence record
}
```

**Relationships**:
- Embedded on session.primaryOpponent
- Persisted to SavedVariables as part of the session record

---

### 5. Import Metadata (additions)

The existing `ImportMetadata` entity (referenced as `session.import`) gains two new fields:

```
ImportMetadata {
  -- ... all existing fields preserved ...

  -- NEW: How well the selected candidate's enemy roster matched known opponents
  opponentFitScore   : number     -- sum of GUID overlap, primary match, context fit, penalties

  -- NEW: How many enemy sources the selected candidate contained
  enemySourceCount   : number     -- count of combatSources in the EnemyDamageTaken meter type
}
```

---

### 6. Arena Match Metadata (additions)

The existing `MatchMetadata` record (referenced as `matchRecord.metadata`) gains one new field:

```
MatchMetadata {
  -- ... all existing fields preserved ...

  -- NEW: Pre-match rating snapshot captured at PVP_MATCH_ACTIVE time
  preMatchRatingSnapshot : PreMatchRatingSnapshot?
}
```

---

### 7. Pre-Match Rating Snapshot (NEW embedded record)

```
PreMatchRatingSnapshot {
  isRated            : boolean    -- whether the match affects rating

  -- Present when isRated == true and API is available
  before             : RatingBeforeData?

  -- Present when data is unavailable
  missingReason      : "not_rated" | "api_unavailable" | nil
}
```

```
RatingBeforeData {
  personalRating     : number
  bestSeasonRating   : number
  seasonPlayed       : number
  seasonWon          : number
  weeklyPlayed       : number
  weeklyWon          : number
}
```

**Notes**:
- This record lives on `matchRecord.metadata`, not directly on the session.
- At `CreateSession` time, the session inherits `isRated` and `ratingSnapshot` from this record.
- The session's existing `ratingSnapshot` field is unchanged in shape; it is now populated from the match metadata instead of directly from the API call.

---

### 8. Combat Session (additions)

The existing `Session` entity gains fields inherited from match metadata:

```
Session {
  -- ... all existing fields preserved ...

  -- MODIFIED BEHAVIOR: isRated is now populated from matchRecord.metadata at CreateSession time
  -- (previously populated only when session existed at PVP_MATCH_ACTIVE time)
  isRated            : boolean

  -- MODIFIED BEHAVIOR: ratingSnapshot is now populated from matchRecord.metadata at CreateSession time
  -- (previously populated only when session existed at PVP_MATCH_ACTIVE time)
  ratingSnapshot     : RatingSnapshot?

  -- NEW: Duel opponent name from DUEL_REQUESTED event (last-resort fallback)
  duelOpponentName   : string?
}
```

**Notes**:
- `duelOpponentName` is populated in `HandleDuelInbounds` from the pending duel metadata. It serves as a last-resort fallback for `Helpers.ResolveOpponentName` when no other opponent identity source is available.
- The `isRated` and `ratingSnapshot` fields exist already; only their population timing changes.

---

## Unchanged Entities

The following entities from the 001 data model are **not modified** by this feature:

- TimelineEvent
- PlayerSnapshot
- Attribution
- SpellAggregate
- AuraAggregate
- CooldownAggregate
- SessionTotals
- SessionMetrics
- Suggestion
- CaptureQuality
- Provenance
- SlotFieldConfidence
- ArenaRound (structure unchanged; slots within rounds are modified as described above)

---

## Migration

No schema version bump is required. All new fields are:
- Additive (new keys on existing records)
- Defaulting safely to nil/absent when not present
- Only populated going forward on new sessions

Existing sessions in SavedVariables are unaffected. ResolveOpponentName and other readers already use nil-safe access patterns.
