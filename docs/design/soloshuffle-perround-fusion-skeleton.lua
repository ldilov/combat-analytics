-- ============================================================================
-- DESIGN SKELETON — NOT A LOADED ADDON FILE — DO NOT ADD TO CombatAnalytics.toc
-- ============================================================================
-- Feature: "Solo Shuffle per-round fusion"
-- Status : DESIGN SKELETON. Spike-independent parts are written out; every part
--          that depends on the UNVERIFIED in-game spike is marked  -- SPIKE: ...
--
-- This file passes `luac -p` (Lua 5.4) as a standalone syntax check. It is NOT
-- wired into the addon. When implemented for real, the functions below get
-- split across DamageMeterService.lua, ArenaRoundTracker.lua, CombatTracker.lua
-- and Constants.lua at the integration points cited inline.
--
-- ----------------------------------------------------------------------------
-- TWO CO-EQUAL CAPTURE STRATEGIES (the point of this skeleton)
-- ----------------------------------------------------------------------------
-- The whole feature hinges on ONE unverified question, answered only by an
-- in-game spike: does C_DamageMeter spawn a discrete session per Solo Shuffle
-- round, or keep ONE continuous match-long session? This skeleton builds BOTH
-- answers as first-class, co-equal capture paths so a single spike run decides
-- everything with minimal rewiring:
--
--   STRATEGY A ("expired_session_snapshot"):
--     IF the meter spawns one session per round, then at each PostRound the
--     newest `Expired`-type session IS that round's damage. Snapshot it.
--
--   STRATEGY B ("current_session_delta"):
--     IF the meter keeps ONE continuous `Current`-type session for the whole
--     match, then round N's damage = (cumulative Current damage at end of
--     round N) - (cumulative at end of round N-1). Delta-track it.
--
-- The capture step at PostRound records BOTH signals every round (cheap: two
-- reads). `selectCaptureStrategy(captureLog)` runs post-match and picks A or B
-- based on which capture actually produced usable per-round data. Whichever
-- wins, the SAME post-match scaling (ratio = scoreboardTotal / sum) is applied.
--
-- The spike harness `docs/design/soloshuffle-spike-harness.lua` already probes
-- for BOTH: it logs Expired-session counts (A) AND Current-session ID stability
-- + cumulative trail (B), so one spike run resolves the A-vs-B question.
--
-- ----------------------------------------------------------------------------
-- PROBLEM
-- ----------------------------------------------------------------------------
-- WoW Solo Shuffle = one rated match of 6 rounds (3v3, rotating teams).
-- CombatAnalytics creates ONE combat session per round, but each round's
-- session.arena.rounds[i].damageDone / healingDone / damageTaken are HARDCODED
-- to 0 in ArenaRoundTracker.lua:1060-1063 (CopyStateIntoSession). This skeleton
-- fills those fields.
--
-- API REALITY (12.0.5, given — not re-derived here):
--   * CLEU removed for addon code.
--   * C_PvP.GetScoreInfo = SecretInActivePvPMatch. MATCH-scoped. Readable only
--     AFTER the whole 6-round match goes inactive. Yields ONE cumulative
--     whole-match damage total per player. CANNOT be read per-round.
--   * C_DamageMeter session data = SecretWhenInCombat (readable out of combat).
--     Enum.DamageMeterSessionType = Overall(0) / Current(1) / Expired(2).
--   * PvPMatchState has a distinct PostRound state (value 4), surfaced via
--     C_PvP.GetActiveMatchState() and PVP_MATCH_STATE_CHANGED.
--
-- APPROACH (sensor fusion — strategy-agnostic):
--   SHAPE   — at each round's PostRound transition, capture per-round relative
--             magnitudes. Strategy A reads the Expired session snapshot;
--             Strategy B reads the Current session's cumulative total and
--             deltas it against the previous round.
--   MAGNITUDE — after the whole match goes inactive, read the authoritative
--             scoreboard total (already captured: session.postMatchScores).
--   FUSE    — scale the 6 per-round SHAPE values so they sum to the
--             scoreboard MAGNITUDE total. SAME scaling for A and B.
--
-- *** CRITICAL UNVERIFIED HYPOTHESIS ***
--   Strategy A assumes each Solo Shuffle round spawns a discrete C_DamageMeter
--   session reachable as `Expired`. Strategy B assumes a single continuous
--   `Current` session with a monotonic cumulative trail. EXACTLY ONE of these
--   is true and NOBODY HAS CONFIRMED WHICH. It cannot be verified without a
--   running WoW client. All code paths that depend on it are marked
--   -- SPIKE: ...  and the design degrades gracefully (falls back to even
--   split + LOW confidence) if NEITHER strategy yields usable data.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- SECTION 0 — Constants additions  (TARGET FILE: Constants.lua)
-- ----------------------------------------------------------------------------
-- Self-contained mirror so this skeleton type-checks standalone. In the real
-- patch these are MERGED into the existing Constants table — do not redefine it.
local Constants = {}

-- SCHEMA_VERSION bump: 10 -> 11. Migration is additive only (see SECTION 6).
Constants.SCHEMA_VERSION = 11

-- Existing enum (Constants.lua:121) — mirrored, do not redefine in real patch.
Constants.METRIC_CONFIDENCE = {
    HIGH      = "high",
    ESTIMATED = "estimated",
    LOW       = "low",
    UNKNOWN   = "unknown",
}

