-- Insights/InsightsTimeline.lua
-- Pure-logic builder for the "Fight Timeline Read" section of the new
-- Insights tab.
--
-- The UI section renders a 5-node horizontal strip summarising one fight:
--
--   Opener -> First Go -> First Defensive -> First CC -> End
--
-- This module turns a session into the deterministic list of node descriptors
-- the UI then paints. It is side-effect free, never touches SavedVariables,
-- and reads ONLY from session fields that exist without raw CLEU access:
--
--   session.openerFingerprint  -- engagementAt, openerCastCount,
--                                 firstMajorOffensiveRelative,
--                                 firstMajorDefensiveRelative
--   session.duration
--   session.result             -- Constants.SESSION_RESULT.*
--   session.survival.deaths
--
-- Per checkpoint and PLAN.md the section must NOT depend on rawEvents and must
-- degrade gracefully when fields are absent (e.g., very old sessions, sparse
-- characters). When the addon does not yet attribute a `firstCCAt` or a
-- `survival.timeOfDeath`, the corresponding node renders an "unknown" status
-- rather than blanking the whole row.

local _, ns = ...
ns = ns or {}

local InsightsTimeline = {}

-- ---------------------------------------------------------------------------
-- Node keys + ordering.
-- ---------------------------------------------------------------------------
local NODE = {
    OPENER = "opener",
    GO1    = "go1",
    DEF1   = "def1",
    CC1    = "cc1",
    END    = "end_",
}

local NODE_ORDER = {
    NODE.OPENER,
    NODE.GO1,
    NODE.DEF1,
    NODE.CC1,
    NODE.END,
}

local NODE_LABEL = {
    [NODE.OPENER] = "Opener",
    [NODE.GO1]    = "First Go",
    [NODE.DEF1]   = "First Defensive",
    [NODE.CC1]    = "First CC",
    [NODE.END]    = "End",
}

-- Reason codes that belong to each node's drilldown row.
local NODE_REASONS = {
    [NODE.OPENER] = {
        SUBOPTIMAL_OPENER_SEQUENCE = true,
        DUMMY_OPENER_VARIANCE      = true,
    },
    [NODE.GO1] = {
        LATE_FIRST_GO         = true,
        WEAK_BURST_FOR_CONTEXT = true,
        PROC_WINDOWS_UNDERUSED = true,
    },
    [NODE.DEF1] = {
        DEFENSIVE_DRIFT          = true,
        DEFENSIVE_UNUSED_ON_LOSS = true,
        REACTIVE_DEFENSIVE_LATE  = true,
        DIED_WITH_DEFENSIVES     = true,
    },
    [NODE.CC1] = {
        TRINKET_TIMING_POOR     = true,
        HIGH_CC_UPTIME          = true,
        CC_DR_WASTE             = true,
        CC_LATE_TRINKET         = true,
        CC_MISSED_KILL_WINDOW   = true,
        CC_GOOD_TRINKET         = true,
        CC_CHAIN_BREAK          = true,
        CC_HIGH_UPTIME          = true,
        DIED_IN_CC              = true,
    },
    [NODE.END] = {
        HIGH_DAMAGE_TAKEN_VS_OPPONENT = true,
        TILT_WARNING                  = true,
        SPEC_WINRATE_DEFICIT          = true,
        SPEC_WINRATE_STRENGTH         = true,
        COMP_DEFICIT                  = true,
    },
}

-- Status palette key used by the UI layer to pick a color and adjective.
-- "good"    -> green-ish, "on time" / "won"
-- "late"    -> warning,   action present but slow
-- "miss"    -> warning,   action expected but absent
-- "loss"    -> warning,   end node when result == LOST
-- "unknown" -> muted,     data source not available for this session
local STATUS = {
    GOOD    = "good",
    LATE    = "late",
    MISS    = "miss",
    LOSS    = "loss",
    UNKNOWN = "unknown",
}

-- Thresholds (seconds, engagement-relative) for "late" classification.
local LATE_THRESHOLD = {
    [NODE.GO1]  = 5.0,
    [NODE.DEF1] = 6.0,
}

local function safeNumber(v)
    return tonumber(v)
end

