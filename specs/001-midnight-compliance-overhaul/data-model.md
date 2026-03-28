# Data Model: Midnight 12.0.1 Compliance Overhaul

**Branch**: `001-midnight-compliance-overhaul` | **Date**: 2026-03-28

## Schema Version

Current: **5** → Target: **6**

Migration is additive. New fields have defaults. Old fields preserved read-only.

---

## Core Entities

### 1. Combat Session (Primary Entity)

The central persisted record. One session = one discrete combat encounter (one arena round, one duel, one dummy pull).

```
Session {
  -- Identity
  id                  : string           -- UUID
  schemaVersion       : number           -- 6 for new sessions
  timestamp           : number           -- server time at creation
  startedAt           : number           -- server time at combat start
  endedAt             : number           -- server time at finalization
  duration            : number           -- seconds (endedAt - startedAt)
  state               : "active" | "finalized"

  -- Context
  context             : CONTEXT          -- ARENA | DUEL | TRAINING_DUMMY | BATTLEGROUND | WORLD_PVP | GENERAL
  subcontext          : SUBCONTEXT       -- SOLO_SHUFFLE | RATED_ARENA | SKIRMISH | TO_THE_DEATH | etc.
  zoneName            : string
  mapId               : number
  bracket             : number?          -- arena bracket size (2, 3, 5)
  isRated             : boolean

  -- Identity / Classification
  identity            : SessionIdentity  -- from SessionClassifier
  identitySource      : "state" | "event" | "legacy"

  -- Player Snapshot (at combat start)
  playerSnapshot      : PlayerSnapshot

  -- Primary Opponent
  primaryOpponent     : OpponentRecord?

  -- Timeline (NEW in v6 — replaces rawEvents for new sessions)
  timelineEvents      : TimelineEvent[]  -- ordered by t

  -- Legacy (preserved read-only for old sessions)
  rawEvents           : RawEvent[]?      -- ring buffer from CLEU era
  rawEventWrap        : boolean?
  rawEventWriteHead   : number?

  -- Spell Aggregates
  spells              : map<spellId, SpellAggregate>

  -- Aura Windows
  auras               : map<auraKey, AuraAggregate>

  -- Cooldown Tracking
  cooldowns           : map<spellId, CooldownAggregate>

  -- Totals
  totals              : SessionTotals
  localTotals         : SessionTotals?   -- from live tracking
  importedTotals      : SessionTotals?   -- from DamageMeter

  -- Attribution
  attribution         : Attribution | false

  -- Arena-specific
  arena               : ArenaSessionData | false

  -- Metrics (computed at finalization)
  metrics             : SessionMetrics

  -- Coaching
  suggestions         : Suggestion[]
  openerSequence      : OpenerSequence?

  -- Provenance (NEW in v6)
  provenance          : map<fieldName, ProvenanceSource>

  -- Capture Quality
  captureQuality      : CaptureQuality

  -- DamageMeter Import
  import              : ImportMetadata

  -- Result
  result              : SESSION_RESULT   -- WON | LOST | TRADED | DISENGAGED | DRAW | UNKNOWN

  -- Rating
  ratingSnapshot      : RatingSnapshot?

  -- Actors (unit snapshots seen during session)
  actors              : map<guid, ActorSnapshot>
}
```

**Relationships**:
- Belongs to ArenaMatch (via `arena.matchKey`) when context is ARENA
- Contains 0..N TimelineEvents
- Contains 0..N Suggestions
- References PlayerSnapshot (embedded)
- References 0..1 PrimaryOpponent

---

### 2. Timeline Event (NEW — replaces rawEvents)

```
TimelineEvent {
  t                   : number           -- seconds from session start
  lane                : TimelineLane     -- classification
  type                : string           -- sub-classification within lane
  spellId             : number?
  spellName           : string?
  unitToken           : string?          -- e.g., "arena1", "target"
  guid                : string?
  amount              : number?          -- damage/healing/absorb
  source              : ProvenanceSource -- which API produced this
  confidence          : "confirmed" | "partial" | "estimated"
  meta                : table?           -- lane-specific extra data
}
```