-- NEW: provenance tag for a fused per-round damage value. Stored on each
-- session.arena.rounds[i].fusion.method so the UI / SuggestionEngine can tell
-- a real per-round number from an evenly-split guess.
Constants.ROUND_FUSION_METHOD = {
    -- STRATEGY A: per-round Expired-session SHAPE snapshot scaled to scoreboard
    -- MAGNITUDE. Best case if the meter spawns one session per round.
    SCALED_FROM_EXPIRED   = "scaled_from_expired",
    -- STRATEGY B: per-round Current-session cumulative DELTA scaled to
    -- scoreboard MAGNITUDE. Best case if the meter keeps one continuous session.
    SCALED_FROM_DELTA     = "scaled_from_delta",
    -- SHAPE values all summed to 0, or NEITHER strategy yielded usable data:
    -- scoreboard total divided evenly across the completed rounds. Coarse.
    EVEN_SPLIT            = "even_split",
    -- Per-round SHAPE captured but NO scoreboard total to scale against:
    -- raw snapshot kept as-is (magnitude unverified).
    RAW_SNAPSHOT_UNSCALED = "raw_snapshot_unscaled",
    -- Nothing usable. Fields stay 0.
    NONE                  = "none",
}

-- NEW: which capture strategy resolved the per-round SHAPE. Stored on
-- session.arena.fusionStrategy and (per round) fusion.basis so downstream code
-- and the spike post-mortem can tell A-derived numbers from B-derived ones.
-- A and B are CO-EQUAL — neither is a "primary"; the spike picks the winner.
Constants.ROUND_FUSION_STRATEGY = {
    -- Strategy A: newest Expired C_DamageMeter session snapshotted per round.
    EXPIRED_SNAPSHOT = "expired_session_snapshot",
    -- Strategy B: continuous Current session, per-round cumulative delta.
    CURRENT_DELTA    = "current_session_delta",
    -- Neither A nor B produced usable per-round data this match.
    NONE             = "none",
}

-- Maps a fusion method to the METRIC_CONFIDENCE tier the resulting per-round
-- damage value should carry. A fused value is NEVER "high" — neither Strategy A
-- nor Strategy B is a genuine authoritative per-round source, so both top out
-- at "estimated". Only a real per-round API (which does not exist) could be HIGH.
Constants.ROUND_FUSION_CONFIDENCE = {
    scaled_from_expired   = Constants.METRIC_CONFIDENCE.ESTIMATED,
    scaled_from_delta     = Constants.METRIC_CONFIDENCE.ESTIMATED,
    even_split            = Constants.METRIC_CONFIDENCE.LOW,
    raw_snapshot_unscaled = Constants.METRIC_CONFIDENCE.LOW,
    none                  = Constants.METRIC_CONFIDENCE.UNKNOWN,
}


-- ============================================================================
-- SECTION 1 — Per-round SHAPE capture  (TARGET FILE: DamageMeterService.lua)
-- ----------------------------------------------------------------------------
-- New methods on DamageMeterService. They reuse the EXISTING wrapper machinery:
--   * _buildSnapshotFromSessionType(session, <Enum.DamageMeterSessionType.X>)
--     (DamageMeterService.lua:1300) already builds a full player-damage snapshot
--     from a given session type — CaptureCurrentSessionSnapshot:1374 already
--     fast-paths Expired. We reuse it verbatim for BOTH the Expired read
--     (Strategy A) and the Current read (Strategy B).
--   * GetAvailableSessions / GetLatestSessionId (lines 438 / 442) for sessionId
--     bookkeeping — Strategy A uses it to avoid re-snapshotting the same DM
--     session; Strategy B uses it to detect a Current-session ID change.
--
-- CO-EQUAL CAPTURE: at every PostRound transition we record BOTH signals —
-- (a) the newest Expired session snapshot (Strategy A input) and (b) the
-- Current session's cumulative damage reading (Strategy B input). Both reads
-- are cheap; capturing both every round means one spike run decides which
-- strategy the post-match resolver uses, with zero re-instrumentation.
-- ============================================================================

local DamageMeterService = {}  -- skeleton stub; real patch extends the module

-- InitSoloShuffleFusion(): reset per-match fusion state. Called once when a
-- Solo Shuffle match begins. HOOK: CombatTracker:HandlePlayerJoinedPvpMatch /
-- ArenaRoundTracker:BeginMatch path, gated on subcontext == SOLO_SHUFFLE.
function DamageMeterService:InitSoloShuffleFusion()
    -- captureLog[roundIndex] = {
    --   roundIndex=,
    --   expired = { damageDone=, healingDone=, damageTaken=, dmSessionId=,
    --               hadData= } | nil   -- Strategy A input
    --   current = { cumDamageDone=, cumHealingDone=, cumDamageTaken=,
    --               dmSessionId=, hadData= } | nil   -- Strategy B input
    --   capturedAt=,
    -- }
    self.soloShuffleFusion = {
        captureLog       = {},
        lastSnapshotDmId = self:GetLatestSessionId() or 0,
        active           = true,
    }
end

