# Sprint B Design — P0 Correctness Fixes + Visual Timeline Replay + Build Comparator

## Overview

Sprint B combines two P0 correctness fixes that affect data trust with two high-value new features that directly answer the player's core questions: *why did I lose this round?* and *which build performs better into this matchup?*

All work targets the existing Lua/WoW Midnight addon architecture. No CLEU event data is used — the addon operates within restricted-mode constraints.

---

## P0 Fix 1 — Aggregate Lookup Helpers

### Problem

`CombatStore:GetAggregateBuckets(kind)` returns a **sorted list** of bucket objects:

```lua
-- Returns: { {id="261", fights=10, wins=6, ...}, {id="105", fights=3, ...}, ... }
```

Four consumers treat the result as a **keyed map** (`buckets["261"]`), which is always `nil`. This silently zeroes out:

- Counter guide left-panel W/L badges (`UI/CounterGuideView.lua:67-68`)
- `StrategyEngine` spec win-rate calculations (`StrategyEngine.lua:133-142`, `197-200`)
- `SuggestionEngine` SPEC_WINRATE_DEFICIT rule (`SuggestionEngine.lua:237-239`)
- Build-personalized guide decisions (CounterGuideView)

### Fix

Add two accessor helpers to `CombatStore`:

```lua
-- Returns the single bucket matching kind/key/characterKey, or nil.
function CombatStore:GetAggregateBucketByKey(kind, key, characterKey) end

-- Convenience wrapper for spec buckets.
function CombatStore:GetSpecBucket(specId, characterKey) end
```

Update all four call sites to use the new helpers instead of direct map indexing.

---

## P0 Fix 2 — Snapshot Accessor Inconsistency

### Problem

`Core.lua` writes the latest player snapshot to `runtime.latestPlayerSnapshot` and exposes `ns.Addon:GetLatestPlayerSnapshot()`. Three consumers read a **different field** — `runtime.playerSnapshot` — which is never written. `buildHash` is always `nil` in:

- `UI/CounterGuideView.lua:197` — build-personalized guide decisions
- `UI/MatchupDetailView.lua:59` — matchup detail personalization
- `CombatTracker.lua:2527` — pre-match advisory build awareness

### Fix

Replace all three direct field reads with the canonical accessor:

```lua
-- Before (broken):
local snap = ns.Addon.runtime and ns.Addon.runtime.playerSnapshot
-- After:
local snap = ns.Addon:GetLatestPlayerSnapshot()
```

---

## Feature: Visual Timeline Replay

### Purpose

Display a compact visual timeline for any selected session, showing the first 60 seconds (or full duration) of combat. Answers *what happened in this round?* and *when did key events occur relative to each other?*

### Data Sources (no CLEU required)

| Lane | Source | Field |
|---|---|---|
| Offensive casts | `session.rawEvents` | `eventType == "SPELL_CAST_SUCCESS"`, `spellId`, `timestampOffset` |
| Defensive windows | `session.cooldowns` | `spellId`, `activatedAt`, `deactivatedAt` |
| CC received | `session.ccReceived[]` | `startedAt`, `endedAt`, `spellId` |
| Kill windows | `session.killWindows[]` | `openedAt`, `closedAt`, `type` |
| Death marker | `session.deathEvents[]` | `timestamp` (first entry) |
| Session duration | `session.duration` | seconds |

### Layout

A new `UI/ReplayView.lua` module renders a stateless canvas given a session object. It is opened from the History detail button (new "Replay" button alongside existing "Details").

```
[Replay — <session label>]

[Offensive Casts] ●  ●     ●●        ●
[Defensive]       [=====]      [===]
[CC Received]              [====]
[Kill Window]                    [=====]

0s          15s         30s         45s        60s
```

Each lane is a WoW `Frame` with child `Texture` objects (colored bars/dots) positioned via proportional `SetPoint`. No custom rendering library needed.

**Coaching cards** below the canvas (FontString blocks):
- **Opener** — first 8s offensive cast sequence
- **Defensive trade** — CC received vs defensive windows used
- **Death context** — last 3 casts before death marker (if death present)

