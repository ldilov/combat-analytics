local _, ns = ...

local Constants = ns.Constants
local Helpers = ns.Helpers

local CombatStore = {}

local function buildEmptyDb()
    return {
        schemaVersion = Constants.SCHEMA_VERSION,
        settings = Helpers.CopyTable(Constants.DEFAULT_SETTINGS, true),
        matches = {
            order = {},
            byId = {},
        },
        combats = {
            order = {},
            byId = {},
        },
        aggregates = {
            opponents = {},
            classes = {},
            specs = {},
            builds = {},
            contexts = {},
            daily = {},
            weekly = {},
        },
        dummyBenchmarks = {},
        suggestionCache = {
            order = {},
            bySessionId = {},
        },
        maintenance = {
            totalRawEvents = 0,
            lastRebuildAt = nil,
            aggregateVersion = 1,
            warnings = {},
            traceLog = {},
        },
    }
end

local function ensureDefaults(db)
    db.schemaVersion = db.schemaVersion or Constants.SCHEMA_VERSION
    db.settings = db.settings or Helpers.CopyTable(Constants.DEFAULT_SETTINGS, true)
    for key, value in pairs(Constants.DEFAULT_SETTINGS) do
        if db.settings[key] == nil then
            db.settings[key] = value
        end
    end

    db.matches = db.matches or { order = {}, byId = {} }
    db.matches.order = db.matches.order or {}
    db.matches.byId = db.matches.byId or {}

    db.combats = db.combats or { order = {}, byId = {} }
    db.combats.order = db.combats.order or {}
    db.combats.byId = db.combats.byId or {}

    db.aggregates = db.aggregates or {}
    db.aggregates.opponents = db.aggregates.opponents or {}
    db.aggregates.classes = db.aggregates.classes or {}
    db.aggregates.specs = db.aggregates.specs or {}
    db.aggregates.builds = db.aggregates.builds or {}
    db.aggregates.contexts = db.aggregates.contexts or {}
    db.aggregates.daily = db.aggregates.daily or {}
    db.aggregates.weekly = db.aggregates.weekly or {}

    db.dummyBenchmarks = db.dummyBenchmarks or {}

    db.suggestionCache = db.suggestionCache or { order = {}, bySessionId = {} }
    db.suggestionCache.order = db.suggestionCache.order or {}
    db.suggestionCache.bySessionId = db.suggestionCache.bySessionId or {}

    db.maintenance = db.maintenance or {}
    db.maintenance.totalRawEvents = db.maintenance.totalRawEvents or 0
    db.maintenance.aggregateVersion = db.maintenance.aggregateVersion or 1
    db.maintenance.warnings = db.maintenance.warnings or {}
    db.maintenance.traceLog = db.maintenance.traceLog or {}
    db.maintenance.stabilizationVersion = db.maintenance.stabilizationVersion or 0
end

local function buildAggregateBucket(kind, key, label)
    return {
        kind = kind,
        key = key,
        label = label or key,
        fights = 0,
        wins = 0,
        losses = 0,
        other = 0,
        totalDuration = 0,
        totalDamageDone = 0,
        totalHealingDone = 0,
        totalDamageTaken = 0,
        totalDeaths = 0,
        totalPressureScore = 0,
        totalBurstScore = 0,
        totalSurvivabilityScore = 0,
        topSpells = {},
        lastSessionId = nil,
        lastUpdatedAt = nil,
    }
end

local function updateTopSpells(bucket, session)
    bucket.topSpells = bucket.topSpells or {}
    for spellId, aggregate in pairs(session.spells or {}) do
        local spellBucket = bucket.topSpells[spellId]
        if not spellBucket then
            spellBucket = {
                spellId = spellId,
                totalDamage = 0,
                totalHealing = 0,
                casts = 0,
                hits = 0,
            }
            bucket.topSpells[spellId] = spellBucket
        end
        spellBucket.totalDamage = spellBucket.totalDamage + (aggregate.totalDamage or 0)
        spellBucket.totalHealing = spellBucket.totalHealing + (aggregate.totalHealing or 0)
        spellBucket.casts = spellBucket.casts + (aggregate.castCount or 0)
        spellBucket.hits = spellBucket.hits + (aggregate.hitCount or 0)
    end
