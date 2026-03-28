# Contract: BuildCatalogService

**Module**: `BuildCatalogService.lua` (new)
**Registration**: `ns.Addon:RegisterModule("BuildCatalogService", BuildCatalogService)`
**Consumers**: `BuildComparatorView.lua`, `BuildComparisonService.lua`, `CombatTracker.lua`

---

## Purpose

Owns the build catalog lifecycle: registering builds, exposing the current live build, managing display labels and aliases, and providing profile queries. All catalog reads and writes go through this service — not through `CombatStore` directly.

---

## Public API

### `BuildCatalogService:RefreshFromSnapshot(snapshot)`

Registers or updates the catalog entry for the build described by `snapshot`.

**Parameters**:
- `snapshot` (`table | nil`) — the player snapshot from `SnapshotService:GetCurrentSnapshot()`. If nil, no-op.

**Behavior**:
1. Calls `BuildHash.ComputeBuildId(snapshot)` and `BuildHash.ComputeLoadoutId(snapshot)`.
2. Calls `CombatStore:UpsertBuildProfile(buildId, fields)` with identity fields, `lastSeenAt = GetTime()`, `isCurrentBuild = true`.
3. Clears `isCurrentBuild = false` on all other profiles for the same `characterKey + specId`.
4. If `snapshot.snapshotFreshness == UNAVAILABLE`: upserts as a placeholder with `isLowConfidence = true`; does not set `isCurrentBuild = true`.

**Returns**: `buildId: string | nil`

**Error behavior**: Silently returns nil on nil input or missing hash inputs; never raises a Lua error.

---

### `BuildCatalogService:GetCurrentLiveBuild()`

Returns the profile for the player's currently active talent setup.

**Returns**: `BuildProfile | nil`

**Behavior**: Reads `isCurrentBuild == true` from the catalog. If none is flagged (e.g., first load before a refresh fires), returns a transient BuildProfile constructed from `SnapshotService:GetCurrentSnapshot()` without persisting it.

---

### `BuildCatalogService:GetProfile(buildId)`

Returns the catalog entry for a known build.

**Parameters**:
- `buildId` (`string`) — canonical build identifier.

**Returns**: `BuildProfile | nil` — nil if not in catalog.

---

### `BuildCatalogService:GetAllProfiles(characterKey)`

Returns all non-archived catalog entries for a character, sorted by `lastSeenAt` descending.

**Parameters**:
- `characterKey` (`string`) — `"Name-Realm"` format. Defaults to current character if nil.

**Returns**: `BuildProfile[]` — empty array if no profiles. Current live build is always first regardless of sort.

---

### `BuildCatalogService:GetDisplayLabel(buildId)`

Returns a human-readable label string for a build.

**Parameters**:
- `buildId` (`string`)

**Returns**: `string` — e.g., `"Devastation / Scalecommander / Nullifying Shroud + Obsidian Mettle"`

**Fallback**: If spec name or hero talent name is unavailable from WoW APIs, returns `"Class / Spec / Unknown Hero"`. Never returns nil.

---

### `BuildCatalogService:SetAlias(buildId, alias)`

Adds a player-assigned alias to a build profile's `aliases` list.

**Parameters**:
- `buildId` (`string`)
- `alias` (`string`) — must be non-empty; max 64 characters.

**Returns**: `true` on success, `false` if buildId not found or alias is invalid.

**Validation**: Duplicate aliases on the same profile are silently deduplicated. Alias deduplication is case-insensitive.

---

### `BuildCatalogService:ArchiveProfile(buildId)`

Sets `isArchived = true` on a catalog entry. Archived profiles are excluded from `GetAllProfiles` results and the build selector.

**Parameters**:
- `buildId` (`string`)

**Returns**: `true` on success, `false` if not found.

---

### `BuildCatalogService:GetMigrationWarnings()`

Returns any migration warnings recorded during v6→v7 migration.

**Returns**: `string[]` — array of warning strings. Empty array if no warnings.

---

## Events Consumed

| WoW Event | Response |
|-----------|----------|
| `TRAIT_CONFIG_LIST_UPDATED` | Triggers `RefreshFromSnapshot` via SnapshotService refresh cycle |
| `TRAIT_CONFIG_UPDATED` | Triggers `RefreshFromSnapshot` via SnapshotService refresh cycle |
| `PLAYER_SPECIALIZATION_CHANGED` | Triggers `RefreshFromSnapshot`; clears `isCurrentBuild` on previous spec's profile |
| `PLAYER_PVP_TALENT_UPDATE` | Triggers `RefreshFromSnapshot` |

---

## State Invariants

- At most one `BuildProfile` per `characterKey` has `isCurrentBuild == true` at any time.
- `buildId` on a profile MUST equal `BuildHash.ComputeBuildId(profile)` — enforced on write.
- `sessionCount` MUST be updated atomically with session persistence (via `CombatStore:UpsertBuildProfile`).
- `firstSeenAt` is set once on creation; never updated on subsequent upserts.
