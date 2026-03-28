# Tasks: Build Comparator Overhaul

**Branch**: `003-build-comparator-overhaul` | **Date**: 2026-03-28
**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)
**Total Tasks**: 31 | **MVP Scope**: US2 + US1 (canonical identity + live build detection)

## User Story Summary

| Story | Priority | Description | Key Files |
|-------|----------|-------------|-----------|
| US2 | P1 | Canonical build identity stable across loadout slots | `Utils/BuildHash.lua`, `SnapshotService.lua`, `CombatTracker.lua` |
| US1 | P1 | Current live build visible before any combat session | `BuildCatalogService.lua` (new), `SnapshotService.lua` |
| US3 | P1 | Comparison results scoped to a specific context | `BuildComparisonService.lua` (new) |
| US4 | P2 | Build differences readable without external tools | `BuildComparisonService.lua` |
| US5 | P2 | Confidence and data quality surfaced clearly | `BuildComparisonService.lua` |
| US6 | P2 | Build selector is discoverable and navigable | `UI/BuildComparatorView.lua` |
| US7 | P3 | Historical data survives migration | `CombatStore.lua` |

## Implementation Strategy

1. **MVP**: US2 + US1 — Canonical identity at the data layer plus live build detection. Together these eliminate the core trust gap: identical setups stop appearing as separate builds, and new setups appear immediately without requiring a combat session.
2. **Next**: US3 — Scoped comparison unlocks meaningful analytics (not global noise).
3. **Then**: US4 + US5 — Diff panel and confidence tiers make the comparison actionable and honest.
4. **Then**: US6 — Selector redesign scales to many builds; depends on full service layer.
5. **Finally**: US7 + Polish — Migration preserves existing data; diagnostics and edge cases complete the feature.

**Parallel opportunities**: T002, T003, T004 in Foundational phase can all run simultaneously (different files). T027–T030 in the Polish phase are independent.

---

## Phase 1: Setup

**Goal**: Register new modules in the addon load order so all subsequent Lua files are loaded by the WoW client.

### Tasks

- [X] T001 Register `BuildCatalogService.lua` and `BuildComparisonService.lua` in `CombatAnalytics.toc` — add both entries in dependency order after `SnapshotService.lua`: `BuildCatalogService.lua` first, then `BuildComparisonService.lua`

---

## Phase 2: Foundational — Blocking Prerequisites for All User Stories

**Goal**: Establish constants, event routing, identity hash functions, and persistence APIs that every user story depends on. Complete this phase before starting any user story.

**Independent Test**: After this phase, calling `BuildHash.ComputeBuildId({classId=1,specId=65,heroTalentSpecId=0,talentNodes={},pvpTalents={}})` from a `/ca debug` command returns a 40-char string; `Constants.CONFIDENCE_TIER.HIGH` equals `"high"`; and `CombatStore:GetBuildProfile("any-id")` returns nil without error.

### Tasks

