# Research: Midnight 12.0.1 Compliance Overhaul

**Branch**: `001-midnight-compliance-overhaul` | **Date**: 2026-03-28

## R1: CLEU Legacy Code Paths — What Must Be Removed or Quarantined

### Decision
Remove or quarantine six CLEU-era entry points and rewire their downstream consumers to the sanctioned timeline + Damage Meter model.

### Findings

The event router (`Events.lua:29`) already avoids registering `COMBAT_LOG_EVENT_UNFILTERED`. However, six functions still assume a CLEU-shaped `eventRecord`:

| Function | File:Line | Called From | Consumers |
|----------|-----------|-------------|-----------|
| `NormalizeCombatLogEvent(...)` | CombatTracker:590 | `HandleCombatLogEvent()` only | Returns eventRecord |
| `HandleCombatLogEvent()` | CombatTracker:1839 | **No active caller** (legacy) | `NormalizeCombatLogEvent` → `HandleNormalizedEvent` |
| `HandleNormalizedEvent(eventRecord)` | CombatTracker:1183 | Multiple paths | SessionClassifier, ArenaRoundTracker, SpellAttributionPipeline, stats aggregation, rawEvents ring buffer |
| `HandleCombatLogEvent(eventRecord)` | ArenaRoundTracker:561 | CombatTracker:1253 (arena only) | Pressure scoring, GUID-to-slot resolution |
| `HandleCombatLogEvent(session, eventRecord)` | SpellAttribution:202 | CombatTracker:1260 | Enemy damage attribution, summon tracking |
| `AccumulateEvidence(session, eventRecord)` | SessionClassifier:567 | CombatTracker:1244 | Context promotion (duel/dummy/world-PvP scoring) |

**Critical insight**: `HandleNormalizedEvent` is the hub. It feeds stats aggregation (spells, auras, cooldowns, utility, survival), ArenaRoundTracker pressure, SpellAttribution, and SessionClassifier evidence. Removing it means each consumer needs a new data source.

### Approach
1. **Delete**: `HandleCombatLogEvent()` in CombatTracker (no caller), `NormalizeCombatLogEvent()` (only called by deleted function).
2. **Rewire HandleNormalizedEvent consumers** to pull from sanctioned sources:
   - Stats aggregation → `UNIT_SPELLCAST_SUCCEEDED` for player casts, `UNIT_AURA` for aura windows, `C_DamageMeter` for totals/spell rows
   - ArenaRoundTracker pressure → Damage Meter per-source breakdowns post-combat, plus visible unit state during combat
   - SpellAttribution → `DamageMeterService.MergeDamageMeterSource()` (already exists at line 1143)
   - SessionClassifier evidence → State-based resolution already works (`ResolveContextFromState`), remove event-based evidence accumulation for duel/dummy; use `DUEL_*` events and creature-ID checks instead
3. **Quarantine**: Keep `HandleNormalizedEvent` skeleton for non-production dev/debug mode only, gated behind a `CA_DEV_CLEU` flag that is never set in production.

### Alternatives Considered
- **Keep HandleNormalizedEvent as-is, just remove CLEU registration**: Rejected because the function shapes naming, confidence labels, and downstream assumptions. The architectural drift persists.
- **Gradual deprecation with adapter layer**: Rejected as overengineered. The code paths are well-scoped; a clean cut is safer than a shim.

---

## R2: Sanctioned Timeline Model — Replacing rawEvents

### Decision
Replace the CLEU-shaped `rawEvents` ring buffer with a `timelineEvents[]` array built from sanctioned producers.

### Findings

Current `rawEvents` (CombatTracker:485):
- Ring buffer of max `MAX_RAW_EVENTS_PER_SESSION` entries
- Shape: `{timestampOffset, subEvent, eventType, sourceGuid, destGuid, spellId, amount, critical, sourceMine, destMine, ...}`
- Used for: death cause analysis (last 6 damage events), opener sequence (first 5 player casts), replay timeline, detail view
- **Problem**: Only populated from CLEU events. In Midnight arena, ring buffer stays empty → Detail and Replay views show nothing.

### New Timeline Schema

```
timelineEvent = {
  t            : number,        -- seconds from session start
  lane         : string,        -- classification (see below)
  type         : string,        -- sub-classification within lane
  spellId      : number?,       -- spell/ability ID when applicable
  spellName    : string?,       -- localized name (for display)
  unitToken    : string?,       -- source or target unit token
  guid         : string?,       -- source or target GUID
  amount       : number?,       -- damage/healing/absorb amount
  source       : string,        -- provenance enum value
  confidence   : string,        -- "confirmed" | "partial" | "estimated"
  meta         : table?,        -- lane-specific extra data
}
```

**Lane types and their producers**:

