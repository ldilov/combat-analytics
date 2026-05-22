# Insights Tab Rework — Implementation Plan

**Status:** Draft for review. No code yet.
**Constraints (locked):**
- NO CLEU dependency. Use scoreboard, session.totals, session.metrics, session.openerFingerprint, session.survival, cross-session aggregates.
- Single scrollview (no sub-tabs inside Insights).
- 4-pillar consolidation: Pressure / Survival / Control / Consistency.
- Mitigations adopted: M1 (pillar drill-down), M2 (Trends → peek card), M3 (onboarding states), M5 (visible priority formula), M6 (timeline node click → inline expand).
- Mitigation rejected: M4 (CLEU swap) — moot, no CLEU anywhere.

## Goal

Replace `UI/SuggestionsView.lua` with a coaching-focused dashboard that answers one question per session: **"What is the highest-impact thing to fix before my next queue?"** Plus longitudinal context without burying it.

## Final Layout (top → bottom in single scroll)

```
┌────────────────────────────────────────────────────────────────────┐
│ [Fidelity badge]   Character · Spec · Context · Result · Date      │  ← slim, 1 row
├────────────────────────────────────────────────────────────────────┤
│ NEXT QUEUE FOCUS                                                   │
│ ┌──────────────────────────────────────────────────────────────┐   │
│ │ ▍ High priority                                               │  │
│ │ TRADE EARLIER INTO STUN CHAINS                                │  │
│ │ You died in CC with a defensive available; first defensive    │  │
│ │ landed 4.8s later than your baseline.                         │  │
│ │ [chip] reason=DIED_WITH_DEFENSIVES                            │  │
│ │ [chip] delta=+4.8s vs baseline                                │  │
│ │ [chip] confidence=0.82                                        │  │
│ │ Why this came first (hover): sev 0.9 × conf 0.82 × rec 3 ×    │  │
│ │ ctrl 1.0 = 2.21                                               │  │
│ └──────────────────────────────────────────────────────────────┘   │
├────────────────────────────────────────────────────────────────────┤
│ FIGHT TIMELINE READ        (5 nodes horizontal, click to expand)   │
│ ┌──────────────────────────────────────────────────────────────┐   │
│ │  ●─────●─────●─────●─────●                                    │  │
│ │  Opener Go1   Def1  CC1   End                                 │  │
│ │  good  late   miss  good  loss                                │  │
│ └──────────────────────────────────────────────────────────────┘   │
│ [when a node is clicked, an inline drawer expands BELOW the timeline │
│  showing the related metric fingerprint + that node's underlying    │
│  reason codes — NOT a scrubbable CLEU timeline, just summary data] │
├────────────────────────────────────────────────────────────────────┤
│ PILLAR SCOREBOARD                                                  │
│ ┌─────────┬─────────┬─────────┬─────────┐                          │
│ │Pressure │Survival │ Control │Consistncy│ ← 4 columns, click any  │
│ │  72     │   58    │   81    │   67    │   to expand inline       │
│ │ −12%    │  −22%   │  +4%    │  −8%    │   showing contributing   │
│ │ vs you  │ vs you  │ vs you  │ vs you  │   reason codes for THIS  │
│ │ N=18    │ N=18    │ N=12    │ N=14    │   session                │
│ └─────────┴─────────┴─────────┴─────────┘                          │
├────────────────────────────────────────────────────────────────────┤
│ MATCHUP PLAN — vs Affliction Warlock                               │
│ W/L vs spec: 4-7  ·  Common failure: late defensive (×6/11)        │
│ Counter-action: pre-cast defensive before fear chain               │
├────────────────────────────────────────────────────────────────────┤
│ TRENDS PEEK  → see full Trends in Rating tab                       │
│ [sparkline pressureScore last 14d]   [rating Δ +12 this week]     │
├────────────────────────────────────────────────────────────────────┤
│ PRACTICE PLAN (recurring only)                                     │
│ • Drill: First defensive timing (4 occurrences this week)          │
│ • Drill: Opener pacing vs Affliction (3 occurrences this week)     │
├────────────────────────────────────────────────────────────────────┤
│ ▸ EVIDENCE DRAWER (collapsed) — all 30 reason codes filterable     │
└────────────────────────────────────────────────────────────────────┘
```

## Module changes

### New modules

