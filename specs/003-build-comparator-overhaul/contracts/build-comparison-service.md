# Contract: BuildComparisonService

**Module**: `BuildComparisonService.lua` (new)
**Registration**: `ns.Addon:RegisterModule("BuildComparisonService", BuildComparisonService)`
**Consumers**: `BuildComparatorView.lua`
**Depends on**: `BuildCatalogService`, `CombatStore`

---

## Purpose

Computes and returns comparison results between two build profiles within a scoped session sample. All comparison logic lives here — the UI view only renders the `ComparisonResult` this service provides.

---

## Public API

### `BuildComparisonService:Compare(buildIdA, buildIdB, scope)`

Primary entry point. Returns a complete comparison result.

**Parameters**:
- `buildIdA` (`string`) — canonical buildId for left-side build.
- `buildIdB` (`string`) — canonical buildId for right-side build.
- `scope` (`ComparisonScope`) — scope filter (see data-model.md). `nil` = use default scope for current character/spec.

**Returns**: `ComparisonResult`

```
ComparisonResult {
    buildA: BuildProfile,
    buildB: BuildProfile,
    scope: ComparisonScope,
    samplesA: number,
    samplesB: number,
    metricsA: MetricSummary | nil,   -- nil when samplesA == 0
    metricsB: MetricSummary | nil,
    confidenceA: ConfidenceTier,
    confidenceB: ConfidenceTier,
    diff: BuildDiff,
    computedAt: number,              -- GetTime()
}
```

**Behavior**:
1. Resolves both profiles via `BuildCatalogService:GetProfile(buildId)`. If a profile is not in catalog, constructs a minimal profile from available snapshot data.
2. Calls `CombatStore:GetSessionsForBuild(buildId, scope)` for each build.
3. Aggregates `MetricSummary` from session arrays (win rate, pressure, burst, survival; nil fields when no session data available for that metric).
4. Classifies `ConfidenceTier` per build using `Constants.CONFIDENCE_TIER_THRESHOLDS`.
5. Calls `ComputeDiff(profileA, profileB)`.
6. Returns the assembled `ComparisonResult`.

**Error behavior**: If `buildIdA == buildIdB`, returns a result with `diff.isIdentical = true` and identical metric summaries. Never raises a Lua error on valid input.

**Caching**: Results are NOT cached — the caller (UI) may cache them per scope key. Scope-keyed session sample cache lives in `CombatStore`.

---

### `BuildComparisonService:ComputeDiff(profileA, profileB)`

Computes a structured talent diff between two profiles.

**Parameters**:
- `profileA` (`BuildProfile`) — left-side build.
- `profileB` (`BuildProfile`) — right-side build.

**Returns**: `BuildDiff`

```
BuildDiff {
    heroTalentChange: HeroTalentChange | nil,
    pvpTalentChanges: PvPTalentChange[],
    talentChanges: TalentChange[],
    isIdentical: boolean,
    totalChanges: number,
}
```

**Diff algorithm** (from research Decision 5):
1. **Hero talent**: compare `heroTalentSpecId` fields. If different, produce a `HeroTalentChange`.
2. **PvP talents**: sort both `pvpTalentSignature` arrays; compute symmetric difference; produce `PvPTalentChange` per entry.
3. **PvE talents**: index both `talentNodes` arrays by `nodeId`:
   - nodeId in A only → `changeType = "removed"` (in B: absent)
   - nodeId in B only → `changeType = "added"` (in A: absent)
   - nodeId in both, `entryId` differs → `changeType = "choice_changed"`
   - nodeId in both, `entryId` same, `activeRank` differs → `changeType = "rank_changed"`
4. **Sort output** by importance: hero → pvp → choice_changed → added/removed → rank_changed.
5. **Spell names**: attempt `GetSpellInfo(definitionSpellId)` for each changed node. If unavailable (restricted zone), leave `spellNameA`/`spellNameB` as nil; never block on missing names.

**Returns an `isIdentical = true` result** when all three comparisons produce zero changes.

---

### `BuildComparisonService:ClassifyConfidence(sampleCount)`

Returns the confidence tier for a given session count.

**Parameters**:
- `sampleCount` (`number`) — session count for one build in the current scope.

**Returns**: `ConfidenceTier` (string constant from `Constants.CONFIDENCE_TIER`)

| Sample count | Returns |
|---|---|
| 0 | `"no_data"` |
| 1–4 | `"low"` |
| 5–14 | `"medium"` |
| ≥15 | `"high"` |

**Note**: Thresholds are read from `Constants.CONFIDENCE_TIER_THRESHOLDS` — never hardcoded.

---

### `BuildComparisonService:GetDefaultScope(characterKey, specId)`

Returns the default `ComparisonScope` for a given character and spec.

**Parameters**:
- `characterKey` (`string`) — `"Name-Realm"`.
- `specId` (`number`)

**Returns**: `ComparisonScope` with:
- `characterKey` = given value
- `specId` = given value
- `context` = last-used context (from `db.characterPrefs`) or `nil` (all contexts)
- all other fields = `nil` (no filter)

---

### `BuildComparisonService:GetLastScope(characterKey, specId)`

Returns the persisted last-used scope, falling back to default.

**Parameters**:
- `characterKey` (`string`)
- `specId` (`number`)

**Returns**: `ComparisonScope` — never nil (falls back to `GetDefaultScope`).

---

### `BuildComparisonService:SaveScope(characterKey, specId, scope)`

Persists the active scope to `db.characterPrefs` for restoration on next login.

**Parameters**:
- `characterKey` (`string`)
- `specId` (`number`)
- `scope` (`ComparisonScope`)

**Returns**: nothing.

---

### `BuildComparisonService:BuildScopeKey(scope)`

Serializes a scope to a stable string key for caching.

**Parameters**:
- `scope` (`ComparisonScope`)

**Returns**: `string` — format: `characterKey:specId:context:bracket:opponentClassId:opponentSpecId:dateFrom:dateTo`. Nil fields are serialized as empty string segments.

---

### `BuildComparisonService:GetBestHistoricalInScope(characterKey, specId, scope)`

Returns the `buildId` with the highest win rate in scope among HIGH-confidence builds.

**Parameters**:
- `characterKey` (`string`)
- `specId` (`number`)
- `scope` (`ComparisonScope`)

**Returns**: `string | nil` — nil if no HIGH-confidence build exists in scope.

---

### `BuildComparisonService:GetMostUsedInScope(characterKey, specId, scope)`

Returns the `buildId` with the highest session count in scope.

**Parameters**:
- `characterKey` (`string`)
- `specId` (`number`)
- `scope` (`ComparisonScope`)

**Returns**: `string | nil` — nil if no sessions found for any build in scope.

---

## Nil-Safety Contract

All public methods MUST:
- Accept `nil` for optional parameters without raising a Lua error.
- Return the documented type or nil — never raise `attempt to index a nil value` or equivalent.
- Log a trace message (using the existing trace/debug utility) when a nil or unexpected input causes a degraded result.

---

## Verdict Suppression Rules

The service does NOT produce verdict strings. Verdict language ("Build A is better") is explicitly prohibited. The UI layer is responsible for deciding whether to show delta comparisons and must check `confidenceA` / `confidenceB` before rendering metric deltas.

- `LOW` or `NO_DATA` confidence → UI MUST suppress verdict and delta indicators.
- `MEDIUM` or `HIGH` confidence → UI MAY render deltas and metric comparisons.

This is a rendering contract, not enforced in the service return value.
