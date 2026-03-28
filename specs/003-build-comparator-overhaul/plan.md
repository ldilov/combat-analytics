# Implementation Plan: Build Comparator Overhaul

**Feature**: `003-build-comparator-overhaul` | **Date**: 2026-03-28
**Spec**: [spec.md](spec.md) | **Research**: [research.md](research.md) | **Data Model**: [data-model.md](data-model.md)

---

## Scope

Implement canonical build identity, build catalog persistence, live build detection, scoped comparison, human-readable talent diff, confidence tiers, searchable build selector, and v6→v7 schema migration.

**In scope**: All FRs in spec.md (FR-001 through FR-048), US1–US7.
**Out of scope**: Gear-based identity, cross-character comparison, import string as identity signal, opponent talent data.

---

## Proposed Design

### Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Lua 5.1 (WoW Midnight 12.0.1, Interface 120001) |
| Runtime | WoW client addon runtime |
| Persistence | SavedVariables (CombatAnalyticsDB) |
| Module system | `ns.Addon:RegisterModule()` / `:GetModule()` flat namespace |
| Hashing | Custom FNV-1a-32 (existing in Utils/Helpers.lua) or addon-safe SHA-like digest |
| UI | WoW FrameXML + UIParent widget tree (no external frameworks) |

### Architecture

Two new service modules split the work currently embedded in `BuildComparatorView.lua`:

```
┌────────────────────────────────────────────────────────────────────┐
│ Addon pipeline                                                      │
│                                                                     │
│  Events.lua  ──→  SnapshotService.lua  ──→  BuildCatalogService    │
│                         │                         │                │
│                    CombatTracker.lua              db.buildCatalog   │
│                         │                                          │
│                    CombatStore.lua (persist + migrate)             │
│                                                                     │
│  UI/BuildComparatorView.lua  ──→  BuildComparisonService  ──→      │
│            (render only)           (query + diff + confidence)     │
└────────────────────────────────────────────────────────────────────┘
```

### File Locations

All new and modified files sit at the addon root or `UI/` / `Utils/` subdirectories, consistent with the existing 34-module flat layout.

| File | Status | Description |
|------|--------|-------------|
| `Constants.lua` | Modify | Add `SCHEMA_VERSION=7`, `CONFIDENCE_TIER`, `SNAPSHOT_FRESHNESS`, `BUILD_IDENTITY_VERSION=1` |
| `Events.lua` | Modify | Wire `TRAIT_CONFIG_UPDATED` event |
| `Utils/BuildHash.lua` | Modify | Add `ComputeBuildId()`, `ComputeLoadoutId()`; keep `FromSnapshot()` for migration |
| `SnapshotService.lua` | Modify | Add `buildId`/`loadoutId`/`snapshotFreshness` to snapshots; wire `TRAIT_CONFIG_UPDATED` handler |
| `CombatTracker.lua` | Modify | Attach `buildId`/`loadoutId`/`snapshotFreshness` at session start |
| `CombatStore.lua` | Modify | Add v6→v7 migration gate, `db.buildCatalog` persistence, scoped query API |
| `BuildCatalogService.lua` | **NEW** | Build catalog CRUD, current live build registration, alias management |
| `BuildComparisonService.lua` | **NEW** | Scoped session scan, confidence computation, metric aggregation, diff generation |
| `UI/BuildComparatorView.lua` | Modify | Redesign to consume service APIs; replace arrow cycling with selector; add diff panel |
| `CombatAnalytics.toc` | Modify | Register two new service files |

---

## Implementation Phases

### Phase 1 — Foundation (Constants, Events, BuildHash)

**Rationale**: All other phases depend on the new constants and identity computation. No UI or storage changes here — zero risk of regression.

**Files**: `Constants.lua`, `Events.lua`, `Utils/BuildHash.lua`

**Deliverables**:
1. `Constants.lua` additions:
   - `SCHEMA_VERSION = 7` (bump from 6)
   - `BUILD_IDENTITY_VERSION = 1`
   - `SNAPSHOT_FRESHNESS = { FRESH, PENDING_REFRESH, DEGRADED, UNAVAILABLE }`
   - `CONFIDENCE_TIER = { NO_DATA, LOW, MEDIUM, HIGH }`
   - `CONFIDENCE_TIER_THRESHOLDS = { LOW_MIN=1, MEDIUM_MIN=5, HIGH_MIN=15 }`

2. `Events.lua` additions:
   - Map `"TRAIT_CONFIG_UPDATED"` to the internal event router (same pattern as `TRAIT_CONFIG_LIST_UPDATED`)

