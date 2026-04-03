local _, ns = ...

local Helpers = {}

function Helpers.Now()
    return GetTime and GetTime() or 0
end

function Helpers.Round(value, precision)
    local multiplier = 10 ^ (precision or 0)
    return math.floor((value or 0) * multiplier + 0.5) / multiplier
end

function Helpers.Clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

function Helpers.Trim(value)
    if type(value) ~= "string" then
        return value
    end
    -- Use string.match() directly (not value:match()) to avoid metatable __index
    -- on secret strings.  Also pcall-guard: if value is still a secret string
    -- (tostring propagates the taint flag), return as-is rather than crashing.
    local ok, result = pcall(string.match, value, "^%s*(.-)%s*$")
    return ok and result or value
end

function Helpers.IsBlank(value)
    return value == nil or Helpers.Trim(value) == ""
end

function Helpers.CreateSet(list)
    local result = {}
    if not list then
        return result
    end
    for _, item in ipairs(list) do
        result[item] = true
    end
    return result
end

function Helpers.CopyTable(source, deep)
    if type(source) ~= "table" then
        return source
    end

    local copy = {}
    for key, value in pairs(source) do
        if deep and type(value) == "table" then
            copy[key] = Helpers.CopyTable(value, true)
        else
            copy[key] = value
        end
    end
    return copy
end

function Helpers.EnsureTable(root, key)
    root[key] = root[key] or {}
    return root[key]
end

function Helpers.ArrayFind(list, predicate)
    if not list or not predicate then
        return nil
    end
    for index, value in ipairs(list) do
        if predicate(value, index) then
            return value, index
        end
    end
    return nil
end

function Helpers.ArrayRemoveIf(list, predicate)
    if not list or not predicate then
        return 0
    end

    local removed = 0
    for index = #list, 1, -1 do
        if predicate(list[index], index) then
            table.remove(list, index)
            removed = removed + 1
        end
    end
    return removed
end