-- CaptureSoloShuffleRoundSnapshot(roundIndex): records BOTH capture signals for
-- this round. Spike-INDEPENDENT in mechanism (both reads use session types the
-- codebase already touches) but the SEMANTIC assumption of each — A: Expired
-- holds only the round just finished; B: Current is one continuous cumulative
-- session — is the unverified spike. We capture both and let
-- selectCaptureStrategy() decide post-match.
--
-- Returns the capture record table or nil. Never throws; C_DamageMeter reads
-- are wrapped because round-transition timing vs. SecretWhenInCombat is
-- uncertain — and one signal failing must not block the other.
function DamageMeterService:CaptureSoloShuffleRoundSnapshot(roundIndex)
    if not self.soloShuffleFusion or not self.soloShuffleFusion.active then
        return nil
    end
    if type(roundIndex) ~= "number" or roundIndex < 1 then
        return nil
    end

    local record = {
        roundIndex = roundIndex,
        capturedAt = (Helpers and Helpers.Now and Helpers.Now()) or 0,
        expired    = nil,
        current    = nil,
    }

    -- --- STRATEGY A input: newest Expired session snapshot -----------------
    -- SPIKE: verify in-client that at PostRound the Expired session type holds
    -- ONLY the round just completed (not Overall, not cumulative). If true,
    -- this snapshot IS round N's damage and resolveRoundsFromExpiredSnapshots
    -- consumes it directly.
    local okE, expiredSnap = pcall(function()
        -- _buildSnapshotFromSessionType already exists at DamageMeterService.lua:1300.
        -- Passing a throwaway session table: we only want the totals, not the
        -- session-mutating side effects of ApplySnapshotToSession.
        return self:_buildSnapshotFromSessionType({}, Enum.DamageMeterSessionType.Expired)
    end)
    if okE and type(expiredSnap) == "table" then
        local e = {
            damageDone  = tonumber(expiredSnap.damageDone)  or 0,
            healingDone = tonumber(expiredSnap.healingDone) or 0,
            damageTaken = tonumber(expiredSnap.damageTaken) or 0,
            dmSessionId = self:GetLatestSessionId() or 0,
            hadData     = false,
        }
        e.hadData = (e.damageDone + e.healingDone + e.damageTaken) > 0
        record.expired = e
    end

    -- --- STRATEGY B input: Current session CUMULATIVE reading --------------
    -- SPIKE: verify in-client that the Current session persists across the
    -- whole match with a monotonically-growing cumulative total, and that its
    -- sessionId is STABLE round-to-round. If true, resolveRoundsFromCurrentDeltas
    -- differences these cumulative readings into per-round damage.
    -- The dmSessionId is recorded EVERY round precisely so the resolver can
    -- detect a mid-match Current-session ID change (Strategy B edge case).
    local okC, currentSnap = pcall(function()
        return self:_buildSnapshotFromSessionType({}, Enum.DamageMeterSessionType.Current)
    end)
    if okC and type(currentSnap) == "table" then
        local c = {
            cumDamageDone  = tonumber(currentSnap.damageDone)  or 0,
            cumHealingDone = tonumber(currentSnap.healingDone) or 0,
            cumDamageTaken = tonumber(currentSnap.damageTaken) or 0,
            -- Current session is meant to be ONE session; capture its id so a
            -- change between rounds flags Strategy B as unavailable.
            dmSessionId    = (currentSnap.sessionId)
                              or (self:GetLatestSessionId() or 0),
            hadData        = false,
        }
        c.hadData = (c.cumDamageDone + c.cumHealingDone + c.cumDamageTaken) > 0
        record.current = c
    end

    self:_recordRoundSnapshot(roundIndex, record)
    return record
end

-- _recordRoundSnapshot: idempotent store. A round capture is written at most
-- once; a later duplicate PostRound event for the same index is ignored so a
-- re-fired event cannot double-count (matters for BOTH strategies — a doubled
-- Current reading would corrupt the delta chain).
function DamageMeterService:_recordRoundSnapshot(roundIndex, record)
    local fusion = self.soloShuffleFusion
    if not fusion then return end
    if fusion.captureLog[roundIndex] ~= nil then
        return  -- already captured — keep the first, most-timely read
    end
    fusion.captureLog[roundIndex] = record or { roundIndex = roundIndex }
end

-- GetSoloShuffleCaptureLog(): accessor for the fusion step. Returns the raw
-- per-round capture log holding BOTH the expired and current signals.
function DamageMeterService:GetSoloShuffleCaptureLog()
    return self.soloShuffleFusion and self.soloShuffleFusion.captureLog or {}
end


-- ============================================================================
-- SECTION 2 — Post-match resolution + SCALING  (TARGET FILE: CombatTracker.lua)
-- ----------------------------------------------------------------------------
-- Runs once, after the whole match is inactive and session.postMatchScores has
-- been harvested. Integrates with — does NOT duplicate — the existing arena
-- scoreboard anchor (ApplyScoreboardAnchorIfNeeded, CombatTracker.lua:1643).
--
-- The anchor at :1647 EXPLICITLY early-returns for SOLO_SHUFFLE because the
-- scoreboard is whole-match and a session is one round — anchoring per-round
-- would 6x over-count. This fusion step is the Solo-Shuffle-specific complement:
-- it consumes the SAME source (scoreboard player damage row) but DISTRIBUTES it
-- across rounds instead of assigning the whole total to one session.
--
-- THREE-STEP POST-MATCH PIPELINE:
--   1. selectCaptureStrategy(captureLog) -> "A" / "B" / nil
--   2. resolveRoundsFromExpiredSnapshots() OR resolveRoundsFromCurrentDeltas()
--      -> a uniform { [roundIndex] = { damageDone, healingDone, damageTaken } }
--         per-round SHAPE table, regardless of which strategy produced it.
--   3. _applyScaledFusion() — the ONE shared scaling step. ratio = total / sum,
--      applied to whichever strategy's per-round SHAPE was resolved. Scaling is
--      NOT duplicated per strategy.
-- ============================================================================

local CombatTracker = {}  -- skeleton stub

