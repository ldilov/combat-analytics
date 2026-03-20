local _, ns = ...

local Helpers = ns.Helpers
local Constants = ns.Constants

local ExportSerializer = {}

local function prettifyToken(value)
    local text = tostring(value or "unknown")
    text = string.gsub(text, "_", " ")
    text = string.lower(text)
    return string.gsub(text, "(%a)([%w']*)", function(first, rest)
        return string.upper(first) .. rest
    end)
end

function ExportSerializer.Serialize(session)
    if not session then return "[CA] No session data." end

    local parts = {}
    parts[#parts + 1] = string.format("[CA v%d]", Constants.SCHEMA_VERSION or 2)

    -- Context
    local ctx = prettifyToken(session.context)
    if session.subcontext then
        ctx = ctx .. ":" .. prettifyToken(session.subcontext)
    end
    parts[#parts + 1] = ctx

    -- Result
    local result = session.result or "unknown"
    if result == Constants.SESSION_RESULT.WON then
        parts[#parts + 1] = "|cff00cc00Won|r"
    elseif result == Constants.SESSION_RESULT.LOST then
        parts[#parts + 1] = "|cffcc0000Lost|r"
    else
        parts[#parts + 1] = prettifyToken(result)
    end

    -- Duration
    if session.duration then
        parts[#parts + 1] = Helpers.FormatDuration(session.duration)
    end

    -- Opponent
    local opponent = session.primaryOpponent
    if opponent then
        local label = opponent.specName or opponent.name or opponent.guid or "Unknown"
        if opponent.className and opponent.specName then
            label = string.format("%s %s", opponent.className, opponent.specName)
        end
        parts[#parts + 1] = "vs " .. label
    end

    -- Damage
    if session.totals and session.totals.damageDone then
        parts[#parts + 1] = Helpers.FormatNumber(session.totals.damageDone) .. " dmg"
    end

    -- Pressure / Burst
    if session.metrics then
        if session.metrics.pressureScore then
            parts[#parts + 1] = string.format("P:%.1f", session.metrics.pressureScore)
        end
        if session.metrics.burstScore then
            parts[#parts + 1] = string.format("B:%.1f", session.metrics.burstScore)
        end
    end

    -- Suggestions
    if session.suggestions and #session.suggestions > 0 then
        local codes = {}
        for i = 1, math.min(3, #session.suggestions) do
            codes[#codes + 1] = session.suggestions[i].reasonCode or "?"
        end
        parts[#parts + 1] = "Hints:" .. table.concat(codes, ",")
    end

    -- Build hash (short)
    local snapshot = session.playerSnapshot
    if snapshot and snapshot.buildHash then
        local short = string.sub(snapshot.buildHash, 1, 8)
        parts[#parts + 1] = "Build:" .. short
    end

    -- Rating change
    if session.ratingSnapshot and session.ratingSnapshot.after then
        local after = session.ratingSnapshot.after
        if after.personalRating then
            local change = ""
            if session.ratingSnapshot.before and session.ratingSnapshot.before.personalRating then
                local diff = after.personalRating - session.ratingSnapshot.before.personalRating
                if diff > 0 then
                    change = string.format(" (+%d)", diff)
                elseif diff < 0 then
                    change = string.format(" (%d)", diff)
                end
            end
            parts[#parts + 1] = string.format("Rating:%d%s", after.personalRating, change)
        end
    end

    return table.concat(parts, " | ")
end

ns.Addon:RegisterModule("ExportSerializer", ExportSerializer)
