# Feature Specification: Build Comparator Overhaul

**Feature Branch**: `003-build-comparator-overhaul`
**Created**: 2026-03-28
**Status**: Draft
**Input**: Build Comparator redesign requirements — canonical build identity, live build detection, scoped comparison, human-readable diffs, migration from legacy hashes.

---

## Context

The current Build Comparator cannot be trusted because build identity is indirect and unstable. A "build" only comes into existence after combat history is recorded under a specific hash that mixes talent identity with Blizzard loadout slot identity. This means two identical talent setups in different loadout slots appear as different builds, a brand-new talent configuration is invisible until at least one combat session is recorded, and there is no way to inspect what differs between two builds in human-readable form.

The overhaul separates three distinct concepts — canonical build, loadout metadata, and session snapshot — and introduces an explicit build catalog, current live build detection, scoped comparison semantics, and a human-readable talent diff. It also provides a migration path that preserves all historical session data while reindexing it under the new identity model.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Current Live Build Is Immediately Visible (Priority: P1)

As a player, when I switch to a new talent setup, I want to open the Build Comparator and immediately see that setup listed as a selectable build — even before I have played a single match with it.

**Why this priority**: The most commonly reported failure is that a new build "doesn't appear" after changing talents. Fixing this eliminates the core trust gap and is the entry point for every other comparator feature.

**Independent Test**: Switch talent nodes in the talent UI, immediately open Build Comparator, confirm the new configuration appears as "Current Live Build" with a label showing the spec and hero talent tree. No combat session required.

**Acceptance Scenarios**:

1. **Given** the player changes one or more talent nodes without switching specialization, **When** the Build Comparator is opened, **Then** the current live build entry reflects the updated talent selection.

2. **Given** the player has changed talents but has zero recorded sessions with the new configuration, **When** the Build Comparator displays the current live build, **Then** the entry shows build metadata and a "No combat history yet in current scope" message rather than being hidden or blank.

3. **Given** the player has selected a PvP talent, **When** the Build Comparator is opened, **Then** the current live build entry includes the updated PvP talent in its label and diff summary.

4. **Given** the current build snapshot is in a degraded or stale state (e.g., talent data not yet fully loaded), **When** the Build Comparator displays the current live build, **Then** the entry shows an explicit freshness warning rather than silently presenting potentially incorrect build information.

5. **Given** the player logs in after a long absence, **When** the Build Comparator is opened, **Then** the current live build is refreshed from the player's actual current talents before being displayed.

---

### User Story 2 — Canonical Build Identity Is Stable Across Loadout Slots (Priority: P1)

As a player, when I save the same talent setup in two different Blizzard loadout slots, I want the Build Comparator to recognize them as the same build and aggregate their history together.

**Why this priority**: The legacy hash includes the Blizzard config slot ID, causing identical talent setups to appear as separate builds. This silently splits history and makes the comparator misleading without any indication to the player.

**Independent Test**: Record sessions with identical talent selections stored in loadout slot 1 and loadout slot 2. Open Build Comparator — both session sets should appear under a single consolidated build entry, not as two separate builds.

**Acceptance Scenarios**:

1. **Given** two Blizzard loadout slots contain identical talent nodes and PvP talents, **When** the canonical build identity is computed for each, **Then** both produce the same build identifier.

2. **Given** two sessions were recorded under different loadout slot IDs but identical talent selections, **When** the build catalog is queried, **Then** both sessions appear under the same build profile.

3. **Given** a player imports the same talent configuration from an import string into two different loadout slots, **When** comparing builds, **Then** the comparator treats them as the same canonical build while preserving the different loadout metadata for reference.

4. **Given** two identical talent setups differ only in their Blizzard-assigned config ID, **When** migration runs over historical data, **Then** both historical records are merged under a single canonical build profile.

---

### User Story 3 — Comparison Results Are Scoped to a Specific Context (Priority: P1)