| Lane | Producer | Source Provenance |
|------|----------|-------------------|
| `player_cast` | `UNIT_SPELLCAST_SUCCEEDED` | `state` |
| `visible_aura` | `UNIT_AURA` (applied/removed) | `visible_unit` |
| `cc_received` | `LOSS_OF_CONTROL_*`, `PLAYER_CONTROL_*`, DR APIs | `loss_of_control` |
| `dr_update` | `UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED` | `spell_diminish` |
| `kill_window` | Derived from healer-CC + burst timing | `estimated` |
| `death` | Player death event + last defensive state | `state` |
| `match_state` | `PVP_MATCH_*`, `DUEL_*`, round markers | `state` |
| `inspect` | `INSPECT_READY` completion | `inspect` |
| `dm_checkpoint` | `DAMAGE_METER_*_UPDATED` events | `damage_meter` |
| `dm_spell` | C_DamageMeter spell row imports | `damage_meter` |
| `dm_enemy_spell` | C_DamageMeter Enemy Damage Taken rows | `damage_meter` |

### Migration
- Existing sessions with `rawEvents` remain readable via legacy adapter
- New sessions populate `timelineEvents` instead
- `rawEvents` field deprecated but not deleted in schema migration (read-only fallback)

### Alternatives Considered
- **Keep rawEvents and add timelineEvents alongside**: Rejected — dual schemas create confusion and double storage. Clean break preferred.
- **Convert rawEvents to timelineEvents on migration**: Rejected — old rawEvents are CLEU-shaped with different provenance guarantees. Better to leave them as-is for legacy display and only produce timelineEvents for new sessions.

---

## R3: Session Lifecycle Reliability

### Decision
Session lifecycle anchored on `PLAYER_REGEN_DISABLED` → combat → `PLAYER_REGEN_ENABLED` + Damage Meter stabilization delay.

### Findings

Current lifecycle (CombatTracker):
- **Start**: `HandlePlayerRegenDisabled()` (line 2061) — already state-based, calls `SessionClassifier:ResolveContextFromState()`
- **Finalize triggers**: PLAYER_REGEN_ENABLED (0.5s delay), OnUpdate timeout (context-specific: 6-20s), context transition, DM events (0.2-0.35s delay), PVP_MATCH_COMPLETE
- **DM retry**: Up to 3 retries at 0.75s intervals if DamageMeter import finds no data
- **Problem**: Multiple finalize triggers can race. Finalization is idempotent (checks `state == "active"`), which is correct.

### Key Design Decisions
1. **Keep PLAYER_REGEN_DISABLED as primary combat start** — already works, well-tested
2. **Keep multi-trigger finalization** but add a stabilization window:
   - After PLAYER_REGEN_ENABLED, wait for DM stabilization (configurable, default 1.5s)
   - After DM stabilization, finalize with best available data
   - If DM import still empty after 3 retries, finalize with `provenance = "state"` only
3. **Arena sessions**: Pre-created from match/prep events, combat start links to existing shell
4. **Duel sessions**: Created on `DUEL_INBOUNDS` (not DUEL_REQUESTED), finalized on `DUEL_FINISHED`
5. **Dummy sessions**: Created on PLAYER_REGEN_DISABLED + positive dummy identification

### Alternatives Considered
- **Start sessions from DM events only**: Rejected — DM events fire too late for opener capture and context classification.
- **Remove OnUpdate timeout**: Rejected — still needed as safety net for edge cases (e.g., logout mid-combat).

---

## R4: Arena Match and Round Identity

### Decision
Keep existing match/round key scheme, enhance with field-level slot confidence.

### Findings

Current identity model (ArenaRoundTracker):
- **matchKey**: `player={guid}|map={mapId}|ctx={context}|sub={subcontext}|joined={timestamp}` (line 87-95)
- **roundKey**: `{matchKey}|round={roundIndex}|roster={rosterSignature}` (line 116-119)
- **rosterSignature**: Sorted `{slot}:{guid or "?"}:{prepSpecId or 0}:{classFile or "?"}` (line 99-114)
- **Solo Shuffle**: Each round gets unique roundKey due to roster changes. Match key stays stable.

This scheme is **already correct and stable**. The gaps are:
1. No field-level confidence on slots (prep vs visible vs inspect)
2. Unresolved GUIDs staged but not tracked with provenance
3. No explicit "round incomplete" marker for early-leave scenarios

### Enhancements
1. Add `slot.fieldConfidence` object:
   ```
   fieldConfidence = {
     spec = "prep" | "visible" | "inspect",
     guid = "prep" | "visible" | "inspect",
     pvpTalents = "inspect" | nil,
     talentImportString = "inspect" | nil,
     pressure = "cleu" | "damage_meter" | "estimated",
     learnedAt = { spec = timestamp, guid = timestamp, ... }
   }
   ```
2. Add `round.completionState` = "complete" | "partial_leaver" | "partial_disconnect"
3. Preserve existing matchKey/roundKey generation — it works correctly

