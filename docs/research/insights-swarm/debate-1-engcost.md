This is a UX nightmare masquerading as a "streamlined" design. You’ve traded a navigation problem (tabs) for a cognitive load problem (the Infinite Scroll of Doom).

**The "Single Scrollview" is a death trap.** You are cramming high-density analytics, sparklines, and a "drawer" into one vertical strip. In WoW's limited frame space, this will either be a microscopic sliver or a screen-blocking monolith. The moment a user has to scroll three times to find the "Practice Plan," they’ll stop using the addon.

**The 4-Pillar consolidation is "Data Theater."** You’re aggregating 30 distinct reason-codes into four buckets. You aren't simplifying the signal; you're burying it. A "Pressure" score is useless if the user doesn't know *why* it's low. If the "Evidence Drawer" is collapsed by default, you've effectively hidden the only actionable data in the entire UI.

**The CLEU-restricted swap is a coding landmine.** Swapping columns dynamically based on a boolean flag is a recipe for anchor-point hell and layout flickering. If the "Cooldown-Usage" column has different text lengths or requirements than "Pressure," your grid will shift or clip.

**New players are invisible here.** This design assumes a baseline of "Personal Baselines" and "Matchup Mastery." A player with <5 sessions will see a screen full of "N/A," "Insufficient Data," and empty sparklines. You’ve built a tool for the 1% of analysts, not the 99% of players.

**TOP 3 RISKS:**
1. **UX Friction:** The scrollview creates a "wall of data" that kills the immediate dopamine hit of a post-match review.
2. **Data Obfuscation:** Pillar scores hide the specific failures (reason-codes) that actually drive improvement.
3. **Engineering Debt:** Dynamic column swapping and inline sparklines in a single scroll-frame will tank frame rates and lead to anchor-management nightmares.