end

local function applySessionToBucket(bucket, session)
    bucket.fights = bucket.fights + 1
    bucket.totalDuration = bucket.totalDuration + (session.duration or 0)
    bucket.totalDamageDone = bucket.totalDamageDone + (session.totals.damageDone or 0)
    bucket.totalHealingDone = bucket.totalHealingDone + (session.totals.healingDone or 0)
    bucket.totalDamageTaken = bucket.totalDamageTaken + (session.totals.damageTaken or 0)
    bucket.totalDeaths = bucket.totalDeaths + (session.survival.deaths or 0)
    bucket.totalPressureScore = bucket.totalPressureScore + (session.metrics.pressureScore or 0)
    bucket.totalBurstScore = bucket.totalBurstScore + (session.metrics.burstScore or 0)
    bucket.totalSurvivabilityScore = bucket.totalSurvivabilityScore + (session.metrics.survivabilityScore or 0)
    bucket.lastSessionId = session.id
    bucket.lastUpdatedAt = session.timestamp

    local resultBucket = Helpers.GetResultBucket(session.result)
    bucket[resultBucket] = (bucket[resultBucket] or 0) + 1

    updateTopSpells(bucket, session)
end

local function getOrCreateBucket(container, kind, key, label)
    if Helpers.IsBlank(key) then
        key = "unknown"
    end
    container[key] = container[key] or buildAggregateBucket(kind, key, label)
    return container[key]
end

local function getPrimaryOpponent(session)
    return session.primaryOpponent
end

local function updateDummyBenchmark(db, session)
    if session.context ~= Constants.CONTEXT.TRAINING_DUMMY then
        return
    end

    local opponent = getPrimaryOpponent(session) or {}
    local buildHash = session.playerSnapshot and session.playerSnapshot.buildHash or "unknown"
    local specId = session.playerSnapshot and session.playerSnapshot.specId or 0
    local key = table.concat({
        tostring(buildHash),
        tostring(specId),
        tostring(opponent.name or "dummy"),
        tostring(opponent.level or 0),
    }, "#")

    local benchmark = db.dummyBenchmarks[key]
    if not benchmark then
        benchmark = {
            key = key,
            buildHash = buildHash,
            specId = specId,
            dummyName = opponent.name or "Training Dummy",
            dummyLevel = opponent.level or 0,
            sessions = 0,
            totalSustainedDps = 0,
            totalBurstDps = 0,
            totalOpenerDamage = 0,
            totalRotationScore = 0,
            lastSessionId = nil,
            lastUpdatedAt = nil,
        }
        db.dummyBenchmarks[key] = benchmark
    end

    benchmark.sessions = benchmark.sessions + 1
    benchmark.totalSustainedDps = benchmark.totalSustainedDps + (session.metrics.sustainedDps or 0)
    benchmark.totalBurstDps = benchmark.totalBurstDps + (session.metrics.burstDps or 0)
    benchmark.totalOpenerDamage = benchmark.totalOpenerDamage + (session.metrics.openerDamage or 0)
    benchmark.totalRotationScore = benchmark.totalRotationScore + (session.metrics.rotationalConsistencyScore or 0)
    benchmark.lastSessionId = session.id
    benchmark.lastUpdatedAt = session.timestamp
end

function CombatStore:Initialize()
    CombatAnalyticsDB = CombatAnalyticsDB or buildEmptyDb()
    ensureDefaults(CombatAnalyticsDB)
    if (CombatAnalyticsDB.maintenance.stabilizationVersion or 0) < 1 then
        CombatAnalyticsDB.settings.showMinimapButton = false
        CombatAnalyticsDB.settings.showSummaryAfterCombat = false
        CombatAnalyticsDB.maintenance.stabilizationVersion = 1
    end