As a player, when I compare two builds, I want the results to reflect only the combat context I care about — for example, only rated 2v2 arena matches against Frost Mages — so the metrics are meaningful rather than diluted across all contexts.

**Why this priority**: Unscoped global aggregates across arenas, duels, battlegrounds, and training dummies produce meaningless averages. A build that performs differently in each context requires scoped filtering before any comparison has value.

**Independent Test**: Set scope to "2v2 arena" and select two builds. Verify that sample counts and metrics change when scope is changed to "duel" — confirming the comparison re-filters to the selected context.

**Acceptance Scenarios**:

1. **Given** the scope is set to "2v2 arena," **When** a comparison is displayed, **Then** only sessions from 2v2 arena matches are included in the sample counts and metrics.

2. **Given** the scope is narrowed to "opponent class: Death Knight," **When** the comparison is displayed, **Then** the scope banner reads something like "Comparing 8 arena sessions on this character vs Death Knight."

3. **Given** a build has sessions in duels but zero sessions in the current scope of "rated 3v3 arena," **When** the comparison is displayed, **Then** the build shows "No combat history in current scope" rather than pulling in out-of-scope session data.

4. **Given** a player has set a custom scope on a previous session, **When** the Build Comparator is re-opened on the same character and specialization, **Then** the last-used scope is restored.

5. **Given** no scope filter has been selected, **When** the comparison is displayed, **Then** the default scope applies: current character, same specialization, current or last-used combat context.

---

### User Story 4 — Build Differences Are Readable Without External Tools (Priority: P2)

As a player, when I select two builds to compare, I want to see a plain-language description of what is different between them — which talents were added, removed, or changed — so I can understand the implications without leaving the addon.

**Why this priority**: Without a diff, the player can only see numeric metrics and must remember or manually inspect two talent setups to understand what changed. A diff makes the purpose of each historical build self-evident.

**Independent Test**: Select two builds that differ in two talent nodes and one PvP talent. Verify the diff panel lists those three differences by talent name, clearly indicating which build has each choice.

**Acceptance Scenarios**:

1. **Given** Build A has talent X selected and Build B does not, **When** the diff is displayed, **Then** talent X appears in the diff with a human-readable name indicating it is present in Build A and absent in Build B.

2. **Given** Build A and Build B share the same hero talent tree but differ in one choice node within it, **When** the diff is displayed, **Then** the changed choice node appears under the hero talent section with both options named.

3. **Given** the diff has many changes, **When** displayed in compact mode, **Then** only the most impactful changes are shown with a count of additional differences; expanding to detailed mode shows all changes.

4. **Given** two builds have identical talent selections, **When** compared, **Then** the diff panel explicitly states the builds are identical in talent selection rather than showing an empty or blank section.

5. **Given** one of the selected builds has zero recorded sessions, **When** the diff is displayed, **Then** the diff renders correctly based on stored talent data, unaffected by the absence of metrics.

---

### User Story 5 — Confidence and Data Quality Are Surfaced Clearly (Priority: P2)

As a player, when viewing a comparison, I want to know whether I have enough match history to trust the numbers — and when I don't, I want the UI to say so plainly rather than presenting unreliable statistics as if they were conclusive.

**Why this priority**: Small sample sizes produce noisy win rates and misleading metric deltas. Players who act on low-confidence data will draw wrong conclusions about which build is better.

**Independent Test**: Compare a build with 1 session against a build with 20 sessions. Verify that the 1-session build shows a visible "Low sample size" badge and that no "Build A is better" verdict appears for it.

**Acceptance Scenarios**:

1. **Given** a build has a sample count below the low-confidence threshold for the current scope, **When** the comparison is displayed, **Then** a confidence badge (e.g., "Low — 2 sessions") appears prominently on that build's panel.

2. **Given** a low-confidence comparison is displayed, **When** the system would otherwise derive a verdict such as "Build A wins," **Then** the verdict is suppressed and replaced with an explicit insufficient-data message.

