# Baseline Threat Score — Design

**Date:** 2026-03-21
**Status:** Approved
**Scope:** `StrategyEngine.lua`, `UI/CounterGuideView.lua`

---

## Problem

The Counter Guides tab shows `? (no data)` for Threat Level until the player has accumulated
≥ 3 personal fights against a spec. New users and infrequently-encountered specs always show
a blank bar, which feels broken.

## Goal

Show a reasonable estimated threat score immediately — derived entirely from already-curated
seed data — while making it visually distinct from measured personal data.

---

## Solution: Coefficient Formula at Runtime

`StrategyEngine.GetCounterGuide()` computes a `baselineThreatScore` for every spec using a
weighted sum of archetype, threat-tag, range, and CC-family data already present in
`SeedSpecArchetypes` and `SeedArenaControl`. No new seed files or API calls required.

### Coefficient Table

All weights are local constants at the top of `StrategyEngine.lua` for easy tuning.

#### Base

| | Weight |
|---|---|
| Base score | 0.45 |

#### Archetype Bonuses

| Archetype | Bonus |
|---|---|
| `setup_burst` | +0.15 |
| `melee_pressure` | +0.10 |
| `skirmisher` | +0.08 |
| `sustained_caster` | +0.05 |
| `sustained_ranged` | +0.05 |
| `control_healer` | +0.05 |
| `reactive_healer` | +0.03 |
| `bruiser` | +0.00 |

#### Threat Tag Bonuses

| Tag | Bonus |
|---|---|
| `frequent_cc` | +0.10 |
| `execute_risk` | +0.08 |
| `immunity_risk` | +0.08 |
| `control_pressure` | +0.08 |
| `mobility_heavy` | +0.06 |
| `purge_pressure` | +0.04 |

#### Range & CC

| Factor | Bonus |
|---|---|
| `rangeBucket == "melee"` | +0.05 |
| per unique CC family | +0.03 (max 4 families = +0.12) |

#### Final Clamp

```
score = Clamp(score, 0.25, 0.90)
```

### Sample Outputs

| Spec | Score | Key factors |
|---|---|---|
| Subtlety Rogue | ~0.87 | setup_burst + frequent_cc + melee + 4 CC families |
| Balance Druid | ~0.82 | setup_burst + frequent_cc + mobility_heavy + 3 families |
| Havoc DH | ~0.74 | skirmisher + mobility_heavy + melee + 2 families |
| Blood DK | ~0.62 | bruiser + execute_risk + melee + 2 families |
| BM Hunter | ~0.58 | sustained_ranged + mobility_heavy + 2 families |
| Holy Paladin | ~0.54 | control_healer + immunity_risk + 1 family |

---

## Data Flow

```
SeedSpecArchetypes  ──┐
                       ├──► ComputeBaselineThreatScore(specId)
SeedArenaControl    ──┘         │
                                ▼
                    GetCounterGuide() returns
                    { ..., baselineThreatScore = 0.62 }
                                │
                                ▼
                    CounterGuideView resolves:
                    1. fights >= 3  → 1 - historicalWinRate  (personal, exact)
                    2. baselineThreatScore  → ~score%  (estimated, muted)
                    3. neither  → "? (no data)"  (shouldn't occur post-change)
```

---

## Files Changed

### `StrategyEngine.lua`

1. Add local coefficient tables `ARCHETYPE_THREAT_BONUS`, `TAG_THREAT_BONUS` near the top.
2. Add local function `ComputeBaselineThreatScore(specId)` — reads archetype + CC families,
   applies formula, clamps result.
3. In `GetCounterGuide()`: call `ComputeBaselineThreatScore(specId)` and add
   `baselineThreatScore` field to the returned table.

### `UI/CounterGuideView.lua`

1. Replace the binary `fights >= 3 or 0.5` threat resolution with a three-step fallback.
2. Track an `isEstimated` boolean alongside `threatScore`.
3. Estimated display: value prefixed with `~`, rendered in `Theme.textMuted` colour.
4. Add a small `"est."` FontString label beside the value when estimated.
5. The bar renders at the estimated value but at 60% alpha to signal it is not measured.

---

## Non-Goals

- No new seed files.
- No changes to how personal fight data is stored or aggregated.
- No changes to the `>= 3 fights` gate for personal data — the baseline supplements it,
  does not replace it.
- No API calls or external data sources.