-- --------------------------------------------------------------------------
-- selectCaptureStrategy(captureLog): post-match, decide which capture actually
-- produced usable per-round data. A and B are CO-EQUAL candidates — the spike
-- determines which one the meter's real behaviour supports, and the live data
-- in captureLog reflects that. Returns "A", "B", or nil (-> even-split).
--
--   Strategy A WINS  if >= 5 distinct Expired snapshots were captured (i.e. the
--                    meter spawned a discrete session per round, as Strategy A
--                    assumes). 5 not 6 tolerates one missed PostRound capture.
--   Strategy B WINS  if a single Current session was seen all match (stable
--                    dmSessionId) AND its cumulative trail is monotonic-ish
--                    (no large drops -> small drops clamp later), across >= 5
--                    rounds. This is the world where the meter keeps ONE
--                    continuous session, refuting Strategy A.
--   NEITHER          -> nil; caller falls back to EVEN_SPLIT.
--
-- If BOTH somehow qualify (should not happen — the meter behaves one way),
-- Strategy A is preferred because a direct per-round snapshot needs no delta
-- arithmetic and so carries less compounding error. This tie-break is NOT a
-- demotion of B; it only matters in the impossible-both case.
-- --------------------------------------------------------------------------
function CombatTracker:selectCaptureStrategy(captureLog)
    if type(captureLog) ~= "table" then return nil end

    -- --- evaluate Strategy A: count distinct Expired snapshots ------------
    local expiredCount, seenExpiredIds = 0, {}
    for _, rec in pairs(captureLog) do
        local e = rec and rec.expired
        if e and e.hadData then
            local id = e.dmSessionId or 0
            -- distinct == different dmSessionId, OR id 0 (unknowable) counted
            -- once per round since a round with data is itself evidence.
            if id == 0 or not seenExpiredIds[id] then
                expiredCount = expiredCount + 1
                if id ~= 0 then seenExpiredIds[id] = true end
            end
        end
    end
    local strategyAUsable = expiredCount >= 5

    -- --- evaluate Strategy B: single stable Current session, monotonic ----
    local currentRounds, currentId, idStable = 0, nil, true
    local lastCum, monotonicIsh = nil, true
    -- iterate in round order so the cumulative trail is checked in sequence
    for ri = 1, 12 do
        local rec = captureLog[ri]
        local c = rec and rec.current
        if c and c.hadData then
            currentRounds = currentRounds + 1
            if currentId == nil then
                currentId = c.dmSessionId
            elseif c.dmSessionId ~= currentId then
                -- EDGE CASE: Current session ID changed mid-match -> the meter
                -- did NOT keep one continuous session -> Strategy B is invalid.
                idStable = false
            end
            if lastCum ~= nil and c.cumDamageDone < lastCum then
                -- a cumulative reading went DOWN: the meter reset mid-match.
                -- One small dip is tolerable (the delta clamps to 0 later); a
                -- gross drop means the cumulative trail is unusable.
                monotonicIsh = false
            end
            lastCum = c.cumDamageDone
        end
    end
    local strategyBUsable = idStable and monotonicIsh and currentRounds >= 5

    -- --- decide -----------------------------------------------------------
    if strategyAUsable then return "A" end   -- tie-break favours A (see above)
    if strategyBUsable then return "B" end
    return nil                               -- neither -> even split
end

-- --------------------------------------------------------------------------
-- resolveRoundsFromExpiredSnapshots(captureLog): STRATEGY A resolver.
-- Each round's Expired snapshot IS that round's damage — copy it through.
-- Returns a uniform per-round SHAPE table { [roundIndex] = { damageDone=,
-- healingDone=, damageTaken=, dmSessionId= } } consumed by _applyScaledFusion.
-- --------------------------------------------------------------------------
function CombatTracker:resolveRoundsFromExpiredSnapshots(captureLog)
    local shape = {}
    if type(captureLog) ~= "table" then return shape end
    for ri, rec in pairs(captureLog) do
        local e = rec and rec.expired
        if e then
            shape[ri] = {
                damageDone  = e.damageDone  or 0,
                healingDone = e.healingDone or 0,
                damageTaken = e.damageTaken or 0,
                dmSessionId = e.dmSessionId,
            }
        end
    end
    return shape
end