end

function CombatStore:GetDB()
    return CombatAnalyticsDB
end

function CombatStore:CreateMatchRecord(context, subcontext)
    local db = self:GetDB()
    local id = Helpers.GenerateId("match")
    local zoneName, mapId = ns.ApiCompat.GetCurrentZoneName()
    local record = {
        id = id,
        context = context,
        subcontext = subcontext,
        createdAt = ns.ApiCompat.GetServerTime(),
        zoneName = zoneName,
        mapId = mapId,
        sessionIds = {},
        result = Constants.MATCH_RESULT.UNKNOWN,
        state = "pending",
        metadata = {},
    }

    db.matches.byId[id] = record
    db.matches.order[#db.matches.order + 1] = id
    return record
end

function CombatStore:GetMatch(matchId)
    local db = self:GetDB()
    return db.matches.byId[matchId]
end

function CombatStore:GetCombatById(sessionId)
    local db = self:GetDB()
    return db.combats.byId[sessionId]
end

function CombatStore:GetLatestSession()
    local db = self:GetDB()
    local lastId = db.combats.order[#db.combats.order]
    return lastId and db.combats.byId[lastId] or nil
end

function CombatStore:UpdateAggregatesForSession(session)
    local db = self:GetDB()
    local aggregates = db.aggregates
    local opponent = getPrimaryOpponent(session)

    if opponent then
        local opponentKey = opponent.guid or opponent.name or "unknown"
        local opponentLabel = opponent.name or opponent.guid or "Unknown Opponent"
        applySessionToBucket(getOrCreateBucket(aggregates.opponents, Constants.AGGREGATE_KIND.OPPONENT, opponentKey, opponentLabel), session)

        if opponent.classFile then
            applySessionToBucket(getOrCreateBucket(aggregates.classes, Constants.AGGREGATE_KIND.CLASS, opponent.classFile, opponent.className or opponent.classFile), session)
        end
        if opponent.specId then
            local specKey = tostring(opponent.specId)
            local specLabel = opponent.specName or specKey
            applySessionToBucket(getOrCreateBucket(aggregates.specs, Constants.AGGREGATE_KIND.SPEC, specKey, specLabel), session)
        end
    end

    local buildHash = session.playerSnapshot and session.playerSnapshot.buildHash or "unknown"
    applySessionToBucket(getOrCreateBucket(aggregates.builds, Constants.AGGREGATE_KIND.BUILD, buildHash, buildHash), session)

    local contextKey = session.context
    if session.subcontext then
        contextKey = string.format("%s:%s", session.context, session.subcontext)
    end
    applySessionToBucket(getOrCreateBucket(aggregates.contexts, Constants.AGGREGATE_KIND.CONTEXT, contextKey, contextKey), session)

    local dateKey = Helpers.GetDateKey(session.timestamp)
    applySessionToBucket(getOrCreateBucket(aggregates.daily, Constants.AGGREGATE_KIND.DAILY, dateKey, dateKey), session)

    local weekKey = Helpers.GetWeekKey(session.timestamp)
    applySessionToBucket(getOrCreateBucket(aggregates.weekly, Constants.AGGREGATE_KIND.WEEKLY, weekKey, weekKey), session)

    updateDummyBenchmark(db, session)
end

function CombatStore:PersistSession(session)
    if not session or not session.id then
        return
    end

    local db = self:GetDB()
    local isNew = db.combats.byId[session.id] == nil
    db.combats.byId[session.id] = session
    if isNew then
        db.combats.order[#db.combats.order + 1] = session.id
    end

    if session.parentMatchId then
        local matchRecord = db.matches.byId[session.parentMatchId]
        if matchRecord then
            matchRecord.sessionIds = matchRecord.sessionIds or {}
            if not Helpers.ArrayFind(matchRecord.sessionIds, function(value)
                return value == session.id
            end) then
                matchRecord.sessionIds[#matchRecord.sessionIds + 1] = session.id
            end
            matchRecord.lastSessionId = session.id
            matchRecord.lastUpdatedAt = session.timestamp
        end
    end

    db.maintenance.totalRawEvents = db.maintenance.totalRawEvents + #(session.rawEvents or {})
    self:UpdateAggregatesForSession(session)

    db.suggestionCache.bySessionId[session.id] = session.suggestions or {}
    if isNew then
        db.suggestionCache.order[#db.suggestionCache.order + 1] = session.id
    end

    if db.maintenance.totalRawEvents > Constants.RAW_EVENT_WARNING_THRESHOLD then
        db.maintenance.warnings[#db.maintenance.warnings + 1] = {
            timestamp = session.timestamp,
            message = "Stored raw events exceeded the recommended threshold.",
        }
    end
end

function CombatStore:ListCombats(page, pageSize, filters)
    local db = self:GetDB()
    local results = {}
    filters = filters or {}
    page = math.max(page or 1, 1)
    pageSize = pageSize or Constants.HISTORY_PAGE_SIZE

    for index = #db.combats.order, 1, -1 do
        local sessionId = db.combats.order[index]
        local session = db.combats.byId[sessionId]
        if session then
            local include = true
            if filters.context and session.context ~= filters.context then
                include = false
            end
            if include and filters.opponent and session.primaryOpponent and session.primaryOpponent.name ~= filters.opponent then
                include = false
            end
            if include then
                results[#results + 1] = session
            end
        end
    end

    local startIndex = (page - 1) * pageSize + 1
    local endIndex = math.min(startIndex + pageSize - 1, #results)
    local pageResults = {}
    for index = startIndex, endIndex do
        pageResults[#pageResults + 1] = results[index]
    end
    return pageResults, #results
end

function CombatStore:GetAggregateBuckets(kind)
    local db = self:GetDB()
    local source = db.aggregates[kind] or {}
    local list = {}
    for _, bucket in pairs(source) do
        list[#list + 1] = bucket
    end
    Helpers.SortByField(list, "fights", true)
    return list
end

function CombatStore:GetDummyBenchmarks()
    local db = self:GetDB()
    local results = {}
    for _, benchmark in pairs(db.dummyBenchmarks) do
        results[#results + 1] = benchmark
    end
    Helpers.SortByField(results, "lastUpdatedAt", true)
    return results
end

function CombatStore:GetRecentSuggestions(limit)
    local db = self:GetDB()
    local results = {}
    for index = #db.suggestionCache.order, 1, -1 do
        local sessionId = db.suggestionCache.order[index]
        local suggestions = db.suggestionCache.bySessionId[sessionId]
        if suggestions then
            for _, suggestion in ipairs(suggestions) do
                results[#results + 1] = suggestion
                if limit and #results >= limit then
                    return results
                end
            end
        end
    end
    return results
end

function CombatStore:GetBuildBaseline(buildHash, context)
    local bucket = self:GetDB().aggregates.builds[buildHash or "unknown"]
    if not bucket or bucket.fights <= 0 then
        return nil
    end
    return {
        fights = bucket.fights,
        averagePressureScore = bucket.totalPressureScore / bucket.fights,
        averageBurstScore = bucket.totalBurstScore / bucket.fights,
        averageSurvivabilityScore = bucket.totalSurvivabilityScore / bucket.fights,
        averageDamageDone = bucket.totalDamageDone / bucket.fights,
        context = context,
    }
end

function CombatStore:GetContextBaseline(contextKey)
    local bucket = self:GetDB().aggregates.contexts[contextKey]
    if not bucket or bucket.fights <= 0 then
        return nil
    end
    return {
        fights = bucket.fights,
        averagePressureScore = bucket.totalPressureScore / bucket.fights,
        averageBurstScore = bucket.totalBurstScore / bucket.fights,
        averageDuration = bucket.totalDuration / bucket.fights,
    }
end

function CombatStore:GetOpponentBaseline(opponentKey)
    local bucket = self:GetDB().aggregates.opponents[opponentKey]
    if not bucket or bucket.fights <= 0 then
        return nil
    end
    return {
        fights = bucket.fights,
        averageDamageTaken = bucket.totalDamageTaken / bucket.fights,
        averageDuration = bucket.totalDuration / bucket.fights,
        averagePressureScore = bucket.totalPressureScore / bucket.fights,
    }
end

function CombatStore:ResetAggregates()
    local db = self:GetDB()
    db.aggregates = {
        opponents = {},
        classes = {},
        specs = {},
        builds = {},
        contexts = {},
        daily = {},
        weekly = {},
    }
    db.dummyBenchmarks = {}
    db.suggestionCache = {
        order = {},
        bySessionId = {},
    }
    db.maintenance.totalRawEvents = 0
    db.maintenance.warnings = {}
end

function CombatStore:RebuildAggregates()
    local db = self:GetDB()
    self:ResetAggregates()
    for _, sessionId in ipairs(db.combats.order) do
        local session = db.combats.byId[sessionId]
        if session then
            db.maintenance.totalRawEvents = db.maintenance.totalRawEvents + #(session.rawEvents or {})
            self:UpdateAggregatesForSession(session)
            db.suggestionCache.bySessionId[session.id] = session.suggestions or {}
            db.suggestionCache.order[#db.suggestionCache.order + 1] = session.id
        end
    end
    db.maintenance.lastRebuildAt = ns.ApiCompat.GetServerTime()
    if db.maintenance.totalRawEvents > Constants.RAW_EVENT_WARNING_THRESHOLD then
        db.maintenance.warnings[#db.maintenance.warnings + 1] = {
            timestamp = db.maintenance.lastRebuildAt,
            message = "Stored raw events exceeded the recommended threshold.",
        }
    end
end

function CombatStore:DeleteSessions(filters)
    local db = self:GetDB()
    filters = filters or {}
    local deleted = 0

    for index = #db.combats.order, 1, -1 do
        local sessionId = db.combats.order[index]
        local session = db.combats.byId[sessionId]
        if session then
            local matches = true

            if filters.dateFrom and session.timestamp < filters.dateFrom then
                matches = false
            end
            if matches and filters.dateTo and session.timestamp > filters.dateTo then
                matches = false
            end
            if matches and filters.context and session.context ~= filters.context then
                matches = false
            end
            if matches and filters.opponent then
                local opponent = session.primaryOpponent
                if not opponent or (opponent.guid ~= filters.opponent and opponent.name ~= filters.opponent) then
                    matches = false
                end
            end
            if matches and filters.rawLogOnly and #(session.rawEvents or {}) == 0 then
                matches = false
            end

            if matches then
                db.combats.byId[sessionId] = nil
                table.remove(db.combats.order, index)
                deleted = deleted + 1
            end
        end
    end

    local emptyMatchIds = {}
    for matchId, matchRecord in pairs(db.matches.byId) do
        Helpers.ArrayRemoveIf(matchRecord.sessionIds, function(sessionId)
            return db.combats.byId[sessionId] == nil
        end)
        if #matchRecord.sessionIds == 0 then
            emptyMatchIds[#emptyMatchIds + 1] = matchId
        end
    end

    for _, matchId in ipairs(emptyMatchIds) do
        db.matches.byId[matchId] = nil
        Helpers.ArrayRemoveIf(db.matches.order, function(value)
            return value == matchId
        end)
    end

    self:RebuildAggregates()
    return deleted
end

function CombatStore:GetStorageStats()
    local db = self:GetDB()
    return {
        sessions = #db.combats.order,
        matches = #db.matches.order,
        totalRawEvents = db.maintenance.totalRawEvents or 0,
        warnings = db.maintenance.warnings or {},
    }
end

ns.Addon:RegisterModule("CombatStore", CombatStore)
