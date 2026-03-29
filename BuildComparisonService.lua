local _, ns = ...

local Constants = ns.Constants

local BuildComparisonService = {}

-- ──────────────────────────────────────────────────────────────────────────────
-- Internal helpers
-- ──────────────────────────────────────────────────────────────────────────────

local function getStore()
    return ns.Addon:GetModule("CombatStore")
end

local function getCatalog()
    return ns.Addon:GetModule("BuildCatalogService")
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Scope helpers (T014)
-- ──────────────────────────────────────────────────────────────────────────────

-- Serialize a ComparisonScope to a stable string key for caching / persistence.
function BuildComparisonService:BuildScopeKey(scope)
    scope = scope or {}
    return table.concat({
        scope.characterKey    or "",
        tostring(scope.specId or ""),
        scope.context         or "",
        scope.bracket         or "",
        tostring(scope.opponentClassId  or ""),
        tostring(scope.opponentSpecId   or ""),
        tostring(scope.dateFrom         or ""),
        tostring(scope.dateTo           or ""),
    }, ":")
end

-- Return the default scope for characterKey + specId.
function BuildComparisonService:GetDefaultScope(characterKey, specId)
    return {
        characterKey   = characterKey,
        specId         = specId,
        context        = nil,
        bracket        = nil,
        opponentClassId  = nil,
        opponentSpecId   = nil,
        dateFrom       = nil,
        dateTo         = nil,
    }
end

