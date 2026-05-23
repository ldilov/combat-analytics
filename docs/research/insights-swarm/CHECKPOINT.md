# Insights Rework — Checkpoint

**Last updated:** 2026-05-23 (second pass)
**Branch:** `main`
**Head commit:** `54ac42d feat(insights): add Evidence Drawer with filter chips`
**Remote:** `combat-analytics` → https://github.com/ldilov/combat-analytics (pushed)

**Status:** All 8 sections from PLAN.md shipped. No remaining deferred sections.
**Suite:** 187 pass / 56 fail / 243 total. Baseline 56 failures unchanged across
all 5 new commits. `luac -p` clean on every touched file.

Section commits (in build order):
- `9203302` Fight Timeline Read (+19 tests, InsightsTimeline pure logic)
- `da7f567` Matchup Plan (+12 tests, InsightsMatchupSummary)
- `ef39e5f` Trends Peek (+12 tests, InsightsTrendsPeek)
- `852b475` Practice Plan (+8 tests, InsightsRecurringDrills, PracticePlannerService:GetRecurringDrills)
- `54ac42d` Evidence Drawer (+12 tests, InsightsEvidenceFilter)

---

## 1. Initial plan (from PLAN.md)

Replace the old `UI/SuggestionsView.lua` "trust + story + 8 generic cards + drawer" stack with a coaching dashboard that answers one question per session: **"What is the highest-impact thing to fix before my next queue?"** — plus longitudinal context without burying it.

**Locked constraints:**
- NO CLEU dependency. Use `session.totals`, `session.metrics`, `session.openerFingerprint`, `session.survival`, cross-session aggregates only.
- Single scrollview (no sub-tabs inside Insights).
- 4-pillar consolidation: Pressure / Survival / Control / Consistency.
- Adopted mitigations: M1 (pillar drilldown), M2 (Trends → peek card), M3 (onboarding states), M5 (visible priority formula), M6 (timeline node click → inline expand).
- Rejected mitigation: M4 (CLEU-aware column swap) — moot, no CLEU anywhere.

**Final layout (top → bottom in single scroll):**
1. Fidelity badge (slim, 1 row)
2. Next Queue Focus (top-priority callout, hover-visible formula)
3. Fight Timeline Read (5-node horizontal: opener → first go → first def → first CC → end)
4. Pillar Scoreboard (4 columns, click to expand inline)
5. Matchup Plan (folds Strategy Spotlight + Matchup Memory)
6. Trends Peek (single card → links to RatingView)
7. Practice Plan (recurring drills only)
8. Evidence Drawer (collapsed)

---

## 2. Multi-LLM orchestration recap

- 🟠 vLLM Gemma-4 31B NVFP4 × 6 personas (coach, datasci, ux, skeptic, streamer, analyst) at seeds 1117/2241/3359/4473/5587/6691, temps 0.30–0.90
- 🔴 Codex GPT-5.5 × 2 (proposal triangulation + adversarial debate)
- 🟠 Gemma critics × 3 (engcost, uxskeptic, outlier) at seeds 7711/8821/9933
- 11 LLM calls total → 6 viable directions → A+E+F hybrid chosen
- Adversarial debate gate surfaced 3 shared risks (false precision / pillar hiding / single-scrollview density) → mitigations M1+M3+M5 adopted in plan

All artifacts under `docs/research/insights-swarm/`.

---

## 3. Done (shipped in commit `8678333`)

### Pure-logic modules
- `Insights/InsightsPriority.lua` — ranking, formula `severity × confidence × recurrenceWeight × controllability`, recurrence resolution map → suggestion.recurrenceCount → 0
- `Insights/InsightsPillarMapper.lua` — 30 reason codes → 4 pillars, plus `Bucket`, `PillarValue`, `PILLARS` (stable order), `GetLabel`
- `Insights/InsightsOnboarding.lua` — Cold / Sparse / Full classifier, `SectionVisibility`, `OnboardingMessage`

### Constants extensions (`Constants.lua`)
- `INSIGHTS_ONBOARDING_THRESHOLD = 3`
- `PILLAR` enum (pressure/survival/control/consistency)
- Numeric `CONTROLLABILITY` table (31 reason codes, 0..1 weights) — parallel to existing categorical CONTROLLABILITY in SuggestionEngine

### SuggestionEngine wiring (`SuggestionEngine.lua:910`)
- 1-line addition: `sug.recurrenceCount = recentSuggestionCounts[sug.reasonCode] or 0` on every emitted suggestion

### UI
- `UI/Insights/InsightsView.lua` — new view, `viewId="insights"`, renders:
  - FidelityBar (session metadata + character history depth + data source)
  - Onboarding banner (Cold/Sparse only)
  - Next Queue Focus card (severity-colored badge, hover-visible priority formula breakdown)
  - Pillar Scoreboard (4 clickable columns, inline drilldown to contributing reason codes)
- `UI/MainFrame.lua:13` — tab `insights` routes to InsightsView (old SuggestionsView still registered for trivial revert)
- `CombatAnalytics.toc` — 4 new files registered

### Tests
- `test/test_InsightsPriority.lua` — 16 tests
- `test/test_InsightsPillarMapper.lua` — 16 tests
- `test/test_InsightsOnboarding.lua` — 10 tests
- **Total: +42 new passing tests. Baseline 56 failures unchanged.**
- Suite: 124 pass / 56 fail / 180 total
- `luac -p` clean on all touched files

