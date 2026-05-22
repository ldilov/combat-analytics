## Redesign: The "Pattern Engine" Dashboard

### Vision
Shift the "Insights" tab from a **Post-Game Summary** (which is noise) to a **Longitudinal Performance Tracker** (which is signal). Instead of telling the user "you messed up your opener this game," the UI identifies if the user is *struggling to adapt to a specific spec over the last 10 games*. We move from "Fight Story" (singular/fragile) to "Trend Analysis" (aggregate/robust).

### Layout
A vertical scroll view divided into three distinct zones:
1.  **The Signal Header:** A compact "Data Fidelity" bar (replacing the bulky Trust Card) and a "Session Context" summary.
2.  **The Pattern Grid:** A 2x2 grid of "Trend Cards" focusing on cross-session delta.
3.  **The Execution Log:** A chronological list of "Reason Codes" filtered by frequency across the week, not just the session.

### Core Sections
*   **Fidelity Bar:** A slim, top-aligned strip. (Green/Yellow/Red) indicating if the session was CLEU-restricted. If Red, it explicitly flags: *"Damage data suppressed; focusing on CC/Cooldown patterns."*
*   **The "Drift" Analysis (Pattern Card 1):** Compares current session metrics (Pressure/Burst/Survivability) against the player's 14-day rolling average. 
    *   *Visual:* A sparkline showing the metric trend.
*   **The "Matchup Mastery" (Pattern Card 2):** Specifically targets the `primaryOpponent` spec. 
    *   *Insight:* "You are currently 40% less effective against [Spec] than your average; focus on [Reason Code: REACTIVE_DEFENSIVE_LATE]."
*   **The "Critical Failure" Heatmap:** Instead of a "Fight Story" sentence, this lists the top 3 Reason Codes triggered this session, but weights them by *frequency in the last 20 games*.
    *   *Example:* "DIED_WITH_DEFENSIVES (Occurred 4x this session | 12x this week) $\rightarrow$ High Priority."
*   **The "Learning Velocity" Tracker:** A progress bar showing the decline of specific Reason Codes over time (e.g., "TRINKET_TIMING_POOR" is appearing 30% less often this week).

### Data Wiring
*   **Cross-Session Aggregates $\rightarrow$ Pattern Grid:** Pulls from `weekly` and `opponents` aggregates to create the baseline.
*   **Reason Codes $\rightarrow$ Heatmap:** Maps `suggestions[]` from the current session to the `Cross-session` frequency table.
*   **Metrics $\rightarrow$ Drift Analysis:** Compares `metrics{}` of the current `matchKey` against the `dummyBenchmarks` and historical averages.

### Why this beats current
The current system treats every game as an isolated event. If a user has one bad game due to a lag spike, the "Fight Story" tells them they failed. The Redesign recognizes that one game is noise. By anchoring current performance to a 14-day baseline, it identifies **systemic flaws** (e.g., a consistent inability to use defensives) rather than **incidental errors**.

### Risks
*   **Cold Start:** Users with <5 games of data will see empty "Trend" cards. (Mitigation: Use `dummyBenchmarks` as the initial baseline).
*   **Data Fragmentation:** CLEU restrictions make "Drift" analysis noisy if some games have full data and others don't. (Mitigation: Only compare "CC/Control" metrics when damage data is missing).
