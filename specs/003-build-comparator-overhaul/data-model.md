# Data Model: Build Comparator Overhaul

**Feature**: `003-build-comparator-overhaul` | **Date**: 2026-03-28
**Spec**: [spec.md](spec.md) | **Research**: [research.md](research.md)

---

## Entity Relationship Overview

```
BuildProfile (catalog entry, persisted)
  ├── embeds BuildIdentity (canonical content)
  ├── embeds LoadoutMetadata[] (associated loadout slots)
  └── references Session[] via buildId on each session.playerSnapshot

Session (existing entity, enhanced)
  └── playerSnapshot
        ├── buildId → BuildProfile
        ├── loadoutId → (loadout fingerprint, no catalog entry)
        └── snapshotFreshness (enum: FRESH | PENDING | DEGRADED | UNAVAILABLE)

ComparisonResult (in-memory, not persisted)
  ├── buildA → BuildProfile
  ├── buildB → BuildProfile
  ├── scope  → ComparisonScope (serialized as cache key)
  ├── confidence → ConfidenceTier
  └── diff   → BuildDiff
```

---

## Entity 1 — BuildIdentity (Embedded Value Object)

Not stored as a standalone table. Embedded within `BuildProfile` and reconstructed from `playerSnapshot` for identity computation.

| Field | Type | Description | Notes |
|-------|------|-------------|-------|
| `buildIdentityVersion` | number | Prefix marker for hash space versioning. | Constant = 1 for v1. Increment forces full re-hash. |
| `classId` | number | WoW numeric class identifier. | From `UnitClassBase("player")` |
| `specId` | number | WoW numeric specialization identifier. | From `GetSpecializationInfo` |
| `heroTalentSpecId` | number \| nil | Hero talent tree identifier. | nil if hero tree not yet chosen |
| `talentSignature` | string | Serialized, sorted `nodeId:entryId:rank` triples. | Produced by `serializeTalentNodes()` |
| `pvpTalentSignature` | string | Comma-separated sorted PvP talent IDs. | Empty string if none selected |

**Derived field**: `buildId` = `SHA256(buildIdentityVersion + "#" + classId + "#" + specId + "#" + heroTalentSpecId + "#" + pvpTalentSignature + "#" + talentSignature)` truncated to 40 hex chars.

**Validation rules**:
- `classId` and `specId` MUST be non-zero for a full-confidence identity.
- If `heroTalentSpecId` is nil, treat as `0` in hash input.
- `talentSignature` MAY be empty for a zero-talent snapshot — buildId is still computable.

**State transitions**: BuildIdentity is immutable once computed. Recalculation produces a new value and potentially a new `buildId`.

---

## Entity 2 — LoadoutMetadata (Embedded Value Object)

Attached to `playerSnapshot` on each session. Not stored as a first-class catalog entry.

| Field | Type | Description | Notes |
|-------|------|-------------|-------|
| `loadoutId` | string | Fingerprint of Blizzard loadout slot + import string prefix. | 40-char hex hash |
| `activeConfigId` | number | Blizzard loadout slot identifier (1–4 typically). | Stored for audit; excluded from buildId |
| `importString` | string \| nil | Full import string from Blizzard API. | First 64 chars used in loadoutId hash |
| `loadoutName` | string \| nil | Player-assigned loadout name if available. | Cosmetic only |

**Derived field**: `loadoutId` = `SHA256(activeConfigId + "#" + importString[1..64])` truncated to 40 hex chars.

---

## Entity 3 — BuildProfile (Persisted Catalog Entry)

Stored in `db.buildCatalog.byId[buildId]`. One entry per distinct canonical build.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `buildId` | string | ✓ | Canonical identity hash (40-char hex). Primary key. |
| `buildIdentityVersion` | number | ✓ | Version of identity computation used. |
| `classId` | number | ✓ | WoW class identifier. |
| `specId` | number | ✓ | WoW specialization identifier. |
| `heroTalentSpecId` | number \| nil | — | Hero talent tree identifier; nil if absent. |
| `talentSignature` | string | ✓ | Serialized talent nodes; reproducible. |
| `pvpTalentSignature` | string | ✓ | Sorted PvP talent IDs. |
| `displayNames` | string[] | ✓ | Ordered list: first is canonical label. |
| `aliases` | string[] | — | Player-assigned or auto-generated alternate names. |
| `associatedLoadoutIds` | string[] | — | All loadout identifiers seen for this build. |
| `legacyBuildHashes` | string[] | — | Prior hash values before v6→v7 migration. |
| `firstSeenAt` | number | ✓ | Unix timestamp of first detection. |
| `lastSeenAt` | number | ✓ | Unix timestamp of most recent detection. |
| `latestSessionId` | string \| nil | — | ID of the most recent session under this build. |
| `sessionCount` | number | ✓ | Count of sessions attributed to this build. |
| `characterKey` | string | ✓ | `"Name-Realm"` — owner of this profile. |
| **State flags** | | | |
| `isCurrentBuild` | boolean | ✓ | True when this is the player's active talent setup. |
| `isArchived` | boolean | ✓ | True when manually archived. |
| `isLowConfidence` | boolean | ✓ | True when sample count < LOW_CONFIDENCE threshold. |
| `isMigrated` | boolean | ✓ | True when created during v6→v7 migration. |
| `isMigratedWithWarnings` | boolean | — | True when migration data was incomplete. |