### Research artifacts (committed)
- `PLAN.md`, `SYNTHESIS.md`, `CHECKPOINT.md` (this file)
- 7 agent proposals (6 Gemma + 1 Codex)
- 4 adversarial debate critiques
- All raw payloads, dispatch scripts (`dispatch.sh`, `debate-dispatch.sh`)

---

## 4. Remaining sections (deferred)

These 5 sections are designed in PLAN.md but not built. Each anchors below the Pillar Scoreboard in the single scrollview. Add in order — each builds on the previous anchor point.

| # | Section | Anchor target | New module(s) | Data source |
|---|---|---|---|---|
| 1 | **Fight Timeline Read** | below `drilldown` | `UI/Insights/Sections/FightTimelineRead.lua` | `session.openerFingerprint` (firstMajorOffensiveAt, firstMajorDefensiveAt, firstCCAt) + `session.survival.timeOfDeath` + `session.result`. 5 nodes, click any node = inline expand showing related metrics fingerprint + reason codes. NO rawEvents reads. |
| 2 | **Matchup Plan** | below timeline | `UI/Insights/Sections/MatchupPlanCard.lua` | `CombatStore.aggregates.specs[specId]` + `StrategyEngine.GetCounterGuide(specId)`. Folds old Strategy Spotlight + Matchup Memory. |
| 3 | **Trends Peek** | below matchup | `UI/Insights/Sections/TrendsPeek.lua` | `TrendAnalyzer:Get14DaySparkline()` + rating delta. Single peek card linking to `RatingView`. |
| 4 | **Practice Plan** | below trends | extend `PracticePlannerService.lua` with `:GetRecurringDrills(characterKey, weekDays)`; UI `UI/Insights/Sections/PracticePlanList.lua` | Drills filtered to reason codes appearing ≥2 times in last 7d. |
| 5 | **Evidence Drawer** | bottom, collapsed | `UI/Insights/Sections/EvidenceDrawer.lua` | Full `session.suggestions[]` rendering with filter chips (Offense/Defense/CC/Matchup/Consistency). |

### Additional polish deferred
- Calibrate priority formula weights with real session corpus (currently shipped with conservative defaults)
- Replace `pillarValueColor` heuristic bands (70/50/35) with actual baseline-delta coloring once Pillar Scoreboard wired to `CombatStore:GetBuildBaseline()`
- Pillar columns currently show only `value` + `count` — wire `deltaText` against personal baseline once Sparse+ onboarding handles it
- Visual screenshot tests per onboarding state (Cold/Sparse/Full)

---

## 5. Resume prompt

```
Resume the Insights tab rework on `combat-analytics` (commit 8678333).
Logic layer + Pillar Scoreboard already shipped. Read
docs/research/insights-swarm/CHECKPOINT.md for full state, and
docs/research/insights-swarm/PLAN.md for the original design.

Next section to build: Fight Timeline Read (5-node horizontal strip,
click-to-expand inline drilldown). Source data: session.openerFingerprint
+ session.survival.timeOfDeath + session.result. NO CLEU dependency.
Anchor below InsightsView.drilldown so the new section does not move
existing layout.

Constraints unchanged:
  - No CLEU reads (no rawEvents).
  - Single scrollview, no sub-tabs.
  - Every section degrades gracefully via InsightsOnboarding.SectionVisibility().
  - luac -p must stay clean, baseline test failures (56) must not increase.
  - Severity-colored cards via existing ns.Widgets.CreateInsightCard
    :SetData(severity, title, body, evidence).

Build order for remaining sections (each in own commit if possible):
  1. Fight Timeline Read
  2. Matchup Plan
  3. Trends Peek
  4. Practice Plan (also extend PracticePlannerService:GetRecurringDrills)
  5. Evidence Drawer (collapsed-by-default + filter chips)

After each section: luac -p, run full test suite, expect 124+ pass / 56 fail.
Commit individually with conventional commit style (feat(insights): ...).
Push to combat-analytics/main after rebase.
```

---

## 6. Quick reference — key files

| Path | Role |
|---|---|
| `Insights/InsightsPriority.lua` | Ranking module (Score/Rank/Top) |
| `Insights/InsightsPillarMapper.lua` | Reason → pillar bucket + PillarValue lookup |
| `Insights/InsightsOnboarding.lua` | Cold/Sparse/Full + section visibility map |
| `UI/Insights/InsightsView.lua` | View module, register + Build + Refresh + OnPillarClick |
| `UI/Widgets.lua` | `CreateInsightCard`, `CreateSurface`, `CreateSectionTitle`, `CreateCaption`, `CreateScrollCanvas`, `SetCanvasHeight`, `SetBackdropColors`, `THEME` |
| `Constants.lua:457+` | New Insights constants block |
| `SuggestionEngine.lua:910` | `recurrenceCount` field assignment |
| `CombatAnalytics.toc` | Load order — Insights/* registered before Events.lua |
| `test/test_Insights*.lua` | 42 unit tests |
| `docs/research/insights-swarm/PLAN.md` | Original implementation plan |
| `docs/research/insights-swarm/SYNTHESIS.md` | Multi-LLM proposal synthesis |
| `docs/research/insights-swarm/debate-*.md` | Adversarial debate critiques |

## 7. Test invocation reminder

```bash
# Run a single test file (lua 5.1+)
cat > /tmp/run-one.lua <<'EOF'
dofile("test/TestRunner.lua")
dofile("test/test_InsightsPriority.lua")
TestRunner.RunAll()
EOF
lua /tmp/run-one.lua

# Run full suite (loads mocks + every test_*.lua)
# Script at /tmp/test-all.lua from previous session — recreate if needed.

# luac syntax check (the real load gate per project memory)
luac -p path/to/file.lua
```