- [X] T002 [P] Add new constants to `Constants.lua`: `SCHEMA_VERSION = 7`, `BUILD_IDENTITY_VERSION = 1`, `SNAPSHOT_FRESHNESS = { FRESH="fresh", PENDING_REFRESH="pending_refresh", DEGRADED="degraded", UNAVAILABLE="unavailable" }`, `CONFIDENCE_TIER = { NO_DATA="no_data", LOW="low", MEDIUM="medium", HIGH="high" }`, `CONFIDENCE_TIER_THRESHOLDS = { LOW_MIN=1, MEDIUM_MIN=5, HIGH_MIN=15 }`
- [X] T003 [P] Wire `TRAIT_CONFIG_UPDATED` into the event routing table in `Events.lua` — same pattern as existing `TRAIT_CONFIG_LIST_UPDATED` entry; maps the WoW event to an internal dispatch handler name
- [X] T004 [P] Add `BuildHash.ComputeBuildId(snapshot)` and `BuildHash.ComputeLoadoutId(snapshot)` to `Utils/BuildHash.lua` — keep `FromSnapshot()` intact for migration compatibility; `ComputeBuildId` excludes `activeConfigId` and `importString`, prefixes hash input with `buildIdentityVersion`; `ComputeLoadoutId` hashes `activeConfigId .. "#" .. (importString or ""):sub(1,64)`; both return a 40-char deterministic hex string or `nil` on nil input
- [X] T005 Add catalog persistence APIs to `CombatStore.lua` — initialize `db.buildCatalog = { order={}, byId={} }` and `db.characterPrefs = db.characterPrefs or {}` if absent (in the existing db initialization block); add `CombatStore:UpsertBuildProfile(buildId, fields)` (create or merge update), `CombatStore:GetBuildProfile(buildId)` → `BuildProfile | nil`, `CombatStore:GetAllBuildProfiles(characterKey)` → ordered array sorted by `lastSeenAt` desc, `CombatStore:UpdateBuildProfileFlag(buildId, flag, value)` — sets a named state flag on a profile
- [X] T006 Add scoped session query to `CombatStore.lua` — `CombatStore:GetSessionsForBuild(buildId, scope)` scans `db.combats.byId` filtering by `session.playerSnapshot.buildId == buildId` then by scope fields (characterKey, specId, context, bracket, opponentClassId, opponentSpecId, dateFrom/dateTo — nil fields are wildcards); cache results in `CombatStore._queryCache[buildId .. ":" .. scopeKey]`; invalidate the entire cache when a new session is added to `db.combats`

---

## Phase 3: User Story 2 — Canonical Build Identity Stable Across Loadout Slots (P1)

**Story Goal**: Two identical talent setups stored in different Blizzard loadout slots produce the same canonical `buildId` and are stored under a single build profile.

**Independent Test**: Switch to loadout slot 1, run `/ca debug snapshot` — note the `buildId`. Switch to loadout slot 2 with identical talents. Run `/ca debug snapshot` again — `buildId` must be identical. Both sessions (recorded in each slot) must appear under the same build profile in `/ca debug catalog`.

### Tasks

- [X] T007 [US2] Enrich snapshot capture in `SnapshotService.lua` — after each successful `CaptureSnapshot()`, call `BuildHash.ComputeBuildId(snapshot)` and `BuildHash.ComputeLoadoutId(snapshot)` and store results as `snapshot.buildId` and `snapshot.loadoutId`; set `snapshot.snapshotFreshness = Constants.SNAPSHOT_FRESHNESS.FRESH` on full capture, `DEGRADED` when talent API returns partial data, `UNAVAILABLE` when API returns nil
- [X] T008 [US2] Wire `TRAIT_CONFIG_UPDATED` handler in `SnapshotService.lua` — add handler that calls `TryRefreshDeferredSnapshot()` (the existing method); guard against re-entry within the same frame using the existing `pendingFullRefresh` coalescing flag so multiple rapid `TRAIT_CONFIG_UPDATED` events fire only one refresh cycle
- [X] T009 [US2] Attach `buildId`, `loadoutId`, and `snapshotFreshness` to session in `CombatTracker.lua` — in `CreateSession()`, after creating the session object, read `SnapshotService:GetCurrentSnapshot()` and copy `snapshot.buildId`, `snapshot.loadoutId`, and `snapshot.snapshotFreshness` onto `session.playerSnapshot`; if snapshot is `DEGRADED` or `UNAVAILABLE`, record that state rather than blocking session creation

---

## Phase 4: User Story 1 — Current Live Build Visible Before Any Combat Session (P1)

**Story Goal**: Opening the Build Comparator immediately after a talent change shows the new setup as "Current Live Build" — no combat session required.

**Independent Test**: Change one talent node, do NOT enter combat, open the Build Comparator → "Current Live Build" entry is present, shows correct spec and hero talent label, displays "No combat history yet in current scope" rather than being blank or hidden. Run `/ca debug catalog` → at least one profile with `isCurrentBuild=true`.

