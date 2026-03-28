# Implementation Plan: Midnight 12.0.1 Compliance Overhaul

**Branch**: `001-midnight-compliance-overhaul` | **Date**: 2026-03-28 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/001-midnight-compliance-overhaul/spec.md`

## Summary

Remove all CLEU runtime dependencies from CombatAnalytics and rebuild the data pipeline around sanctioned Midnight 12.0.1 APIs (stateful PvP events + C_DamageMeter). Replace the CLEU-shaped `rawEvents` model with a provenance-tagged `timelineEvents` system. Standardize UI across all 12+ pages with reusable chart primitives. Add new PvP features (arena scout, trade ledger, CC/DR coach, opener lab) on the corrected foundation.

**User priority**: Correctness first — sessions, enemies, arenas, spells must be reliably identified before any UI or feature work.

## Technical Context

**Language/Version**: Lua 5.1 (WoW addon dialect)
**Primary Dependencies**: WoW Midnight 12.0.1 API (Interface 120001), C_DamageMeter, C_PvP, C_Traits, C_SpecializationInfo
**Storage**: WoW SavedVariables (Lua table serialization, schema v5 → v6)
**Testing**: Manual in-game regression matrix + diagnostic exports (no external test framework)
**Target Platform**: World of Warcraft Midnight 12.0.1 (Windows/macOS)
**Project Type**: WoW addon (34 Lua modules, ~12,043 lines)
**Performance Goals**: Session finalization < 100ms, UI page render < 200ms, < 5MB SavedVariables for 500 sessions
**Constraints**: No CLEU in production, no fabricated enemy data, no protected action automation, pcall-wrapped restricted APIs
**Scale/Scope**: 34 existing modules, 12+ UI pages, 43 functional requirements across 6 phases

## Constitution Check

*Constitution file is a blank template — no project-specific gates defined.*

No violations to check. Proceeding.

## Project Structure

### Documentation (this feature)

```text
specs/001-midnight-compliance-overhaul/
├── plan.md              # This file
├── spec.md              # Feature specification (43 FRs, 8 user stories)
├── research.md          # Phase 0: 10 research decisions
├── data-model.md        # Phase 1: 12 entities, enums, migration plan
├── quickstart.md        # Phase 1: dev onboarding guide
├── contracts/
│   ├── session-lifecycle.md    # Session state machine and guarantees
│   ├── timeline-producer.md    # Timeline event producer registry
│   ├── arena-identity.md       # Match/round/slot identity contracts
│   └── provenance-model.md     # Provenance and confidence system
├── checklists/
│   └── requirements.md         # Spec quality checklist
└── tasks.md             # Phase 2 output (created by /speckit.tasks)
```

### Source Code (repository root)

```text
CombatAnalytics/
├── CombatAnalytics.toc          # Addon manifest (load order)
├── Constants.lua                # Enums, SCHEMA_VERSION, event registry
├── ApiCompat.lua                # API version wrappers, SanitizeNumber/String
├── Events.lua                   # Event router → dispatches to modules
├── CombatTracker.lua            # Session lifecycle, stats aggregation (MODIFY HEAVILY)
├── SessionClassifier.lua        # Context detection (MODIFY: remove CLEU evidence)
├── ArenaRoundTracker.lua        # Match/round/slot identity (MODIFY: remove CLEU, add confidence)
├── SpellAttributionPipeline.lua # Enemy damage attribution (MODIFY: DM-only source)
├── DamageMeterService.lua       # C_DamageMeter integration (MODIFY: Death Recap support)
├── CombatStore.lua              # Persistence, schema migration (MODIFY: v5→v6)
├── SnapshotService.lua          # Player build snapshot
├── SuggestionEngine.lua         # Coaching suggestions (MODIFY: new reason codes)
├── TimelineProducer.lua         # NEW: Timeline event producer system
├── TradeLedgerService.lua       # NEW: Post-combat trade sequence analysis
├── CCCoachService.lua           # NEW: CC/DR coaching analysis
├── OpenerLabService.lua         # NEW: Opener aggregation and ranking
├── ArenaScoutService.lua        # NEW: Pre-match scouting card
├── MatchupMemoryService.lua     # NEW: Personalized matchup memory
├── DuelLabService.lua           # NEW: Duel series tracking
├── PracticePlannerService.lua   # NEW: Practice suggestion generation
├── Utils/
│   ├── Metrics.lua              # Pressure/burst/survivability scores
│   ├── BuildHash.lua            # Build hash computation
│   ├── Helpers.lua              # General utilities
│   └── Math.lua                 # Math utilities
├── UI/
│   ├── Widgets.lua              # Reusable components (MODIFY: add 9 chart primitives)
│   ├── MainFrame.lua            # Tab structure
│   ├── SummaryView.lua          # MODIFY: hero scorecards, output bars, fight story
│   ├── CombatHistoryView.lua    # MODIFY: sparkline, context chips, mini-bars
│   ├── CombatDetailView.lua     # MODIFY: sanctioned multi-lane timeline
│   ├── OpponentStatsView.lua    # MODIFY: bar charts, heat strip, roster cards
│   ├── ClassSpecView.lua        # MODIFY: grouped bars, heat-grid
│   ├── MatchupDetailView.lua    # MODIFY: mirrored bars, MMR strips
│   ├── DummyBenchmarkView.lua   # MODIFY: trend lines, consistency bands
│   ├── RatingView.lua           # MODIFY: add confidence markers
│   ├── SuggestionsView.lua      # MODIFY: ranked issue stack, severity bars
│   ├── CounterGuideView.lua     # MODIFY: threat gauge, answer cards
│   ├── BuildComparatorView.lua  # MODIFY: mirrored delta bars
│   ├── CleanupView.lua          # MODIFY: storage bars, delete preview
│   ├── ReplayView.lua           # MODIFY: source legend, provenance chips
│   ├── ArenaScoutView.lua       # NEW: Prep scout card overlay
│   └── TradeLedgerView.lua      # NEW: Trade ledger panel
└── seed/generated/
    ├── SeedSpellIntelligence.lua
    ├── SeedSpecArchetypes.lua
    ├── SeedArenaControl.lua
    └── SeedDummyCatalog.lua