function Helpers.ArrayKeys(map)
    local keys = {}
    for key in pairs(map or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

function Helpers.StartsWith(value, prefix)
    -- Use string.sub() directly to avoid indexing a potential secret string value.
    return type(value) == "string" and string.sub(value, 1, #prefix) == prefix
end

function Helpers.ContainsIgnoreCase(haystack, needle)
    if type(haystack) ~= "string" or type(needle) ~= "string" then
        return false
    end
    return string.find(string.lower(haystack), string.lower(needle), 1, true) ~= nil
end

function Helpers.GetDateKey(timestamp)
    local value = date("*t", timestamp or time())
    return string.format("%04d-%02d-%02d", value.year, value.month, value.day)
end

function Helpers.GetWeekKey(timestamp)
    local value = date("*t", timestamp or time())
    local week = tonumber(date("%V", timestamp or time()))
    return string.format("%04d-W%02d", value.year, week or 0)
end

function Helpers.ParseDateKey(dateKey)
    local year, month, day = string.match(dateKey or "", "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not year then
        return nil
    end
    return {
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
    }
end

function Helpers.FormatDuration(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    local minutes = math.floor(seconds / 60)
    local remainder = seconds % 60
    return string.format("%d:%02d", minutes, remainder)
end

function Helpers.FormatNumber(value)
    value = tonumber(value) or 0
    if value >= 1000000 then
        return string.format("%.1fm", value / 1000000)
    end
    if value >= 1000 then
        return string.format("%.1fk", value / 1000)
    end
    return tostring(math.floor(value + 0.5))
end

function Helpers.GenerateId(prefix)
    local now = time()
    local randomPart = math.random(100000, 999999)
    return string.format("%s-%d-%d", prefix or "id", now, randomPart)
end

function Helpers.GetFirstKey(map)
    for key in pairs(map or {}) do
        return key
    end
    return nil
end

function Helpers.SafeCall(func, ...)
    if type(func) ~= "function" then
        return false
    end
    return pcall(func, ...)
end

function Helpers.CountMapEntries(map)
    local count = 0
    for _ in pairs(map or {}) do
        count = count + 1
    end
    return count
end

function Helpers.SortByField(list, field, descending)
    table.sort(list, function(left, right)
        local leftValue = left and left[field] or 0
        local rightValue = right and right[field] or 0
        if leftValue == rightValue then
            return tostring(left.id or left.name or "") < tostring(right.id or right.name or "")
        end
        if descending then
            return leftValue > rightValue
        end
        return leftValue < rightValue
    end)
end

function Helpers.ToPercentage(part, total)
    if not total or total <= 0 then
        return 0
    end
    return (part or 0) / total
end

function Helpers.GetResultBucket(result)
    if result == ns.Constants.SESSION_RESULT.WON then
        return "wins"
    end
    if result == ns.Constants.SESSION_RESULT.LOST then
        return "losses"
    end
    return "other"
end

function Helpers.IsStrictPvpContext(context)
    local ctx = ns.Constants.CONTEXT
    return context == ctx.ARENA
        or context == ctx.BATTLEGROUND
        or context == ctx.DUEL
        or context == ctx.WORLD_PVP
end

-- Training dummy sessions stay tagged as training_dummy so benchmark flows
-- remain intact, but we still let them exercise PvP analytics surfaces.
function Helpers.IsPvpAnalyticsContext(context)
    return Helpers.IsStrictPvpContext(context)
        or context == ns.Constants.CONTEXT.TRAINING_DUMMY
end

-- Resolve the best available opponent display name from a session.
-- Walks through primary opponent fields, arena slots, post-match
-- scoreboard, actor table, and duel metadata to find a non-nil
-- human-readable name.
function Helpers.ResolveOpponentName(session, fallback)
    fallback = fallback or "Unknown"
    if session.primaryOpponent then
        local po = session.primaryOpponent
        if po.name then return po.name end
        if po.specName then return po.specName end
        if po.className then return po.className end
    end
    if session.arena and session.arena.slots then
        for _, slot in pairs(session.arena.slots) do
            if slot.name then return slot.name end
            if slot.prepSpecName then return slot.prepSpecName end
        end
    end
    if session.postMatchScores then
        local ApiCompat = ns.ApiCompat
        local myGuid = ApiCompat and ApiCompat.GetPlayerGUID() or nil
        -- Fallback: if entry.guid is nil (couldn't be harvested — secret or
        -- missing at harvest time), check name instead.  Name isn't globally
        -- unique but it's the only remaining signal; it correctly handles the
        -- "played against myself" case where the player's own entry appears
        -- first with a nil GUID but a non-nil name.
        local myName = ApiCompat and ApiCompat.GetPlayerName() or nil
        for _, entry in ipairs(session.postMatchScores) do
            local isPlayer = (myGuid ~= nil and entry.guid == myGuid)
                          or (entry.guid == nil and myName ~= nil and entry.name == myName)
            if not isPlayer and entry.name then
                return entry.name
            end
        end
    end
    -- Walk the actors table for any hostile player with a name.  Prefer the
    -- actor whose GUID matches primaryOpponent (if it exists but had a nil
    -- name) so we pick the right enemy in multi-target sessions.
    if session.actors then
        local ApiCompat = ns.ApiCompat
        local myGuid = ApiCompat and ApiCompat.GetPlayerGUID() or nil
        local poGuid = session.primaryOpponent and session.primaryOpponent.guid or nil
        local bestName = nil
        for guid, actor in pairs(session.actors) do
            if actor.name and actor.isHostile and actor.isPlayer and guid ~= myGuid then
                if guid == poGuid then
                    return actor.name
                end
                bestName = bestName or actor.name
            end
        end
        if bestName then
            return bestName
        end
    end
    -- Duel opponent name captured from DUEL_REQUESTED event.
    if session.duelOpponentName then
        return session.duelOpponentName
    end
    return fallback
end

ns.Helpers = Helpers