### Tasks

- [X] T010 [US1] Create `BuildCatalogService.lua` — module scaffold with `ns.Addon:RegisterModule("BuildCatalogService", BuildCatalogService)`; implement `BuildCatalogService:RefreshFromSnapshot(snapshot)` (compute buildId, upsert profile via `CombatStore:UpsertBuildProfile`, set `isCurrentBuild=true` on new profile and `false` on all others for the same `characterKey+specId`) and `BuildCatalogService:GetCurrentLiveBuild()` (return profile where `isCurrentBuild==true`; if none, construct and return a transient profile from `SnapshotService:GetCurrentSnapshot()` without persisting)
- [X] T011 [US1] Implement catalog query methods in `BuildCatalogService.lua` — `GetAllProfiles(characterKey)` returns all non-archived profiles for a character sorted by `lastSeenAt` desc with current live build pinned first; `GetProfile(buildId)` delegates to `CombatStore:GetBuildProfile(buildId)`; `GetDisplayLabel(buildId)` constructs a human-readable label from `GetSpecializationInfoByID(specId)` spec name + hero talent display name + abbreviated PvP talent list (fallback: `"Class / Spec / Unknown Hero"` — never returns nil)
- [X] T012 [US1] Implement management methods in `BuildCatalogService.lua` — `SetAlias(buildId, alias)` validates alias is non-empty string ≤64 chars, appends to `profile.aliases` deduplicated case-insensitively, returns `true/false`; `ArchiveProfile(buildId)` calls `CombatStore:UpdateBuildProfileFlag(buildId, "isArchived", true)`, returns `true/false`; `GetMigrationWarnings()` returns `{}` until migration phase adds data
- [X] T013 [US1] Wire `BuildCatalogService:RefreshFromSnapshot` into `SnapshotService.lua` — after each successful snapshot refresh completes, call `BuildCatalogService:RefreshFromSnapshot(snapshot)` so the catalog updates every time the live build changes; use a `pcall` guard so a catalog error never breaks the snapshot cycle

---

## Phase 5: User Story 3 — Comparison Results Scoped to a Specific Context (P1)

**Story Goal**: Comparison results reflect only the active scope (e.g., only rated 2v2 sessions vs Frost Mages); changing scope changes sample counts.

**Independent Test**: Select two builds with sessions in both 2v2 arena and duel. Set scope to "2v2 Arena". Note sample counts. Change scope to "Duel". Sample counts change. The scope banner text updates to match. Both scope states persist after closing and reopening the comparator.

### Tasks

- [X] T014 [US3] Create `BuildComparisonService.lua` — module scaffold with `ns.Addon:RegisterModule("BuildComparisonService", BuildComparisonService)`; implement scope helpers: `BuildScopeKey(scope)` serializes scope to `"charKey:specId:context:bracket:oppClass:oppSpec:from:to"` (nil fields as empty segments), `GetDefaultScope(characterKey, specId)` returns a scope with just characterKey+specId plus last-used context from `db.characterPrefs`, `GetLastScope(characterKey, specId)` reads persisted scope or falls back to default, `SaveScope(characterKey, specId, scope)` writes to `db.characterPrefs[characterKey].lastComparatorScope`
- [X] T015 [US3] Implement `BuildComparisonService:Compare(buildIdA, buildIdB, scope)` in `BuildComparisonService.lua` — resolve both profiles via `BuildCatalogService:GetProfile` (fall back to minimal transient profile if not in catalog); call `CombatStore:GetSessionsForBuild` for each; aggregate `MetricSummary` from session arrays (win rate from `session.result`, pressureScore/burstScore/survivalScore from `session.metrics` — skip nil metric fields); populate `samplesA`, `samplesB`, `metricsA`, `metricsB`; assemble and return full `ComparisonResult` with `computedAt = GetTime()`
- [X] T016 [P] [US3] Implement `BuildComparisonService:GetBestHistoricalInScope(characterKey, specId, scope)` and `GetMostUsedInScope(characterKey, specId, scope)` in `BuildComparisonService.lua` — `GetBestHistoricalInScope` iterates all profiles for characterKey+specId, runs `GetSessionsForBuild` per profile, returns `buildId` with highest win rate among those with sample count ≥ `HIGH_MIN`; `GetMostUsedInScope` returns `buildId` with the highest session count in scope; both return `nil` if no qualifying profile found