-- --------------------------------------------------------------------------
-- resolveRoundsFromCurrentDeltas(captureLog): STRATEGY B resolver.
-- The Current session is cumulative across the whole match, so round N's
-- damage = (cumulative at end of round N) - (cumulative at end of round N-1).
--
-- Strategy B edge cases, handled inline:
--   * FIRST ROUND: there is no round 0 to subtract — round 1's delta IS its
--     first cumulative reading (delta against an implicit 0 baseline).
--   * NEGATIVE DELTA: if cumulative went DOWN (the meter reset mid-match), the
--     raw subtraction is negative. A round cannot do negative damage -> CLAMP
--     the delta to 0. selectCaptureStrategy already rejects a grossly
--     non-monotonic trail; this clamp is the belt-and-braces for a small dip.
--   * MISSING ROUND IN THE MIDDLE: if round N-1 has no Current reading, the
--     delta for round N is taken against the most recent PRIOR reading that
--     does exist (carry-forward baseline), so a single dropped capture does
--     not zero out two rounds.
-- Returns the same uniform per-round SHAPE table shape as the Strategy A
-- resolver, so _applyScaledFusion treats both identically.
-- --------------------------------------------------------------------------
function CombatTracker:resolveRoundsFromCurrentDeltas(captureLog)
    local shape = {}
    if type(captureLog) ~= "table" then return shape end

    -- prevCum* hold the last KNOWN cumulative readings (carry-forward baseline,
    -- starting at 0 so round 1's delta == round 1's first cumulative reading).
    local prevDmg, prevHeal, prevTaken = 0, 0, 0
    for ri = 1, 12 do
        local rec = captureLog[ri]
        local c = rec and rec.current
        if c then
            local rawDmg   = (c.cumDamageDone  or 0) - prevDmg
            local rawHeal  = (c.cumHealingDone or 0) - prevHeal
            local rawTaken = (c.cumDamageTaken or 0) - prevTaken
            shape[ri] = {
                -- EDGE CASE: negative delta -> meter reset -> clamp to 0.
                damageDone  = (rawDmg   > 0) and rawDmg   or 0,
                healingDone = (rawHeal  > 0) and rawHeal  or 0,
                damageTaken = (rawTaken > 0) and rawTaken or 0,
                dmSessionId = c.dmSessionId,
            }
            -- advance the carry-forward baseline to this round's cumulative.
            prevDmg, prevHeal, prevTaken =
                c.cumDamageDone or prevDmg,
                c.cumHealingDone or prevHeal,
                c.cumDamageTaken or prevTaken
        end
        -- if c is nil: leave the baseline unchanged so the NEXT present round
        -- deltas against the last known reading (carry-forward).
    end
    return shape
end

-- FuseSoloShuffleRoundDamage(session): the core orchestrator. Selects a
-- strategy, resolves per-round SHAPE with the matching resolver, then runs the
-- ONE shared scaling step. Writes session.arena.rounds[i].{damageDone,...} and
-- a session.arena.rounds[i].fusion provenance block. Returns the method used.
--
-- Edge cases handled explicitly:
--   (A) scoreboard read failed / no player row  -> RAW_SNAPSHOT_UNSCALED
--                                                  (or NONE if no SHAPE).
--   (B) SHAPE sum is 0, or NEITHER strategy
--       qualified (selectCaptureStrategy -> nil) -> EVEN_SPLIT of scoreboard.
--   (C) a single round's SHAPE is 0 but
--       others are non-zero                     -> that round legitimately gets
--                                                  0 from the scaled share; it
--                                                  is NOT back-filled — a real
--                                                  0-damage round is possible.
--   (D) SHAPE count != completed-round count    -> scale only over rounds that
--       (leaver / partial match)                   HAVE SHAPE; missing rounds
--                                                  stay 0 + method NONE.
--   (E) scoreboard total < sum of SHAPE (DM
--       over-reported pets/absorbs)             -> still scales (ratio < 1);
--                                                  ratio is uncapped downward.
function CombatTracker:FuseSoloShuffleRoundDamage(session)
    if not session or not session.arena or not session.arena.rounds then
        return Constants.ROUND_FUSION_METHOD.NONE
    end

    local dmSvc = ns and ns.Addon and ns.Addon:GetModule("DamageMeterService")
    local captureLog = (dmSvc and dmSvc:GetSoloShuffleCaptureLog()) or {}
    local rounds = session.arena.rounds

    -- --- STEP 1: pick the strategy the live capture actually supports -----
    local strategy = self:selectCaptureStrategy(captureLog)

    -- --- STEP 2: resolve per-round SHAPE with the matching resolver -------
    local shape, method, basis
    if strategy == "A" then
        shape  = self:resolveRoundsFromExpiredSnapshots(captureLog)
        method = Constants.ROUND_FUSION_METHOD.SCALED_FROM_EXPIRED
        basis  = Constants.ROUND_FUSION_STRATEGY.EXPIRED_SNAPSHOT
    elseif strategy == "B" then
        shape  = self:resolveRoundsFromCurrentDeltas(captureLog)
        method = Constants.ROUND_FUSION_METHOD.SCALED_FROM_DELTA
        basis  = Constants.ROUND_FUSION_STRATEGY.CURRENT_DELTA
    else
        shape  = {}  -- neither strategy usable -> even-split path below
        method = nil
        basis  = Constants.ROUND_FUSION_STRATEGY.NONE
    end
    session.arena.fusionStrategy = basis

    -- --- gather SHAPE sum / count (strategy-agnostic) --------------------
    local shapeSum, shapeCount = 0, 0
    for _, r in ipairs(rounds) do
        local s = shape[r.roundIndex]
        if s then
            shapeCount = shapeCount + 1
            shapeSum = shapeSum + (s.damageDone or 0)
        end
    end

    -- --- gather MAGNITUDE: authoritative whole-match scoreboard total -----
    -- Reuse the EXISTING accessor rather than re-walking postMatchScores.
    local scoreboardTotal = nil
    if dmSvc and dmSvc.GetScoreboardPlayerDamage then
        scoreboardTotal = dmSvc:GetScoreboardPlayerDamage(session)
    end
    local haveScoreboard = type(scoreboardTotal) == "number" and scoreboardTotal > 0

    -- --- edge case (A): no scoreboard magnitude --------------------------
    if not haveScoreboard then
        if shapeCount == 0 then
            self:_applyScaledFusion(rounds, shape, 1.0,
                Constants.ROUND_FUSION_METHOD.NONE, basis)
            return Constants.ROUND_FUSION_METHOD.NONE
        end
        -- Keep raw SHAPE magnitudes; mark them unverified.
        self:_applyScaledFusion(rounds, shape, 1.0,
            Constants.ROUND_FUSION_METHOD.RAW_SNAPSHOT_UNSCALED, basis)
        return Constants.ROUND_FUSION_METHOD.RAW_SNAPSHOT_UNSCALED
    end

    -- --- edge case (B): no usable SHAPE -> EVEN_SPLIT --------------------
    -- Reached when selectCaptureStrategy returned nil (NEITHER A nor B), or the
    -- chosen strategy's SHAPE summed to 0. Even-split keeps the match-total
    -- honest. SPIKE: a nil strategy is the expected outcome if the spike shows
    -- the meter behaves in some THIRD way neither A nor B anticipated.
    if shapeSum <= 0 then
        local completed = 0
        for _, r in ipairs(rounds) do
            if r.completionState == nil or r.completionState == "complete"
               or r.irregular ~= true then
                completed = completed + 1
            end
        end
        if completed <= 0 then completed = #rounds end
        local perRound = (completed > 0) and (scoreboardTotal / completed) or 0
        for _, r in ipairs(rounds) do
            r.damageDone = perRound
            r.fusion = {
                method     = Constants.ROUND_FUSION_METHOD.EVEN_SPLIT,
                confidence = Constants.ROUND_FUSION_CONFIDENCE.even_split,
                basis      = Constants.ROUND_FUSION_STRATEGY.NONE,
                scaleRatio = nil,
                scoreboardTotal = scoreboardTotal,
            }
        end
        return Constants.ROUND_FUSION_METHOD.EVEN_SPLIT
    end

    -- --- STEP 3: the ONE shared scaling step -----------------------------
    -- ratio distributes the authoritative total across rounds in proportion to
    -- each round's resolved SHAPE. Sum of scaled values == scoreboard total
    -- (modulo float error, < 1 and irrelevant for damage counts). This SAME
    -- formula and SAME _applyScaledFusion path serve Strategy A and Strategy B
    -- identically — the only thing that differs upstream is which resolver
    -- produced `shape`. Scaling is never duplicated per strategy.
    local ratio = scoreboardTotal / shapeSum
    self:_applyScaledFusion(rounds, shape, ratio, method, basis)
    return method
