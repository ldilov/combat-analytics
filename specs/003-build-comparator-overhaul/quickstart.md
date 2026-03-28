# Quickstart: Build Comparator Overhaul

**Feature**: `003-build-comparator-overhaul` | **Date**: 2026-03-28

This document describes the key integration scenarios a developer needs to validate during implementation. Each scenario is independently testable in-game.

---

## Scenario 1 — Current Live Build Appears Before Any Combat

**Goal**: Validates FR-008, FR-011, FR-013, SC-001

**Setup**: A fresh character or a character whose catalog is empty for the current spec.

**Steps**:
1. Log in or `/reload`.
2. Open the talent UI and confirm at least one talent node is selected.
3. Open the Build Comparator (`/ca` → comparator tab).

**Expected result**:
- A "Current Live Build" entry is visible in the build selector.
- The entry shows the correct specialization name and hero talent tree.
- No session count or metrics are shown; the message "No combat history yet in current scope" or equivalent is displayed.
- No Lua error in the system log.

**Failure modes to check**:
- Entry is absent → `BuildCatalogService:RefreshFromSnapshot` did not fire or `isCurrentBuild` was not set.
- Entry shows stale data from a previous spec → `isCurrentBuild` was not cleared on spec change.

---

## Scenario 2 — Talent Node Click Updates Live Build Identity

**Goal**: Validates FR-012 (TRAIT_CONFIG_UPDATED coverage), SC-001

**Setup**: Build Comparator open (or openable immediately after the talent change).

**Steps**:
1. Open the talent UI.
2. Select or deselect one talent node.
3. Close the talent UI.
4. Open the Build Comparator.

**Expected result**:
- The "Current Live Build" entry reflects the updated talent selection.
- If the change produces a new `buildId`, the selector shows it as a distinct entry from any prior live build.
- No snapshot freshness warning (snapshot should be FRESH after the config update event).

**Developer check**: Run `/ca debug snapshot` (or equivalent debug command) immediately after the talent change to confirm `buildId` and `snapshotFreshness = FRESH` appear in output.

---

## Scenario 3 — Identical Builds Across Two Loadout Slots Merge

**Goal**: Validates FR-003, FR-042, SC-002

**Setup**: A character with sessions recorded in two different Blizzard loadout slots that use the same talent nodes and PvP talents.

**Steps** (simulate by triggering migration or recording fresh sessions):
1. Select loadout slot 1 with talent setup X.
2. Record one or more arena sessions.
3. Switch to loadout slot 2 with the exact same talent setup X.
4. Record one or more arena sessions.
5. Open the Build Comparator.

**Expected result**:
- Both session sets appear under **one** build profile entry, not two separate entries.
- The combined session count equals the total from both slots.
- The profile's `legacyBuildHashes` field contains both old hash values (verifiable via `/ca debug export`).

**Migration path** (existing data): If sessions were recorded before this feature, run a UI reload after updating the addon. The v6→v7 migration should consolidate them on first load.

---

## Scenario 4 — Scoped Comparison Changes Sample Counts

**Goal**: Validates FR-017, FR-018, FR-019, SC-004

**Setup**: A character with sessions in at least two distinct contexts (e.g., 2v2 arena and duels).

**Steps**:
1. Open the Build Comparator with the default scope.
2. Note the sample count for both builds A and B.
3. Change the scope to "2v2 Arena" only.
4. Note the updated sample counts.
5. Change the scope to "Duel" only.
6. Note the updated sample counts again.

**Expected result**:
- Sample counts differ across scope changes, confirming the filter is applied.
- The scope banner text updates to describe the active scope (e.g., "2 arena sessions on this character vs all opponents").
- A build with sessions in 2v2 but zero duel sessions shows "No data for this scope" when scope is set to Duel.

**Developer check**: Verify `CombatStore:GetSessionsForBuild(buildId, scope)` returns different counts for each scope by adding a temporary trace log.

---

