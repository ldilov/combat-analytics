## Redesign: The "Evidence-First" Post-Game Report

### Vision
Stop trying to "tell a story" with a single sentence. Users hate being told *what* happened by a black-box algorithm; they want to see the *evidence* that led to the conclusion. We shift from "Coaching Notes" (opinion) to "Data Anomalies" (fact). If the data is degraded (CLEU restricted), we don't hide the tab—we pivot to the only reliable data left: Cooldowns and Auras.

### Layout
A vertical, scrollable feed of **Evidence Cards**. Each card is a "Fact $\rightarrow$ Conclusion" pair.
- **Header:** Session Health (Confidence Score + Data Mode: Full/Degraded).
- **Body:** A series of prioritized cards sorted by `severityScore`.
- **Footer:** Quick-link to the raw event log for the specific timestamp mentioned in the card.

### Core Sections
*   **The "Critical Miss" Feed:** High-severity cards based on `REASON_CODES`. Instead of "You played poorly," it shows: *"Defensive unused on loss: [Spell X] was available for 12s during final 15s of fight."*
*   **Resource Efficiency:** A side-by-side comparison of `metrics{burstScore}` vs `dummyBenchmarks`.
*   **The "Cooldown Gap" Timeline:** A visual representation of `cooldowns{}` spacing. Highlights gaps where `rotationConsistencyScore` dropped.
*   **Matchup Baseline:** A simple "Current vs. Average" table using `Cross-session aggregates` (e.g., "Your damage vs. [SpecId] is 12% lower than your average").

### Data Wiring
*   **Degraded Mode Logic:** If `captureQuality.cleuRestricted == true`, the UI **automatically disables** `totals{damageDone}` and `metrics{pressureScore}`. It replaces them with `cooldowns{}` and `auras{}` analysis. You cannot derive a "Pressure Score" from restricted data; you can only derive "Cooldown Usage."
*   **Reason Code Mapping:** Each `REASON_CODE` must map to a specific data point. 
    *   `DIED_WITH_DEFENSIVES` $\rightarrow$ Check `cooldowns{}` for unused IDs at `timestampOffset` of death.
    *   `POOR_INTERRUPT_RATE` $\rightarrow$ `spells{}` (Interrupt IDs) / `arena.opposingTeam` cast count.
*   **Provenance:** Every card includes a "Source" tag (e.g., `Source: auras{}`), so the user knows exactly where the "insight" came from.

### Why this beats current
1.  **No Hallucinations:** It replaces the "Fight Story" (which is just a string template) with actual data-backed anomalies.
2.  **Honest Degradation:** Instead of a "Trust Bar" that just warns the user, the UI physically removes the broken metrics and replaces them with the reliable ones (Cooldowns/Auras).
3.  **Actionable:** "Review opener pacing" is vague. "Opener X was 2.1s slower than benchmark" is a fact.

### Risks
*   **Data Noise:** If the `REASON_CODES` trigger too often, the feed becomes a wall of text. *Mitigation:* Strict thresholding based on `severityScore`.
*   **API Limitations:** Heavy reliance on `Cross-session aggregates` may cause frame stutters if the database grows too large. *Mitigation:* Cache aggregates on login.