end

-- _applyScaledFusion: THE SHARED SCALING STEP. Apply a scale ratio to every
-- round that has resolved SHAPE, and stamp the fusion provenance block.
-- Strategy-agnostic — `shape` has the same form whether it came from
-- resolveRoundsFromExpiredSnapshots or resolveRoundsFromCurrentDeltas. Rounds
-- with no SHAPE stay at 0 with method NONE (edge case D).
function CombatTracker:_applyScaledFusion(rounds, shape, ratio, method, basis)
    local confidence = Constants.ROUND_FUSION_CONFIDENCE[method]
        or Constants.METRIC_CONFIDENCE.UNKNOWN
    for _, r in ipairs(rounds) do
        local s = shape[r.roundIndex]
        if s then
            r.damageDone      = (s.damageDone  or 0) * ratio
            r.healingDone     = (s.healingDone or 0) * ratio
            r.damageTaken     = (s.damageTaken or 0) * ratio
            r.fusion = {
                method      = method,
                -- `basis` distinguishes which strategy fed this number:
                -- "expired_session_snapshot" (A) vs "current_session_delta" (B).
                basis       = basis or Constants.ROUND_FUSION_STRATEGY.NONE,
                confidence  = confidence,
                scaleRatio  = ratio,
                rawSnapshot = {
                    damageDone  = s.damageDone  or 0,
                    healingDone = s.healingDone or 0,
                    damageTaken = s.damageTaken or 0,
                },
                dmSessionId = s.dmSessionId,
            }
        else
            -- No SHAPE for this round — leave the hardcoded 0 in place.
            r.fusion = {
                method     = Constants.ROUND_FUSION_METHOD.NONE,
                basis      = Constants.ROUND_FUSION_STRATEGY.NONE,
                confidence = Constants.METRIC_CONFIDENCE.UNKNOWN,
            }
        end
    end
end


-- ============================================================================
-- SECTION 3 — Lifecycle hooks  (where the two sections above get called)
-- ----------------------------------------------------------------------------
-- These are thin shims showing the EXACT integration points. In the real patch
-- the bodies are inlined into the cited existing functions.
-- ============================================================================

-- HOOK 1: round end SHAPE capture (records BOTH Strategy A and B signals).
-- INTEGRATION POINT: ArenaRoundTracker:EndRound (ArenaRoundTracker.lua:318),
-- inside the existing `if matchRecord.subcontext == SOLO_SHUFFLE` block at
-- ArenaRoundTracker.lua:333. EndRound already runs at "pvp_match_complete" and
-- per-round boundaries; the SHAPE read must happen here, NOT in CLEU.
--
-- SPIKE: EndRound currently fires from CombatTracker at pvp_match_complete only
-- (CombatTracker.lua:3009). For per-round capture we ALSO need a hook on the
-- PostRound transition. PVP_MATCH_STATE_CHANGED is already routed to
-- HandlePvpMatchStateChanged (Events.lua:99, CombatTracker.lua:3228). The spike
-- must confirm: (a) PostRound == match state value 4; (b) BOTH the Expired and
-- the Current DM session types are readable (out of combat) at that instant.
-- If yes, call the shim below from HandlePvpMatchStateChanged when the new
-- state == PostRound. CaptureSoloShuffleRoundSnapshot records both signals in
-- one call, so the hook is strategy-agnostic — no rewiring once the spike picks.
function CombatTracker_HandlePostRound_shim(roundIndex)
    -- SPIKE: only call when GetActiveMatchState() transitions INTO PostRound(4).
    local dmSvc = ns and ns.Addon and ns.Addon:GetModule("DamageMeterService")
    if dmSvc and dmSvc.CaptureSoloShuffleRoundSnapshot then
        dmSvc:CaptureSoloShuffleRoundSnapshot(roundIndex)
    end