3. **Given** both builds have sufficient session history for the current scope, **When** the comparison is displayed, **Then** metric deltas, trend indicators, and verdict summaries may be shown.

4. **Given** a build has zero sessions in the current scope but has sessions in other scopes, **When** the comparison is displayed for the current scope, **Then** the build shows "No data for this scope" rather than silently substituting out-of-scope sessions.

5. **Given** the player expands the confidence indicator, **When** the detail is shown, **Then** the sample count and the thresholds for each confidence tier are visible.

---

### User Story 6 — Build Selector Is Discoverable and Navigable (Priority: P2)

As a player, when I want to select a build for comparison, I want to use a real search and sort interface rather than cycling through builds with arrows, so I can find a specific build quickly and understand what each option represents.

**Why this priority**: With multiple builds accumulating over time, arrow-based cycling becomes unusable. A searchable, sortable selector with readable labels is required for the feature to scale.

**Independent Test**: Create five or more builds across different specs. Open the build selector, search for a build by spec name, sort by session count, and verify the selector shows human-readable labels including spec name and hero talent tree.

**Acceptance Scenarios**:

1. **Given** the player has multiple builds, **When** the build selector is opened and a partial spec name is typed, **Then** the list narrows to matching builds.

2. **Given** the player sorts by session count, **When** the build list is displayed, **Then** builds with more recorded sessions appear earlier.

3. **Given** the same build is already selected on Side A, **When** the player attempts to select it on Side B, **Then** the selector prevents or warns against a same-build comparison.

4. **Given** only one build exists in the catalog, **When** the comparator is opened, **Then** a message explains that additional builds will appear as different talent setups are used.

5. **Given** the player selects the "Compare current to best historical in scope" quick action, **When** executed, **Then** the comparator populates both slots and displays the result.

---

### User Story 7 — Historical Data Survives Migration (Priority: P3)

As a player with existing match history, I want all my previously recorded sessions to remain accessible after the addon updates, correctly grouped under the new build identity system, without any loss.

**Why this priority**: Existing players have meaningful history invested in the addon. A migration that silently loses, misattributes, or drops sessions will damage trust irrecoverably.

**Independent Test**: Update the addon on a character with at least 10 recorded sessions. Open Build Comparator and verify all sessions remain visible and the total session count matches the pre-migration count. Run debug export and verify no data-loss warnings.

**Acceptance Scenarios**:

1. **Given** migration runs on existing saved data, **When** the Build Comparator is opened, **Then** all historical sessions remain visible and attributed to build profiles.

2. **Given** historical sessions were recorded under two different legacy hashes that differ only by Blizzard config slot ID, **When** migration completes, **Then** both are merged under a single canonical build profile with the original legacy hashes preserved for audit.

3. **Given** a historical session has incomplete talent data and cannot be fully migrated, **When** the catalog is queried, **Then** the session is preserved as a partial record and the build profile is marked as migrated-with-warnings, rather than discarded.

4. **Given** migration has already run successfully, **When** migration is triggered again, **Then** no duplicate build profiles are created and the result is identical to the first run.

---

## Requirements *(mandatory)*

### Functional Requirements

#### Build Identity

- **FR-001**: The system MUST compute canonical build identity from talent selections only: class, specialization, hero talent tree, selected PvE talent nodes, and selected PvP talents.

- **FR-002**: Canonical build identity MUST exclude: Blizzard loadout slot identifier, gear, average item level, stats, import string (by default), timestamps, and transient runtime state.

- **FR-003**: Two talent setups with identical class, specialization, hero talent tree, PvE talent node selections, and PvP talents MUST produce the same canonical build identifier regardless of which Blizzard loadout slot they are stored in or which import string was used.

- **FR-004**: The identity system MUST include a version marker so that future changes to identity computation can be detected and existing data can be re-migrated safely.

