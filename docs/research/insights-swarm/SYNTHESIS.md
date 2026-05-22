# Insights Tab Rework — Multi-Agent Synthesis

**Inputs:** 6 × Gemma-4 31B (NIA vLLM) with distinct personas/seeds/temps + 1 × Codex GPT-5.5.

## Convergent themes (high agreement across agents)

1. **Demote "Session Trust"** from top-level card to a slim badge / saturation overlay.
   *Sources: coach, ux, skeptic, streamer, analyst, codex (6/7)*
2. **Replace flat 30-reason-code list with 3-5 grouped pillars.**
   Pillars converged on: **Pressure / Survival / Control / Consistency** + optional Matchup.
   *Sources: ux (4 pillars), codex (3 scoreboards), analyst (top-3 weighted), skeptic (priority feed)*
3. **Anchor insights to time** (specific seconds + sequence). The "Fight Story" sentence is universally rejected.
   *Sources: coach, streamer, codex (timeline strip), ux (sparklines)*
4. **Compare against baselines, not absolutes.** Cohort, build, matchup, weekly.
   *Sources: datasci, codex, analyst, ux*
5. **Graceful CLEU-restricted degradation.** Don't gray-warn — switch the data source visible.
   *Sources: skeptic (most insistent), codex, ux, analyst*
6. **One primary recommendation surfaces above all.** Triage > buffet.
   *Sources: coach (next-game checklist), codex (Next Queue Focus), ux (Verdict banner), streamer (turning point)*

## Divergent directions (the real choice)

Six distinct viable systems. Three orthogonal axes:

| Axis | Pole A | Pole B |
|---|---|---|
| Time horizon | Single session | Longitudinal trend |
| Primary verb | Triage (rank + fix) | Compare (vs cohort) |
| Anchor | Timeline / moment | Card / pillar |

## Options for direction

### Option A — "Next Queue Focus" Triage Dashboard
*Fusion of coach + codex.* Single scroll view. Top: one giant **Next Queue Focus** card (the #1 fix). Below: **Fight Timeline Read** (horizontal sequence: opener → first go → first def → first CC → end, each node tagged good/late/missing/unknown). Below: **Pressure / Survival / Control scoreboard** (3 columns vs baselines). Then **Matchup Plan**, **Practice Plan** (recurring codes only), and a collapsed **Evidence Drawer**. Priority = severity × confidence × recurrence × controllability.

**Strength:** Lowest UX friction, leads with action. **Weakness:** Single session view only.

### Option B — "Bento Verdict" Editorial Dashboard
*From ux-designer.* Asymmetric grid, fixed viewport (no scroll). **Verdict banner** (full-width headline + sub-headline). 2/3 left bento of **Pillar tiles** (Pressure / Survival / Control / Consistency, each tile has a sparkline + gauge). 1/3 right **Context sidebar** (Matchup heat, Trust as saturation overlay). Bottom **Strategy Pivot bar**.

**Strength:** Highest glanceability, distinctive look. **Weakness:** Bento in `CreateFrame` is anchor-management heavy.

### Option C — "VOD Timeline" Narrative
*Fusion of streamer + coach.* Horizontal **Timeline Scrub Bar** top (0:00 → end with markers). **Moment Stream** in center — each Moment Card anchored to a timestamp ("at 0:42 — defensive gap"). Right sidebar: opponent context + trust watermark. Bottom: filter chips (The Throws / The Wins / The Gaps).

**Strength:** Storytelling, shareable moments, exactly where coaches think. **Weakness:** Useless when CLEU restricted unless we hard-degrade to scoreboard timeline.

### Option D — "Distribution Engine" Cohort Analytics
*From data-scientist.* Tabbed sub-nav: Session → Cohort → Trend. **Confidence header** (N samples + fidelity). **Delta Grid 3×2** (6 metrics, each shows current → cohort mean → z-score). **Percentile bands** (horizontal bars showing rank). **Outlier log** (only events >1.5σ from baseline).

**Strength:** Honest, rigorous, scales with data. **Weakness:** Reads as a research paper — emotionally cold. Needs sample size > 30 for niche specs.

### Option E — "Pattern Engine" Longitudinal
*From esports-analyst.* Slim **Fidelity bar** top. **Pattern Grid 2×2**: Drift card (14-day rolling avg sparkline), Matchup Mastery card (cross-session vs this spec), Critical Failure Heatmap (reason codes weighted by week frequency), Learning Velocity (decline rate of specific codes).

**Strength:** Catches systemic flaws that single-session noise hides. Best alignment with "Heuristics enhancement initiative" already in memory. **Weakness:** Cold-start problem for new players (<5 sessions).

### Option F — "Evidence-First" Anomaly Feed
*From skeptic.* Vertical feed of **Evidence Cards** (Fact → Conclusion pairs). Header: Session Health badge + Data Mode (Full/Degraded). Each card includes a `Source: cooldowns{}` provenance tag. CLEU-restricted mode **physically replaces** damage cards with cooldown/aura cards rather than warning.

**Strength:** Maximum honesty, zero hallucination risk, mode-switch UX for degraded sessions. **Weakness:** Less inspiring visually than B/C.

## Recommended composition

**Hybrid: A (frame) + E (depth) + F (degradation rule)**

- Make Option A the **default landing** layout for a session.
- Make Option E a **sibling sub-tab** ("Trends") accessible from Insights — feeds Drift/Mastery/Velocity cards from existing weekly aggregates.
- Adopt Option F's rule: **CLEU-restricted sessions** swap the Pressure/Survival/Control scoreboard cards for Control/Cooldown/Roster cards. No grayed-out fantasy metrics.
- Borrow Option C's **Fight Timeline Read** as the spine of Option A (already in codex proposal).
- Borrow Option B's **Verdict banner** styling for the Next Queue Focus card.
- Defer Option D (cohort z-scores) — premature without a 50+ session corpus per spec.

This lines up with memory: scoreboard anchor + per-metric provenance shipped; Decision-Gap Engine deferred — but Option A's priority formula IS the Decision-Gap Engine in lighter form.