end

-- HOOK 2: post-match fusion.
-- INTEGRATION POINT: CombatTracker:HarvestPostMatchData (CombatTracker.lua:3018),
-- AFTER `session.postMatchScores = scores` is set (CombatTracker.lua:3046).
-- HarvestPostMatchData runs from HandlePvpMatchInactive (CombatTracker.lua:3209)
-- — the only place GetScoreInfo is non-secret. Fusion must run here, before
-- FinalizeSession at CombatTracker.lua:3218 persists the session.
function CombatTracker_HarvestPostMatchData_fusionTail(session)
    if not session then return end
    if session.subcontext ~= "solo_shuffle" then return end  -- Constants.SUBCONTEXT.SOLO_SHUFFLE
    local tracker = ns and ns.Addon and ns.Addon:GetModule("CombatTracker")
    if tracker and tracker.FuseSoloShuffleRoundDamage then
        tracker:FuseSoloShuffleRoundDamage(session)
    end
end


-- ============================================================================
-- SECTION 4 — ArenaRoundTracker export change
-- ----------------------------------------------------------------------------
-- TARGET: ArenaRoundTracker:CopyStateIntoSession, the roundEntry builder at
-- ArenaRoundTracker.lua:1053-1068. Currently damageDone/healingDone/damageTaken
-- are LITERAL 0. They must stay 0 HERE (CopyStateIntoSession runs at
-- FinalizeSession, which for Solo Shuffle is per-round and the scoreboard is
-- not yet harvested) — fusion writes them later in HarvestPostMatchData.
--
-- The ONLY change to that builder: add an empty `fusion` placeholder so the
-- field exists in the schema from creation, and so a session persisted before
-- fusion runs has a well-defined (UNKNOWN) provenance instead of a nil hole.
-- The placeholder carries `basis = NONE` too, so a pre-fusion session also has
-- a defined strategy provenance (not nil) regardless of A vs B.
--
--   roundEntry.fusion = {
--       method     = Constants.ROUND_FUSION_METHOD.NONE,
--       basis      = Constants.ROUND_FUSION_STRATEGY.NONE,
--       confidence = Constants.METRIC_CONFIDENCE.UNKNOWN,
--   }
--
-- Skeleton illustration of the amended builder fragment:
local function buildRoundEntry_skeleton(r)
    return {
        roundIndex  = r.roundIndex,
        roundKey    = r.roundKey,
        damageDone  = 0,   -- filled by FuseSoloShuffleRoundDamage post-match
        healingDone = 0,   -- filled by FuseSoloShuffleRoundDamage post-match
        damageTaken = 0,   -- filled by FuseSoloShuffleRoundDamage post-match
        duration    = r.duration or 0,
        fusion = {         -- NEW: provenance placeholder, upgraded post-match
            method     = Constants.ROUND_FUSION_METHOD.NONE,
            basis      = Constants.ROUND_FUSION_STRATEGY.NONE,
            confidence = Constants.METRIC_CONFIDENCE.UNKNOWN,
        },
    }
end


-- ============================================================================
-- SECTION 5 — Edge-case summary (mirrors SECTION 1 & 2 inline comments)
-- ----------------------------------------------------------------------------
-- SHARED (apply to whichever strategy is selected):
--  (A) Scoreboard read fails           -> RAW_SNAPSHOT_UNSCALED (LOW) or NONE.
--  (B) SHAPE sum is 0, or NEITHER A nor
--      B qualified                     -> EVEN_SPLIT of scoreboard (LOW).
--  (C) One round's SHAPE is 0          -> scaled share is 0; NOT back-filled
--                                         (a real zero-damage round is valid).
--  (D) SHAPE count < round count       -> scale only resolved rounds; the
--                                         rest stay 0 / method NONE.
--  (E) scoreboard < SHAPE sum          -> ratio < 1; applied uncapped downward.
--  (F) duplicate PostRound event       -> _recordRoundSnapshot is idempotent
--                                         (critical for B: a doubled Current
--                                         reading would corrupt the delta chain).
--  (G) match abandoned mid-round       -> FuseSoloShuffleRoundDamage may not
--                                         run; rounds keep 0 + method NONE from
--                                         the SECTION 4 placeholder.
--
-- STRATEGY A (expired_session_snapshot) specific:
--  (A1) Expired session purged before
--       PostRound fires                -> that round has no `expired` capture;
--                                         counts against the >=5 threshold in
--                                         selectCaptureStrategy.
--  (A2) Expired session is actually
--       cumulative (spike refutes A)   -> Expired counts drop below 5 / data
--                                         looks wrong; B is selected instead.
--
-- STRATEGY B (current_session_delta) specific:
--  (B1) NEGATIVE delta (meter reset
--       mid-match)                     -> delta CLAMPED to 0 in
--                                         resolveRoundsFromCurrentDeltas; a
--                                         gross drop also fails the
--                                         monotonic-ish check -> B rejected.
--  (B2) Current session ID CHANGES
--       mid-match                      -> the meter did not keep one
--                                         continuous session -> B marked
--                                         UNAVAILABLE by selectCaptureStrategy.
--  (B3) FIRST round's delta            -> no round 0 to subtract; round 1's
--                                         delta IS its first cumulative reading
--                                         (implicit 0 baseline).
--  (B4) A middle round's Current read
--       is missing                     -> next present round deltas against the
--                                         last KNOWN cumulative (carry-forward
--                                         baseline) so one drop does not zero
--                                         two rounds.
-- ============================================================================


