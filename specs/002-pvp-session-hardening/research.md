# Research: Midnight PvP Session Reliability Hardening

**Branch**: `002-pvp-session-hardening` | **Date**: 2026-03-28

## Research Context

This feature was designed from observed failure modes in production sessions. The engineering plan document (`2026-03-28-midnight-pvp-session-hardening.md`) was produced after analyzing real misfires. Research below consolidates the decisions already validated against the codebase and the Midnight API surface.

---

## R1: How to rank arena opponents without CLEU

### Decision
Use post-session evidence from sanctioned data paths: `session.attribution.bySource` (enemy damage attribution from C_DamageMeter) and death recap timeline events (lane `DM_ENEMY_SPELL`, type `death_recap`). These are mapped to arena slots by GUID and accumulated into a weighted composite pressure score.

### Rationale
- `session.attribution.bySource` is the strongest "who hurt me" signal available without CLEU. It is populated by `SpellAttributionPipeline` from `DamageMeterService` imports and is present for the vast majority of arena sessions.
- Death recap events capture near-lethal damage contributors, which is a high-signal indicator of pressure even when the total damage is similar across enemies.
- Two fields (`damageTakenFromPlayer` and `ccOnPlayer`) remain structurally present but unfed on Midnight, preserving forward compatibility.

### Alternatives Considered
1. **Use raw visible-unit last-seen order** (previous approach): Rejected because it produced effectively random opponent selection among 2-3 visible enemies.
2. **Use player's current target at finalization**: Rejected because the player may have no target or may be targeting a non-opponent (e.g., focusing on a healer while the DPS killed them).
3. **Use C_PvP.GetScoreInfo post-match damage**: Only available for the post-match scoreboard. Does not disambiguate per-round in Solo Shuffle and arrives too late (after finalization starts).

---

## R2: How to disambiguate Damage Meter candidate sessions

### Decision
Compare each candidate session's enemy source GUIDs against the addon's known enemy roster (from `primaryOpponent.guid`, `session.identity.opponentGuid`, `session.arena.slots[*].guid`, and live `ArenaRoundTracker:GetSlots()`). Award a score boost for GUID overlap, a strong boost for primary opponent GUID match, and a penalty for zero overlap. Also penalize large duration mismatches (>15s).

### Rationale
- For back-to-back arena rounds, generic damage/duration signals are often nearly identical. Roster GUID overlap is the most discriminating signal because different rounds have different opponent subsets (especially in Solo Shuffle).
- Zero-overlap penalty is critical: it actively pushes away obviously wrong candidates rather than merely failing to reward correct ones.
- Duration mismatch penalty catches cases where a long-lived historical session superficially looks like a good match on damage totals alone.

### Alternatives Considered
1. **Use only duration + damage totals** (previous approach): Rejected because multiple recent sessions often have similar duration and damage, especially in Solo Shuffle.
2. **Use session creation timestamp proximity**: Rejected because C_DamageMeter session IDs are monotonically increasing but their creation timestamps don't always align precisely with addon session boundaries.
3. **Use spell-ID overlap between candidates and session spells**: Partially useful but not discriminating enough — many spells are common across all arena sessions for a given spec.

---

## R3: Optimal finalization order for arena sessions

### Decision
Move `ArenaRoundTracker:CopyStateIntoSession(session)` to run immediately after Damage Meter import and before classifier sync, metrics derivation, and suggestion generation.

### Rationale
- `CopyStateIntoSession` is where the hardened primary opponent selection is exported. If it runs after metrics/suggestions, those downstream systems consume a stale placeholder opponent.
- The Damage Meter import must complete first because it populates `session.attribution.bySource`, which is the primary input to `ApplySessionPressure`.
- No other finalization step depends on the arena export being late. Moving it earlier has no negative side effects.

### Alternatives Considered
1. **Run CopyStateIntoSession twice** (before and after DM import): Rejected as unnecessarily complex. One call after DM import is sufficient.
2. **Defer all analytics to a post-finalization pass**: Rejected because it would require a two-phase commit model that adds complexity with no benefit.

---

## R4: Rating snapshot timing race

### Decision
Capture the pre-match rating snapshot on `matchRecord.metadata` (match-level state) in `HandlePvpMatchActive`, then propagate it to the combat session at `CreateSession` time. This decouples the snapshot from session existence.