- **FR-005**: The system MUST maintain a separate loadout identity capturing Blizzard's loadout metadata (slot identifier, loadout name, import string, user aliases), distinct from canonical build identity.

- **FR-006**: Import strings MUST be treated as loadout metadata by default and MUST NOT influence canonical build identity.

#### Build Catalog

- **FR-007**: The system MUST maintain a persistent build catalog where each entry is indexed by canonical build identifier and persists across sessions.

- **FR-008**: A build profile MUST become visible in the comparator as soon as the player activates the corresponding talent setup, with no requirement for a prior recorded combat session.

- **FR-009**: Each build profile MUST record: first seen timestamp, last seen timestamp, latest session reference, canonical build details, associated loadout identifiers, known display names and aliases, session count, and per-character ownership.

- **FR-010**: Build profiles MUST support the following state properties. Persisted flags (stored on the profile): current/active, archived, migrated, migrated-with-warnings. Derived properties (computed at query time per scope, not stored): low-confidence, no-samples-in-scope. The distinction is intentional — low-confidence and no-samples-in-scope are scope-dependent and cannot be meaningfully stored as fixed profile attributes.

#### Current Live Build

- **FR-011**: The system MUST expose the player's current active talent setup as a dedicated "Current Live Build" entry that is always present and selectable in the build selector.

- **FR-012**: The system MUST refresh the live build state when any of the following occur: player login or UI reload, specialization change, PvP talent change, hero talent change, active talent node selection change, or any event that alters the current talent state.

- **FR-013**: The current live build MUST remain selectable in the comparator even when it has zero recorded combat sessions globally or in the active scope.

- **FR-014**: The system MUST track the freshness of the current build snapshot and expose at minimum the following states: fresh, pending refresh, degraded, unavailable.

- **FR-015**: If a combat session begins while the build snapshot is in a degraded or unavailable state, the session MUST record that degraded state so the capture is not silently treated as full-confidence.

- **FR-016**: The comparator MUST never silently present build information derived from a stale or degraded snapshot; an explicit freshness warning MUST be shown to the player.

#### Comparison Scope

- **FR-017**: Comparison results MUST be computed from a filtered set of sessions matching an explicit active scope, not from unfiltered global aggregates.

- **FR-018**: Scope MUST support filtering by at minimum: character, specialization, combat context (arena, duel, dummy, world PvP, etc.), bracket or subcontext, opponent class, opponent specialization when available, and date range.

- **FR-019**: The comparator MUST display the active scope in a visible scope banner describing exactly which sessions are included. Example: "12 arena sessions on this character vs Frost Mage."

- **FR-020**: The default scope MUST be: current character, same specialization, current or last-used combat context, all opponents.

- **FR-021**: The last-used scope MUST persist per character and specialization.

#### Comparison Output

- **FR-022**: For every A vs B comparison, the UI MUST show: a summary for each build (name, spec, hero talent, sample count), the active scope, core performance metrics per build, a confidence classification, and a build diff summary.

- **FR-023**: A build with zero sessions in the active scope MUST still display build metadata and diff in the comparison, with an explicit "No combat history in this scope" message in place of metric data.

- **FR-024**: The system MUST classify comparison confidence using at minimum four tiers: no data, low confidence, medium confidence, high confidence, based on sample count thresholds that are centrally defined.

- **FR-025**: Low-confidence comparisons MUST show the sample count prominently and MUST NOT use verdict language (e.g., "Build A is better").

- **FR-026**: High-confidence comparisons MAY show metric deltas, trend indicators, and verdict summaries.

- **FR-027**: Comparison metrics MUST be queryable by scope so that changing scope dimensions re-filters the sample set.

#### Build Diff

- **FR-028**: The comparator MUST provide a human-readable diff between any two selected builds covering: added talents, removed talents, changed choice node selections, changed talent ranks where applicable, changed PvP talents, and changed hero talent tree or hero spec.