---

## Phase 6: User Story 4 — Build Differences Readable Without External Tools (P2)

**Story Goal**: Selecting two builds shows a plain-language diff listing added, removed, and changed talents by name — readable in-addon without leaving.

**Independent Test**: Select Build A (with talent X selected) and Build B (talent X absent, talent Y selected instead, different PvP talent). Diff panel lists talent X as removed, talent Y as added, PvP change listed. Hero talent change (if any) appears first. Two identical builds show "Builds are identical in talent selection."

### Tasks

- [X] T017 [US4] Implement `BuildComparisonService:ComputeDiff(profileA, profileB)` in `BuildComparisonService.lua` — (1) compare `heroTalentSpecId`: if different, produce `HeroTalentChange`; (2) sort both `pvpTalentSignature` arrays and compute symmetric difference as `PvPTalentChange[]`; (3) index each profile's `talentNodes` array by `nodeId`; for each nodeId: A-only → `{changeType="removed"}`, B-only → `{changeType="added"}`, both with different `entryId` → `{changeType="choice_changed"}`, both with same `entryId` but different `activeRank` → `{changeType="rank_changed"}`; (4) attempt `GetSpellInfo(definitionSpellId)` for each changed node and store result as `spellNameA`/`spellNameB` (nil if unavailable — non-blocking); (5) sort output by importance order: hero → pvp → choice_changed → added/removed → rank_changed; (6) set `isIdentical=true` and `totalChanges=0` when all three comparisons yield zero changes; wire `ComputeDiff` into `Compare()` so `ComparisonResult.diff` is always populated

---

## Phase 7: User Story 5 — Confidence and Data Quality Surfaced Clearly (P2)

**Story Goal**: A build with 1 session shows a "Low — 1 session" badge; verdict language is suppressed. A build with 20+ sessions may show metric deltas.

**Independent Test**: Compare a build with 1 session (in scope) against a build with 20 sessions. Build A's panel shows confidence badge "Low — 1 session". No "Build A wins" or "Build B is better" text appears anywhere. Build B's panel shows HIGH confidence tier.

### Tasks

- [X] T018 [US5] Implement `BuildComparisonService:ClassifyConfidence(sampleCount)` in `BuildComparisonService.lua` — reads `Constants.CONFIDENCE_TIER_THRESHOLDS`: returns `NO_DATA` for 0, `LOW` for 1–`MEDIUM_MIN-1`, `MEDIUM` for `MEDIUM_MIN`–`HIGH_MIN-1`, `HIGH` for ≥`HIGH_MIN`; wire into `Compare()` so `confidenceA = ClassifyConfidence(samplesA)` and `confidenceB = ClassifyConfidence(samplesB)` are set on every `ComparisonResult`

---

## Phase 8: User Story 6 — Build Selector Discoverable and Navigable (P2)

**Story Goal**: Players can search, sort, and select builds from a list; Current Live Build is always visible at top; same-build comparison is prevented.

**Independent Test**: Create 5+ builds. Open comparator. Type partial spec name in search box → list narrows. Sort by session count → highest count appears first. Current Live Build is always at top regardless of sort. Attempt to select the same build on Side B as Side A → selector shows a warning or prevents the action.

### Tasks

