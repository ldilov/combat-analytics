# Quickstart: Midnight 12.0.1 Compliance Overhaul

**Branch**: `001-midnight-compliance-overhaul` | **Date**: 2026-03-28

## What This Feature Does

Refactors CombatAnalytics to be fully Midnight 12.0.1 compliant by:
1. Removing all CLEU runtime dependencies
2. Replacing `rawEvents` with a sanctioned `timelineEvents` model
3. Adding per-field provenance and confidence tracking
4. Standardizing UI with reusable chart primitives
5. Adding new PvP features (arena scout, trade ledger, CC coach, opener lab)

## Key Files to Understand

### Core Pipeline (read these first)
| File | Purpose | Key Lines |
|------|---------|-----------|
| `Constants.lua` | All enums, SCHEMA_VERSION, event registry | Enums: 41-75, Events: 130-171 |
| `Events.lua` | WoW event router → dispatches to modules | Router: 17-87, OnUpdate: 155-180 |
| `CombatTracker.lua` | Session lifecycle, stats aggregation | CreateSession: 287, Finalize: 1613, RegenDisabled: 2061 |
| `SessionClassifier.lua` | Context detection (arena/duel/dummy/etc.) | ResolveContextFromState: 689, Priority: 9-16 |
| `ArenaRoundTracker.lua` | Match/round/slot identity, inspect queue | matchKey: 87, roundKey: 116, slots: 125, prep: 307 |

### Data Layer
| File | Purpose |
|------|---------|
| `DamageMeterService.lua` | C_DamageMeter integration, import/merge |
| `SpellAttributionPipeline.lua` | Enemy damage attribution |
| `CombatStore.lua` | SavedVariables persistence, schema migration, aggregates |
| `SnapshotService.lua` | Player build/gear snapshot at combat start |

### UI Layer
| File | Purpose |
|------|---------|
| `UI/Widgets.lua` | Reusable components, theming |
| `UI/MainFrame.lua` | Tab structure (11 tabs, 2 rows) |
| `UI/SummaryView.lua` | Latest fight summary |
| `UI/CombatHistoryView.lua` | Session history list |
| `UI/CombatDetailView.lua` | Timeline and spell breakdown |

### Seed Data
| File | Purpose |
|------|---------|
| `seed/generated/SeedSpellIntelligence.lua` | Offensive/defensive spell catalog |
| `seed/generated/SeedSpecArchetypes.lua` | Spec roles/archetypes |
| `seed/generated/SeedArenaControl.lua` | CC families per spec |
| `seed/generated/SeedDummyCatalog.lua` | Training dummy creature IDs |

## Development Environment

- **Language**: Lua (WoW addon Lua 5.1 dialect)
- **Platform**: World of Warcraft Midnight 12.0.1 (Interface 120001)
- **Storage**: WoW SavedVariables (Lua tables serialized by the client)
- **Testing**: Manual in-game testing + regression matrix (no external test framework)
- **Build**: No build step — source files loaded directly by WoW
- **TOC file**: `CombatAnalytics.toc` lists all source files in load order

## Delivery Phases

### Phase A: Correctness Foundation (P0) — Start Here
Focus: FR-001 through FR-016

1. **Schema migration v5→v6** (`Constants.lua`, `CombatStore.lua`)
   - Bump SCHEMA_VERSION to 6
   - Add migration step for timelineEvents, provenance, fieldConfidence
   - Map old confidence labels to new enum

2. **Delete/quarantine CLEU code paths** (`CombatTracker.lua`)
   - Remove `HandleCombatLogEvent()` (no caller)
   - Remove `NormalizeCombatLogEvent()` (only called by above)
   - Gate `HandleNormalizedEvent()` behind dev flag or remove

3. **Build timeline producer system** (new `TimelineProducer.lua`)
   - Register producers for each sanctioned event source
   - Each producer creates TimelineEvents in the session

4. **Rewire stats aggregation** (`CombatTracker.lua`)
   - Player spell stats from `UNIT_SPELLCAST_SUCCEEDED` + DM import
   - Aura stats from `UNIT_AURA`
   - CC stats from LOC/DR APIs

5. **Rewire SessionClassifier** (`SessionClassifier.lua`)
   - Remove event-based evidence accumulation
   - Use `DUEL_*` events for duel detection
   - Use creature ID for dummy detection
   - `ResolveContextFromState()` becomes the only production path

6. **Rewire ArenaRoundTracker** (`ArenaRoundTracker.lua`)
   - Remove `HandleCombatLogEvent()` dependency
   - Pressure from DM per-source data (post-combat)
   - Add `fieldConfidence` to slots

7. **Rewire SpellAttributionPipeline** (`SpellAttributionPipeline.lua`)
   - Remove CLEU event ingestion
   - Attribution from `DamageMeterService.MergeDamageMeterSource()` only
   - Add provenance tagging

8. **Stabilize session lifecycle** (`CombatTracker.lua`)
   - DM stabilization delay (configurable)
   - Idempotent finalization
   - Duel pending state timeout (30s)

### Phase B: UI Visual Standards (P0)
Focus: FR-021 through FR-025

1. **Build chart primitives** (`UI/Widgets.lua`)
   - Sparkline, SegmentedBar, MirroredDeltaBar, HeatGrid, TimelineLane, Gauge, ConfidencePill, MiniLegend, DeltaBadge

2. **Summary page overhaul** (`UI/SummaryView.lua`)
3. **History page overhaul** (`UI/CombatHistoryView.lua`)
4. **Detail page timeline** (`UI/CombatDetailView.lua`)

### Phase C: Confidence & Migration (P1)
Focus: FR-017 through FR-020

### Phase D: Page-Level Visuals (P1)
Focus: FR-026 through FR-033

### Phase E: New PvP Features (P1)
Focus: FR-034 through FR-039

### Phase F: Advanced Features (P2)
Focus: FR-040 through FR-043

## Key Architectural Decisions

1. **Timeline replaces rawEvents** — not additive, clean break. Old sessions keep rawEvents read-only.
2. **Provenance is mandatory** — every producer tags source and confidence. No untagged data in v6+ sessions.
3. **DamageMeter is source of truth for numbers** — live state tracking provides context/timing, DM provides accurate totals.
4. **Field-level confidence on arena slots** — each field independently tracks how it was learned.
5. **No fabricated enemy data** — estimated insights are visually distinct from confirmed observations.

## Common Patterns in This Codebase

- **Module pattern**: `ns.Addon:GetModule("ModuleName")` for cross-module access
- **Safe number handling**: `ApiCompat.SanitizeNumber()` guards against Midnight secret values
- **pcall wrapping**: All inspect and restricted API calls wrapped in `pcall()` for safety
- **Theme access**: `Widgets.THEME.colorName` for consistent colors
- **Texture drawing**: `WHITE8x8` + `SetVertexColor()` for all rectangle/bar rendering