## Scenario 5 — Build Diff Lists Talent Changes by Name

**Goal**: Validates FR-028, FR-029, FR-031, SC-003

**Setup**: Two distinct build profiles in the catalog that differ in at least one choice node, one PvP talent, and one hero talent tree (or any combination of differences).

**Steps**:
1. Open the Build Comparator.
2. Select Build A on the left side and Build B on the right side.
3. Inspect the diff panel.

**Expected result**:
- Each change is listed with a readable spell/talent name (or a nodeId fallback if spell name is unavailable).
- Hero talent change (if any) appears first.
- PvP talent changes appear before PvE talent changes.
- Choice node changes appear before rank changes.
- "2 more differences" (or similar) appears in compact mode when more than 3 changes exist.
- Expanding to full mode shows all changes.

**Edge case**: Both builds are identical → diff panel shows "Builds are identical in talent selection" message, no change list.

---

## Scenario 6 — Confidence Badge Suppresses Verdict on Low Sample

**Goal**: Validates FR-024, FR-025, SC-005

**Setup**: Build A has 1 session in the current scope; Build B has 20+ sessions.

**Steps**:
1. Open the Build Comparator with Build A and Build B selected.
2. Set scope to a context where Build A has 1 session.

**Expected result**:
- Build A's panel shows a "Low — 1 session" confidence badge (or equivalent).
- No verdict language ("Build A wins", "Build B is better") appears anywhere.
- Build B's panel shows its higher confidence tier.
- Metric deltas (if any) are suppressed or marked as unreliable for Build A's side.

---

## Scenario 7 — Migration Preserves All Sessions

**Goal**: Validates FR-040, FR-041, FR-044, SC-007

**Setup**: A character with 10+ sessions recorded before this feature was implemented (schema version 6 data).

**Steps**:
1. Note the total session count via `/ca history` or `/ca debug export` (pre-migration).
2. Deploy the updated addon (schema version 7).
3. Log in — migration runs automatically.
4. Open Build Comparator and History tab.

**Expected result**:
- Total session count matches the pre-migration total.
- All sessions appear under build profiles (no orphaned sessions).
- Sessions that were split across loadout slots due to the old hash are now grouped under a single profile.
- `/ca debug export` includes `db.buildCatalog` with at least one profile per distinct talent setup.
- Re-running the migration (second `/reload`) produces no additional profiles or duplicate entries.

**Partial data**: If any session had nil `talentNodes`, it appears under a `"legacy-partial-XXXXXXXX"` profile with `isMigratedWithWarnings = true`. The session is NOT discarded.

---

## Scenario 8 — Degraded Snapshot Shows Freshness Warning

**Goal**: Validates FR-014, FR-015, FR-016, SC-008

**Setup**: Simulate a degraded snapshot state by opening the Build Comparator immediately after login before talent data is fully loaded, or by temporarily blocking the snapshot refresh in a test scenario.

**Steps**:
1. Log in and immediately open the Build Comparator before the talent data has loaded.
   *(In practice, use `/ca debug snapshot` to check `snapshotFreshness` value.)*

**Expected result**:
- If `snapshotFreshness == DEGRADED` or `UNAVAILABLE`, the Build Comparator shows an explicit freshness warning banner on the current live build entry.
- The warning is not a generic error — it specifically explains that talent data is loading or unavailable.
- The current live build is still selectable for comparison; it does not disappear.
- Once the snapshot refreshes to FRESH, the warning disappears without requiring a manual action.

---

## Debug Commands Reference

| Command | Purpose |
|---------|---------|
| `/ca debug snapshot` | Print current `playerSnapshot` including `buildId`, `loadoutId`, `snapshotFreshness` |
| `/ca debug export` | Full SavedVariables dump including `db.buildCatalog` summary |
| `/ca debug catalog` | List all `BuildProfile` entries with flags and session counts |
| `/ca stats` | Session totals per character (use for pre/post migration count verification) |