- [X] T019 [US6] Redesign `UI/BuildComparatorView.lua` structure — remove `_indexA`, `_indexB` arrow-cycling variables and all associated arrow button handlers; remove `computeMetrics()`, `buildLabel()`, `resolveBuildMeta()` local functions and the `LOW_SAMPLE_THRESHOLD = 5` constant (replaced by `Constants.CONFIDENCE_TIER_THRESHOLDS`); add a scrollable build list panel per side (A and B) populated by `BuildCatalogService:GetAllProfiles(characterKey)`; pin "Current Live Build" (from `BuildCatalogService:GetCurrentLiveBuild()`) as the first entry regardless of sort
- [X] T020 [US6] Add text search filter and sort controls to the build selector in `UI/BuildComparatorView.lua` — `EditBox` for text search (client-side match against `GetDisplayLabel`); sort dropdown with options: Most Recent, Session Count, Win Rate in Scope, Name A–Z; re-render list on search input change or sort change; same build selected on Side A must be marked disabled/unavailable in Side B's selector with a tooltip "Already selected on the other side"
- [X] T021 [US6] Add scope banner and scope selector to `UI/BuildComparatorView.lua` — scope banner (`FontString`) always visible above both panels showing active scope description (e.g., "12 arena sessions on this character vs all opponents"); add scope controls: context dropdown (`CONTEXT` enum values), bracket dropdown, opponent class dropdown; on scope change, call `BuildComparisonService:SaveScope()` then re-run `Compare()` and re-render; restore scope via `BuildComparisonService:GetLastScope()` on comparator open
- [X] T022 [US6] Add per-build panels A and B to `UI/BuildComparatorView.lua` — each panel shows: display label (from `GetDisplayLabel`), sample count (`N sessions`), confidence badge (color-coded `FontString`: gray=NO_DATA, yellow=LOW, blue=MEDIUM, green=HIGH), metrics row (win rate, pressure, burst, survival) hidden when `confidenceA/B` is `NO_DATA` or `LOW`, "No combat history in this scope" `FontString` placeholder when samples=0; remove all direct `db.aggregates.builds` reads — use `BuildComparisonService:Compare()` result exclusively
- [X] T023 [US6] Add diff panel and quick-actions to `UI/BuildComparatorView.lua` — diff panel below both build panels: compact mode shows top-3 changes by importance with `"X more differences"` count button to expand; expanded mode shows full ordered change list from `ComparisonResult.diff`; "Builds are identical in talent selection" state when `diff.isIdentical==true`; quick-actions bar: Swap A↔B button, "Compare current vs previous" button (selects current live build on A and previous profile in catalog on B), "Compare current vs best in scope" button (calls `GetBestHistoricalInScope`)

---

## Phase 9: User Story 7 — Historical Data Survives Migration (P3)

**Story Goal**: All sessions recorded before this feature update remain visible and correctly grouped after migration to schema v7.

**Independent Test**: Note total session count before addon update via `/ca stats`. Update addon. Log in. Check `/ca stats` — total count identical. Open Build Comparator — all sessions visible under build profiles. Run `/ca debug export` — `db.buildCatalog` populated, no `null` buildId in any session. Reload twice — profile count unchanged.

### Tasks

