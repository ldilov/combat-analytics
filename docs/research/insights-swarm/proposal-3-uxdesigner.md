## Redesign: The "Combat Post-Mortem" Dashboard

### Vision
Stop treating "Insights" as a list of notes; treat it as a **Diagnostic Report**. We move from a "vertical stack of cards" to a **Bento-Grid Editorial Layout**. The goal is "Glanceability": the user should know within 3 seconds if they lost due to mechanical failure, strategic mismatch, or data degradation.

### Layout
A non-linear, asymmetric grid. We abandon the scroll-list for a fixed-viewport dashboard with three distinct visual tiers:
1.  **The Header (The Verdict):** Full-width, high-contrast summary.
2.  **The Main Body (The Evidence):** A 2/3 left column for "Primary Failures" and a 1/3 right column for "Context & Trust."
3.  **The Footer (The Action):** A horizontal "Quick-Fix" bar.

### Core Sections
*   **The Verdict (Top Banner):** A bold headline driven by the `Fight Story`. Instead of a paragraph, use a **Headline + Sub-headline** format. 
    *   *Example:* **"Sustained Pressure Failure"** $\rightarrow$ *"You maintained high uptime, but burst windows were missed."*
*   **The Criticals (Main Left - Bento Grid):** 3-4 high-density tiles. Instead of 8 generic notes, we group `Reason Codes` into "buckets":
    *   **Resource/Cooldown Tile:** (Drives: `DEFENSIVE_UNUSED`, `DIED_WITH_DEFENSIVES`). Visual: A timeline sparkline of CD usage vs. damage taken.
    *   **Pressure Tile:** (Drives: `LOW_PRESSURE`, `ROTATION_GAPS`). Visual: A "Pressure Meter" (Current vs. Baseline).
    *   **Control Tile:** (Drives: `CC_MISSED_KILL_WINDOW`, `TRINKET_TIMING`). Visual: A "CC Chain" sequence map.
*   **The Context Panel (Right Sidebar):**
    *   **Trust Score:** A subtle, semi-transparent overlay or small gauge. If `confidence` is LOW, the entire panel desaturates to signal "Take this with a grain of salt."
    *   **Matchup Memory:** A "Win/Loss" heat map against this specific `specId`.
*   **The Strategy Pivot (Bottom Bar):** A horizontal strip of "Suggested Adjustments" based on `Strategy Spotlight` (e.g., "Swap Talent X $\rightarrow$ Y for this matchup").

### Data Wiring
*   **Trust State:** `captureQuality.confidence` acts as a global multiplier for UI opacity/saturation.
*   **Reason Code Mapping:** Map the 30 codes to 4 "Analytical Pillars" (Pressure, Survival, Control, Consistency). This aggregates 8 fragmented cards into 4 meaningful data-tiles.
*   **Evidence Framing:** Use `metrics` (burstScore, pressureScore) to drive the "needle" on the gauges, while `rawEvents` provide the "Evidence Line" beneath the gauge.

### Why this beats current
*   **Information Hierarchy:** It replaces "reading a list" with "scanning a dashboard."
*   **Emotional Pacing:** The "Verdict" provides immediate closure; the "Criticals" provide the *why*; the "Pivot" provides the *how* to improve.
*   **Honest Data:** By linking `confidence` to visual saturation, we stop lying to the user when CLEU is restricted.

### Risks
*   **Lua Complexity:** Implementing a bento-grid in `CreateFrame` requires strict anchor management and custom scaling logic.
*   **Data Sparsity:** If `suggestions[]` is empty, the "Criticals" tiles must fail-gracefully to "Optimal Performance" states rather than appearing broken.