**Lane types** (TimelineLane enum):
- `player_cast` — Player spell casts from UNIT_SPELLCAST_SUCCEEDED
- `visible_aura` — Aura applied/removed from UNIT_AURA
- `cc_received` — CC on player from LOSS_OF_CONTROL / PLAYER_CONTROL
- `dr_update` — DR state change from UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED
- `kill_window` — Derived burst+healer-CC window (estimated)
- `death` — Player death with defensive state context
- `match_state` — Round/match/duel state transitions
- `inspect` — Inspect completion markers
- `dm_checkpoint` — DamageMeter update events
- `dm_spell` — DamageMeter player spell row imports
- `dm_enemy_spell` — DamageMeter enemy damage/death recap rows

**Meta examples by lane**:
- `player_cast.meta`: `{ isOffensive, isDefensive, isTrinket, isCooldown }`
- `cc_received.meta`: `{ drCategory, duration, isImmune, spellName }`
- `kill_window.meta`: `{ healerCCSpellId, burstSpellIds[], converted }`
- `death.meta`: `{ lastDefensiveSpellId, lastDefensiveAge, killingBlowSpellId }`
- `dm_enemy_spell.meta`: `{ sourceGuid, sourceName, sourceClassFile }`

---

### 3. Arena Match

```
ArenaMatch {
  matchKey            : string           -- "player={guid}|map={mapId}|ctx={ctx}|sub={sub}|joined={ts}"
  playerGuid          : string
  mapId               : number
  context             : CONTEXT
  subcontext          : SUBCONTEXT
  bracket             : number
  joinedAt            : number           -- server timestamp
  state               : "prep" | "active" | "complete"
  completedAt         : number?
  result              : SESSION_RESULT?
  metadata            : MatchMetadata?

  -- Rounds
  rounds              : ArenaRound[]

  -- Prep data (captured before combat)
  prepOpponents       : map<slot, PrepOpponentData>
}
```

**Relationships**:
- Contains 1..N ArenaRounds
- Contains 1..N PrepOpponentData
- Referenced by CombatSessions (via matchKey)

---

### 4. Arena Round

```
ArenaRound {
  roundKey            : string           -- "{matchKey}|round={idx}|roster={sig}"
  roundIndex          : number           -- 1-based
  rosterSignature     : string           -- sorted slot+guid+spec hash
  state               : "active" | "complete" | "partial_leaver" | "partial_disconnect"
  startedAt           : number?
  endedAt             : number?
  endReason           : string?          -- "pvp_match_complete", "timeout", etc.
  winner              : number?          -- faction index
  duration            : number?

  -- Slots
  slots               : map<slotNumber, ArenaSlot>

  -- Unresolved GUIDs (staging)
  unresolvedGuids     : map<guid, UnresolvedGuidRecord>

  -- GUID-to-slot mapping
  guidToSlot          : map<guid, slotNumber>
}
```

---

### 5. Arena Slot (Enhanced with field-level confidence)

```
ArenaSlot {
  -- Core identity
  slot                : number           -- 1-5
  unitToken           : string           -- "arena1".."arena5"
  visible             : boolean

  -- Identity fields
  guid                : string?
  name                : string?
  className           : string?
  classFile           : string?
  classId             : number?
  raceName            : string?
  raceFile            : string?
  raceId              : number?
  healthMax           : number?

  -- Spec (from prep or inspect)
  prepSpecId          : number?
  prepSpecName        : string?
  prepSpecIconId      : number?
  prepRole            : string?
  prepClassFile       : string?
  specId              : number?          -- best known (prep or inspect)
  specName            : string?

  -- Inspect data
  pvpTalents          : number[]?        -- PvP talent IDs
  talentImportString  : string?          -- full build string

  -- DR State
  drState             : map<category, DRRecord>

  -- Pressure metrics
  damageToPlayer      : number           -- cumulative damage dealt to player
  damageTakenFromPlayer : number         -- cumulative damage taken from player
  ccOnPlayer          : number           -- CC applications on player
  killParticipation   : number
  pressureScore       : number           -- weighted composite

  -- Lifecycle
  isDead              : boolean
  lastSeenAt          : number?
  lastUpdateReason    : string?          -- "seen" | "unseen"
  lastUpdateAt        : number?

  -- Field-level confidence (NEW in v6)
  fieldConfidence     : SlotFieldConfidence
}
```

---

### 6. Slot Field Confidence (NEW)