local function fmtSeconds(seconds)
    if not seconds then return "--" end
    if seconds < 10 then
        return string.format("%.1fs", seconds)
    end
    return string.format("%.0fs", seconds)
end

local function isLoss(session)
    if not session then return false end
    local r = session.result
    if not r then return false end
    local Constants = ns.Constants
    if Constants and Constants.SESSION_RESULT and Constants.SESSION_RESULT.LOST then
        return r == Constants.SESSION_RESULT.LOST
    end
    return tostring(r):lower() == "lost"
end

local function isWin(session)
    if not session then return false end
    local r = session.result
    if not r then return false end
    local Constants = ns.Constants
    if Constants and Constants.SESSION_RESULT and Constants.SESSION_RESULT.WON then
        return r == Constants.SESSION_RESULT.WON
    end
    return tostring(r):lower() == "won"
end

-- ---------------------------------------------------------------------------
-- Per-node builders
-- ---------------------------------------------------------------------------

local function buildOpener(session)
    local fp = session.openerFingerprint or {}
    local castCount = safeNumber(fp.openerCastCount) or 0
    local engagement = safeNumber(fp.engagementAt)

    if castCount == 0 and (not engagement or engagement == 0) then
        return {
            key      = NODE.OPENER,
            label    = NODE_LABEL[NODE.OPENER],
            status   = STATUS.UNKNOWN,
            valueText = "--",
            detail   = "No opener cast data captured for this session.",
        }
    end

    local status = STATUS.GOOD
    local detail
    if castCount > 0 then
        detail = string.format(
            "%d cast%s recorded in opener window.",
            castCount, castCount == 1 and "" or "s"
        )
    else
        status = STATUS.MISS
        detail = "Engagement detected but no casts recorded in the opener window."
    end

    return {
        key      = NODE.OPENER,
        label    = NODE_LABEL[NODE.OPENER],
        status   = status,
        valueText = engagement and engagement > 0 and string.format("t+%s", fmtSeconds(engagement)) or "start",
        detail   = detail,
    }
end

local function buildOffensive(session)
    local fp = session.openerFingerprint or {}
    local relative = safeNumber(fp.firstMajorOffensiveRelative)
    if not relative then
        return {
            key      = NODE.GO1,
            label    = NODE_LABEL[NODE.GO1],
            status   = STATUS.MISS,
            valueText = "--",
            detail   = "No major offensive cooldown was used during this fight.",
        }
    end

    local status = relative > LATE_THRESHOLD[NODE.GO1] and STATUS.LATE or STATUS.GOOD
    return {
        key      = NODE.GO1,
        label    = NODE_LABEL[NODE.GO1],
        status   = status,
        valueText = fmtSeconds(relative),
        detail   = string.format(
            "First major offensive landed %s after engagement.",
            fmtSeconds(relative)
        ),
    }
end

local function buildDefensive(session)
    local fp = session.openerFingerprint or {}
    local relative = safeNumber(fp.firstMajorDefensiveRelative)
    local survival = session.survival or {}
    local defensivesUsed = safeNumber(survival.defensivesUsed) or 0
    local deaths = safeNumber(survival.deaths) or 0

    if not relative then
        if deaths > 0 and defensivesUsed == 0 then
            return {
                key      = NODE.DEF1,
                label    = NODE_LABEL[NODE.DEF1],
                status   = STATUS.MISS,
                valueText = "--",
                detail   = "Died without using a major defensive cooldown.",
            }
        end
        return {
            key      = NODE.DEF1,
            label    = NODE_LABEL[NODE.DEF1],
            status   = STATUS.UNKNOWN,
            valueText = "--",
            detail   = defensivesUsed > 0
                and string.format("%d defensive use%s recorded but no major cooldown timing data.",
                    defensivesUsed, defensivesUsed == 1 and "" or "s")
                or "No major defensive cooldown timing data for this session.",
        }
    end

    local status = relative > LATE_THRESHOLD[NODE.DEF1] and STATUS.LATE or STATUS.GOOD
    return {
        key      = NODE.DEF1,
        label    = NODE_LABEL[NODE.DEF1],
        status   = status,
        valueText = fmtSeconds(relative),
        detail   = string.format(
            "First major defensive landed %s after engagement.",
            fmtSeconds(relative)
        ),
    }