| File | Purpose |
|---|---|
| `UI/Insights/InsightsView.lua` | Top-level frame, scrollview, sections orchestration. Replaces current `UI/SuggestionsView.lua` content; old file kept as `.bak` during transition. |
| `UI/Insights/Sections/FidelityBar.lua` | Slim badge: scoreboard-anchor confidence + N samples + session metadata. |
| `UI/Insights/Sections/NextQueueFocusCard.lua` | Top-priority callout. Reads ranked suggestions list. |
| `UI/Insights/Sections/FightTimelineRead.lua` | 5-node horizontal layout + inline-expand drawer. |
| `UI/Insights/Sections/PillarScoreboard.lua` | 4-column scoreboard with click-to-expand reason-code drilldown. |
| `UI/Insights/Sections/MatchupPlanCard.lua` | Folds Strategy Spotlight + Matchup Memory. |
| `UI/Insights/Sections/TrendsPeek.lua` | Single peek card linking to `RatingView`. |
| `UI/Insights/Sections/PracticePlanList.lua` | Drills from `PracticePlannerService`, week-recurring only. |
| `UI/Insights/Sections/EvidenceDrawer.lua` | Collapsed-by-default full reason-code list. |
| `Insights/InsightsPriority.lua` | Pure scoring module: `priority = severity * confidence * recurrence * controllability`. Exposes per-term values for hover. |
| `Insights/InsightsPillarMapper.lua` | Maps 30 reason codes → 4 pillars + drives pillar deltas from session.metrics. |
| `Insights/InsightsOnboarding.lua` | Returns onboarding state per section when N samples below threshold. |

### Modified modules

| File | Change |
|---|---|
| `UI/SuggestionsView.lua` | Becomes thin shim that requires + instantiates `InsightsView`. Preserves `viewId = "insights"` + tab registration. |
| `SuggestionEngine.lua` | Add `severity`, `confidence`, `recurrence`, `controllability` fields to every emitted suggestion. Recurrence = count of same `reasonCode` in last 7d aggregate. Controllability = static per-code lookup (0.0..1.0). |
| `Constants.lua` | Add `PILLAR = { PRESSURE, SURVIVAL, CONTROL, CONSISTENCY }`. Add `CONTROLLABILITY` table per reason code. Add `INSIGHTS_ONBOARDING_THRESHOLD = 3`. |
| `PracticePlannerService.lua` | Add `:GetRecurringDrills(characterKey, weekDays)` filtering to reason codes that appeared ≥2 times in last 7d. |

### Reused without modification

`StrategyEngine`, `TrendAnalyzer`, `TradeLedgerService`, `OpenerLabService`, `CombatStore` (read-only), `Widgets`.

## Data wiring (no-CLEU)

| Section | Source fields |
|---|---|
| Fidelity badge | `session.analysisConfidence`, `session.dataConfidence`, `session.captureSource`, aggregate N for character |
| Next Queue Focus | `InsightsPriority.RankSuggestions(session.suggestions)` → top 1 |
| Fight Timeline Read | `session.openerFingerprint` (firstMajorOffensiveAt, firstMajorDefensiveAt, firstCCAt) + `session.survival.timeOfDeath` + `session.result`. No `rawEvents` reads. |
| Pillar Scoreboard | `session.metrics.{pressureScore, survivabilityScore, burstScore, rotationConsistencyScore}` vs `CombatStore:GetBuildBaseline` / `GetSessionBaseline` |
| Matchup Plan | `CombatStore.aggregates.specs[specId]` + `StrategyEngine.GetCounterGuide(specId)` |
| Trends Peek | `TrendAnalyzer:Get14DaySparkline()` + rating delta from rating aggregate (already shipped per memory) |
| Practice Plan | `PracticePlannerService:GetRecurringDrills(...)` (new method) |
| Evidence Drawer | Existing full `session.suggestions[]` rendering |

## Priority formula (M5: published + visible)

```lua
priority = severity * confidence * recurrence_weight * controllability

-- severity:        0..1 from existing suggestion.severity (high=1.0, medium=0.55, low=0.2)
-- confidence:      0..1 from session.metrics.<metric>.confidence OR suggestion.confidence
-- recurrence_w:    1 + 0.5 * min(occurrences_last_7d, 4)   -- caps at 3.0
-- controllability: 0..1 static table per reasonCode in Constants.lua
```