3. `Utils/BuildHash.lua` additions (keep `FromSnapshot()` intact):
   - `BuildHash.ComputeBuildId(snapshot)` — excludes `activeConfigId` and `importString`; prefixes with `buildIdentityVersion`
   - `BuildHash.ComputeLoadoutId(snapshot)` — hashes `activeConfigId` + first 64 chars of `importString`
   - Both return a 40-char deterministic string; return `nil` on nil input

**Completion gate**: `ComputeBuildId` and `ComputeLoadoutId` exist and are callable. `TRAIT_CONFIG_UPDATED` appears in Events.lua routing table.

---

### Phase 2 — Snapshot + Tracker Enrichment

**Rationale**: Sessions must record `buildId`, `loadoutId`, and `snapshotFreshness` before the migration can stamp historical records. CombatTracker depends on SnapshotService being enriched first.

**Files**: `SnapshotService.lua`, `CombatTracker.lua`

**Deliverables**:
1. `SnapshotService.lua`:
   - After each successful snapshot capture, compute and store `buildId` and `loadoutId` on the snapshot using `BuildHash.ComputeBuildId` / `ComputeLoadoutId`
   - Add `snapshotFreshness` field; set to `FRESH` after full capture, `DEGRADED` when data incomplete, `UNAVAILABLE` when API returns nil
   - Wire `TRAIT_CONFIG_UPDATED` handler → call `TryRefreshDeferredSnapshot()` (existing method), respecting the existing `pendingFullRefresh` coalescing logic
   - Coalesce concurrent refresh triggers: guard against re-entry within the same frame

2. `CombatTracker.lua`:
   - At session start (`CreateSession`), attach `session.playerSnapshot.buildId`, `.loadoutId`, and `.snapshotFreshness` from `SnapshotService:GetCurrentSnapshot()`
   - If snapshot is `DEGRADED` or `UNAVAILABLE`, record degraded state on the snapshot rather than blocking session creation

**Completion gate**: A new session's `playerSnapshot` contains non-nil `buildId`, `loadoutId`, and `snapshotFreshness` fields.

---

### Phase 3 — CombatStore: Migration + Catalog Persistence + Query API

**Rationale**: The catalog is the source of truth; sessions must be indexed against it. Migration consolidates legacy split-hash profiles before any UI work begins.

**Files**: `CombatStore.lua`

**Deliverables**:
1. **v6→v7 migration gate** in `MigrateSchema`:
   - Initialize `db.buildCatalog = { order={}, byId={} }` if absent
   - Initialize `db.characterPrefs = db.characterPrefs or {}`
   - For each session in `db.combats.byId`:
     - If `playerSnapshot` is non-nil and `talentNodes` is non-empty: recompute `buildId` / `loadoutId`; stamp on snapshot
     - If `playerSnapshot` is nil or `talentNodes` is empty: assign `"legacy-partial-" + oldHash`; set `isMigratedWithWarnings=true`
     - Upsert a `BuildProfile` in `db.buildCatalog.byId[buildId]`; append to `legacyBuildHashes`
   - Merge profiles where the new `buildId` is identical but old hashes differ (consolidation of config-slot splits)
   - Gate condition: `db.schemaVersion == 6`; set to 7 on completion

2. **Catalog persistence API** (new methods on CombatStore):
   - `CombatStore:UpsertBuildProfile(buildId, fields)` — create or update a catalog entry
   - `CombatStore:GetBuildProfile(buildId)` → `BuildProfile | nil`
   - `CombatStore:GetAllBuildProfiles()` → ordered array of BuildProfile
   - `CombatStore:UpdateBuildProfileFlag(buildId, flag, value)` — set a state flag

3. **Scoped query API**:
   - `CombatStore:GetSessionsForBuild(buildId, scope)` → array of session refs matching scope
   - Scope matching logic: character key, specId, context, bracket, opponentClassId, opponentSpecId, date range — all nil = wildcard
   - Results cached per `(buildId, scopeKey)` in a session-lifetime in-memory cache (`CombatStore._queryCache`)
   - Cache invalidated when a new session is added to `db.combats`

**Completion gate**: `db.buildCatalog` is initialized on load; migration runs once; scoped query returns correct session subsets.

---

### Phase 4 — BuildCatalogService (New Module)

**Rationale**: Separates catalog CRUD and live build management from persistence (CombatStore) and UI.

**File**: `BuildCatalogService.lua` (new, registered in toc)

**Deliverables**:
1. Module registration: `ns.Addon:RegisterModule("BuildCatalogService", BuildCatalogService)`

2. **Live build management**:
   - `BuildCatalogService:GetCurrentLiveBuild()` → `BuildProfile` for the current snapshot (creates a transient profile if catalog entry absent)
   - `BuildCatalogService:RefreshFromSnapshot(snapshot)` → upserts catalog entry from snapshot; sets `isCurrentBuild=true` on the new profile, false on all others
   - Called on each SnapshotService refresh

