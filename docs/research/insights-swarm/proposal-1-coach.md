## The "VOD Review" Dashboard

### Vision
Stop treating the Insights tab like a spreadsheet; treat it like a coach's clipboard. I don't care about "Session Trust" or "Performance Trends." I care about **The Window**. Did you blow your cooldowns into a defensive? Did you die with a cooldown available? The redesign shifts from "General Feedback" to a **Chronological Failure Map**.

### Layout
Ditch the vertical scroll of generic cards. Use a **Three-Column Grid**:
1. **Left (The Timeline):** A vertical "Heatmap" of the match.
2. **Center (The Criticals):** High-priority, timed-event cards.
3. **Right (The Toolkit):** Resource/CD efficiency and Matchup-specific "Must-Dos."

### Core Sections
*   **The "Kill Window" Timeline:** A linear map of the game. Markers indicate `LATE_FIRST_GO` or `CC_MISSED_KILL_WINDOW`. Clicking a marker jumps the Center column to that specific event.
*   **The "Mistake" Stack (Priority Queue):** Instead of "Coaching Notes," use **Actionable Fixes**. 
    *   *Example:* "Died with Defensives" $\rightarrow$ `DIED_WITH_DEFENSIVES`. 
    *   *Example:* "Trinket wasted" $\rightarrow$ `CC_DR_WASTE`.
*   **The "Trade" Analysis:** A side-by-side comparison of *Your CDs Used* vs *Opponent CDs Used* during the highest burst window.
*   **The Matchup Checklist:** A "Did you do this?" list based on `SPEC_WINRATE_STRENGTH` (e.g., "Keep [Spell X] on [Spec Y]").

### Data Wiring
*   **Timeline:** Driven by `rawEvents[]` timestamps. Map `CC_CHAIN_BREAK` and `REACTIVE_DEFENSIVE_LATE` to specific offsets.
*   **Mistake Stack:** Filter `suggestions[]` by severity. If `captureQuality.confidence` is LOW, the UI doesn't say "Trust is degraded"—it simply hides the damage numbers and only shows the **CC/Control timing** (which is always reliable).
*   **Trade Analysis:** Cross-reference `cooldowns{}` and `auras{}`. If `burstScore` is high but `survivabilityScore` of the target is also high, trigger `CC_MISSED_KILL_WINDOW`.

### Why this beats current
The current UI tells the user "You are inconsistent." My redesign tells them **"At 12.4s, you used your offensive CD while the enemy had a defensive up."** It moves from *descriptive* (what happened) to *prescriptive* (what to fix next game). It removes the "Trust" meta-talk and just shows the data that is actually available.

### Risks
*   **Data Gaps:** If CLEU is restricted, the "Trade Analysis" loses damage numbers. *Fix:* Fall back to "Ability Sequence" (e.g., "You cast X, then Y, then Z").
*   **UI Complexity:** High-density grids can be overwhelming. *Fix:* Use a "Next Game Checklist" summary at the top to distill the 3 most critical fixes.