**Catalog index structure** (`db.buildCatalog`):
```lua
db.buildCatalog = {
    order = { buildId1, buildId2, ... },  -- insertion-ordered array for deterministic iteration
    byId  = {
        [buildId] = BuildProfile,
        ...
    }
}
```

**Validation rules**:
- `buildId` MUST match the hash of the profile's own identity fields.
- `sessionCount` MUST be ≥ 0.
- `firstSeenAt` MUST be ≤ `lastSeenAt`.
- A `characterKey` MUST be present — cross-character profiles are out of scope.

---

## Entity 4 — SessionSnapshot (Enhanced Existing Entity)

Lives at `session.playerSnapshot` (existing field). Three new fields are added.

| Field | Type | Change | Description |
|-------|------|--------|-------------|
| `buildId` | string | **NEW** | Canonical build identifier at session start. |
| `loadoutId` | string | **NEW** | Loadout fingerprint at session start. |
| `snapshotFreshness` | string | **NEW** | Freshness state at session capture time. See enum below. |
| *(all existing fields)* | — | unchanged | specId, heroTalentSpecId, importString, talentNodes[], pvpTalents[], gear, itemLevel, etc. |

**SnapshotFreshness enum** (defined in Constants.lua):

| Value | Meaning |
|-------|---------|
| `FRESH` | Snapshot captured after a valid full refresh; all fields are current. |
| `PENDING_REFRESH` | Refresh event received but talent data not yet fully loaded. |
| `DEGRADED` | Snapshot is available but based on incomplete talent data. |
| `UNAVAILABLE` | No snapshot could be captured (talents API unavailable). |

---

## Entity 5 — ComparisonScope (In-Memory Parameter Object)

Passed to comparison queries. Serialized to a stable string key for in-memory caching.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `characterKey` | string | current character | `"Name-Realm"` |
| `specId` | number | current spec | Filters to sessions with this specialization. |
| `context` | string \| nil | last-used context | `CONTEXT` enum value (ARENA, DUEL, etc.) |
| `bracket` | string \| nil | nil (all) | Subcontext filter (e.g., `"2v2"`, `"3v3"`). |
| `opponentClassId` | number \| nil | nil (all) | Filter by opponent class. |
| `opponentSpecId` | number \| nil | nil (all) | Filter by opponent spec (when available). |
| `dateFrom` | number \| nil | nil (no lower bound) | Unix timestamp lower bound. |
| `dateTo` | number \| nil | nil (no upper bound) | Unix timestamp upper bound. |

**Serialized scope key format**: `characterKey:specId:context:bracket:opponentClassId:opponentSpecId:dateFrom:dateTo`

**Persistence**: last-used scope is stored at `db.characterPrefs[characterKey].lastComparatorScope` (added in CombatStore migration).

---

## Entity 6 — ComparisonResult (In-Memory Output)

Produced by `BuildComparisonService:Compare(buildIdA, buildIdB, scope)`. Never persisted.

| Field | Type | Description |
|-------|------|-------------|
| `buildA` | BuildProfile | Profile for left-side build. |
| `buildB` | BuildProfile | Profile for right-side build. |
| `scope` | ComparisonScope | Scope used to filter sessions. |
| `samplesA` | number | Count of sessions matching scope for Build A. |
| `samplesB` | number | Count of sessions matching scope for Build B. |
| `metricsA` | MetricSummary \| nil | Aggregated metrics for Build A; nil if no data. |
| `metricsB` | MetricSummary \| nil | Aggregated metrics for Build B; nil if no data. |
| `confidenceA` | ConfidenceTier | Confidence classification for Build A. |
| `confidenceB` | ConfidenceTier | Confidence classification for Build B. |
| `diff` | BuildDiff | Human-readable talent diff between A and B. |
| `computedAt` | number | Unix timestamp of computation. |

**MetricSummary** (embedded in ComparisonResult):

| Field | Type | Description |
|-------|------|-------------|
| `winRate` | number \| nil | Win rate in scope (0.0–1.0). nil if no win/loss data. |
| `pressureScore` | number \| nil | Average pressure score in scope. |
| `burstScore` | number \| nil | Average burst score in scope. |
| `survivalScore` | number \| nil | Average survivability score in scope. |

---

## Entity 7 — BuildDiff (Embedded in ComparisonResult)

Represents a structured talent delta between Build A and Build B.