### Rationale
- `PVP_MATCH_ACTIVE` can fire before the combat session is created (common in Midnight where session creation is triggered by first damage or first CLEU-replacement event).
- Storing the snapshot on the match record means any session created for that match inherits the data, regardless of when it is created.
- The match record already exists when `HandlePvpMatchActive` fires (it is created by `CreateOrRefreshMatch` in the prep phase).

### Alternatives Considered
1. **Defer rating capture to finalization**: Rejected because post-match rating APIs return the "after" rating, not the "before" rating. The "before" snapshot must be captured before the match ends.
2. **Create the session earlier** (at match-active time instead of first combat): Rejected because it would produce empty sessions for matches where the player disconnects or the match is cancelled before combat.

---

## R5: Identity stickiness threshold

### Decision
Use an 85% threshold for sticky preferred GUID retention. If the preferred GUID's score is at least 85% of the best slot's score, keep the preferred GUID.

### Rationale
- In Solo Shuffle, the same three enemies appear across six rounds. Between rounds, pressure profiles change. A low threshold (e.g., 50%) would never switch. A high threshold (e.g., 99%) would flap constantly.
- 85% was chosen as a conservative initial value that biases toward stability: the preferred enemy stays unless another enemy is meaningfully more dominant.
- The value is tunable and can be adjusted based on real-world confusion data.

### Alternatives Considered
1. **No stickiness (always pick highest score)**: Rejected because minor score fluctuations across similar rounds would cause identity flapping.
2. **100% stickiness (never switch)**: Rejected because it would lock in the first round's opponent even when a different enemy becomes the clear primary threat.
3. **Adaptive threshold based on score magnitude**: Rejected as over-engineering for the initial implementation. Static threshold is simpler and sufficient.

---

## R6: Scoring weight distribution

### Decision
Pressure score weights: `damageToPlayer * 0.45 + damageTakenFromPlayer * 0.30 + ccOnPlayer * 0.15 + killParticipation * 0.10`.

### Rationale
- `damageToPlayer` is the strongest signal because it directly measures "who is pressuring me."
- `damageTakenFromPlayer` is medium weight — it indicates who the player is focusing, which often correlates with kill target.
- `ccOnPlayer` is lower weight — important but less discriminating (healers CC the player frequently without being the primary threat).
- `killParticipation` is lowest but still non-zero — it catches lethal burst contributors who may not dominate sustained damage.
- Currently only `damageToPlayer` and `killParticipation` are actively fed from sanctioned data. The weights are forward-compatible for when Blizzard exposes more sanctioned signals.

### Alternatives Considered
1. **Equal weights (0.25 each)**: Rejected because it would dilute the strongest available signal (damageToPlayer) with dormant zeros.
2. **Binary selection (highest single metric wins)**: Rejected because composite scoring handles mixed-threat scenarios better.
3. **Omit unfed fields entirely**: Rejected because the weights cost nothing and preserve forward compatibility.

---

## R7: Opponent fit scoring parameters for Damage Meter matching

### Decision
- Primary GUID match: `+28`
- Per-overlap GUID: `+10`, capped at `+30`
- Zero-overlap penalty: `-18`
- Arena exact bracket match: `+10`, off-by-one: `+6`
- Duel single-source bonus: `+14`, multi-source penalty: `-8`
- Duration mismatch >15s penalty: `-20`

### Rationale
- These values were hand-picked to be conservatively strong. The primary GUID match (`+28`) is the single strongest disambiguator because it directly validates "this candidate session includes the enemy we're tracking."
- The zero-overlap penalty (`-18`) is deliberately less than the primary match boost, so a candidate that matches on other signals can still win even if the roster GUID set has changed (e.g., after a disconnect/reconnect).
- Duration mismatch penalty is applied only when session duration is non-zero, preventing false penalization of instant sessions.
- All values are tuning knobs that can be adjusted based on real confusion cases.

### Alternatives Considered
1. **Machine-learned scoring**: Rejected for now — insufficient training data exists. Hand-picked conservative values are more predictable and debuggable.
2. **Binary threshold (GUID match or reject)**: Rejected because partial matches (1 of 3 GUIDs overlap) should be scored proportionally, not binary.
