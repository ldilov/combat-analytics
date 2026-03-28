# Contract: Timeline Event Producers

**Version**: 1.0 | **Date**: 2026-03-28

## Overview

Each sanctioned data source produces TimelineEvents through a registered producer. Producers are responsible for normalizing API data into the TimelineEvent schema and tagging provenance.

## Producer Registry

### PlayerCastProducer
- **Source event**: `UNIT_SPELLCAST_SUCCEEDED`
- **Lane**: `player_cast`
- **Fires**: When player or player-owned unit (pet/guardian) completes a cast
- **Fields**: `t`, `spellId`, `spellName`, `guid` (caster), `source = "state"`, `confidence = "confirmed"`
- **Meta**: `{ isOffensive, isDefensive, isTrinket, isCooldown }` — classified from `SeedSpellIntelligence`
- **Guarantee**: Every visible player cast produces exactly one timeline event

### VisibleAuraProducer
- **Source event**: `UNIT_AURA`
- **Lane**: `visible_aura`
- **Types**: `"applied"`, `"removed"`, `"refreshed"`
- **Fires**: When an aura is applied to or removed from a visible unit
- **Fields**: `t`, `spellId`, `spellName`, `unitToken`, `guid`, `source = "visible_unit"`, `confidence = "confirmed"`
- **Meta**: `{ auraType, duration, stacks }`
- **Guarantee**: Aura windows open/close as pairs (close forced at session finalization if still open)

### CCReceivedProducer
- **Source events**: `LOSS_OF_CONTROL_ADDED`, `LOSS_OF_CONTROL_REMOVED`, `PLAYER_CONTROL_LOST`, `PLAYER_CONTROL_CHANGED`
- **Lane**: `cc_received`
- **Types**: `"start"`, `"end"`
- **Fields**: `t`, `spellId`, `spellName`, `source = "loss_of_control"`, `confidence = "confirmed"`
- **Meta**: `{ locType, duration, timeRemaining }`
- **Guarantee**: CC events represent confirmed loss of player control

### DRUpdateProducer
- **Source event**: `UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED`
- **Lane**: `dr_update`
- **Fires**: When DR category state changes on an arena unit
- **Fields**: `t`, `unitToken`, `guid`, `source = "spell_diminish"`, `confidence = "confirmed"`
- **Meta**: `{ category, startTime, duration, isImmune, showCountdown }`
- **Guarantee**: Only produces events for visible arena units

### MatchStateProducer
- **Source events**: `PVP_MATCH_*`, `DUEL_*`, `PLAYER_REGEN_DISABLED/ENABLED`
- **Lane**: `match_state`
- **Types**: `"combat_start"`, `"combat_end"`, `"match_start"`, `"match_complete"`, `"round_start"`, `"round_end"`, `"duel_start"`, `"duel_end"`
- **Fields**: `t`, `source = "state"`, `confidence = "confirmed"`
- **Meta**: Varies by type (e.g., `{ result, ratingDelta }` for match_complete)

### InspectProducer
- **Source event**: `INSPECT_READY`
- **Lane**: `inspect`
- **Fires**: When inspect data becomes available for an arena opponent
- **Fields**: `t`, `unitToken`, `guid`, `source = "inspect"`, `confidence = "confirmed"`
- **Meta**: `{ pvpTalents[], talentImportString, slotNumber }`

### DamageMeterCheckpointProducer
- **Source events**: `DAMAGE_METER_COMBAT_SESSION_UPDATED`, `DAMAGE_METER_CURRENT_SESSION_UPDATED`
- **Lane**: `dm_checkpoint`
- **Fires**: When DamageMeter data updates
- **Fields**: `t`, `source = "damage_meter"`, `confidence = "confirmed"`
- **Meta**: `{ sessionId, updateType }`

### DamageMeterSpellProducer
- **Source**: `C_DamageMeter.GetCombatSessionSourceFromID()` spell rows
- **Lane**: `dm_spell` (player spells) or `dm_enemy_spell` (enemy spells)
- **Fires**: At DamageMeter import time (post-combat)
- **Fields**: `t = session.duration` (end-of-combat timestamp), `spellId`, `amount`, `source = "damage_meter"`, `confidence = "confirmed"`
- **Meta**: `{ sourceGuid, sourceName, sourceClassFile }` (for enemy spells)
- **Guarantee**: DM spell rows are post-combat snapshots, not real-time. Timestamp represents import time.

## Producer Invariants

1. All producers tag `source` from the ProvenanceSource enum
2. All producers tag `confidence` as confirmed/partial/estimated
3. Producers never fabricate data — if the API didn't provide it, the event is not created
4. Enemy cast timelines are only produced from sanctioned APIs (DM Enemy Damage Taken, Death Recap, visible CC/LOC)
5. Estimated events (kill_window, derived insights) are always `confidence = "estimated"`
