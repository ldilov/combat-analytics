# Research: Build Comparator Overhaul

**Feature**: `003-build-comparator-overhaul` | **Date**: 2026-03-28
**Spec**: [spec.md](spec.md) | **Output of**: Phase 0 research

---

## Decision 1 — Canonical buildId Computation

**Decision**: Compute `buildId` from `classId + specId + heroTalentSpecId + sorted pvpTalents + serialized talentNodes`, prefixed with a `buildIdentityVersion` marker. Exclude `activeConfigId` and `importString`.

**Rationale**: The existing `BuildHash.FromSnapshot()` in `Utils/BuildHash.lua` (line 27–35) currently includes `activeConfigId` (the Blizzard loadout slot number) and `importString` in the hash input. These are the sole cause of identical talent setups producing different hashes. Removing them collapses the identity space to just talent content. The existing `serializeTalentNodes()` helper (lines 5–17) already normalizes talent node lists correctly by sorting. PvP talents are already sorted before hashing.

**Alternatives considered**:
- Use only `classId + specId + talentNodes` without hero talent or PvP: rejected because two specs with the same PvE tree but different PvP selections must be distinct builds.
- Use `importString` as a normalized identity signal: rejected per spec requirement FR-006 (import string is loadout metadata by default). Import strings are tied to config slots and are not guaranteed to be content-addressable across different servers/patches.
- Compute a content hash from spell IDs only (not node IDs): rejected because multiple nodes may reference the same spell at different ranks; `nodeId + entryId + activeRank` is the authoritative identity.

**Implementation note**: `buildIdentityVersion = 1` prefixes the hash input string so any future change to identity fields produces a new, distinct hash space without collision.

---

## Decision 2 — Separate loadoutId Computation

**Decision**: Compute `loadoutId` from `activeConfigId + importString (first 64 chars, normalized)`. This is a secondary identifier stored separately from `buildId`.

**Rationale**: The loadout identity is needed to preserve Blizzard-facing metadata (which slot a player used, the loadout name they gave it) without contaminating build identity. `activeConfigId` alone is a small integer and not user-readable; pairing it with a prefix of the import string creates a loadout fingerprint that survives slot reassignment.

**Alternatives considered**:
- Store loadout purely as freeform metadata without hashing: acceptable, but having a stable `loadoutId` makes it easier to join loadout metadata across sessions without string matching.
- Hash loadout name instead: loadout names are mutable by the user; the config slot ID is stable within a character's lifetime.

---

## Decision 3 — Build Catalog Storage Shape

**Decision**: Add `db.buildCatalog = { order = {}, byId = {} }` as a top-level key in the SavedVariables database, parallel to `db.matches` and `db.combats`. Each entry is a build profile keyed by `buildId`.

**Rationale**: The catalog is a first-class persistence entity, not a derived aggregate. Storing it under `db.aggregates` would imply it is recomputable from sessions, but catalog profiles must survive even before any session is recorded (per FR-008). Placing it at the top level alongside `matches` and `combats` makes its intent unambiguous.

**Alternatives considered**:
- Store under `db.aggregates.buildProfiles`: rejected because aggregates are recomputed from sessions; a catalog profile created for a zero-history build cannot be reconstructed from sessions.
- Store in a separate SavedVariables (e.g., `CombatAnalyticsBuildsDB`): rejected because the addon uses a single SavedVariables, and splitting would require separate migration handling.

**Migration gate**: `db.buildCatalog` will be initialized in the v6→v7 `MigrateSchema` gate.

---

## Decision 4 — Scoped Comparison Query Strategy

**Decision**: Implement scoped queries by scanning `db.combats.byId` with a filter closure. Cache per `(buildIdA, buildIdB, scopeKey)` tuples for the session's lifetime using a lightweight in-memory cache invalidated on new session record.

**Rationale**: The addon's session count is bounded (a few hundred sessions is typical; a few thousand is the extreme upper bound). A linear scan over sessions with a filter is well within the Lua frame budget for an on-demand comparison request. No pre-built index is needed for v1.

**Alternatives considered**:
- Pre-build context-keyed bucket tables during session finalization: provides O(1) lookup at comparison time, but requires storing derived buckets per `(buildId × context × opponentClass)` — a potentially large combinatorial space that bloats the SavedVariables file.
- SQL-style index table: no query engine is available; simulating one in Lua would exceed the complexity budget for v1.

**Scope key**: A scope is serialized to a stable string key for cache invalidation: `characterKey:specId:context:bracket:opponentClassId:opponentSpecId:dateFrom:dateTo`.

---

## Decision 5 — Build Diff Algorithm

**Decision**: Compute talent diff by indexing each build's `talentNodes` array by `nodeId`. For each nodeId: if in A only → removed in B; if in B only → added in B; if in both and `entryId` differs → changed choice node; if in both and only `activeRank` differs → changed rank. PvP diffs: set difference on sorted `pvpTalents` arrays. Hero talent diff: compare `heroTalentSpecId` values.

**Rationale**: The existing `talentNodes` structure in `SnapshotService.lua` (lines 82–89) stores `nodeId`, `entryId`, `activeRank`, and `definitionSpellId`. Using `nodeId` as the diff key gives a stable, tree-position-based comparison that is independent of display order and spell ID renaming.

**Alternatives considered**:
- Diff by `definitionSpellId` only: would miss rank changes and choice-node alternatives that share the same spell family.
- Diff by `importString` comparison: import strings are not human-readable and are excluded from canonical identity; diffing them provides no user value.