- **FR-029**: The diff MUST be computed and displayed even when one or both selected builds have zero recorded sessions.

- **FR-030**: The diff MUST support two display modes: compact (most impactful differences only, with a count of remaining changes) and expanded (full change list).

- **FR-031**: Diff entries MUST be ordered by importance, with the most impactful or most visible changes shown first.

#### Build Selector and Navigation

- **FR-032**: The build selector MUST support: text search, sorting by recency, sorting by session count, sorting by win rate in current scope, and sorting by display name.

- **FR-033**: The Current Live Build MUST be prominently surfaced in the build selector regardless of sort order.

- **FR-034**: The comparator MUST prevent selecting the same build on both Side A and Side B, unless an explicit debug mode permits it.

- **FR-035**: The comparator MUST provide quick-action shortcuts: Swap A and B, Compare current to previous build, Compare current to most-used build in scope, Compare current to best historical build in scope.

- **FR-036**: When fewer than two distinct builds exist in the catalog, the comparator MUST display a message explaining how additional builds become available.

#### Build Labeling

- **FR-037**: Each build entry MUST display a human-readable label that includes at minimum: specialization name, hero talent tree, and PvP talent summary.

- **FR-038**: If no user-facing name exists, the system MUST generate a deterministic fallback label from build attributes (e.g., "Devastation / Scalecommander / Nullifying Shroud + Obsidian Mettle").

- **FR-039**: A build profile MUST support multiple names and aliases, and those aliases MUST be preserved and visible in the comparator.

#### Data Migration

- **FR-040**: The system MUST run a migration step when the stored data schema version changes, processing all existing session records to reconstruct canonical build identities and populate the build catalog.

- **FR-041**: Migration MUST preserve legacy build hash values on all affected records and profiles for audit reference.

- **FR-042**: Historical sessions previously recorded under two different legacy hashes that differ only by Blizzard loadout slot identifier MUST be consolidated under a single canonical build profile.

- **FR-043**: If a historical session lacks sufficient talent data to reconstruct a canonical build identity, it MUST be preserved as a partial record with migration warnings rather than discarded.

- **FR-044**: Migration MUST be idempotent: re-running it on already-migrated data MUST NOT produce duplicate profiles or alter correctly migrated records.

#### Service Architecture

- **FR-045**: Build catalog operations (register, update, query, manage aliases, expose current live build) MUST be handled by a dedicated service layer, not embedded in the UI view.

- **FR-046**: Comparison computation (scope filtering, confidence evaluation, metric aggregation, diff generation) MUST be handled by a dedicated service layer, not embedded in the UI view.

- **FR-047**: The comparator UI MUST render results provided by the service and persistence layers rather than deriving them directly.

#### Diagnostics

- **FR-048**: The addon MUST expose diagnostic information including: current build identifier, current loadout identifier, snapshot freshness status, and any migration warnings — accessible via the existing debug export path.

---

### Key Entities

- **Canonical Build**: The talent configuration that uniquely identifies a build for comparison purposes. Defined by class, specialization, hero talent tree, PvE talent node selections, and PvP talent selections. Excludes gear, loadout slot, and import string.

- **Build Identifier (buildId)**: A stable, deterministic identifier derived from the canonical build fields. Includes an identity version marker. Two identical talent setups always produce the same buildId.

- **Loadout**: Blizzard or user-facing metadata attached to a build. Includes Blizzard config slot, loadout name, import string, and user-assigned aliases. Has its own loadoutId, separate from buildId.

- **Build Profile**: A persistent catalog entry tracking a canonical build across time. Stores buildId, associated loadout identifiers, display names, session count, timestamps, and state flags.

- **Session Snapshot**: The exact state attached to a combat session at start. Includes canonical build, loadout metadata, gear, stats, freshness status, and capture timestamp. Immutable after session start.

- **Build Catalog**: The persistent registry of all known build profiles per character. The source of truth for build identity in the comparator.