```
SlotFieldConfidence {
  spec                : "prep" | "visible" | "inspect" | nil
  guid                : "prep" | "visible" | "inspect" | nil
  name                : "visible" | "inspect" | nil
  class               : "prep" | "visible" | "inspect" | nil
  pvpTalents          : "inspect" | nil
  talentImportString  : "inspect" | nil
  pressure            : "damage_meter" | "visible_unit" | "estimated" | nil

  -- When each field was learned
  learnedAt           : map<fieldName, number>  -- server timestamps
}
```

---

### 7. Player Snapshot

```
PlayerSnapshot {
  guid                : string
  name                : string
  realm               : string
  classFile           : string
  specId              : number
  specName            : string
  activeConfigId      : number?
  heroTalentSpecId    : number?
  talentNodes         : TalentNode[]
  pvpTalents          : number[]
  gear                : GearItem[]
  weapons             : GearItem[]
  trinkets            : GearItem[]
  averageItemLevel    : number
  equippedItemLevel   : number
  pvpItemLevel        : number?
  masteryEffect       : number?
  versatilityDamageDone : number?
  versatilityDamageTaken : number?
  buildHash           : string
  captureFlags        : { buildSnapshot: CAPTURE_QUALITY }
}
```

---

### 8. Attribution

```
Attribution {
  bySource            : map<guid, SourceAttribution>
  bySourceSpell       : map<guid, map<spellId, SpellDamageAggregate>>
  bySourceTargetSpell : map<guid, map<targetKey, map<spellId, SpellDamageAggregate>>>
  byTarget            : map<targetKey, TargetAttribution>
  summons             : map<petGuid, ownerGuid>
  reconciliation      : ReconciliationRecord
}

SourceAttribution {
  guid                : string
  name                : string?
  classFile           : string?
  specId              : number?
  specIconId          : number?
  totalAmount         : number
  hitCount            : number
  critCount           : number
  source              : ProvenanceSource  -- NEW: "damage_meter" | "visible_unit" | "legacy_import"
}
```

---

### 9. Capture Quality (Enhanced)

```
CaptureQuality {
  -- Session-level confidence (NEW labels in v6)
  confidence          : SessionConfidence

  -- Per-subsystem quality
  rawEvents           : CAPTURE_QUALITY?       -- OK | DEGRADED | OVERFLOW | RESTRICTED
  spellBreakdown      : CAPTURE_QUALITY?
  damageMeter         : CAPTURE_QUALITY?
  timeline            : CAPTURE_QUALITY?       -- NEW: quality of timelineEvents
  roster              : CAPTURE_QUALITY?       -- NEW: arena slot completeness
  cleuRestricted      : boolean
}
```

---

### 10. Trade Ledger Entry (NEW)

```
TradeLedgerEntry {
  t                   : number           -- seconds from session start
  category            : "offensive" | "defensive" | "trinket" | "cc_received" | "kill_window" | "death"
  spellId             : number?
  spellName           : string?
  targetGuid          : string?
  targetName          : string?
  duration            : number?          -- for CC/windows
  outcome             : string?          -- "converted" | "wasted" | "survived"
  source              : ProvenanceSource
  confidence          : "confirmed" | "partial" | "estimated"
}
```

---

### 11. Matchup Memory Card (NEW)

```
MatchupMemoryCard {
  specId              : number           -- opponent spec
  compKey             : string?          -- opponent comp archetype (optional)
  sampleSize          : number
  winRate             : number           -- 0.0 to 1.0
  avgDuration         : number           -- seconds
  commonDeathPattern  : string?          -- description of most common death cause
  avgFirstGoTiming    : number?          -- seconds into match
  bestBuildHash       : string?          -- highest WR build
  bestBuildWinRate    : number?
  avgHealerPressure   : number?          -- pressure score on enemy healer
  dangerSpells        : number[]?        -- top enemy threat spell IDs
  lastUpdated         : number           -- server timestamp
}
```

---

### 12. Practice Plan (NEW)

```
PracticePlan {
  generatedAt         : number
  weakAreas           : WeakArea[]
  suggestions         : PracticeSuggestion[]
}

WeakArea {
  category            : "opener" | "cc_timing" | "trinket" | "defensive" | "matchup" | "consistency"
  description         : string
  severity            : "high" | "medium" | "low"
  evidence            : string           -- data backing the assessment
}

PracticeSuggestion {
  action              : string           -- e.g., "10 opener reps on dummy"
  reason              : string           -- links to weak area
  context             : CONTEXT?         -- DUEL | TRAINING_DUMMY | ARENA
  targetSpec          : number?          -- specific spec to practice against
}
```