3. **Catalog CRUD**:
   - `BuildCatalogService:GetProfile(buildId)` → `BuildProfile | nil`
   - `BuildCatalogService:GetAllProfiles(characterKey)` → ordered array sorted by `lastSeenAt` desc
   - `BuildCatalogService:SetAlias(buildId, alias)` — add an alias string
   - `BuildCatalogService:ArchiveProfile(buildId)` — set `isArchived=true`

4. **Label generation**:
   - `BuildCatalogService:GetDisplayLabel(buildId)` → spec name + hero talent tree + abbreviated PvP talent summary
   - Falls back to `"Class / Spec / Unknown Hero"` if display name data unavailable
   - Uses `GetSpecializationInfoByID(specId)` and spell name lookup for PvP talents

5. **toc registration**: add `BuildCatalogService.lua` after `SnapshotService.lua` in load order

**Completion gate**: `BuildCatalogService:GetCurrentLiveBuild()` returns a non-nil profile after a talent change event fires, before any combat session is recorded.

---

### Phase 5 — BuildComparisonService (New Module)

**Rationale**: All comparison logic extracted from the UI. The view becomes a renderer; this service becomes the engine.

**File**: `BuildComparisonService.lua` (new, registered in toc)

**Deliverables**:
1. Module registration: `ns.Addon:RegisterModule("BuildComparisonService", BuildComparisonService)`

2. **Core comparison**:
   - `BuildComparisonService:Compare(buildIdA, buildIdB, scope)` → `ComparisonResult`
   - Calls `CombatStore:GetSessionsForBuild` for each build with the scope
   - Derives `MetricSummary` (winRate, pressureScore, burstScore, survivalScore) from session arrays
   - Classifies `ConfidenceTier` per build using `CONFIDENCE_TIER_THRESHOLDS`
   - Generates `BuildDiff` (see below)

3. **Build diff computation**:
   - `BuildComparisonService:ComputeDiff(profileA, profileB)` → `BuildDiff`
   - Index `talentNodes` by `nodeId` for both builds
   - Classify each node: added, removed, choice_changed (entryId differs), rank_changed (only rank differs)
   - PvP diff: set difference on sorted pvpTalents arrays
   - Hero diff: compare `heroTalentSpecId` values
   - Sort output by importance: hero → pvp → choice_changed → added/removed → rank_changed

4. **Scope resolution helpers**:
   - `BuildComparisonService:BuildScopeKey(scope)` → stable serialized string
   - `BuildComparisonService:GetDefaultScope(characterKey, specId)` → `ComparisonScope`
   - `BuildComparisonService:GetLastScope(characterKey, specId)` → persisted scope or default

5. **Quick actions**:
   - `BuildComparisonService:GetBestHistoricalInScope(characterKey, specId, scope)` → `buildId | nil` (highest win rate above HIGH threshold)
   - `BuildComparisonService:GetMostUsedInScope(characterKey, specId, scope)` → `buildId | nil` (highest session count)

6. **toc registration**: add `BuildComparisonService.lua` after `BuildCatalogService.lua` in load order

**Completion gate**: `Compare(buildIdA, buildIdB, scope)` returns a valid `ComparisonResult` with non-nil `diff` and correct `confidenceA`/`confidenceB` values.

---

### Phase 6 — UI Redesign (BuildComparatorView)

**Rationale**: The view is restructured to consume service APIs only — no direct `db.aggregates.builds` access. Arrow-based cycling is replaced with a dropdown/list selector. Diff panel and confidence badges are added.

**File**: `UI/BuildComparatorView.lua` (significant restructure)

**Deliverables**:
1. **Scope banner**: always-visible row showing active scope description (e.g., "Comparing arena sessions on this character vs all opponents")
2. **Scope selector**: controls for context, bracket, opponent class; updates scope and triggers recompute
3. **Build selector** (replaces arrow cycling):
   - Dropdown or scrollable list per side (A / B)
   - Text search filter (client-side string match on display label)
   - Sort options: most recent, session count, win rate in scope
   - "Current Live Build" always at top regardless of sort
   - Prevents selecting the same build on both sides
4. **Per-build panels** (A and B):
   - Display label (spec + hero talent + PvP summary)
   - Sample count
   - Confidence badge (`ConfidenceTier` → color-coded chip)
   - Metrics row (win rate, pressure, burst, survival) — hidden or suppressed for LOW/NO_DATA
   - "No combat history in this scope" placeholder when samplesA/B = 0
5. **Diff panel**:
   - Compact mode: top-3 changes + "X more differences" count
   - Expanded mode: full ordered change list
   - "Builds are identical in talent selection" state