`InsightsPriority.lua` returns `{ priority, severity, confidence, recurrenceWeight, controllability, reasonCode }` so hover can show the breakdown. Calibration is one file — easy to tune from match histories.

## Onboarding (M3)

`InsightsOnboarding.lua` returns one of: `:Full | :Sparse | :Cold` per character.

- **Cold** (0 sessions): Next Queue Focus shows static guide. Pillar Scoreboard hidden; replaced by single "Collecting data — 1/3 sessions" card. Practice Plan hidden.
- **Sparse** (1-2 sessions): Pillars show absolute values + dummyBenchmark deltas (not personal baselines). Recurrence formula falls back to 1.0. Trends Peek hidden.
- **Full** (≥3 sessions): All sections live.

Every section has an explicit empty state. Never "N/A" + no explanation.

## Reason-code → pillar mapping (M1)

Each pillar card click expands inline. Bucketing:

- **Pressure**: LOW_PRESSURE_VS_BUILD_BASELINE, WEAK_BURST_FOR_CONTEXT, LATE_FIRST_GO, SUBOPTIMAL_OPENER_SEQUENCE, LOW_HEALER_PRESSURE, DUMMY_OPENER_VARIANCE, DUMMY_SUSTAINED_VARIANCE, PROC_WINDOWS_UNDERUSED
- **Survival**: DEFENSIVE_UNUSED_ON_LOSS, DEFENSIVE_DRIFT, DIED_IN_CC, DIED_WITH_DEFENSIVES, REACTIVE_DEFENSIVE_LATE, HIGH_DAMAGE_TAKEN_VS_OPPONENT
- **Control**: TRINKET_TIMING_POOR, HIGH_CC_UPTIME, POOR_INTERRUPT_RATE, CC_DR_WASTE, CC_LATE_TRINKET, CC_MISSED_KILL_WINDOW, CC_GOOD_TRINKET, CC_CHAIN_BREAK, CC_HIGH_UPTIME
- **Consistency**: ROTATION_GAPS_OBSERVED, TILT_WARNING
- *(Matchup codes go to Matchup Plan section, not a pillar)*
- *(Meta codes MIDNIGHT_SAFE_LIMITS, RAW_EVENT_OVERFLOW → Fidelity badge only)*

## Build order (suggested)

1. Scaffolding: `Insights/InsightsPriority.lua` + `InsightsPillarMapper.lua` + `InsightsOnboarding.lua` (pure logic, unit-testable).
2. Replace `SuggestionEngine.lua` suggestion emit with extended fields (severity/confidence/recurrence/controllability).
3. `UI/Insights/InsightsView.lua` + skeleton scrollview that registers as `viewId="insights"`.
4. Sections built bottom-up: FidelityBar → EvidenceDrawer → PracticePlanList → TrendsPeek → MatchupPlanCard → PillarScoreboard → FightTimelineRead → NextQueueFocusCard.
5. Delete old `SuggestionsView.lua` body, leave shim. Update any references.
6. Smoke test via existing fixtures.

## Test plan

- Unit: `InsightsPriority.lua` ranking with stable inputs.
- Unit: `InsightsPillarMapper.lua` returns deterministic pillar for each of 30 codes.
- Unit: `InsightsOnboarding.lua` returns Cold/Sparse/Full for 0/2/5 session counts.
- Integration: load addon, open `/ca insights`, verify scrollview renders for: empty character, sparse character, full-data character.
- Visual: screenshot each onboarding state.
- Verification: `luac -p` on all touched files. Run `test/` suite, ensure failure count does not increase from baseline (per memory: 56 constant pre-existing failures).

## Risks remaining after mitigation

- Priority formula calibration: ship with conservative weights, expose hover; tune from real session corpus post-merge.
- `openerFingerprint` may be unset on early sessions — handled by Onboarding Cold/Sparse states.
- Practice Plan recurrence requires aggregate query — verify `PracticePlannerService` already touches the right aggregates or adapt.

## Out of scope (deferred)

- Scrubbable CLEU-based VOD timeline (rejected per no-CLEU constraint).
- Cohort z-score comparison (Option D — defer until 50+ session corpus).
- Multi-character comparison view.
- Insights export to CSV / clipboard share.