```

**Structure Decision**: Flat module structure (WoW addon convention). New services follow existing pattern: one file per service module, registered via `ns.Addon:GetModule()`. UI follows existing one-file-per-tab pattern.

## Implementation Phases

### Phase A: Correctness Foundation (P0) — HIGHEST PRIORITY

**Goal**: Every session correctly identifies context, enemies, spells, and carries provenance. No CLEU dependency.

**Delivery order** (each step builds on the previous):

| Step | Files | FR Coverage | Description |
|------|-------|-------------|-------------|
| A1 | Constants.lua, CombatStore.lua | FR-019 | Schema migration v5→v6: add timelineEvents, provenance, fieldConfidence, new enums |
| A2 | Constants.lua | FR-015, FR-017 | Add ProvenanceSource and SessionConfidence enums, TimelineLane enum |
| A3 | CombatTracker.lua | FR-001 | Delete HandleCombatLogEvent, NormalizeCombatLogEvent. Gate HandleNormalizedEvent behind dev flag. |
| A4 | TimelineProducer.lua (NEW) | FR-003, FR-004 | Build timeline producer system with 8 producers (see contracts/timeline-producer.md) |
| A5 | Events.lua, CombatTracker.lua | FR-002, FR-005 | Wire timeline producers to event router. Session start from REGEN_DISABLED + context. Finalization with DM stabilization delay. |
| A6 | SessionClassifier.lua | FR-011, FR-012 | Remove AccumulateEvidence (CLEU path). Duel detection from DUEL_* events only. Dummy detection from creature ID + state. |
| A7 | CombatTracker.lua | FR-005, FR-006, FR-016 | Stabilize session lifecycle: idempotent finalization, duel pending timeout (30s), re-entrant safety on reload/logout |
| A8 | ArenaRoundTracker.lua | FR-007, FR-008, FR-009 | Remove HandleCombatLogEvent. Add fieldConfidence to slots. Keep match/round key generation (already correct). |
| A9 | SpellAttributionPipeline.lua | FR-013, FR-014 | Remove CLEU event ingestion. Attribution from DamageMeterService.MergeDamageMeterSource only. Provenance tagging. |
| A10 | DamageMeterService.lua | FR-002 | Add Death Recap category support. Merge enemy spell rows into timeline as dm_enemy_spell events. Graceful fallback. |
| A11 | CombatTracker.lua | FR-010 | Arena result from PvP match state APIs. Rating snapshots with missing-reason. |
| A12 | CombatTracker.lua, CombatStore.lua | FR-015 | Provenance tagging on all non-trivial persisted fields during finalization. |

**Acceptance gate**: Arena (2v2, 3v3, Solo Shuffle), duel (accepted, canceled), and dummy sessions all create correct sessions with provenance — no runtime errors, no CLEU calls.

### Phase B: UI Visual Standards (P0)

**Goal**: Every page has a primary visual. Shared chart primitives prevent per-page reimplementation.

| Step | Files | FR Coverage | Description |
|------|-------|-------------|-------------|
| B1 | UI/Widgets.lua | FR-022 | Build 9 chart primitives: Sparkline, SegmentedBar, MirroredDeltaBar, HeatGrid, TimelineLane, Gauge, ConfidencePill, MiniLegend, DeltaBadge |
| B2 | UI/SummaryView.lua | FR-023 | Hero scorecards, output split bar, top-spell bars, fight-story strip |
| B3 | UI/CombatHistoryView.lua | FR-024 | Results sparkline, context chips, mini-bars, context filter toggles |
| B4 | UI/CombatDetailView.lua | FR-025 | Sanctioned multi-lane timeline using TimelineLane widget. Graceful fallback for empty timelineEvents. |

### Phase C: Confidence & Migration Polish (P1)

| Step | Files | FR Coverage | Description |
|------|-------|-------------|-------------|
| C1 | Constants.lua, CombatStore.lua | FR-017 | Replace all CLEU-centric labels in UI text and stored data |
| C2 | ArenaRoundTracker.lua | FR-018 | Persist learnedAt timestamps per slot field |
| C3 | CombatStore.lua | FR-019 | Validate migration with mixed-schema datasets |
| C4 | CombatTracker.lua | FR-020 | Diagnostic export: session fields, match identity, slot confidence, DM session IDs, timeline counts |

### Phase D: Page-Level Visuals (P1)

| Step | Files | FR Coverage | Description |
|------|-------|-------------|-------------|
| D1 | UI/OpponentStatsView.lua | FR-026 | Top-opponent bars, WR heat strip, roster cards |
| D2 | UI/ClassSpecView.lua | FR-027 | Class-grouped bars, spec heat-grid |
| D3 | UI/MatchupDetailView.lua | FR-028 | Mirrored bars, MMR strips, best-build badge |
| D4 | UI/DummyBenchmarkView.lua | FR-029 | Trend lines, consistency bands |
| D5 | UI/SuggestionsView.lua | FR-030 | Ranked issue stack, severity bars, filters |
| D6 | UI/CounterGuideView.lua | FR-031 | Threat gauge, enemy spell icons, answer cards |
| D7 | UI/BuildComparatorView.lua | FR-032 | Mirrored delta bars, metric win counter |
| D8 | UI/CleanupView.lua | FR-033 | Storage bars, delete preview |

### Phase E: New PvP Features (P1)

| Step | Files | FR Coverage | Description |
|------|-------|-------------|-------------|
| E1 | ArenaScoutService.lua (NEW), UI/ArenaScoutView.lua (NEW) | FR-034 | Arena prep scout card: enemy specs, comp archetype, WR, notes |
| E2 | TradeLedgerService.lua (NEW), UI/TradeLedgerView.lua (NEW) | FR-035 | Post-combat trade ledger: offensives, defensives, trinket, CC, kills |
| E3 | CCCoachService.lua (NEW) | FR-036 | CC/DR coaching: chain length, DR waste, trinket timing |
| E4 | OpenerLabService.lua (NEW) | FR-037 | Opener aggregation: first 3-5 casts ranked by WR/pressure |
| E5 | ArenaScoutService.lua | FR-038 | Between-round Solo Shuffle adaptation card |
| E6 | DamageMeterService.lua, CombatTracker.lua | FR-039 | Death Recap Coach: merge DM death recap + CC + defensive state |

### Phase F: Advanced Features (P2)

| Step | Files | FR Coverage | Description |
|------|-------|-------------|-------------|
| F1 | DuelLabService.lua (NEW) | FR-040 | Duel lab: opponent grouping, set score, adaptation trend |
| F2 | Utils/Metrics.lua, UI/DummyBenchmarkView.lua | FR-041 | Dummy rotation consistency: gap histogram, variance band |
| F3 | MatchupMemoryService.lua (NEW) | FR-042 | Personalized matchup memory cards |
| F4 | PracticePlannerService.lua (NEW) | FR-043 | Practice planner: concrete actions from weak areas |

## Dependency Graph

```
A1 (schema) ──→ A2 (enums) ──→ A3 (delete CLEU) ──→ A4 (timeline producers)
                                                         │