end

local function buildCC(session)
    -- CC timing data is not currently attributed at session-finalize time
    -- without rawEvents. Show an honest "unknown" rather than fabricating a
    -- number. The drilldown still surfaces any CC-related reason codes.
    local metrics = session.metrics or {}
    local ccUptime = safeNumber(metrics.ccUptime) or safeNumber(metrics.ccDuration)
    if ccUptime and ccUptime > 0 then
        return {
            key      = NODE.CC1,
            label    = NODE_LABEL[NODE.CC1],
            status   = STATUS.GOOD,
            valueText = fmtSeconds(ccUptime),
            detail   = string.format(
                "Total CC uptime %s. (Per-event timing not captured without raw events.)",
                fmtSeconds(ccUptime)
            ),
        }
    end
    return {
        key      = NODE.CC1,
        label    = NODE_LABEL[NODE.CC1],
        status   = STATUS.UNKNOWN,
        valueText = "--",
        detail   = "No crowd-control timing data for this session.",
    }
end

local function buildEnd(session)
    local duration = safeNumber(session.duration)
    local won = isWin(session)
    local lost = isLoss(session)

    local valueText = duration and fmtSeconds(duration) or "--"
    local status, detail
    if won then
        status = STATUS.GOOD
        detail = string.format("Match ended in a win after %s.", duration and fmtSeconds(duration) or "an unknown duration")
    elseif lost then
        status = STATUS.LOSS
        detail = string.format("Match ended in a loss after %s.", duration and fmtSeconds(duration) or "an unknown duration")
    else
        status = STATUS.UNKNOWN
        detail = duration
            and string.format("Match ended after %s. Result unknown.", fmtSeconds(duration))
            or "End-of-match data unavailable."
    end

    return {
        key      = NODE.END,
        label    = NODE_LABEL[NODE.END],
        status   = status,
        valueText = valueText,
        detail   = detail,
    }
end

local NODE_BUILDERS = {
    [NODE.OPENER] = buildOpener,
    [NODE.GO1]    = buildOffensive,
    [NODE.DEF1]   = buildDefensive,
    [NODE.CC1]    = buildCC,
    [NODE.END]    = buildEnd,
}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Build the ordered list of 5 timeline nodes for a session.
--- Always returns 5 entries in canonical order. Missing data degrades the
--- node to status "unknown" or "miss" rather than removing the node.
--- @param session table?  finalised session table (may be nil)
--- @return table  list of node descriptors
function InsightsTimeline.BuildNodes(session)
    local nodes = {}
    if type(session) ~= "table" then
        for i, key in ipairs(NODE_ORDER) do
            nodes[i] = {
                key       = key,
                label     = NODE_LABEL[key],
                status    = STATUS.UNKNOWN,
                valueText = "--",
                detail    = "No session selected.",
            }
        end
        return nodes
    end

    for i, key in ipairs(NODE_ORDER) do
        local builder = NODE_BUILDERS[key]
        nodes[i] = builder(session)
    end
    return nodes
end

--- Return the suggestion reason codes that belong to a node's drilldown.
--- Used by the UI to surface "what coaching notes touch this moment?" when a
--- node is clicked.
function InsightsTimeline.GetReasonsForNode(nodeKey, suggestions)
    local out = {}
    local allowed = NODE_REASONS[nodeKey]
    if not allowed or type(suggestions) ~= "table" then return out end
    for _, s in ipairs(suggestions) do
        if s and s.reasonCode and allowed[s.reasonCode] then
            out[#out + 1] = s
        end
    end
    return out
end

InsightsTimeline.NODE         = NODE
InsightsTimeline.NODE_ORDER   = NODE_ORDER
InsightsTimeline.NODE_LABEL   = NODE_LABEL
InsightsTimeline.NODE_REASONS = NODE_REASONS
InsightsTimeline.STATUS       = STATUS
InsightsTimeline.LATE_THRESHOLD = LATE_THRESHOLD

ns.InsightsTimeline = InsightsTimeline
return InsightsTimeline
