## VOD-Slayer: The Narrative Review Redesign

### Vision
Stop the "Report Card" vibe. No one wants to read a spreadsheet of their failures; they want to see the *moment* they threw. We shift from "Static Insights" to a **Timeline-Driven Story**. The tab becomes a VOD review tool where the data points to specific seconds in the fight, turning raw logs into "Clip-worthy" narrative beats.

### Layout
A horizontal-first, scrollable interface. 
- **Top:** A high-contrast **Timeline Scrub Bar** (0:00 $\rightarrow$ End).
- **Center:** The **Moment Stream**. A vertical feed of "Moment Cards" anchored to the timeline.
- **Right:** The **Context Sidebar** (Opponent Spec/Build + Trust Level).
- **Bottom:** Quick-filter chips (e.g., "The Throws," "The Wins," "The Gaps").

### Core Sections
*   **The Narrative Timeline:** A linear map of the match. Red/Green markers indicate "Turning Points." Clicking a marker snaps the view to the corresponding Moment Card.
*   **Moment Cards:** Instead of "Coaching Notes," these are event-driven cards.
    *   *Example:* **"The Defensive Gap"** (at 0:42). "You took 40k damage here, but your `Sustain_CD` was still off cooldown."
    *   *Visuals:* Event timestamp $\rightarrow$ Reason Code $\rightarrow$ Contrast Comparison (Your Action vs. Optimal).
*   **The "Turning Point" Analysis:** A dedicated section highlighting the 2-3 moments where the `pressureScore` shifted most drastically.
*   **Matchup Memory (The 'Tape'):** A side-by-side of "This Match" vs. "Your Average vs. [Spec]." (e.g., "Usually you interrupt 60% of this spec; today you hit 20%").

### Data Wiring
*   **Timeline Anchors:** `rawEvents[]` + `timestampOffset` $\rightarrow$ Map to X-axis of the scrub bar.
*   **Moment Generation:** Map `REASON_CODES` to specific timestamps. 
    *   `DIED_WITH_DEFENSIVES` $\rightarrow$ Trigger Moment Card at `deathTimestamp` $\rightarrow$ Query `auras{}` for active defensives.
    *   `CC_MISSED_KILL_WINDOW` $\rightarrow$ Trigger Card at `burstScore` peak $\rightarrow$ Query `cooldowns{}` for unused offensive CDs.
*   **Trust Integration:** Instead of a "Trust Card," the Trust Level is a subtle watermark on the timeline. If `cleuRestricted` is true, the timeline shows "Approximate" markers.

### Why this beats current
The current UI is a post-game autopsy; this is a VOD review. It replaces abstract "Severity Bars" (which mean nothing) with **Temporal Context** (which means everything). By anchoring `REASON_CODES` to `timestampOffset`, we move from "You are bad at defensives" to "At 1:12, you forgot your defensive."

### Risks
*   **CLEU Restrictions:** If data is too degraded, the timeline becomes sparse. *Mitigation:* Fall back to "Aggregate Narratives" if `confidence` is LOW.
*   **UI Overhead:** Drawing many frames in Lua can lag. *Mitigation:* Use a virtualized list for Moment Cards.