- [X] T024 [US7] Add v6→v7 migration gate to `CombatStore:MigrateSchema()` in `CombatStore.lua` — gate condition: `db.schemaVersion == 6`; (1) initialize `db.buildCatalog = { order={}, byId={} }` if absent; (2) initialize `db.characterPrefs = db.characterPrefs or {}`; (3) iterate all sessions in `db.combats.byId`: call `BuildHash.ComputeBuildId(session.playerSnapshot)` and `BuildHash.ComputeLoadoutId(session.playerSnapshot)`, stamp results onto `session.playerSnapshot.buildId` and `.loadoutId`; set `session.playerSnapshot.snapshotFreshness = SNAPSHOT_FRESHNESS.FRESH` (migrated data is treated as valid); upsert a `BuildProfile` via `CombatStore:UpsertBuildProfile(buildId, ...)` for each unique buildId; set `db.schemaVersion = 7` on completion
- [X] T025 [US7] Implement legacy hash merge in migration gate in `CombatStore.lua` — after stamping all sessions: group sessions by new `buildId`; for each `buildId`, collect all distinct `legacyBuildHash` values from those sessions (read from `session.playerSnapshot.buildHash`, the pre-existing field); append all collected legacy hashes to `profile.legacyBuildHashes` deduplicating by value; recalculate `profile.sessionCount` from actual session count; this consolidates split-hash sessions (previously different slots, same talents) under one profile
- [X] T026 [US7] Handle partial-data sessions in migration gate in `CombatStore.lua` — if `session.playerSnapshot` is nil or `session.playerSnapshot.talentNodes` is nil or empty: compute a deterministic fallback `buildId = "legacy-partial-" .. (session.playerSnapshot and session.playerSnapshot.buildHash or session.id):sub(1,8)`; set `isMigrated=true`, `isMigratedWithWarnings=true` on the resulting profile; preserve the session under this profile rather than discarding it; idempotence: skip stamping if `session.playerSnapshot.buildId` is already non-nil (migration already ran)

---

## Final Phase: Polish — Diagnostics, Edge Cases, and Nil-Guard Audit

**Goal**: Freshness warnings, debug export coverage, empty states, and nil-guard verification complete the feature. All code paths tolerate nil or missing inputs without Lua errors.

### Tasks

- [X] T027 [P] Add freshness warning banner to `UI/BuildComparatorView.lua` — a visible `FontString` or frame positioned above the build selector that shows "Build data loading — talent information may be incomplete" when `BuildCatalogService:GetCurrentLiveBuild().snapshotFreshness` is `DEGRADED` or `UNAVAILABLE`; hidden when freshness is `FRESH` or `PENDING_REFRESH`; auto-clears on the next snapshot refresh event without requiring player action
- [X] T028 [P] Extend the `/ca debug export` output — in the debug export code path (existing `CombatStore` or debug handler): append current `buildId` (from `BuildCatalogService:GetCurrentLiveBuild().buildId`), `loadoutId`, `snapshotFreshness`, and a `buildCatalog` summary block listing profile count, each profile's `buildId`, `sessionCount`, `isCurrentBuild`, `isMigratedWithWarnings` flag
- [X] T029 [P] Add single-build empty state to `UI/BuildComparatorView.lua` — when `BuildCatalogService:GetAllProfiles()` returns fewer than 2 profiles, hide both build selector panels and show a centered `FontString`: "Only one talent build recorded so far. Switch to a different talent setup and play a match to create a second build for comparison."
- [X] T030 [P] Add empty-scope state to `UI/BuildComparatorView.lua` — when `BuildComparisonService:Compare()` returns `samplesA=0` AND `samplesB=0` AND both builds have non-empty catalog entries, show a scope-description message: "No sessions found for the current scope. Try broadening the filter or selecting a different context." alongside the scope selector so the player can adjust
- [X] T031 Nil-guard audit across `BuildCatalogService.lua` and `BuildComparisonService.lua` — verify every public method listed in the contracts (`RefreshFromSnapshot`, `GetCurrentLiveBuild`, `GetAllProfiles`, `GetProfile`, `GetDisplayLabel`, `SetAlias`, `ArchiveProfile`, `Compare`, `ComputeDiff`, `ClassifyConfidence`, `GetDefaultScope`, `GetLastScope`, `GetBestHistoricalInScope`, `GetMostUsedInScope`) tolerates `nil` input parameters without Lua error; add `if not x then return nil end` guards where absent; add trace log (using existing trace utility) for any degraded-result case

---

## Dependency Graph

