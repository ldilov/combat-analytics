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

-- ---------------------------------------------------------------------------
-- T066: ExportDiagnosticSession — human-readable multi-line diagnostic dump.
-- ---------------------------------------------------------------------------
function ExportSerializer.ExportDiagnosticSession(session)
    if not session then return "[CA] No session data." end

    local lines = {}
    local function add(text) lines[#lines + 1] = text end
    local function sep()     lines[#lines + 1] = "---" end

    -- Session header
    add(string.format("[CombatAnalytics Diagnostic — Schema v%d]", Constants.SCHEMA_VERSION or 8))
    add(string.format("Session ID : %s", session.id or "unknown"))
    add(string.format("Context    : %s%s",
        session.context or "unknown",
        session.subcontext and (":" .. session.subcontext) or ""))
    add(string.format("Result     : %s", session.result or "unknown"))
    add(string.format("Duration   : %.1fs", session.duration or 0))
    local opp = session.primaryOpponent
    if opp then
        add(string.format("Opponent   : %s (%s %s)",
            opp.name or opp.guid or "unknown",
            opp.className or "",
            opp.specName  or ""))
    end
    sep()

    -- Import block
    local imp = session.importedTotals
    if imp then
        add("DAMAGE IMPORT")
        add(string.format("  importStatus   : %s", tostring(imp.importStatus   or "nil")))
        add(string.format("  totalAuthority : %s", tostring(imp.totalAuthority or "nil")))
        add(string.format("  damageDone     : %s", tostring(imp.damageDone     or 0)))
        local diag = imp.importDiagnostics
        if diag then
            add("  -- diagnostics --")
            add(string.format("  baselineSessionId  : %s", tostring(diag.baselineSessionId  or "nil")))
            add(string.format("  selectedCandidateId: %s", tostring(diag.selectedCandidateId or "nil")))
            add(string.format("  selectedDmType     : %s", tostring(diag.selectedDmType     or "nil")))
            add(string.format("  sourceResolutionPath:%s", tostring(diag.sourceResolutionPath or "nil")))
            add(string.format("  durationDelta      : %s", tostring(diag.durationDelta       or "nil")))
            add(string.format("  opponentFitScore   : %s", tostring(diag.opponentFitScore    or "nil")))
            add(string.format("  signalScore        : %s", tostring(diag.signalScore         or "nil")))
            add(string.format("  fallbackUsed       : %s", tostring(diag.fallbackUsed        or "nil")))
            add(string.format("  failureReason      : %s", tostring(diag.failureReason       or "nil")))
            if diag.candidateIds and #diag.candidateIds > 0 then
                local _ids = {}
                for _, _id in ipairs(diag.candidateIds) do _ids[#_ids + 1] = tostring(_id) end
                add(string.format("  candidateIds       : [%s]", table.concat(_ids, ", ")))
            end
        end
    else
        add("DAMAGE IMPORT : (no importedTotals)")
    end
    sep()

    -- Capture quality block
    local cq = session.captureQuality
    if cq then
        add("CAPTURE QUALITY")
        for k, v in pairs(cq) do
            add(string.format("  %-24s: %s", k, tostring(v)))
        end
    end
    sep()

    -- Snapshot block
    local snap = session.playerSnapshot
    if snap then
        add("PLAYER SNAPSHOT")
        add(string.format("  specId        : %s", tostring(snap.specId        or "nil")))
        add(string.format("  buildHash     : %s", tostring(snap.buildHash     or "nil")))
        add(string.format("  itemLevel     : %s", tostring(snap.itemLevel     or "nil")))
        local sp = snap.statProfile
        if sp then
            add(string.format("  statFreshness : %s", tostring(sp.snapshotFreshness or "nil")))
            add(string.format("  critPct       : %s", tostring(sp.critPct           or "nil")))
            add(string.format("  hastePct      : %s", tostring(sp.hastePct          or "nil")))
            add(string.format("  masteryPct    : %s", tostring(sp.masteryPct        or "nil")))
        else
            add("  statProfile   : (no stat profile captured)")
        end
    end
    sep()

    -- Arena block
    local ar = session.arena
    if ar and (ar.matchKey or ar.roundKey) then
        add("ARENA")
        add(string.format("  matchKey  : %s", tostring(ar.matchKey  or "nil")))
        add(string.format("  roundKey  : %s", tostring(ar.roundKey  or "nil")))
        local rosterCount = ar.roster and #ar.roster or 0
        add(string.format("  rosterSlots : %d", rosterCount))
    end
    sep()

    -- Summary line
    local rawCount = session.rawEvents and #session.rawEvents or 0
    add(string.format("Raw events: %d", rawCount))

    return table.concat(lines, "\n")
end

ns.Addon:RegisterModule("ExportSerializer", ExportSerializer)