- **Comparison Scope**: The set of filter dimensions applied to session samples when computing comparison results. Includes context, bracket, character, specialization, opponent filters, and date range.

- **Comparison Result**: The output of comparing Build A against Build B within a scope. Includes per-build summaries, sample counts, metrics, confidence classification, and build diff.

- **Build Diff**: A human-readable summary of talent differences between two builds. Covers added, removed, and changed PvE talents, PvP talents, and hero talent tree choices.

- **Confidence Tier**: A classification of how reliable a comparison result is, based on sample counts within the active scope. Tiers: no data, low confidence, medium confidence, high confidence.

---

## Success Criteria *(mandatory)*

- **SC-001**: After a player changes talent nodes and immediately opens the Build Comparator without playing any matches, the updated talent setup appears as "Current Live Build" and is selectable for comparison.

- **SC-002**: Two sessions recorded with identical talent selections but saved under different Blizzard loadout slots are grouped under a single build profile and their session counts are combined.

- **SC-003**: Any two builds with differing talent selections show a human-readable diff in the comparator naming the specific talents added, removed, or changed.

- **SC-004**: A comparison scoped to "2v2 arena" includes only 2v2 arena sessions in its sample counts; switching scope to "duel" changes the sample counts to reflect only duel sessions.

- **SC-005**: A build below the low-confidence threshold shows a clearly labeled confidence badge and no verdict language in the comparison output.

- **SC-006**: The comparator is fully functional (shows build metadata and talent diff) for a brand-new build with zero recorded sessions.

- **SC-007**: After migration runs on existing saved data, all historical sessions remain queryable and the total session count per character matches the pre-migration total.

- **SC-008**: When the current build snapshot is stale or degraded, the player sees an explicit freshness indicator; no stale data is silently presented as current.

---

## Edge Cases

- **Specialization switch during a session**: The session snapshot locks to the specialization at session start and is not overwritten by a post-switch state.

- **Import string used to populate talents, different result in another slot**: Import string alone does not determine build identity. Identity is computed from the actual selected talent nodes.

- **Hero talent tree not yet chosen**: Build identity is computable from available fields. Absent hero talent data degrades gracefully and does not block catalog registration.

- **PvP talents unavailable outside PvP zone**: If PvP talent data is unavailable at snapshot time, the build profile records available data and marks PvP talent coverage as partial.

- **Both comparison sides have zero history in scope**: Metadata and diff are shown for both builds; zero-data messages appear on both metric panels without errors.

- **Scope yields zero sessions for all builds**: The comparator shows an empty-state message describing the active scope and suggesting a broader filter.

- **Legacy sessions with missing talent node data**: Migration preserves these as partial records under the best available identity reconstruction. They are not discarded.

- **Duplicate alias names across build profiles**: Display resolves gracefully without error, preferring the most recently active profile.

- **Single-build catalog**: The comparator remains operable and explains how a second build becomes available.

- **Multiple refresh events on login**: Concurrent snapshot refresh triggers (spec change, login, talent load) are coalesced into a single refresh to avoid redundant computation.

---

## Assumptions

- The comparator is scoped to talent build comparison only in this version. Gear comparisons are explicitly excluded from canonical build identity, though gear data continues to be stored in session snapshots for potential future use.

- Import strings are loadout metadata and do not participate in canonical build identity. Future adoption as an identity signal would require a separate spec.

- Confidence thresholds (session counts for low/medium/high tiers) will be defined during implementation based on observed session volumes and centralized in a configuration surface.

- Unrated and rated arena are distinct combat contexts. A scope set to rated 2v2 will not include unrated matches.

- The comparator operates per character. Cross-character build comparison is out of scope for this version.

- The build identity version starts at 1 and increments when identity computation changes in a future update.

- Migration is triggered automatically on schema version change and requires no player action.

- Opponent talent data is not available in most contexts. Opponent filtering in scope is limited to opponent class and specialization.
