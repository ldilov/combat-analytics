# Contract: Provenance & Confidence Model

**Version**: 1.0 | **Date**: 2026-03-28

## Overview

Every non-trivial persisted field must carry provenance (where it came from) and confidence (how trustworthy it is). This replaces the CLEU-centric ANALYSIS_CONFIDENCE system.

## Provenance Source Enum

| Value | Meaning | Example |
|-------|---------|---------|
| `state` | From session state events (REGEN, PVP_MATCH, DUEL) | Session start/end times, combat duration |
| `damage_meter` | From C_DamageMeter APIs | Damage totals, spell rows, per-source breakdowns |
| `visible_unit` | From UNIT_AURA, UNIT_SPELLCAST_SUCCEEDED, ARENA_OPPONENT_UPDATE | Player casts, visible auras, unit identity |
| `inspect` | From NotifyInspect / INSPECT_READY path | PvP talents, talent import strings |
| `loss_of_control` | From LOSS_OF_CONTROL_*, PLAYER_CONTROL_* | CC received events |
| `spell_diminish` | From UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED | DR state per arena slot |
| `estimated` | Derived/calculated, not directly observed | Kill windows, coaching insights, inferred timing |
| `legacy_import` | Migrated from old (pre-v6) schema | Old sessions preserved from CLEU era |

## Confidence Levels

### Per-field confidence
| Level | Meaning |
|-------|---------|
| `confirmed` | Directly observed via sanctioned API |
| `partial` | Observed but possibly incomplete (e.g., visible enemy cast that may not represent full rotation) |
| `estimated` | Calculated/inferred from indirect evidence |

### Session-level confidence (SessionConfidence enum)
| Label | Meaning | When Assigned |
|-------|---------|---------------|
| `STATE_PLUS_DAMAGE_METER` | Full state tracking + successful DM import | Best achievable in Midnight |
| `DAMAGE_METER_ONLY` | DM import succeeded, limited state tracking | DM data good, state events missed |
| `VISIBLE_CC_ONLY` | Only CC/LOC data, no DM import | DM unavailable or failed |
| `PARTIAL_ROSTER` | Arena with incomplete slot resolution | Some slots unresolved |
| `ESTIMATED` | Coaching insights from partial data | Insufficient direct observation |
| `LEGACY_CLEU_IMPORT` | Old session from pre-Midnight schema | Schema migration from v5 |

## Assignment Rules

### Session-level confidence resolution (at finalization)
```
if dmImport.success AND stateTracking.complete:
  confidence = STATE_PLUS_DAMAGE_METER
elif dmImport.success:
  confidence = DAMAGE_METER_ONLY
elif ccTracking.hasData:
  confidence = VISIBLE_CC_ONLY
elif arena AND roster.incomplete:
  confidence = PARTIAL_ROSTER
else:
  confidence = ESTIMATED
```

### Per-field provenance assignment
- Timeline events: set by producer at creation time
- Session totals: set at DM import merge
- Arena slot fields: set when field is populated (prep/visible/inspect)
- Attribution: set at DM source merge

## UI Display Contract

### Confidence indicators
- `STATE_PLUS_DAMAGE_METER`: Green pill — "Full Data"
- `DAMAGE_METER_ONLY`: Blue pill — "Post-Combat Data"
- `VISIBLE_CC_ONLY`: Yellow pill — "Limited Data"
- `PARTIAL_ROSTER`: Orange pill — "Incomplete Roster"
- `ESTIMATED`: Gray pill — "Estimated"
- `LEGACY_CLEU_IMPORT`: Gray pill — "Legacy Session"

### Visual distinction rules
1. Confirmed data renders normally (full opacity, standard colors)
2. Estimated data renders with reduced opacity or dashed styling
3. Enemy spell data from DM renders with a provenance icon distinct from player spells
4. Fabricated/hidden enemy data is NEVER rendered — only sanctioned API data appears

### Tooltip provenance
When hovering over any data point that carries provenance, the tooltip should include:
- Source: human-readable name (e.g., "Damage Meter", "Arena Prep", "Inspect")
- Confidence: "Confirmed" | "Partial" | "Estimated"
- Timestamp: when the data was captured