A6 (classifier) ◄──────────────────────────────────────────┘
     │                                                     │
A7 (lifecycle) ◄───────────────── A5 (wire producers) ◄───┘
     │
A8 (arena tracker) ──→ A9 (attribution) ──→ A10 (DM death recap) ──→ A11 (results) ──→ A12 (provenance)
                                                                                            │
B1 (chart widgets) ──→ B2 (summary) ──→ B3 (history) ──→ B4 (detail) ◄─────────────────────┘
     │
     ├──→ D1..D8 (page visuals, parallelizable)
     │
     └──→ E1..E6 (features, depend on Phase A correctness)
                │
                └──→ F1..F4 (advanced, depend on Phase E services)
```

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| DamageMeter API changes in 12.0.2+ | High | Wrap all DM calls in pcall + version checks via ApiCompat |
| Death Recap category unavailable | Medium | Graceful fallback coded into FR-039; provenance shows limited data |
| HandleNormalizedEvent removal breaks undiscovered callers | High | Grep for all references before deletion; dev flag gate initially |
| Schema migration corrupts old data | High | Preserve rawEvents read-only; never re-derive from old data; migration is additive only |
| Solo Shuffle roster changes mid-round | Medium | Slot identity locked after first GUID resolution; unresolved staged separately |
| Inspect API tainted during combat | Low | pcall wrapping already in place; inspect queue respects InCombatLockdown() |

## Complexity Tracking

No constitution violations to justify. Architecture is straightforward: remove CLEU paths, add timeline producers, enhance existing modules with provenance.