**Importance ordering**: Hero talent tree change → PvP talent changes → choice node changes → talent additions/removals → rank changes.

---

## Decision 6 — Refresh Event Coverage

**Decision**: Wire one additional event — `TRAIT_CONFIG_UPDATED` — to catch individual talent node clicks during the talent UI editing session. The three already-wired events (`TRAIT_CONFIG_LIST_UPDATED`, `PLAYER_SPECIALIZATION_CHANGED`, `PLAYER_PVP_TALENT_UPDATE`) cover login/spec/PvP talent refresh but do not fire on every node selection during a live talent editing session.

**Rationale**: `TRAIT_CONFIG_LIST_UPDATED` fires when the list of available configs changes (on login or spec change). `TRAIT_CONFIG_UPDATED` fires when the content of a config changes — i.e., when the player selects or deselects a talent node. This is the event needed for live editing coverage.

**Alternatives considered**:
- Poll with OnUpdate throttle: avoided per addon performance guidelines; event-based is always preferred.
- Snapshot on every `UNIT_AURA` or `UNIT_SPELLCAST_*` event: would fire on every combat action, causing unnecessary overhead.

---

## Decision 7 — Migration Strategy

**Decision**: Add a v6→v7 migration gate in `CombatStore:MigrateSchema()` that: (1) initializes `db.buildCatalog`, (2) iterates all sessions and stamps `buildId` and `loadoutId` by re-running the new identity computation on the stored `playerSnapshot`, (3) creates a build profile for each unique `buildId` found, (4) preserves `legacyBuildHash` on each profile, (5) merges profiles where their constituent sessions previously used different legacy hashes due only to differing `activeConfigId`.

**Rationale**: The existing `MigrateSchema` pattern (forward-only, idempotent, version-gated) is proven and used for 5 prior migrations. Adding v6→v7 follows the established pattern with no risk of regression.

**Merge condition**: Two legacy hashes map to the same `buildId` when the new canonical computation (without `activeConfigId` and `importString`) produces identical results. These are exactly the sessions that should be merged per FR-042.

**Partial-data sessions**: If `playerSnapshot` is nil or `talentNodes` is empty, assign a deterministic fallback buildId (`"legacy-partial-XXXXXXXX"` keyed on the old hash) and mark the profile `isMigrated = true`, `isLowConfidence = true`.

---

## Decision 8 — New Service File Locations

**Decision**: Place new service modules at the addon root alongside existing services (`ArenaScoutService.lua`, `DuelLabService.lua`, etc.) rather than in a `Services/` subdirectory.

**Rationale**: The WoW addon `.toc` file must enumerate every Lua file. A flat directory structure is simpler to register and matches the established pattern for all 34 existing modules. The `Services/` naming in the requirements document is a semantic label, not a required directory.

**Exception**: The recommendations document uses `Services/` as a path prefix. This plan adopts that prefix in names (`BuildCatalogService.lua`, `BuildComparisonService.lua`) placed at the root, consistent with all other service-suffixed files.

---

## Decision 9 — Confidence Tier Thresholds (Initial Values)

**Decision**: Define initial thresholds as named constants in `Constants.lua`:
- `NO_DATA`: 0 sessions in scope
- `LOW_CONFIDENCE`: 1–4 sessions in scope
- `MEDIUM_CONFIDENCE`: 5–14 sessions in scope
- `HIGH_CONFIDENCE`: ≥15 sessions in scope

**Rationale**: The existing `LOW_SAMPLE_THRESHOLD = 5` hardcoded in `BuildComparatorView.lua` (line 9) serves as a reference point. Centralizing and expanding to four tiers makes confidence consistent across all UI surfaces and allows tuning without code changes.

**Alternatives considered**:
- Dynamic thresholds based on context (e.g., lower threshold for duels where fewer total games are played): deferred to a future iteration; static thresholds are sufficient for v1.

---

## Codebase Touchpoints Summary

| File | Current Role | Required Change |
|------|-------------|-----------------|
| `Utils/BuildHash.lua` | Computes legacy hash (40 lines) | Add `ComputeBuildId()`, `ComputeLoadoutId()`; keep `FromSnapshot()` for migration compatibility |
| `SnapshotService.lua` | Captures player state, stores buildHash (419 lines) | Add `buildId`/`loadoutId` to snapshots; wire `TRAIT_CONFIG_UPDATED` |
| `CombatStore.lua` | Persistence + aggregation (1835 lines) | Add catalog persistence, v6→v7 migration, scoped query APIs |
| `CombatTracker.lua` | Session lifecycle | Attach `buildId`/`loadoutId`/freshness at session start |
| `UI/BuildComparatorView.lua` | Comparison UI + all logic (566 lines) | Redesign to consume service APIs |
| `Constants.lua` | Enums + config | Add `SCHEMA_VERSION=7`, confidence tier enum, freshness enum, `BUILD_IDENTITY_VERSION=1` |
| `Events.lua` | Event dispatch | Add `TRAIT_CONFIG_UPDATED` mapping |
| `CombatAnalytics.toc` | Module registration | Register two new service files |
| **NEW** `BuildCatalogService.lua` | — | Build catalog CRUD, current live build |
| **NEW** `BuildComparisonService.lua` | — | Scoped samples, confidence, metrics, diff |