### Architecture

- `UI/ReplayView.lua` — standalone module, exposes `ReplayView:Show(session)` and `ReplayView:Hide()`
- No persistent state; canvas is rebuilt on each `Show()` call
- Reuses `ns.Helpers`, `ns.Constants`, existing font/color theme

### Registering the Entry Point

`UI/CombatHistoryView.lua` gets a "Replay" button per row that calls `ns.ReplayView:Show(session)`.

---

## Feature: Build Comparator

### Purpose

For a given character, compare two builds side-by-side across key performance metrics. Answers *does my current talent setup outperform my previous one into this spec?*

### Data Sources

- `session.playerSnapshot.buildHash` — unique hash per talent/PvP-talent combination
- `CombatStore:GetAggregateBucketByKey("builds", buildHash, characterKey)` — aggregate stats per build
- `session.playerSnapshot.talentNodes`, `pvpTalents` — human-readable build label

### Layout

New "Builds" tab in `MainFrame`. Two dropdown selectors let the user pick Build A and Build B from known builds for the active character. Optional spec/comp filter narrows results.

**Comparison table** (side by side):

| Metric | Build A | Build B |
|---|---|---|
| Record | 8W 3L | 5W 5L |
| Win Rate | 72.7% | 50.0% |
| Avg Pressure Score | 68.4 | 59.1 |
| Avg Damage Done | 284k | 251k |
| Avg Deaths | 1.2 | 1.8 |
| Avg CC Received (s) | 14.3 | 18.7 |
| Top Opener Spell | The Hunt | The Hunt |

Cells with fewer than 5 sessions prefix values with `~` (low-confidence indicator).

A verdict line below the table reads: *"Build A outperforms Build B on 5 of 7 metrics against this spec."*

### Architecture

- `UI/BuildComparatorView.lua` — new tab panel, registered as tab index 9 in `MainFrame`
- Reads build list from `CombatStore:GetAggregateBuckets("builds")`
- Fetches per-build stats via `CombatStore:GetAggregateBucketByKey("builds", hash, charKey)` (depends on P0 Fix 1)
- Build label resolved from most recent session with matching hash

---

## Architecture Notes

### File Changes Summary

| File | Change Type | Reason |
|---|---|---|
| `CombatStore.lua` | Modify | Add `GetAggregateBucketByKey` and `GetSpecBucket` helpers |
| `StrategyEngine.lua` | Modify | Fix 2 broken aggregate lookups |
| `SuggestionEngine.lua` | Modify | Fix 1 broken aggregate lookup |
| `UI/CounterGuideView.lua` | Modify | Fix aggregate lookup + snapshot accessor |
| `UI/MatchupDetailView.lua` | Modify | Fix snapshot accessor |
| `CombatTracker.lua` | Modify | Fix snapshot accessor |
| `UI/ReplayView.lua` | New | Visual timeline canvas |
| `UI/BuildComparatorView.lua` | New | Build comparison tab |
| `UI/CombatHistoryView.lua` | Modify | Add "Replay" button per row |
| `UI/MainFrame.lua` | Modify | Register "Builds" tab |
| `CombatAnalytics.toc` | Modify | Add new files to load order |

### Constraints

- **No CLEU**: All data comes from `rawEvents` (UNIT_SPELLCAST_SUCCEEDED cast records), session aggregates, and stored buckets
- **WoW frame API only**: Textures, FontStrings, Frames — no external rendering
- **Stateless rendering**: ReplayView and BuildComparatorView rebuild their canvas on each open
- **Nil-safe**: All new code guards against nil session fields and empty bucket lists

---

## Success Criteria

1. Counter guide W/L badges show correct historical data (non-zero where history exists)
2. `SPEC_WINRATE_DEFICIT` suggestion fires correctly when win-rate deficit exists
3. `GetLatestPlayerSnapshot()` returns current build hash in all three fixed consumers
4. ReplayView renders without Lua errors for sessions with no rawEvents (graceful empty state)
5. BuildComparatorView dropdowns populate from real build history, comparison table renders correctly
6. All existing tabs continue to work after MainFrame tab registration change