6. **Quick actions bar**: Swap A↔B, Compare current vs previous, Compare current vs best in scope
7. **Freshness warning**: shown when current live build snapshot is DEGRADED or UNAVAILABLE

**Removed logic** (extracted to services):
- `computeMetrics(bucket)`, `buildLabel(bucket)`, `resolveBuildMeta(bucket)` — deleted
- `LOW_SAMPLE_THRESHOLD = 5` hardcoded constant — replaced with `Constants.CONFIDENCE_TIER_THRESHOLDS`
- Direct `db.aggregates.builds` reads — replaced with `BuildCatalogService` / `BuildComparisonService` calls

**Completion gate**: Comparator opens with a scope banner, build selector with search, diff panel, and confidence badges. Current live build visible before any combat session.

---

### Phase 7 — Polish & Diagnostics

**Rationale**: FR-048 requires diagnostic export coverage; edge cases from spec must be tested.

**Files**: `CombatStore.lua`, `BuildCatalogService.lua`, `BuildComparisonService.lua`

**Deliverables**:
1. **Debug export**: extend the existing `/ca debug export` output with:
   - Current `buildId` and `loadoutId`
   - `snapshotFreshness` status
   - `db.buildCatalog` summary (count, profile IDs, migration warnings)
2. **Nil-guard audit**: verify all new service methods tolerate nil snapshots, empty session arrays, nil scope fields without Lua errors
3. **Refresh coalescing**: verify `TRAIT_CONFIG_UPDATED` firing multiple times in one frame does not trigger multiple full refreshes (existing `pendingFullRefresh` guard must cover the new event)
4. **Single-build state**: comparator shows an informational message when catalog has < 2 profiles
5. **Empty scope state**: comparator shows an empty-state message when scope yields 0 sessions for all builds

**Completion gate**: `/ca debug export` includes buildId, loadoutId, freshness, and catalog summary. No Lua errors on nil or empty inputs.

---

## Dependency Graph

```
Phase 1 (Constants, Events, BuildHash)
    │
    ▼
Phase 2 (SnapshotService, CombatTracker)
    │
    ▼
Phase 3 (CombatStore: Migration + Query)
    │
    ├──▶ Phase 4 (BuildCatalogService)
    │         │
    │         └──▶ Phase 5 (BuildComparisonService)
    │                    │
    │                    └──▶ Phase 6 (UI Redesign)
    │                               │
    └──────────────────────────────▶ Phase 7 (Polish)
```

Phase 4 and Phase 5 can begin in parallel once Phase 3 is complete. Phase 6 depends on both Phase 4 and Phase 5 being fully functional.

---

## Validation Plan

| Phase | Manual Test | Automated / In-code |
|-------|-------------|---------------------|
| 1 | Call `BuildHash.ComputeBuildId` and `ComputeLoadoutId` via `/ca debug` and verify output | Unit assertions in BuildHash.lua (if test framework available) |
| 2 | Change a talent node; run `/ca debug snapshot`; verify buildId appears in output | Nil-guard checks in SnapshotService |
| 3 | Reload UI; verify `db.buildCatalog` is initialized; run migration on a character with 10+ sessions | Idempotence: reload twice → same profile count |
| 4 | Change talent build with no sessions → open comparator → verify "Current Live Build" appears | N/A |
| 5 | Compare two known builds with different talent nodes → verify diff lists correct changes | N/A |
| 6 | Full end-to-end: change builds, record sessions, open comparator, scope to 2v2, verify sample counts | N/A |
| 7 | Run `/ca debug export`; verify buildId, loadoutId, freshness, catalog summary present | Nil-guard audit |

**Regression check**: Total session count per character MUST match before and after migration. Verified via `/ca debug export` pre- and post-migration comparison.

---

## Rollback Plan

1. **Schema version gate**: If v6→v7 migration fails halfway, the `db.schemaVersion` remains at 6 — the gate condition prevents partial re-execution. A manual `/ca cleanup` or SavedVariables reset restores to v6 state.

2. **Legacy hash preserved**: `FromSnapshot()` in `BuildHash.lua` is kept unchanged. All legacy `buildHash` fields on sessions remain. If the catalog is cleared, existing UI code dependent on `db.aggregates.builds` can be restored.

3. **Service modules are additive**: `BuildCatalogService.lua` and `BuildComparisonService.lua` are new files. Removing them from the toc and reverting `BuildComparatorView.lua` restores the old UI without touching session data.

4. **UI changes are isolated**: `BuildComparatorView.lua` is the only UI file changed. A git revert of that single file reverts the UI to the arrow-cycling view.

5. **Backward compatibility**: `db.aggregates.builds` (legacy build aggregates) is NOT removed in this version — it remains readable by any unreachable code paths during the transition.