### Alternatives Considered
- **Hash-based matchKey instead of concatenated string**: Rejected — current format is human-readable for debugging, and key uniqueness is already guaranteed by the timestamp component.

---

## R5: Spell Registration Without CLEU

### Decision
Player spells from UNIT_SPELLCAST_SUCCEEDED + UNIT_AURA + DM spell rows. Enemy spells from DM Enemy Damage Taken + Death Recap + visible CC/LOC only.

### Findings

Current spell tracking:
- `UpdateSpellStats()` in HandleNormalizedEvent — processes every CLEU event for spell aggregation
- `session.spells[spellId]` stores: castCount, hitCount, critCount, totalDamage, totalHealing, overkill, intervals, etc.
- `SpellAttributionPipeline` tracks enemy-source damage via CLEU events (line 202-264)
- `DamageMeterService.ImportSession()` already merges DM spell rows (line 987-1175)
- `DamageMeterService.MergeDamageMeterSource()` already feeds SpellAttribution (line 1143-1155)

### New Spell Data Flow

**Player spells**:
1. `UNIT_SPELLCAST_SUCCEEDED` → timeline event (player_cast lane) + spell cast count tracking
2. `UNIT_AURA` → timeline event (visible_aura lane) + aura window tracking
3. C_DamageMeter spell rows → post-combat spell totals (damage, healing amounts)
4. Reconcile: cast counts from live events, damage amounts from DM import

**Enemy spells**:
1. C_DamageMeter Enemy Damage Taken rows → enemy spell damage to player (post-combat)
2. C_DamageMeter Death Recap rows → killing blow and recent damage sequence (post-combat)
3. Visible CC/LOC/DR APIs → enemy CC on player (live)
4. Inspect → enemy build/talents (out-of-combat)
5. **Never fabricated** — estimated enemy data carries `confidence = "estimated"` and is visually distinct

### Alternatives Considered
- **Parse DM spell names to infer enemy casts**: Rejected — DM provides spell IDs directly, no parsing needed.
- **Track enemy casts from UNIT_SPELLCAST_SUCCEEDED with enemy tokens**: Viable for visible enemies only. Worth adding but must be tagged as `confidence = "partial"` since not all enemy casts are visible.

---

## R6: Confidence/Provenance Model

### Decision
Replace CLEU-centric ANALYSIS_CONFIDENCE enum with provenance-centric labels.

### Findings

Current labels (Constants.lua:68-75):
- `FULL_RAW`, `ENRICHED`, `RESTRICTED_RAW`, `DEGRADED`, `PARTIAL_ROSTER`, `UNKNOWN`
- These describe CLEU data quality, not actual provenance

### New Labels

**Session-level capture quality** (`session.captureQuality.confidence`):
- `STATE_PLUS_DAMAGE_METER` — Full state tracking + successful DM import (best Midnight quality)
- `DAMAGE_METER_ONLY` — DM import succeeded but limited state tracking
- `VISIBLE_CC_ONLY` — Only CC/LOC data available, no DM import
- `PARTIAL_ROSTER` — Arena with incomplete slot resolution
- `ESTIMATED` — Coaching insights derived from partial data
- `LEGACY_CLEU_IMPORT` — Old session from pre-Midnight schema

**Per-field provenance** (`source` field on timeline events and slot fields):
- `state` — From session state events (REGEN, PVP_MATCH, DUEL)
- `damage_meter` — From C_DamageMeter APIs
- `visible_unit` — From UNIT_AURA, UNIT_SPELLCAST_SUCCEEDED, ARENA_OPPONENT_UPDATE
- `inspect` — From NotifyInspect / INSPECT_READY
- `loss_of_control` — From LOSS_OF_CONTROL_*, PLAYER_CONTROL_*
- `spell_diminish` — From UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED
- `estimated` — Derived/calculated, not directly observed
- `legacy_import` — Migrated from old schema

### Alternatives Considered
- **Keep old labels + add new ones**: Rejected — creates confusion. Clean replacement with migration for old sessions.

---

## R7: UI Chart Primitives

### Decision
Build 9 reusable chart widgets in Widgets.lua using the existing texture + vertex-coloring pattern.

### Findings

Existing infrastructure:
- ✅ `CreateMetricCard()`, `CreateMetricBar()`, `CreateSpellRow()`, `CreateInsightCard()`, `CreatePill()`, `CreateConfidenceBadge()` — good foundation
- ✅ Texture pooling pattern (CombatDetailView), dot+line chart (RatingView), lane bars (ReplayView)
- ✅ Theme system with 18 color keys, class colors, severity colors
- ❌ No abstracted chart primitives — each page reimplements chart logic

### New Widgets

