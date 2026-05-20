-- ============================================================================
-- Solo Shuffle per-round C_DamageMeter SPIKE HARNESS  (throwaway diagnostic)
-- ============================================================================
-- PURPOSE
--   Resolve the single unverified assumption blocking the "Solo Shuffle
--   per-round fusion" feature: does each Solo Shuffle round produce its OWN
--   discrete C_DamageMeter session, readable as an `Expired` session during
--   the PostRound intermission?
--
--   This harness ALSO captures the data needed to decide the plan-B path
--   (delta-tracking the `Current` session) if the main hypothesis is false.
--
-- HOW TO USE
--   1. Save this file as its own tiny addon, OR paste the body into any
--      `/run` macro-capable scratch addon. It is NOT part of CombatAnalytics
--      and must NOT be added to the .toc — it is a one-time diagnostic.
--   2. Log in, queue a Solo Shuffle.
--   3. It auto-logs on every PvP match-state change. You can also force a
--      dump at any time with:  /cadmspike
--   4. Play all 6 rounds normally.
--   5. After the match, run:  /cadmspike report
--   6. Copy the chat output (or read SavedVariable `CADMSpikeLog`) and hand
--      it back. The verdict table at the bottom of the report says which
--      implementation path is viable.
--
-- WHAT THE RESULT MEANS
--   * Expired-session-ID set grows by exactly 1 each PostRound
--       -> MAIN HYPOTHESIS CONFIRMED. Per-round snapshot of the newest
--          Expired session works. Build the fusion design as specified.
--   * Only ONE Current session exists and its damage keeps climbing across
--     rounds, no new Expired sessions
--       -> MAIN HYPOTHESIS REFUTED. Plan B: delta-track the Current session
--          (snapshot its cumulative damage at each PostRound, subtract the
--          previous snapshot to get per-round damage). The per-round snapshot
--          column in the report tells you if the deltas are sane.
--   * Sessions return secret values / 0 during PostRound
--       -> Both per-round paths are dead; per-round damage is not feasible,
--          keep the whole-match scoreboard total only.
-- ============================================================================

local ADDON_NAME = ...
CADMSpikeLog = CADMSpikeLog or {}

local frame = CreateFrame("Frame")

-- Safe wrapper: C_DamageMeter shapes are uncertain and may return secret
-- values; never let a read throw.
local function safe(fn, ...)
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
    return nil
end

-- issecretvalue may not exist on every build; guard it.
local function isSecret(v)
    if type(issecretvalue) == "function" then
        local ok, res = pcall(issecretvalue, v)
        if ok then return res end
    end
    return false
end

local function num(v)
    if v == nil or isSecret(v) then return nil end
    if type(v) == "number" then return v end
    return nil
end

-- Snapshot every available C_DamageMeter session right now.
local function snapshotSessions(label)
    local entry = {
        label      = label,
        t          = (type(GetTime) == "function" and GetTime()) or 0,
        matchState = safe(C_PvP and C_PvP.GetActiveMatchState),
        inCombat   = (type(InCombatLockdown) == "function" and InCombatLockdown()) or false,
        sessions   = {},
    }

    if not C_DamageMeter then
        entry.error = "C_DamageMeter namespace absent"
        CADMSpikeLog[#CADMSpikeLog + 1] = entry
        return entry
    end

    local list = safe(C_DamageMeter.GetAvailableCombatSessions)
        or safe(C_DamageMeter.GetAvailableSessions)  -- name fallback
        or {}

    for i, s in ipairs(list) do
        local sid  = s.sessionID or s.sessionId or s.id
        local styp = s.sessionType or s.type
        -- Per-source damage for the player, the actual fill value.
        local dmg
        if C_DamageMeter.GetCombatSessionSourceFromID and sid then
            local src = safe(C_DamageMeter.GetCombatSessionSourceFromID, sid,
                Enum and Enum.DamageMeterType and Enum.DamageMeterType.DamageDone or 0)
            dmg = src and num(src.totalAmount)
        end
        entry.sessions[#entry.sessions + 1] = {
            index    = i,
            id       = tostring(sid),
            typeNum  = styp,
            damage   = dmg,        -- nil = unreadable/secret
        }
    end

    CADMSpikeLog[#CADMSpikeLog + 1] = entry
    return entry
end

local function printEntry(entry)
    print(string.format("|cFF66CCFF[CADMSpike]|r %s  state=%s combat=%s  sessions=%d",
        tostring(entry.label), tostring(entry.matchState),
        tostring(entry.inCombat), #entry.sessions))
    for _, s in ipairs(entry.sessions) do
        print(string.format("   #%d id=%s type=%s damage=%s",
            s.index, s.id, tostring(s.typeNum),
            s.damage and string.format("%d", s.damage) or "nil/secret"))
    end
end

-- Auto-capture on every PvP match-state change (PostRound is the one we want).
frame:RegisterEvent("PVP_MATCH_STATE_CHANGED")
frame:RegisterEvent("PVP_MATCH_COMPLETE")
frame:SetScript("OnEvent", function(_, event)
    local entry = snapshotSessions(event)
    printEntry(entry)
end)

-- Verdict: did the set of distinct Expired session IDs grow across the log?
local function report()
    local EXPIRED = (Enum and Enum.DamageMeterSessionType and Enum.DamageMeterSessionType.Expired) or 2
    local CURRENT = (Enum and Enum.DamageMeterSessionType and Enum.DamageMeterSessionType.Current) or 1
    local expiredIds, currentIdSeen, currentDamageTrail = {}, {}, {}
    local expiredCount = 0
    for _, entry in ipairs(CADMSpikeLog) do
        for _, s in ipairs(entry.sessions) do
            if s.typeNum == EXPIRED and not expiredIds[s.id] then
                expiredIds[s.id] = true
                expiredCount = expiredCount + 1
            end
            if s.typeNum == CURRENT then
                currentIdSeen[s.id] = true
                if s.damage then currentDamageTrail[#currentDamageTrail + 1] = s.damage end
            end
        end
    end
    local distinctCurrentIds = 0
    for _ in pairs(currentIdSeen) do distinctCurrentIds = distinctCurrentIds + 1 end

    print("|cFF66CCFF[CADMSpike]|r ===== REPORT =====")
    print(string.format("   log entries: %d", #CADMSpikeLog))
    print(string.format("   distinct EXPIRED session IDs seen: %d", expiredCount))
    print(string.format("   distinct CURRENT session IDs seen: %d", distinctCurrentIds))
    print(string.format("   CURRENT damage trail: %s",
        #currentDamageTrail > 0 and table.concat(currentDamageTrail, " -> ") or "(none readable)"))
    if expiredCount >= 5 then
        print("   VERDICT: MAIN HYPOTHESIS LIKELY CONFIRMED — per-round Expired snapshots viable.")
    elseif distinctCurrentIds == 1 and #currentDamageTrail >= 2 then
        print("   VERDICT: refuted — one continuous Current session. PLAN B: delta-track Current.")
    else
        print("   VERDICT: inconclusive / data unreadable — paste CADMSpikeLog for analysis.")
    end
end

SLASH_CADMSPIKE1 = "/cadmspike"
SlashCmdList["CADMSPIKE"] = function(msg)
    if msg == "report" then
        report()
    else
        printEntry(snapshotSessions("manual"))
    end
end

print("|cFF66CCFF[CADMSpike]|r loaded. Queue Solo Shuffle; auto-logs each round. "
    .. "/cadmspike to dump now, /cadmspike report after the match.")