-- Return the last-used scope for the character, or the default if none saved.
function BuildComparisonService:GetLastScope(characterKey, specId)
    local store = getStore()
    if store then
        local db = store:GetDB()
        if db.characterPrefs and characterKey and db.characterPrefs[characterKey] then
            local raw = db.characterPrefs[characterKey].lastComparatorScope
            if raw then
                -- Deserialize the colon-separated scope key back to fields.
                local parts = {}
                for segment in (raw .. ":"):gmatch("([^:]*):" ) do
                    parts[#parts + 1] = segment
                end
                if #parts >= 8 then
                    return {
                        characterKey     = parts[1] ~= "" and parts[1] or characterKey,
                        specId           = tonumber(parts[2]) or specId,
                        context          = parts[3] ~= "" and parts[3] or nil,
                        bracket          = parts[4] ~= "" and parts[4] or nil,
                        opponentClassId  = tonumber(parts[5]) or nil,
                        opponentSpecId   = tonumber(parts[6]) or nil,
                        dateFrom         = tonumber(parts[7]) or nil,
                        dateTo           = tonumber(parts[8]) or nil,
                    }
                end
            end
        end
    end
    return self:GetDefaultScope(characterKey, specId)
end

-- Persist the active scope to characterPrefs for restoration on next login.
function BuildComparisonService:SaveScope(characterKey, specId, scope)
    if not characterKey or not scope then return end
    local store = getStore()
    if not store then return end
    local db = store:GetDB()
    db.characterPrefs = db.characterPrefs or {}
    db.characterPrefs[characterKey] = db.characterPrefs[characterKey] or {}
    db.characterPrefs[characterKey].lastComparatorScope = self:BuildScopeKey(scope)
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Confidence classification (T018)
-- ──────────────────────────────────────────────────────────────────────────────

-- Classify a session count into a ConfidenceTier string constant.
-- Thresholds are read from Constants.CONFIDENCE_TIER_THRESHOLDS (never hardcoded).
function BuildComparisonService:ClassifyConfidence(sampleCount)
    local t  = Constants.CONFIDENCE_TIER
    local th = Constants.CONFIDENCE_TIER_THRESHOLDS
    sampleCount = sampleCount or 0
    if sampleCount <= 0 then
        return t.NO_DATA
    elseif sampleCount < th.MEDIUM_MIN then
        return t.LOW
    elseif sampleCount < th.HIGH_MIN then
        return t.MEDIUM
    else
        return t.HIGH
    end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Metric aggregation (used by Compare)
-- ──────────────────────────────────────────────────────────────────────────────

local function aggregateMetrics(sessions)
    if not sessions or #sessions == 0 then return nil end

    local wins, total = 0, 0
    local pressureSum, burstSum, survivalSum = 0, 0, 0
    local pressureCount, burstCount, survivalCount = 0, 0, 0

    for _, session in ipairs(sessions) do
        total = total + 1
        local result = session.result or (session.sessionResult)
        if result == Constants.SESSION_RESULT.WON then
            wins = wins + 1
        end

        local m = session.metrics
        if m then
            if m.pressureScore then
                pressureSum   = pressureSum   + m.pressureScore
                pressureCount = pressureCount + 1
            end
            if m.burstScore then
                burstSum   = burstSum   + m.burstScore
                burstCount = burstCount + 1
            end
            if m.survivabilityScore then
                survivalSum   = survivalSum   + m.survivabilityScore
                survivalCount = survivalCount + 1
            end
        end
    end

    return {
        winRate       = total > 0 and (wins / total) or nil,
        pressureScore = pressureCount > 0 and (pressureSum / pressureCount) or nil,
        burstScore    = burstCount    > 0 and (burstSum    / burstCount)    or nil,
        survivalScore = survivalCount > 0 and (survivalSum / survivalCount) or nil,
    }
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Build diff computation (T017)
-- ──────────────────────────────────────────────────────────────────────────────

local function resolveSpellName(spellId)
    if not spellId then return nil end
    local name
    if C_Spell and C_Spell.GetSpellName then
        local ok, n = pcall(C_Spell.GetSpellName, spellId)
        name = ok and n or nil
    else
        local ok, n = pcall(GetSpellInfo, spellId)
        name = ok and n or nil
    end
    return name
end

-- Parse a pvpTalentSignature string into a set (keyed table by talent ID).
local function pvpSigToSet(sig)
    local set = {}
    if not sig or sig == "" then return set end
    for part in sig:gmatch("[^,]+") do
        local id = tonumber(part)
        if id then set[id] = true end
    end
    return set
end

-- Parse a serialized talentSignature into a map keyed by nodeId.
-- Format: "nodeId:entryId:rank|..." (produced by serializeTalentNodes).
-- We also handle the raw talentNodes array form when the profile carries it.
local function buildNodeMap(profile)
    local map = {}
    -- Prefer raw talentNodes from snapshot if available (not always stored in profile).
    -- In practice the profile stores talentSignature (serialized), not the raw nodes.
    -- We store the raw nodes in the profile only during migration / fresh capture.
    if profile.talentNodes and #profile.talentNodes > 0 then
        for _, node in ipairs(profile.talentNodes) do
            if node.nodeId then
                map[node.nodeId] = {
                    nodeId   = node.nodeId,
                    entryId  = node.entryId,
                    rank     = node.activeRank or 0,
                    spellId  = node.definitionSpellId,
                }
            end
        end
        return map
    end

    -- Fall back to parsing talentSignature string "nodeId:entryId:rank|..."
    if profile.talentSignature and profile.talentSignature ~= "" then
        for segment in (profile.talentSignature .. "|"):gmatch("([^|]*)|") do
            local parts = {}
            for p in segment:gmatch("[^:]+") do parts[#parts + 1] = p end
            if #parts >= 3 then
                local nodeId  = tonumber(parts[1])
                local entryId = tonumber(parts[2])
                local rank    = tonumber(parts[3])
                if nodeId then
                    map[nodeId] = {
                        nodeId  = nodeId,
                        entryId = entryId,
                        rank    = rank or 0,
                    }
                end
            end
        end
    end
    return map
end

-- Compute a BuildDiff between two profiles.
function BuildComparisonService:ComputeDiff(profileA, profileB)
    local result = {
        heroTalentChange = nil,
        pvpTalentChanges = {},
        talentChanges    = {},
        isIdentical      = false,
        totalChanges     = 0,
    }
    if not profileA and not profileB then
        result.isIdentical = true
        return result
    end
    profileA = profileA or {}
    profileB = profileB or {}

    -- 1. Hero talent diff.
    local heroA = profileA.heroTalentSpecId
    local heroB = profileB.heroTalentSpecId
    if (heroA or 0) ~= (heroB or 0) then
        result.heroTalentChange = {
            inA   = heroA,
            inB   = heroB,
            nameA = heroA and heroA ~= 0 and resolveSpellName(heroA) or nil,
            nameB = heroB and heroB ~= 0 and resolveSpellName(heroB) or nil,
        }
        result.totalChanges = result.totalChanges + 1
    end

    -- 2. PvP talent diff (symmetric difference on sorted signature sets).
    local setA = pvpSigToSet(profileA.pvpTalentSignature)
    local setB = pvpSigToSet(profileB.pvpTalentSignature)
    for id in pairs(setA) do
        if not setB[id] then
            result.pvpTalentChanges[#result.pvpTalentChanges + 1] = {
                talentId  = id,
                spellName = resolveSpellName(id),
                inA       = true,
                inB       = false,
            }
            result.totalChanges = result.totalChanges + 1
        end
    end
    for id in pairs(setB) do
        if not setA[id] then
            result.pvpTalentChanges[#result.pvpTalentChanges + 1] = {
                talentId  = id,
                spellName = resolveSpellName(id),
                inA       = false,
                inB       = true,
            }
            result.totalChanges = result.totalChanges + 1
        end
    end

    -- 3. PvE talent diff by nodeId.
    local mapA = buildNodeMap(profileA)
    local mapB = buildNodeMap(profileB)

    -- Collect all nodeIds across both maps.
    local allNodes = {}
    for nodeId in pairs(mapA) do allNodes[nodeId] = true end
    for nodeId in pairs(mapB) do allNodes[nodeId] = true end

    for nodeId in pairs(allNodes) do
        local nA = mapA[nodeId]
        local nB = mapB[nodeId]
        local change = nil
        if nA and not nB then
            change = {
                nodeId      = nodeId,
                changeType  = "removed",
                entryIdA    = nA.entryId,
                entryIdB    = nil,
                rankA       = nA.rank,
                rankB       = nil,
                spellNameA  = resolveSpellName(nA.spellId),
                spellNameB  = nil,
            }
        elseif nB and not nA then
            change = {
                nodeId      = nodeId,
                changeType  = "added",
                entryIdA    = nil,
                entryIdB    = nB.entryId,
                rankA       = nil,
                rankB       = nB.rank,
                spellNameA  = nil,
                spellNameB  = resolveSpellName(nB.spellId),
            }
        elseif nA and nB then
            if (nA.entryId or 0) ~= (nB.entryId or 0) then
                change = {
                    nodeId      = nodeId,
                    changeType  = "choice_changed",
                    entryIdA    = nA.entryId,
                    entryIdB    = nB.entryId,
                    rankA       = nA.rank,
                    rankB       = nB.rank,
                    spellNameA  = resolveSpellName(nA.spellId),
                    spellNameB  = resolveSpellName(nB.spellId),
                }
            elseif (nA.rank or 0) ~= (nB.rank or 0) then
                change = {
                    nodeId      = nodeId,
                    changeType  = "rank_changed",
                    entryIdA    = nA.entryId,
                    entryIdB    = nB.entryId,
                    rankA       = nA.rank,
                    rankB       = nB.rank,
                    spellNameA  = resolveSpellName(nA.spellId),
                    spellNameB  = resolveSpellName(nB.spellId),
                }
            end
        end
        if change then
            result.talentChanges[#result.talentChanges + 1] = change
            result.totalChanges = result.totalChanges + 1
        end
    end

    -- 4. Sort talentChanges by importance:
    --    choice_changed(1) > added/removed(2) > rank_changed(3)
    local typeOrder = { choice_changed = 1, added = 2, removed = 2, rank_changed = 3 }
    table.sort(result.talentChanges, function(a, b)
        local oa = typeOrder[a.changeType] or 9
        local ob = typeOrder[b.changeType] or 9
        if oa ~= ob then return oa < ob end
        return (a.nodeId or 0) < (b.nodeId or 0)
    end)

    result.isIdentical = result.totalChanges == 0

    -- 5. Assemble a unified flat `changes` array for UI rendering.
    --    Order: hero change first, then pvp changes, then talent changes (already
    --    sorted by importance within their own groups).
    result.changes = {}
    if result.heroTalentChange then
        local hc = result.heroTalentChange
        result.changes[#result.changes + 1] = {
            changeType = "hero_changed",
            heroIdA    = hc.inA,
            heroIdB    = hc.inB,
            heroNameA  = hc.nameA,
            heroNameB  = hc.nameB,
        }
    end
    for _, pc in ipairs(result.pvpTalentChanges) do
        result.changes[#result.changes + 1] = {
            changeType = "pvp_changed",
            spellId    = pc.talentId,
            spellName  = pc.spellName,
            addedToB   = pc.inB and not pc.inA,  -- true = new in B; false = removed from B
        }
    end
    for _, tc in ipairs(result.talentChanges) do
        result.changes[#result.changes + 1] = tc
    end

    return result
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Core comparison (T015)
-- ──────────────────────────────────────────────────────────────────────────────

-- Compare two builds within a scope. Returns a ComparisonResult, or nil when
-- either buildId is absent.
-- options.buildAMode / options.buildBMode control stat profile resolution:
--   "latest"       → use the build entry's latestStatProfile (default)
--   "current_live" → call BuildCatalogService:GetCurrentLiveStatProfile()
function BuildComparisonService:Compare(buildIdA, buildIdB, scope, options)
    if not buildIdA or not buildIdB then
        ns.Addon:Trace("comparison.compare.nil_build_id", {
            hasA = buildIdA and true or false,
            hasB = buildIdB and true or false,
        })
        return nil
    end
    options = options or {}
    local catalog = getCatalog()
    local store   = getStore()

    -- Resolve profiles (fall back to minimal transient profile if not in catalog).
    local profileA = (catalog and catalog:GetProfile(buildIdA)) or { buildId = buildIdA }
    local profileB = (catalog and catalog:GetProfile(buildIdB)) or { buildId = buildIdB }

    -- Resolve scope (default if nil).
    if not scope then
        local snap = ns.Addon:GetLatestPlayerSnapshot and ns.Addon:GetLatestPlayerSnapshot()
        local charKey = snap and snap.name and snap.realm and (snap.name .. "-" .. snap.realm) or nil
        local specId  = snap and snap.specId or nil
        scope = self:GetLastScope(charKey, specId)
    end

    -- T040: Resolve stat profiles based on mode option.
    local modeA = options.buildAMode or "latest"
    local modeB = options.buildBMode or "latest"

    local statProfileA, statProfileB
    if modeA == "current_live" and catalog then
        statProfileA = catalog:GetCurrentLiveStatProfile()
    else
        statProfileA = profileA.latestStatProfile
    end
    if modeB == "current_live" and catalog then
        statProfileB = catalog:GetCurrentLiveStatProfile()
    else
        statProfileB = profileB.latestStatProfile
    end

    -- T041/T042: Compute stat delta; nil out when either side is untrustworthy.
    local UNAVAILABLE = Constants.SNAPSHOT_FRESHNESS.UNAVAILABLE
    local aFreshness = statProfileA and statProfileA.snapshotFreshness or UNAVAILABLE
    local bFreshness = statProfileB and statProfileB.snapshotFreshness or UNAVAILABLE

    local function deltaOrNil(a, b)
        return (a ~= nil and b ~= nil) and (b - a) or nil
    end

    local statDelta
    if statProfileA == nil or statProfileB == nil
    or aFreshness == UNAVAILABLE or bFreshness == UNAVAILABLE then
        -- T042: Do not show a delta when either side is not trustworthy.
        statDelta = {
            critPct           = nil,
            hastePct          = nil,
            masteryPct        = nil,
            versDamageDonePct = nil,
        }
    else
        statDelta = {
            critPct           = deltaOrNil(statProfileA.critPct,           statProfileB.critPct),
            hastePct          = deltaOrNil(statProfileA.hastePct,          statProfileB.hastePct),
            masteryPct        = deltaOrNil(statProfileA.masteryPct,        statProfileB.masteryPct),
            versDamageDonePct = deltaOrNil(statProfileA.versDamageDonePct, statProfileB.versDamageDonePct),
        }
    end

    -- Fetch session samples.
    local sessionsA = store and store:GetSessionsForBuild(buildIdA, scope) or {}
    local sessionsB = store and store:GetSessionsForBuild(buildIdB, scope) or {}

    local samplesA = #sessionsA
    local samplesB = #sessionsB

    -- Aggregate metrics (nil when no data).
    local metricsA = aggregateMetrics(sessionsA)
    local metricsB = aggregateMetrics(sessionsB)

    -- Confidence classification.
    local confidenceA = self:ClassifyConfidence(samplesA)
    local confidenceB = self:ClassifyConfidence(samplesB)

    -- Build diff.
    local diff = self:ComputeDiff(profileA, profileB)

    return {
        buildA               = profileA,
        buildB               = profileB,
        scope                = scope,
        samplesA             = samplesA,
        samplesB             = samplesB,
        metricsA             = metricsA,
        metricsB             = metricsB,
        confidenceA          = confidenceA,
        confidenceB          = confidenceB,
        diff                 = diff,
        computedAt           = GetTime(),
        statDelta            = statDelta,
        buildAStatFreshness  = aFreshness,
        buildBStatFreshness  = bFreshness,
        buildAStatCapturedAt = statProfileA and statProfileA.capturedAt,
        buildBStatCapturedAt = statProfileB and statProfileB.capturedAt,
    }
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Quick-action helpers (T016)
-- ──────────────────────────────────────────────────────────────────────────────

-- Return the buildId with the highest win rate in scope among HIGH-confidence
-- builds for characterKey+specId. Returns nil if no qualifying build found.
function BuildComparisonService:GetBestHistoricalInScope(characterKey, specId, scope)
    if not characterKey then return nil end
    local catalog = getCatalog()
    local store   = getStore()
    if not catalog or not store then return nil end

    local profiles = catalog:GetAllProfiles(characterKey)
    local bestId, bestWinRate = nil, -1

    for _, profile in ipairs(profiles) do
        if not profile._isTransient and (not specId or profile.specId == specId) then
            local sessions = store:GetSessionsForBuild(profile.buildId, scope)
            local sampleCount = #sessions
            if sampleCount >= Constants.CONFIDENCE_TIER_THRESHOLDS.HIGH_MIN then
                local wins = 0
                for _, s in ipairs(sessions) do
                    local r = s.result or s.sessionResult
                    if r == Constants.SESSION_RESULT.WON then wins = wins + 1 end
                end
                local winRate = sampleCount > 0 and (wins / sampleCount) or 0
                if winRate > bestWinRate then
                    bestWinRate = winRate
                    bestId = profile.buildId
                end
            end
        end
    end

    return bestId
end

-- Return the buildId with the highest session count in scope for
-- characterKey+specId. Returns nil if no sessions found for any build.
function BuildComparisonService:GetMostUsedInScope(characterKey, specId, scope)
    if not characterKey then return nil end
    local catalog = getCatalog()
    local store   = getStore()
    if not catalog or not store then return nil end

    local profiles = catalog:GetAllProfiles(characterKey)
    local bestId, bestCount = nil, 0

    for _, profile in ipairs(profiles) do
        if not profile._isTransient and (not specId or profile.specId == specId) then
            local sessions = store:GetSessionsForBuild(profile.buildId, scope)
            if #sessions > bestCount then
                bestCount = #sessions
                bestId    = profile.buildId
            end
        end
    end

    return bestCount > 0 and bestId or nil
end

ns.Addon:RegisterModule("BuildComparisonService", BuildComparisonService)