| Widget | Pattern Source | Purpose |
|--------|---------------|---------|
| `Sparkline` | RatingView dot+line | Compact trend line (history rows, dummy trends) |
| `SegmentedBar` | MetricBar extension | Multi-segment colored bar (damage/healing/taken split) |
| `MirroredDeltaBar` | New | Two-sided bar comparing two values (matchup, builds) |
| `HeatGrid` | New | N×M colored cell grid (spec heat-grid, matchup matrix) |
| `TimelineLane` | ReplayView lanes | Single horizontal lane with events (detail timeline) |
| `Gauge` | New | Semi-circular or linear gauge (threat level, consistency) |
| `ConfidencePill` | CreatePill extension | Provenance-aware colored pill with tooltip |
| `MiniLegend` | New | Compact color legend strip for charts |
| `DeltaBadge` | New | +/- delta indicator with color coding |

All use `WHITE8x8` texture + `SetVertexColor()` — no external texture dependencies.

---

## R8: Schema Migration v5 → v6

### Decision
Additive migration: new fields added with defaults, old fields preserved read-only.

### Findings

Current schema: v5 (Constants.lua:5). Migration chain: v1→v2→v3→v4→v5 in CombatStore.lua (lines 399-517).

### Migration Steps (v5 → v6)

1. **Add `timelineEvents = {}`** to all sessions (empty for old, populated for new)
2. **Add `provenance = {}`** field to sessions — maps field names to source enum values
3. **Preserve `rawEvents`** — not deleted, marked as legacy read-only
4. **Add `fieldConfidence`** to arena slot records
5. **Map old confidence labels** to new provenance-centric labels:
   - `FULL_RAW` → `LEGACY_CLEU_IMPORT`
   - `ENRICHED` → `LEGACY_CLEU_IMPORT`
   - `RESTRICTED_RAW` → `STATE_PLUS_DAMAGE_METER`
   - `DEGRADED` → `DAMAGE_METER_ONLY`
   - `PARTIAL_ROSTER` → `PARTIAL_ROSTER` (unchanged)
   - `UNKNOWN` → `ESTIMATED`
6. **Bump SCHEMA_VERSION** to 6

### Alternatives Considered
- **Delete rawEvents on migration**: Rejected — loses historical replay data for old sessions.
- **Re-derive timelineEvents from old rawEvents**: Rejected — different provenance guarantees; mixing would be misleading.

---

## R9: Duel and Dummy Session Correctness

### Decision
Duel lifecycle driven entirely by DUEL_* events. Dummy detection by creature ID + seeded name catalog.

### Findings

**Duel** — Current flow:
- `DUEL_REQUESTED` sets `pendingDuel` state in SessionClassifier
- Combat start links to pending duel via opponent name matching
- `DUEL_FINISHED` triggers finalization
- Gap: canceled/expired duels can leave `pendingDuel` state stale

**Fix**: Add timeout on `pendingDuel` (30s). On `DUEL_FINISHED` with no active session, clean up silently. Create session only on `DUEL_INBOUNDS` (confirms duel accepted and started).

**Dummy** — Current flow:
- Detection via `Constants.TRAINING_DUMMY_CREATURE_IDS` and `Constants.TRAINING_DUMMY_PATTERNS`
- Scoring: 100 (creature ID), 85 (creature ID + name), 70 (name only)
- Threshold: 70

**This is already correct.** The `SeedDummyCatalog.lua` provides comprehensive creature IDs. Enhancement: also check `UnitClassification("target")` for "dummy" or "trivial" to prevent false positives from name-only matches near non-dummy NPCs.

---

## R10: DamageMeter Integration Depth

### Decision
DamageMeter is the post-combat source of truth for damage totals, spell breakdowns, and enemy attribution. Pre-combat state tracking provides session boundaries and context.

### Findings

DamageMeterService already provides:
- Session discovery: `FindSessionsForImport()` with scoring (duration match, signal strength, context fit)
- Snapshot building: `BuildHistoricalSnapshot()` with totals, spell rows, per-source breakdowns
- Import merging: `ImportSession()` with reconciliation (FULL_RAW → DEGRADED confidence)
- Per-source enemy damage: `MergeDamageMeterSource()` feeds SpellAttribution
- Spell resolution: `ResolveSpellBreakdownSource()` chooses DamageDone vs EnemyDamageTaken

**12.0.1 additions**: Enemy Damage Taken and Death Recap categories. These are already partially handled — `CollectEnemyDamageSnapshotForCurrent()` iterates `combatSources`. Need to:
1. Check for Death Recap category availability (`Enum.DamageMeterType.DeathRecap` or equivalent)
2. Merge Death Recap rows into timeline as `dm_enemy_spell` lane events
3. Handle graceful fallback when categories are unavailable

### Alternatives Considered
- **Replace DamageMeter with manual tracking**: Not viable — DamageMeter is the only sanctioned source for accurate damage numbers in Midnight.