| Field | Type | Description |
|-------|------|-------------|
| `heroTalentChange` | HeroTalentChange \| nil | Hero talent tree or hero spec difference. |
| `pvpTalentChanges` | PvPTalentChange[] | Added/removed PvP talent changes. |
| `talentChanges` | TalentChange[] | Added/removed/changed PvE talent node changes. |
| `isIdentical` | boolean | True when A and B have no talent differences. |
| `totalChanges` | number | Count of all changes (for compact display). |

**HeroTalentChange** (embedded):

| Field | Type | Description |
|-------|------|-------------|
| `inA` | number \| nil | heroTalentSpecId in Build A (nil = not selected). |
| `inB` | number \| nil | heroTalentSpecId in Build B. |
| `nameA` | string \| nil | Display name for A's hero tree (if available). |
| `nameB` | string \| nil | Display name for B's hero tree. |

**PvPTalentChange** (per changed PvP slot):

| Field | Type | Description |
|-------|------|-------------|
| `talentId` | number | PvP talent ID. |
| `spellName` | string \| nil | Localized spell name (if available). |
| `inA` | boolean | Present in Build A. |
| `inB` | boolean | Present in Build B. |

**TalentChange** (per changed PvE node):

| Field | Type | Description |
|-------|------|-------------|
| `nodeId` | number | Stable talent tree node identifier. |
| `changeType` | string | `"added"`, `"removed"`, `"choice_changed"`, `"rank_changed"` |
| `entryIdA` | number \| nil | Entry (choice) selected in Build A. |
| `entryIdB` | number \| nil | Entry (choice) selected in Build B. |
| `rankA` | number \| nil | Rank in Build A. |
| `rankB` | number \| nil | Rank in Build B. |
| `spellNameA` | string \| nil | Localized spell name for A's selection. |
| `spellNameB` | string \| nil | Localized spell name for B's selection. |

**Importance ordering for display** (highest first):
1. Hero talent tree change
2. PvP talent changes
3. Choice node changes (`choice_changed`)
4. Talent additions/removals
5. Rank changes

---

## Entity 8 — ConfidenceTier (Enum/Constants)

Defined in `Constants.lua`. Used in ComparisonResult and UI badges.

| Constant | Value | Threshold | Description |
|----------|-------|-----------|-------------|
| `CONFIDENCE_TIER.NO_DATA` | `"no_data"` | 0 sessions | No recorded history in scope. |
| `CONFIDENCE_TIER.LOW` | `"low"` | 1–4 sessions | Small sample; high variance expected. |
| `CONFIDENCE_TIER.MEDIUM` | `"medium"` | 5–14 sessions | Growing sample; metrics are indicative. |
| `CONFIDENCE_TIER.HIGH` | `"high"` | ≥15 sessions | Reliable sample for comparison. |

**Thresholds stored as constants** (not hardcoded in comparison logic):
```lua
Constants.CONFIDENCE_TIER_THRESHOLDS = {
    LOW_MIN    = 1,
    MEDIUM_MIN = 5,
    HIGH_MIN   = 15,
}
```

---

## Schema Migration Delta (v6 → v7)

### New top-level db key
```lua
db.buildCatalog = { order = {}, byId = {} }
```

### Fields added to each `session.playerSnapshot`
```lua
playerSnapshot.buildId         -- string | nil (nil on pre-migration sessions until stamped)
playerSnapshot.loadoutId       -- string | nil
playerSnapshot.snapshotFreshness -- string (SnapshotFreshness enum)
```

### Fields added to `db`
```lua
db.characterPrefs = db.characterPrefs or {}
db.characterPrefs[characterKey] = {
    lastComparatorScope = nil,  -- serialized ComparisonScope string
}
```

### Migration idempotence guarantee
- Gate condition: `db.schemaVersion < 7`
- All stamped fields are set only if nil (never overwrites previously migrated data)
- Duplicate profile detection: if `db.buildCatalog.byId[buildId]` already exists, merge `legacyBuildHashes` only

---

## Data Flow Summary

```
WoW Talent UI event
        │
        ▼
SnapshotService.lua
  → captures talentNodes, pvpTalents, heroTalentSpecId
  → calls BuildHash.ComputeBuildId()  → buildId
  → calls BuildHash.ComputeLoadoutId() → loadoutId
  → sets snapshotFreshness
        │
        ▼
BuildCatalogService.lua
  → RegisterOrUpdate(buildId, snapshot)
  → updates db.buildCatalog
        │
        ▼
CombatTracker.lua (session start)
  → attaches buildId, loadoutId, snapshotFreshness to session.playerSnapshot
        │
        ▼
CombatStore.lua (session persist)
  → stores session with enriched playerSnapshot
        │
        ▼
BuildComparisonService.lua (on-demand)
  → Compare(buildIdA, buildIdB, scope)
  → scans db.combats.byId with filter closure
  → produces ComparisonResult + BuildDiff
        │
        ▼
BuildComparatorView.lua (render only)
  → reads ComparisonResult from service
  → renders labels, metrics, confidence badges, diff panel
```