-- ============================================================================
-- SECTION 6 — Schema migration  (TARGET FILE: CombatStore.lua migrations)
-- ----------------------------------------------------------------------------
-- SCHEMA_VERSION 10 -> 11. Migration is PURELY ADDITIVE — no destructive edits.
--
--   For every persisted session with subcontext == SOLO_SHUFFLE and a
--   session.arena.rounds array: for each round entry lacking a `fusion` field,
--   add  { method = ROUND_FUSION_METHOD.NONE,
--          confidence = METRIC_CONFIDENCE.UNKNOWN }.
--   Existing damageDone/healingDone/damageTaken (all 0 in v10 data) are left
--   untouched — historical Solo Shuffle data cannot be retroactively fused
--   (the C_DamageMeter Expired sessions are long gone), so old rounds honestly
--   keep 0 + UNKNOWN provenance.
--
-- Skeleton of the migration step:
local function migrate_v10_to_v11(db)
    if not db or not db.sessions then return end
    for _, session in pairs(db.sessions) do
        local arena = session.arena
        if arena and arena.rounds then
            for _, r in ipairs(arena.rounds) do
                if r.fusion == nil then
                    r.fusion = {
                        method     = Constants.ROUND_FUSION_METHOD.NONE,
                        basis      = Constants.ROUND_FUSION_STRATEGY.NONE,
                        confidence = Constants.METRIC_CONFIDENCE.UNKNOWN,
                    }
                end
            end
        end
    end
    db.schemaVersion = 11
end


-- ============================================================================
-- SECTION 7 — Design notes & provenance (two co-equal strategies)
-- ----------------------------------------------------------------------------
-- STRATEGY PROVENANCE:
--   * Strategy A ("expired_session_snapshot"). Snapshot the newest
--     Expired C_DamageMeter session at each PostRound; each snapshot IS that
--     round's damage if the meter spawns a discrete session per round.
--   * Strategy B ("current_session_delta"). If the meter keeps ONE
--     continuous Current session, snapshot its cumulative total at each
--     PostRound and difference consecutive readings into per-round damage.
--   Both are FIRST-CLASS. The capture step records both signals every round;
--   selectCaptureStrategy() picks the one the live data supports; the SAME
--   post-match scaling (ratio = scoreboardTotal / sum) is then applied. The
--   spike harness probes for both, so one spike run resolves A vs B.
--
-- CONFIDENCE & BASIS:
--   1. A fused per-round value is at best "estimated", NEVER "high" — this
--      holds for BOTH Strategy A and Strategy B. Strategy A's SHAPE is
--      unverified (the per-round-session hypothesis); Strategy B compounds
--      delta arithmetic on a cumulative trail. The MAGNITUDE is whole-match in
--      both cases. So the per-round split is inherently an approximation.
--      ROUND_FUSION_CONFIDENCE maps scaled_from_expired AND scaled_from_delta
--      to ESTIMATED — neither maps to HIGH.
--   2. Each round's fusion block carries a `basis` string that distinguishes
--      the strategies for the spike post-mortem and any downstream UI:
--      "expired_session_snapshot" (A) vs "current_session_delta" (B), or
--      "none" when even-split / unresolved.
--
-- INTEGRATION GUARDRAILS (apply regardless of which strategy wins):
--   3. DO NOT add a new IMPORT_STATUS for fused per-round values. IMPORT_STATUS
--      is SESSION-scoped (it rates session.importedTotals authority). A fused
--      per-round number is a sub-session datum and belongs under a per-round
--      `fusion` block carrying its own METRIC_CONFIDENCE. Overloading
--      IMPORT_STATUS would corrupt ApplyScoreboardAnchorIfNeeded's authority
--      logic (CombatTracker.lua:1655 keys on importedTotals.totalAuthority).
--   4. DO NOT make fusion run inside FinalizeSession. For Solo Shuffle,
--      FinalizeSession fires per ROUND and the whole-match scoreboard is not
--      yet harvested at that point (HarvestPostMatchData runs later, at
--      HandlePvpMatchInactive). Fusion MUST be a post-match tail in
--      HarvestPostMatchData. A design that fuses in FinalizeSession will always
--      read a nil scoreboard and silently even-split everything.
--   5. DO NOT reuse the existing scoreboard ANCHOR for Solo Shuffle by removing
--      the :1647 early-return. The anchor assigns the WHOLE total to ONE
--      session; Solo Shuffle needs DISTRIBUTION. They share the source
--      accessor (GetScoreboardPlayerDamage) but are different operations. Keep
--      the anchor untouched; fusion is additive.
--   6. The whole feature is gated on an UNVERIFIED in-game spike. Any design
--      that presents per-round fusion as a finished, trustworthy number
--      without the EVEN_SPLIT / RAW_SNAPSHOT_UNSCALED degradation path is
--      over-claiming. selectCaptureStrategy returning nil (NEITHER A nor B) is
--      a designed-for outcome, not a bug.
-- ============================================================================

return {
    Constants                       = Constants,
    DamageMeterService              = DamageMeterService,
    CombatTracker                   = CombatTracker,
    buildRoundEntry_skeleton        = buildRoundEntry_skeleton,
    migrate_v10_to_v11              = migrate_v10_to_v11,
}