---

## Enums

### CONTEXT
`ARENA` | `DUEL` | `TRAINING_DUMMY` | `BATTLEGROUND` | `WORLD_PVP` | `GENERAL`

### SUBCONTEXT
`SOLO_SHUFFLE` | `RATED_ARENA` | `SKIRMISH` | `BRAWL` | `RATED_BATTLEGROUND` | `SOLO_RBG` | `RANDOM_BATTLEGROUND` | `TO_THE_DEATH` | `UNKNOWN_ARENA` | `WARGAME` | `TRAINING_GROUNDS`

### SESSION_RESULT
`WON` | `LOST` | `TRADED` | `DISENGAGED` | `DRAW` | `UNKNOWN`

### ProvenanceSource (NEW in v6)
`state` | `damage_meter` | `visible_unit` | `inspect` | `loss_of_control` | `spell_diminish` | `estimated` | `legacy_import`

### SessionConfidence (NEW in v6 — replaces ANALYSIS_CONFIDENCE)
`STATE_PLUS_DAMAGE_METER` | `DAMAGE_METER_ONLY` | `VISIBLE_CC_ONLY` | `PARTIAL_ROSTER` | `ESTIMATED` | `LEGACY_CLEU_IMPORT`

### TimelineLane (NEW in v6)
`player_cast` | `visible_aura` | `cc_received` | `dr_update` | `kill_window` | `death` | `match_state` | `inspect` | `dm_checkpoint` | `dm_spell` | `dm_enemy_spell`

### CAPTURE_QUALITY
`OK` | `DEGRADED` | `OVERFLOW` | `RESTRICTED`

---

## Aggregate Buckets (db.aggregates)

Existing buckets remain. New additions:

```
aggregates {
  -- Existing
  opponents           : map<key, OpponentAggregate>
  classes             : map<classId, ClassAggregate>
  specs               : map<specId, SpecAggregate>
  builds              : map<buildHash, BuildAggregate>
  contexts            : map<context, ContextAggregate>
  daily               : map<dateKey, DailyAggregate>
  weekly              : map<weekKey, WeeklyAggregate>
  dummyBenchmarks     : map<dummyKey, DummyAggregate>
  ratingHistory       : map<charContextKey, RatingEntry[]>
  buildEffectiveness  : map<buildHash, map<specId, EffectivenessRecord>>
  specDamageSignatures: map<specId, SpellSignature>

  -- NEW in v6
  openers             : map<matchupKey, OpenerAggregate[]>
  matchupMemory       : map<specId, MatchupMemoryCard>
  duelSeries          : map<opponentKey, DuelSeriesAggregate>
}
```

---

## Migration Plan: v5 → v6

### Step 1: Bump version
- `Constants.SCHEMA_VERSION = 6`

### Step 2: Per-session migration
For each existing session:
1. Add `timelineEvents = {}` (empty — not backfilled)
2. Add `provenance = {}` (empty — old sessions lack per-field provenance)
3. Map `captureQuality.confidence`:
   - `FULL_RAW` → `LEGACY_CLEU_IMPORT`
   - `ENRICHED` → `LEGACY_CLEU_IMPORT`
   - `RESTRICTED_RAW` → `STATE_PLUS_DAMAGE_METER`
   - `DEGRADED` → `DAMAGE_METER_ONLY`
   - `PARTIAL_ROSTER` → `PARTIAL_ROSTER`
   - `UNKNOWN` → `ESTIMATED`
4. Preserve `rawEvents` as-is (read-only legacy)

### Step 3: Arena slot migration
For each arena session with slot data:
1. Add `fieldConfidence = {}` to each slot
2. Infer initial confidence from existing data:
   - If `prepSpecId` present → `fieldConfidence.spec = "prep"`
   - If `pvpTalents` present → `fieldConfidence.pvpTalents = "inspect"`
   - If `guid` present → `fieldConfidence.guid = "visible"`

### Step 4: New aggregate buckets
- Initialize `openers = {}`, `matchupMemory = {}`, `duelSeries = {}`

### Step 5: Validate
- Verify all sessions load without error
- Verify UI pages render for mixed-schema data