```
T001 (toc registration)
  │
  ├──▶ T002 [P] (Constants.lua)
  ├──▶ T003 [P] (Events.lua)
  └──▶ T004 [P] (BuildHash.lua)
         │
         ▼
       T005 (CombatStore: catalog init + CRUD)
         │
         ▼
       T006 (CombatStore: scoped query)
         │
         ├──▶ T007 (SnapshotService: buildId stamping)    [US2]
         │      │
         │      ▼
         │    T008 (SnapshotService: TRAIT_CONFIG_UPDATED) [US2]
         │      │
         │      ▼
         │    T009 (CombatTracker: session enrichment)    [US2]
         │      │
         │      ▼
         │    T010 (BuildCatalogService: scaffold + core) [US1]
         │      │
         │      ▼
         │    T011 (BuildCatalogService: queries)         [US1]
         │      │
         │      ▼
         │    T012 (BuildCatalogService: management)      [US1]
         │      │
         │      ▼
         │    T013 (wire RefreshFromSnapshot in Snapshot) [US1]
         │      │
         │      ▼
         │    T014 (BuildComparisonService: scaffold)     [US3]
         │      │
         │      ▼
         │    T015 (BuildComparisonService: Compare())    [US3]
         │      │
         │      ├──▶ T016 [P] (GetBest/MostUsed)         [US3]
         │      │
         │      ▼
         │    T017 (ComputeDiff)                          [US4]
         │      │
         │      ▼
         │    T018 (ClassifyConfidence + wire)            [US5]
         │      │
         │      ▼
         │    T019 (UI: structure redesign)               [US6]
         │      │
         │      ▼
         │    T020 (UI: search + sort)                    [US6]
         │      │
         │      ▼
         │    T021 (UI: scope banner + selector)          [US6]
         │      │
         │      ▼
         │    T022 (UI: per-build panels A+B)             [US6]
         │      │
         │      ▼
         │    T023 (UI: diff panel + quick-actions)       [US6]
         │      │
         └──▶ T024 (CombatStore: v6→v7 migration gate)   [US7]
                │
                ▼
              T025 (migration: legacy hash merge)         [US7]
                │
                ▼
              T026 (migration: partial-data sessions)     [US7]
                │
                ▼
         T027 [P] (UI: freshness warning)    ─┐
         T028 [P] (debug export extension)    │  Polish phase
         T029 [P] (UI: single-build state)    │  (all parallel)
         T030 [P] (UI: empty-scope state)     │
         T031     (nil-guard audit)          ─┘
```

**Key sequencing rules:**
- Phase 2 Foundational (T002–T006) blocks ALL user story phases — must complete first
- US2 (T007–T009) must complete before US1 (T010–T013): catalog needs buildId in snapshots
- US1 (T010–T013) must complete before US3 (T014–T016): comparison needs catalog to resolve profiles
- US3 (T014–T016) must complete before US4 (T017) and US5 (T018): diff and confidence depend on Compare()
- US4+US5 must complete before US6 (T019–T023): UI renders ComparisonResult including diff and confidence
- US7 (T024–T026) depends only on T005+T006 (catalog APIs) and T004 (ComputeBuildId) — can begin after Foundational phase, but placed at end due to P3 priority
- Polish (T027–T031) is independent; T027/T028/T029/T030 can run in parallel after US6 and US7 complete

---

## Task Count Summary

| Phase | Story | Tasks | Parallelizable |
|-------|-------|-------|----------------|
| Phase 1 | Setup | 1 (T001) | — |
| Phase 2 | Foundational | 5 (T002–T006) | T002, T003, T004 |
| Phase 3 | US2 (P1) | 3 (T007–T009) | — |
| Phase 4 | US1 (P1) | 4 (T010–T013) | — |
| Phase 5 | US3 (P1) | 3 (T014–T016) | T016 |
| Phase 6 | US4 (P2) | 1 (T017) | — |
| Phase 7 | US5 (P2) | 1 (T018) | — |
| Phase 8 | US6 (P2) | 5 (T019–T023) | — |
| Phase 9 | US7 (P3) | 3 (T024–T026) | — |
| Polish | — | 5 (T027–T031) | T027, T028, T029, T030 |
| **Total** | — | **31** | **8** |
