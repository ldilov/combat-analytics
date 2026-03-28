local _, ns = ...

local Constants = ns.Constants
local ApiCompat = ns.ApiCompat
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
            ratingHistory = {},
            buildEffectiveness = {},
            specDamageSignatures = {},
            soloShuffleSpecStats = {},
            bgBlitzSpecStats = {},
            openerSequenceEffectiveness = {},
            comps = {},
            matchupArchetypes = {},
            openers = {},
            matchupMemory = {},
            duelSeries = {},
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
    db.aggregates.ratingHistory = db.aggregates.ratingHistory or {}
    db.aggregates.buildEffectiveness = db.aggregates.buildEffectiveness or {}
    db.aggregates.specDamageSignatures = db.aggregates.specDamageSignatures or {}
    db.aggregates.soloShuffleSpecStats = db.aggregates.soloShuffleSpecStats or {}
    db.aggregates.bgBlitzSpecStats = db.aggregates.bgBlitzSpecStats or {}
    db.aggregates.openerSequenceEffectiveness = db.aggregates.openerSequenceEffectiveness or {}
    db.aggregates.comps = db.aggregates.comps or {}
    db.aggregates.matchupArchetypes = db.aggregates.matchupArchetypes or {}
    db.aggregates.openers = db.aggregates.openers or {}
    db.aggregates.matchupMemory = db.aggregates.matchupMemory or {}
    db.aggregates.duelSeries = db.aggregates.duelSeries or {}

    db.dummyBenchmarks = db.dummyBenchmarks or {}

    -- Build catalog — v7+. Indexed by canonical buildId.
    db.buildCatalog = db.buildCatalog or { order = {}, byId = {} }
    db.buildCatalog.order = db.buildCatalog.order or {}
    db.buildCatalog.byId  = db.buildCatalog.byId  or {}

    -- Per-character preferences (scope persistence, etc.) — v7+.
    db.characterPrefs = db.characterPrefs or {}

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
    bucket.totalDamageDone  = bucket.totalDamageDone  + (session.totals.damageDone  or 0)
    bucket.totalHealingDone = bucket.totalHealingDone + (session.totals.healingDone or 0)
    bucket.totalDamageTaken = bucket.totalDamageTaken + (session.totals.damageTaken or 0)
    -- session.totals is always initialised in CreateSession; no 2-level guard needed.
    -- session.survival and session.metrics use 2-level guards as a schema-migration
    -- safety net for sessions persisted before those fields were guaranteed.
    bucket.totalDeaths      = bucket.totalDeaths + ((session.survival and session.survival.deaths) or 0)
    bucket.totalPressureScore = bucket.totalPressureScore + ((session.metrics and session.metrics.pressureScore) or 0)
    bucket.totalBurstScore = bucket.totalBurstScore + ((session.metrics and session.metrics.burstScore) or 0)
    bucket.totalSurvivabilityScore = bucket.totalSurvivabilityScore + ((session.metrics and session.metrics.survivabilityScore) or 0)
    bucket.lastSessionId = session.id
    bucket.lastUpdatedAt = session.timestamp

    local resultBucket = Helpers.GetResultBucket(session.result)
    bucket[resultBucket] = (bucket[resultBucket] or 0) + 1

    updateTopSpells(bucket, session)
end

local function getOrCreateBucket(container, kind, key, label)
    -- Arena opponent GUIDs/names are 'secret strings' — WoW marks them so addons
    -- can't read their content.  tostring() propagates the secret flag rather than
    -- stripping it.  Concatenation with "" forces a fresh plain-Lua-string
    -- allocation; if that also throws, fall back to "unknown".
    -- Both key AND label must be sanitized: key is used as a table index (crashes
    -- on secret compare), label is stored in bucket.label and used by UI SetText.
    local okKey, safeKey = pcall(function() return (key or "") .. "" end)
    local okCmp, notEmpty = pcall(function() return safeKey ~= "" end)
    key = (okKey and okCmp and notEmpty and safeKey) or "unknown"
    if Helpers.IsBlank(key) then
        key = "unknown"
    end
    local okLabel, rawLabel = pcall(function() return (label or "") .. "" end)
    local okLabelCmp, labelNotEmpty = pcall(function() return rawLabel ~= "" end)
    local safeLabel = (okLabel and okLabelCmp and labelNotEmpty and rawLabel) or key
    container[key] = container[key] or buildAggregateBucket(kind, key, safeLabel)
    return container[key]
end

local function getPrimaryOpponent(session)
    return session.primaryOpponent
end

local function buildCharacterKey(guid, name, realm)
    if guid and guid ~= "" then
        return guid
    end

    local resolvedName = name or "unknown"
    local resolvedRealm = realm or ""
    if resolvedRealm ~= "" then
        return string.format("%s@%s", resolvedName, resolvedRealm)
    end
    return resolvedName
end

local function getSessionCharacterKey(session)
    local snapshot = session and session.playerSnapshot or nil
    if not snapshot then
        return "unknown"
    end
    return buildCharacterKey(snapshot.guid, snapshot.name, snapshot.realm)
end

local function getSessionCharacterLabel(session)
    local snapshot = session and session.playerSnapshot or nil
    if not snapshot then
        return "Unknown Character"
    end

    local name = snapshot.name or "Unknown"
    local realm = snapshot.realm or ""
    if realm ~= "" then
        return string.format("%s-%s", name, realm)
    end
    return name
end

local function buildCharacterRef(guid, name, realm)
    return {
        key = buildCharacterKey(guid, name, realm),
        guid = guid,
        name = name,
        realm = realm,
    }
end

local function matchesCharacter(session, characterRef)
    if not characterRef then
        return true
    end

    local snapshot = session and session.playerSnapshot or nil
    if not snapshot then
        return false
    end

    local sessionKey = getSessionCharacterKey(session)
    if sessionKey == characterRef.key then
        return true
    end

    local sessionName = tostring(snapshot.name or "")
    local sessionRealm = tostring(snapshot.realm or "")
    local refName = tostring(characterRef.name or "")
    local refRealm = tostring(characterRef.realm or "")

    if sessionName ~= "" and refName ~= "" and string.lower(sessionName) == string.lower(refName) then
        if sessionRealm == "" or refRealm == "" or string.lower(sessionRealm) == string.lower(refRealm) then
            return true
        end
    end

    return false
end

local function updateDummyBenchmarkRecord(container, session)
    if session.context ~= Constants.CONTEXT.TRAINING_DUMMY then
        return
    end

    local opponent = getPrimaryOpponent(session) or {}
    local dummyInfo = opponent.creatureId and ns.StaticPvpData and ns.StaticPvpData.GetDummyInfo and ns.StaticPvpData.GetDummyInfo(opponent.creatureId) or nil
    local buildHash = session.playerSnapshot and session.playerSnapshot.buildHash or "unknown"
    local specId = session.playerSnapshot and session.playerSnapshot.specId or 0
    local key = table.concat({
        tostring(getSessionCharacterKey(session)),
        tostring(buildHash),
        tostring(specId),
        tostring(dummyInfo and dummyInfo.benchmarkGroup or opponent.name or "dummy"),
        tostring(opponent.level or 0),
    }, "#")

    local benchmark = container[key]
    if not benchmark then
        benchmark = {
            key = key,
            characterKey = getSessionCharacterKey(session),
            characterName = getSessionCharacterLabel(session),
            buildHash = buildHash,
            specId = specId,
            dummyName = dummyInfo and dummyInfo.displayName or opponent.name or "Training Dummy",
            dummyFamily = dummyInfo and dummyInfo.family or "unknown",
            benchmarkGroup = dummyInfo and dummyInfo.benchmarkGroup or (opponent.name or "dummy"),
            dummyLevel = opponent.level or 0,
            sessions = 0,
            totalSustainedDps = 0,
            totalBurstDps = 0,
            totalOpenerDamage = 0,
            totalRotationScore = 0,
            lastSessionId = nil,
            lastUpdatedAt = nil,
        }
        container[key] = benchmark
    end

    benchmark.sessions = benchmark.sessions + 1
    benchmark.totalSustainedDps  = benchmark.totalSustainedDps  + ((session.metrics and session.metrics.sustainedDps) or 0)
    benchmark.totalBurstDps      = benchmark.totalBurstDps      + ((session.metrics and session.metrics.burstDps) or 0)
    benchmark.totalOpenerDamage  = benchmark.totalOpenerDamage  + ((session.metrics and session.metrics.openerDamage) or 0)
    benchmark.totalRotationScore = benchmark.totalRotationScore + ((session.metrics and session.metrics.rotationalConsistencyScore) or 0)
    benchmark.lastSessionId = session.id
    benchmark.lastUpdatedAt = session.timestamp
end

local function updateDummyBenchmark(db, session)
    updateDummyBenchmarkRecord(db.dummyBenchmarks, session)
end

local function updateAggregateContainerForSession(aggregates, session, kindFilter)
    local opponent = getPrimaryOpponent(session)

    if (not kindFilter or kindFilter == Constants.AGGREGATE_KIND.OPPONENT) and opponent then
        local opponentKey = opponent.guid or opponent.name or "unknown"
        local opponentLabel = opponent.name or opponent.guid or "Unknown Opponent"
        applySessionToBucket(getOrCreateBucket(aggregates.opponents, Constants.AGGREGATE_KIND.OPPONENT, opponentKey, opponentLabel), session)
    end

    if (not kindFilter or kindFilter == Constants.AGGREGATE_KIND.CLASS) and opponent and opponent.classFile then
        applySessionToBucket(getOrCreateBucket(aggregates.classes, Constants.AGGREGATE_KIND.CLASS, opponent.classFile, opponent.className or opponent.classFile), session)
    end

    if (not kindFilter or kindFilter == Constants.AGGREGATE_KIND.SPEC) and opponent and opponent.specId then
        local specKey = tostring(opponent.specId)
        local specLabel = opponent.specName or specKey
        applySessionToBucket(getOrCreateBucket(aggregates.specs, Constants.AGGREGATE_KIND.SPEC, specKey, specLabel), session)
    end

    local buildHash = session.playerSnapshot and session.playerSnapshot.buildHash or "unknown"
    if not kindFilter or kindFilter == Constants.AGGREGATE_KIND.BUILD then
        local buildBucket = getOrCreateBucket(aggregates.builds, Constants.AGGREGATE_KIND.BUILD, buildHash, buildHash)
        applySessionToBucket(buildBucket, session)
        -- Stamp human-readable snapshot metadata once so the UI can show spec
        -- name + PvP talents instead of the raw hash.  Only written on first
        -- encounter; the hash guarantees the build never changes under this key.
        local snap = session.playerSnapshot
        if snap and not buildBucket.specName then
            buildBucket.specId           = snap.specId
            buildBucket.specName         = snap.specName
            buildBucket.classFile        = snap.classFile
            buildBucket.pvpTalents       = snap.pvpTalents and Helpers.CopyTable(snap.pvpTalents, false) or {}
            buildBucket.heroTalentSpecId = snap.heroTalentSpecId
        end
        -- Build confidence score: sample-size-corrected win rate.
        -- Formula: min(1.0, fights / targetSample) * winRate
        -- Prevents small-sample builds from outranking stable high-fight builds.
        local thresholds   = ns.StaticPvpData and ns.StaticPvpData.METRIC_THRESHOLDS
        local targetSample = (thresholds and thresholds.minSamples and thresholds.minSamples.buildFull)
            or 30
        local winRate      = buildBucket.fights > 0 and (buildBucket.wins / buildBucket.fights) or 0
        local sampleFactor = math.min(1.0, buildBucket.fights / targetSample)
        buildBucket.confidenceScore = sampleFactor * winRate
    end

    local contextKey = session.context
    if session.subcontext then
        contextKey = string.format("%s:%s", session.context, session.subcontext)
    end
    if not kindFilter or kindFilter == Constants.AGGREGATE_KIND.CONTEXT then
        applySessionToBucket(getOrCreateBucket(aggregates.contexts, Constants.AGGREGATE_KIND.CONTEXT, contextKey, contextKey), session)
    end

    local dateKey = Helpers.GetDateKey(session.timestamp)
    if not kindFilter or kindFilter == Constants.AGGREGATE_KIND.DAILY then
        applySessionToBucket(getOrCreateBucket(aggregates.daily, Constants.AGGREGATE_KIND.DAILY, dateKey, dateKey), session)
    end

    local weekKey = Helpers.GetWeekKey(session.timestamp)
    if not kindFilter or kindFilter == Constants.AGGREGATE_KIND.WEEKLY then
        applySessionToBucket(getOrCreateBucket(aggregates.weekly, Constants.AGGREGATE_KIND.WEEKLY, weekKey, weekKey), session)
    end
end

function CombatStore:Initialize()
    CombatAnalyticsDB = CombatAnalyticsDB or buildEmptyDb()
    ensureDefaults(CombatAnalyticsDB)
    if (CombatAnalyticsDB.maintenance.stabilizationVersion or 0) < 1 then
        CombatAnalyticsDB.settings.showMinimapButton = false
        CombatAnalyticsDB.settings.showSummaryAfterCombat = false
        CombatAnalyticsDB.maintenance.stabilizationVersion = 1
    end
    self:MigrateSchema(CombatAnalyticsDB)
end

-- MigrateSchema applies incremental upgrades to saved data.
-- Design rules:
--   • Each version gate is a forward-only, idempotent migration.
--   • Never backfill derived fields that require live API data (GUIDs, specs).
--   • Mark legacy sessions with version metadata so analytics can down-grade
--     confidence rather than silently produce wrong results.
--   • Bump Constants.SCHEMA_VERSION whenever a new gate is added.
function CombatStore:MigrateSchema(db)
    local version = db.schemaVersion or 0

    -- v1 → v2: introduce rawEventVersion field, arena slot metadata, and
    -- attribution stub on existing sessions. No data backfill — sessions
    -- captured under v1 are marked as legacy raw events so confidence labels
    -- reflect actual capture quality.
    if version < 2 then
        for _, sessionId in ipairs(db.combats.order or {}) do
            local session = db.combats.byId[sessionId]
            if session then
                -- Tag raw event format; v1 sessions lack absorbed/resisted
                -- fields in SWING_DAMAGE and several other subevent fields.
                if not session.rawEventVersion then
                    session.rawEventVersion = 1
                end
                -- Stub arena block; will be populated by ArenaRoundTracker
                -- on sessions created under schema v2+.
                if session.arena == nil then
                    session.arena = false  -- false = not an arena session / unknown
                end
                -- Stub attribution block.
                if session.attribution == nil then
                    session.attribution = false  -- false = not yet computed
                end
            end
        end
        db.schemaVersion = 2
    end

    -- v2 → v3: introduce rating, CC, and post-match score fields on sessions,
    -- and initialise new aggregate buckets for rating history, build
    -- effectiveness, and spec damage signatures.
    if version < 3 then
        for _, sessionId in ipairs(db.combats.order or {}) do
            local session = db.combats.byId[sessionId]
            if session then
                if session.ratingSnapshot == nil then
                    session.ratingSnapshot = false
                end
                if session.ccReceived == nil then
                    session.ccReceived = false
                end
                if session.postMatchScores == nil then
                    session.postMatchScores = false
                end
                if session.teamRatingInfo == nil then
                    session.teamRatingInfo = false
                end
                if session.isRated == nil then
                    session.isRated = false
                end
            end
        end

        if db.aggregates.ratingHistory == nil then
            db.aggregates.ratingHistory = {}
        end
        if db.aggregates.buildEffectiveness == nil then
            db.aggregates.buildEffectiveness = {}
        end
        if db.aggregates.specDamageSignatures == nil then
            db.aggregates.specDamageSignatures = {}
        end

        db.schemaVersion = 3
    end

    -- v3 → v4: add fields for loss-of-control tracking, interrupt log,
    -- kill timings, comp analysis, streak context, and arena DR/talent data.
    -- New aggregate bucket: comps (opponent team composition win rates).
    if version < 4 then
        for _, sessionId in ipairs(db.combats.order or {}) do
            local session = db.combats.byId[sessionId]
            if session then
                if session.lossOfControl == nil then
                    session.lossOfControl = false
                end
                if session.interruptLog == nil then
                    session.interruptLog = false
                end
                if session.killTimings == nil then
                    session.killTimings = false
                end
                if session.opponentCompKey == nil then
                    session.opponentCompKey = false
                end
                if session.streakContext == nil then
                    session.streakContext = false
                end
            end
        end

        if db.aggregates.comps == nil then
            db.aggregates.comps = {}
        end

        db.schemaVersion = 4
    end

    -- v4 → v5: greed death / defensive economy / kill window fields
    if version < 5 then
        for _, sessionId in ipairs(db.combats.order or {}) do
            local session = db.combats.byId[sessionId]
            if session then
                session.survival = session.survival or {}
                session.survival.greedDeaths          = session.survival.greedDeaths          or 0
                session.survival.defensiveOverlapCount = session.survival.defensiveOverlapCount or 0
                session.survival.burstWasteCount       = session.survival.burstWasteCount       or 0
                session.killWindows          = session.killWindows          or {}
                session.killWindowConversions = session.killWindowConversions or 0
            end
        end

        db.schemaVersion = 5
    end

    -- v5 → v6: Midnight compliance overhaul — add timelineEvents, provenance,
    -- fieldConfidence on arena slots, new aggregate buckets, and map old
    -- ANALYSIS_CONFIDENCE labels to the new SESSION_CONFIDENCE enum.
    if version < 6 then
        -- Confidence label migration map (old → new)
        local confidenceMap = {
            full_raw       = Constants.SESSION_CONFIDENCE.LEGACY_CLEU_IMPORT,
            enriched       = Constants.SESSION_CONFIDENCE.LEGACY_CLEU_IMPORT,
            restricted_raw = Constants.SESSION_CONFIDENCE.STATE_PLUS_DAMAGE_METER,
            degraded       = Constants.SESSION_CONFIDENCE.DAMAGE_METER_ONLY,
            partial_roster = Constants.SESSION_CONFIDENCE.PARTIAL_ROSTER,
            unknown        = Constants.SESSION_CONFIDENCE.ESTIMATED,
        }

        for _, sessionId in ipairs(db.combats.order or {}) do
            local session = db.combats.byId[sessionId]
            if session then
                -- T006: Add timelineEvents and provenance to all existing sessions
                if session.timelineEvents == nil then
                    session.timelineEvents = {}
                end
                if session.provenance == nil then
                    session.provenance = {}
                end

                -- T007: Map old confidence labels to new SessionConfidence
                if session.captureQuality then
                    local oldConf = session.captureQuality.confidence
                    if oldConf and confidenceMap[oldConf] then
                        session.captureQuality.confidence = confidenceMap[oldConf]
                    end
                end

                -- T008: Add fieldConfidence to existing arena slot records
                if type(session.arena) == "table" then
                    local rounds = session.arena.rounds
                    if type(rounds) == "table" then
                        for _, round in pairs(rounds) do
                            local slots = round and round.slots
                            if type(slots) == "table" then
                                for _, slot in pairs(slots) do
                                    if type(slot) == "table" and not slot.fieldConfidence then
                                        local fc = {}
                                        -- Infer initial confidence from existing data
                                        if slot.prepSpecId then
                                            fc.spec = "prep"
                                            fc.class = "prep"
                                        end
                                        if slot.guid then
                                            fc.guid = "visible"
                                            fc.name = "visible"
                                            if not fc.class then
                                                fc.class = "visible"
                                            end
                                        end
                                        if slot.pvpTalents then
                                            fc.pvpTalents = "inspect"
                                            fc.talentImportString = "inspect"
                                            fc.spec = "inspect" -- upgrade from prep
                                        end
                                        slot.fieldConfidence = fc
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        -- T009: Initialize new aggregate buckets
        db.aggregates.openers = db.aggregates.openers or {}
        db.aggregates.matchupMemory = db.aggregates.matchupMemory or {}
        db.aggregates.duelSeries = db.aggregates.duelSeries or {}

        db.schemaVersion = 6
    end

    -- v6 → v7: Build Comparator Overhaul — initialize build catalog, stamp
    -- canonical buildId / loadoutId onto every existing session snapshot, upsert
    -- build profiles, and merge legacy hash values.
    -- T024 / T025 / T026
    if version < 7 then
        -- (1) Ensure catalog and prefs structures exist (may already exist from
        --     ensureDefaults, but be defensive here too).
        db.buildCatalog = db.buildCatalog or { order = {}, byId = {} }
        db.buildCatalog.order = db.buildCatalog.order or {}
        db.buildCatalog.byId  = db.buildCatalog.byId  or {}
        db.characterPrefs     = db.characterPrefs or {}

        -- T025: Collect legacy hashes per buildId so we can consolidate them
        -- after all sessions are stamped (belt-and-suspenders merge).
        local legacyHashesMap = {}  -- buildId → { hash, ... }
        local buildSessionCounts = {}  -- buildId → count

        for _, sessionId in ipairs(db.combats.order or {}) do
            local session = db.combats.byId[sessionId]
            if session then
                local snap = session.playerSnapshot

                -- T026: Idempotence guard — skip if already stamped.
                if snap and snap.buildId then
                    -- Already migrated; still count for sessionCount accuracy.
                    local bid = snap.buildId
                    buildSessionCounts[bid] = (buildSessionCounts[bid] or 0) + 1
                    local legacyHash = snap.buildHash
                    if legacyHash then
                        legacyHashesMap[bid] = legacyHashesMap[bid] or {}
                        local seen = false
                        for _, h in ipairs(legacyHashesMap[bid]) do
                            if h == legacyHash then seen = true; break end
                        end
                        if not seen then
                            legacyHashesMap[bid][#legacyHashesMap[bid] + 1] = legacyHash
                        end
                    end
                elseif snap and (snap.talentNodes or snap.classId) then
                    -- T024: Normal session with snapshot data — stamp buildId.
                    local ok, bid = pcall(function() return ns.BuildHash.ComputeBuildId(snap) end)
                    if not ok or not bid then
                        bid = nil
                    end

                    local ok2, lid = pcall(function() return ns.BuildHash.ComputeLoadoutId(snap) end)
                    if not ok2 then lid = nil end

                    if bid then
                        snap.buildId             = bid
                        snap.loadoutId           = lid
                        snap.snapshotFreshness   = Constants.SNAPSHOT_FRESHNESS.FRESH
                        buildSessionCounts[bid]  = (buildSessionCounts[bid] or 0) + 1

                        -- T025: Collect the old legacy hash for later consolidation.
                        local legacyHash = snap.buildHash
                        if legacyHash then
                            legacyHashesMap[bid] = legacyHashesMap[bid] or {}
                            local seen = false
                            for _, h in ipairs(legacyHashesMap[bid]) do
                                if h == legacyHash then seen = true; break end
                            end
                            if not seen then
                                legacyHashesMap[bid][#legacyHashesMap[bid] + 1] = legacyHash
                            end
                        end
                    else
                        -- T026: Partial-data session — assign deterministic fallback buildId.
                        local fallbackSuffix = snap.buildHash or sessionId
                        bid = "legacy-partial-" .. string.sub(tostring(fallbackSuffix), 1, 8)
                        snap.buildId           = bid
                        snap.loadoutId         = nil
                        snap.snapshotFreshness = Constants.SNAPSHOT_FRESHNESS.DEGRADED
                        snap.isMigrated        = true
                        snap.isMigratedWithWarnings = true
                        buildSessionCounts[bid] = (buildSessionCounts[bid] or 0) + 1

                        -- Record warning
                        db.maintenance = db.maintenance or {}
                        db.maintenance.buildMigrationWarnings = db.maintenance.buildMigrationWarnings or {}
                        local warn = db.maintenance.buildMigrationWarnings
                        warn[#warn + 1] = {
                            sessionId = sessionId,
                            reason    = "partial_snapshot_no_talent_data",
                            fallbackBuildId = bid,
                        }
                    end
                else
                    -- T026: Nil snapshot — assign sentinel fallback.
                    local bid = "legacy-partial-" .. string.sub(tostring(sessionId), 1, 8)
                    snap = snap or {}
                    snap.buildId                = bid
                    snap.loadoutId              = nil
                    snap.snapshotFreshness      = Constants.SNAPSHOT_FRESHNESS.DEGRADED
                    snap.isMigrated             = true
                    snap.isMigratedWithWarnings = true
                    session.playerSnapshot      = snap
                    buildSessionCounts[bid]     = (buildSessionCounts[bid] or 0) + 1

                    db.maintenance = db.maintenance or {}
                    db.maintenance.buildMigrationWarnings = db.maintenance.buildMigrationWarnings or {}
                    local warn = db.maintenance.buildMigrationWarnings
                    warn[#warn + 1] = {
                        sessionId = sessionId,
                        reason    = "nil_player_snapshot",
                        fallbackBuildId = bid,
                    }
                end
            end
        end

        -- (2) Upsert one BuildProfile per unique buildId.
        for bid, sessionCount in pairs(buildSessionCounts) do
            local existing = db.buildCatalog.byId[bid]
            if not existing then
                -- Collect one representative snapshot for this buildId.
                local repSnap = nil
                for _, sessionId in ipairs(db.combats.order or {}) do
                    local s = db.combats.byId[sessionId]
                    if s and s.playerSnapshot and s.playerSnapshot.buildId == bid then
                        repSnap = s.playerSnapshot
                        break
                    end
                end

                local charKey = nil
                if repSnap and repSnap.name and repSnap.realm then
                    charKey = repSnap.name .. "-" .. repSnap.realm
                end

                local profile = {
                    buildId              = bid,
                    buildIdentityVersion = Constants.BUILD_IDENTITY_VERSION,
                    classId              = repSnap and repSnap.classId,
                    specId               = repSnap and repSnap.specId,
                    heroTalentSpecId     = repSnap and repSnap.heroTalentSpecId,
                    talentSignature      = "",
                    pvpTalentSignature   = "",
                    displayNames         = { "Migrated Build" },
                    associatedLoadoutIds = {},
                    legacyBuildHashes    = legacyHashesMap[bid] or {},
                    sessionCount         = sessionCount,
                    characterKey         = charKey,
                    isCurrentBuild       = false,
                    isMigrated           = true,
                    isMigratedWithWarnings = (repSnap and repSnap.isMigratedWithWarnings) or false,
                    isLowConfidence      = sessionCount < Constants.CONFIDENCE_TIER_THRESHOLDS.LOW_MIN,
                    firstSeenAt          = 0,
                    lastSeenAt           = 0,
                }

                -- Talent and PvP signature from snapshot
                if repSnap and repSnap.talentNodes then
                    local parts = {}
                    for _, node in ipairs(repSnap.talentNodes) do
                        parts[#parts + 1] = table.concat({
                            tostring(node.nodeId   or 0),
                            tostring(node.entryId  or 0),
                            tostring(node.activeRank or 0),
                        }, ":")
                    end
                    table.sort(parts)
                    profile.talentSignature = table.concat(parts, "|")
                end

                if repSnap and repSnap.pvpTalents then
                    local sorted = {}
                    for _, v in ipairs(repSnap.pvpTalents) do
                        sorted[#sorted + 1] = tostring(v)
                    end
                    table.sort(sorted)
                    profile.pvpTalentSignature = table.concat(sorted, ",")
                end

                db.buildCatalog.byId[bid]                = profile
                db.buildCatalog.order[#db.buildCatalog.order + 1] = bid
            else
                -- T025: Merge any newly found legacy hashes into the existing profile.
                existing.legacyBuildHashes = existing.legacyBuildHashes or {}
                for _, h in ipairs(legacyHashesMap[bid] or {}) do
                    local found = false
                    for _, eh in ipairs(existing.legacyBuildHashes) do
                        if eh == h then found = true; break end
                    end
                    if not found then
                        existing.legacyBuildHashes[#existing.legacyBuildHashes + 1] = h
                    end
                end
                -- Recalculate session count from actual tally
                existing.sessionCount = sessionCount
            end
        end

        db.schemaVersion = 7
        ns.Addon:Trace("migration.v7.complete", {
            profilesCreated = #db.buildCatalog.order,
        })
    end

    -- Future migrations go here as additional `if version < N then` blocks.

    -- T121: Post-migration validation for mixed-version datasets.
    -- Ensures all sessions have required fields regardless of original schema version.
    local validationErrors = 0
    for _, sessionId in ipairs(db.combats.order or {}) do
        local session = db.combats.byId[sessionId]
        if session then
            -- Ensure timelineEvents is always a table (never nil)
            if type(session.timelineEvents) ~= "table" then
                session.timelineEvents = {}
                validationErrors = validationErrors + 1
            end
            -- Ensure provenance is always a table
            if type(session.provenance) ~= "table" then
                session.provenance = {}
                validationErrors = validationErrors + 1
            end
            -- Ensure captureQuality has a confidence field
            if not session.captureQuality then
                session.captureQuality = { confidence = Constants.SESSION_CONFIDENCE.ESTIMATED }
                validationErrors = validationErrors + 1
            elseif not session.captureQuality.confidence then
                session.captureQuality.confidence = Constants.SESSION_CONFIDENCE.ESTIMATED
                validationErrors = validationErrors + 1
            end
            -- Ensure metrics is a table
            if session.metrics == nil then
                session.metrics = {}
            end
        end
    end
    if validationErrors > 0 then
        ns.Addon:Trace("migration.validation_fixes", { count = validationErrors })
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

function CombatStore:GetCurrentCharacterKey()
    local snapshot = ns.Addon:GetLatestPlayerSnapshot()
    if snapshot then
        return buildCharacterKey(snapshot.guid, snapshot.name, snapshot.realm)
    end
    return buildCharacterKey(ApiCompat.GetPlayerGUID(), ApiCompat.GetPlayerName(), ApiCompat.GetNormalizedRealmName())
end

function CombatStore:GetCurrentCharacterRef()
    local snapshot = ns.Addon:GetLatestPlayerSnapshot()
    if snapshot then
        return buildCharacterRef(snapshot.guid, snapshot.name, snapshot.realm)
    end
    return buildCharacterRef(ApiCompat.GetPlayerGUID(), ApiCompat.GetPlayerName(), ApiCompat.GetNormalizedRealmName())
end

function CombatStore:GetSessionCharacterKey(session)
    return getSessionCharacterKey(session)
end

function CombatStore:GetSessionCharacterLabel(session)
    return getSessionCharacterLabel(session)
end

function CombatStore:GetLatestSession(characterKey)
    local db = self:GetDB()
    if not characterKey then
        local lastId = db.combats.order[#db.combats.order]
        return lastId and db.combats.byId[lastId] or nil
    end

    local characterRef = type(characterKey) == "table" and characterKey or buildCharacterRef(characterKey, nil, nil)

    for index = #db.combats.order, 1, -1 do
        local sessionId = db.combats.order[index]
        local session = db.combats.byId[sessionId]
        if session and matchesCharacter(session, characterRef) then
            return session
        end
    end
    return nil
end

local RATING_HISTORY_CAP = 200

local function updateRatingHistory(aggregates, session)
    if not session.isRated then return end
    local snap = session.ratingSnapshot
    if not snap or not snap.before then return end

    local charKey = getSessionCharacterKey(session)
    local contextKey = session.context or "unknown"
    if session.subcontext then
        contextKey = string.format("%s:%s", contextKey, session.subcontext)
    end
    local historyKey = string.format("%s:%s", charKey, contextKey)

    aggregates.ratingHistory = aggregates.ratingHistory or {}
    local history = aggregates.ratingHistory[historyKey]
    if not history then
        history = {}
        aggregates.ratingHistory[historyKey] = history
    end

    local before = snap.before
    local after = snap.after
    local entry = {
        ratingBefore = before.personalRating,
        ratingAfter  = after and after.personalRating or before.personalRating,
        change       = after and (after.personalRating - before.personalRating) or 0,
        mmrBefore    = nil,
        mmrAfter     = nil,
        sessionId    = session.id,
        timestamp    = session.timestamp,
        result       = session.result,
    }

    -- MMR data comes from postMatchScores if available
    if session.postMatchScores then
        local playerGuid = session.playerSnapshot and session.playerSnapshot.guid
            or (ns.ApiCompat and ns.ApiCompat.GetPlayerGUID and ns.ApiCompat.GetPlayerGUID())
        for _, score in ipairs(session.postMatchScores) do
            if score.guid == playerGuid then
                entry.mmrBefore = score.prematchMMR
                entry.mmrAfter  = score.postmatchMMR
                break
            end
        end
    end

    history[#history + 1] = entry

    -- Cap oldest entries
    while #history > RATING_HISTORY_CAP do
        table.remove(history, 1)
    end
end

local function updateBuildEffectiveness(aggregates, session)
    local buildHash = session.playerSnapshot and session.playerSnapshot.buildHash
    if not buildHash then return end
    local opponent = getPrimaryOpponent(session)
    if not opponent or not opponent.specId then return end
    -- Only update for PvP-relevant contexts
    local ctx = session.context
    if ctx ~= Constants.CONTEXT.ARENA
        and ctx ~= Constants.CONTEXT.DUEL
        and ctx ~= Constants.CONTEXT.WORLD_PVP
    then
        return
    end

    aggregates.buildEffectiveness = aggregates.buildEffectiveness or {}
    local buildBucket = aggregates.buildEffectiveness[buildHash]
    if not buildBucket then
        buildBucket = {}
        aggregates.buildEffectiveness[buildHash] = buildBucket
    end

    local specKey = tostring(opponent.specId)
    local entry = buildBucket[specKey]
    if not entry then
        entry = {
            fights = 0, wins = 0, losses = 0, other = 0,
            avgPressureScore = 0, avgSurvivabilityScore = 0,
            avgDuration = 0, lastSessionId = nil,
        }
        buildBucket[specKey] = entry
    end

    entry.fights = entry.fights + 1
    local result = session.result
    if result == Constants.SESSION_RESULT.WON then
        entry.wins = entry.wins + 1
    elseif result == Constants.SESSION_RESULT.LOST then
        entry.losses = entry.losses + 1
    else
        entry.other = entry.other + 1
    end

    local metrics = session.metrics or {}
    -- Running average
    local n = entry.fights
    entry.avgPressureScore = entry.avgPressureScore + ((metrics.pressureScore or 0) - entry.avgPressureScore) / n
    entry.avgSurvivabilityScore = entry.avgSurvivabilityScore + ((metrics.survivabilityScore or 0) - entry.avgSurvivabilityScore) / n
    entry.avgDuration = entry.avgDuration + ((session.duration or 0) - entry.avgDuration) / n
    entry.lastSessionId = session.id
end

local function updateSpecDamageSignatures(aggregates, session)
    local opponent = getPrimaryOpponent(session)
    if not opponent or not opponent.specId then return end
    local attribution = session.attribution
    if type(attribution) ~= "table" or not attribution.bySourceSpell then return end

    local specKey = tostring(opponent.specId)
    aggregates.specDamageSignatures = aggregates.specDamageSignatures or {}
    local sig = aggregates.specDamageSignatures[specKey]
    if not sig then
        sig = { spells = {} }
        aggregates.specDamageSignatures[specKey] = sig
    end

    for _sourceGuid, spellTable in pairs(attribution.bySourceSpell) do
        for spellId, agg in pairs(spellTable) do
            local entry = sig.spells[spellId]
            if not entry then
                entry = { spellId = spellId, totalDamage = 0, hitCount = 0, critCount = 0 }
                sig.spells[spellId] = entry
            end
            entry.totalDamage = entry.totalDamage + (agg.totalAmount or 0)
            entry.hitCount = entry.hitCount + (agg.hitCount or 0)
            entry.critCount = entry.critCount + (agg.critCount or 0)
        end
    end
end

local function updateMMRBandStats(aggregates, session)
    if not session.isRated then return end
    local snap = session.ratingSnapshot
    if not snap or not snap.before or not snap.before.personalRating then return end

    local rating = snap.before.personalRating
    local bandLabel = nil
    for _, band in ipairs(Constants.MMR_BANDS) do
        if rating >= band.min and rating <= band.max then
            bandLabel = band.label
            break
        end
    end
    if not bandLabel then return end

    local isWin = session.result == Constants.SESSION_RESULT.WON
    local isLoss = session.result == Constants.SESSION_RESULT.LOST

    -- Update per-spec MMR band stats
    local opponent = getPrimaryOpponent(session)
    if opponent and opponent.specId then
        local specKey = tostring(opponent.specId)
        local specBucket = aggregates.specs[specKey]
        if specBucket then
            specBucket.mmrBands = specBucket.mmrBands or {}
            local bandBucket = specBucket.mmrBands[bandLabel]
            if not bandBucket then
                bandBucket = { fights = 0, wins = 0, losses = 0 }
                specBucket.mmrBands[bandLabel] = bandBucket
            end
            bandBucket.fights = bandBucket.fights + 1
            if isWin then bandBucket.wins = bandBucket.wins + 1 end
            if isLoss then bandBucket.losses = bandBucket.losses + 1 end
        end
    end

    -- Update per-class MMR band stats
    if opponent and opponent.classFile then
        local classBucket = aggregates.classes[opponent.classFile]
        if classBucket then
            classBucket.mmrBands = classBucket.mmrBands or {}
            local bandBucket = classBucket.mmrBands[bandLabel]
            if not bandBucket then
                bandBucket = { fights = 0, wins = 0, losses = 0 }
                classBucket.mmrBands[bandLabel] = bandBucket
            end
            bandBucket.fights = bandBucket.fights + 1
            if isWin then bandBucket.wins = bandBucket.wins + 1 end
            if isLoss then bandBucket.losses = bandBucket.losses + 1 end
        end
    end
end

local function updateOpenerSequenceEffectiveness(aggregates, session)
    local opener = session.openerSequence
    if not opener or not opener.hash or not opener.spellIds or #opener.spellIds == 0 then return end

    local opponent = getPrimaryOpponent(session)
    if not opponent or not opponent.specId then return end

    local context = session.context
    if context ~= Constants.CONTEXT.ARENA and context ~= Constants.CONTEXT.DUEL and context ~= Constants.CONTEXT.WORLD_PVP then
        return
    end

    local specKey = tostring(opponent.specId)
    aggregates.openerSequenceEffectiveness = aggregates.openerSequenceEffectiveness or {}
    local specBucket = aggregates.openerSequenceEffectiveness[specKey]
    if not specBucket then
        specBucket = {}
        aggregates.openerSequenceEffectiveness[specKey] = specBucket
    end

    local entry = specBucket[opener.hash]
    if not entry then
        entry = { attempts = 0, wins = 0, losses = 0, avgPressureScore = 0 }
        specBucket[opener.hash] = entry
    end

    entry.attempts = entry.attempts + 1
    if session.result == Constants.SESSION_RESULT.WON then
        entry.wins = entry.wins + 1
    elseif session.result == Constants.SESSION_RESULT.LOST then
        entry.losses = entry.losses + 1
    end

    local n = entry.attempts
    entry.avgPressureScore = entry.avgPressureScore + (((session.metrics or {}).pressureScore or 0) - entry.avgPressureScore) / n
end

local function updateMatchupArchetypes(aggregates, session)
    local compArchetype = session.arena and session.arena.compArchetype
    if not compArchetype or compArchetype == "unknown" then return end

    aggregates.matchupArchetypes = aggregates.matchupArchetypes or {}
    local agg = aggregates.matchupArchetypes
    if not agg[compArchetype] then
        agg[compArchetype] = {
            archetype                  = compArchetype,
            fights                     = 0,
            wins                       = 0,
            losses                     = 0,
            totalGreedDeaths           = 0,
            totalBurstWaste            = 0,
            totalKillWindows           = 0,
            totalKillWindowConversions = 0,
        }
    end
    local bucket = agg[compArchetype]
    bucket.fights = bucket.fights + 1
    if session.result == Constants.SESSION_RESULT.WON then
        bucket.wins   = bucket.wins   + 1
    elseif session.result == Constants.SESSION_RESULT.LOST then
        bucket.losses = bucket.losses + 1
    end
    bucket.totalGreedDeaths = bucket.totalGreedDeaths
        + ((session.survival and session.survival.greedDeaths)    or 0)
    bucket.totalBurstWaste  = bucket.totalBurstWaste
        + ((session.survival and session.survival.burstWasteCount) or 0)
    bucket.totalKillWindows = bucket.totalKillWindows
        + (session.killWindows and #session.killWindows or 0)
    bucket.totalKillWindowConversions = bucket.totalKillWindowConversions
        + (session.killWindowConversions or 0)
end

function CombatStore:UpdateAggregatesForSession(session)
    local db = self:GetDB()
    local aggregates = db.aggregates
    updateAggregateContainerForSession(aggregates, session)
    updateRatingHistory(aggregates, session)
    updateBuildEffectiveness(aggregates, session)
    updateSpecDamageSignatures(aggregates, session)
    updateMMRBandStats(aggregates, session)
    updateOpenerSequenceEffectiveness(aggregates, session)
    updateMatchupArchetypes(aggregates, session)
    updateDummyBenchmark(db, session)
    self:UpdateCompAggregate(session)
end

function CombatStore:PersistSession(session)
    if not session or not session.id then
        return
    end

    local db = self:GetDB()
    session.characterKey = session.characterKey or getSessionCharacterKey(session)
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
    -- Invalidate the scoped-session query cache whenever a new session is added.
    if isNew and self._queryCache then
        self._queryCache = {}
    end
    C_Timer.After(0, function()
        self:UpdateAggregatesForSession(session)
    end)

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

function CombatStore:ListCombats(page, pageSize, filters, characterKey)
    local db = self:GetDB()
    local results = {}
    filters = filters or {}
    page = math.max(page or 1, 1)
    pageSize = pageSize or Constants.HISTORY_PAGE_SIZE
    local characterRef = nil
    if characterKey then
        characterRef = type(characterKey) == "table" and characterKey or buildCharacterRef(characterKey, nil, nil)
    end

    for index = #db.combats.order, 1, -1 do
        local sessionId = db.combats.order[index]
        local session = db.combats.byId[sessionId]
        if session then
            local include = true
            if include and characterRef and not matchesCharacter(session, characterRef) then
                include = false
            end
            if filters.context and session.context ~= filters.context then
                include = false
            end
            if include and filters.result and string.lower(tostring(session.result or "")) ~= filters.result then
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

function CombatStore:GetAggregateBuckets(kind, characterKey)
    local db = self:GetDB()
    local characterRef = nil
    if characterKey then
        characterRef = type(characterKey) == "table" and characterKey or buildCharacterRef(characterKey, nil, nil)
    end
    if not characterKey then
        local source = db.aggregates[kind] or {}
        local list = {}
        for _, bucket in pairs(source) do
            list[#list + 1] = bucket
        end
        Helpers.SortByField(list, "fights", true)
        return list
    end

    local aggregates = {
        opponents = {},
        classes = {},
        specs = {},
        builds = {},
        contexts = {},
        daily = {},
        weekly = {},
        ratingHistory = {},
        buildEffectiveness = {},
        specDamageSignatures = {},
    }

    for _, sessionId in ipairs(db.combats.order or {}) do
        local session = db.combats.byId[sessionId]
        if session and matchesCharacter(session, characterRef) then
            updateAggregateContainerForSession(aggregates, session, kind)
        end
    end

    local source = aggregates[kind] or {}
    local list = {}
    for _, bucket in pairs(source) do
        list[#list + 1] = bucket
    end
    Helpers.SortByField(list, "fights", true)
    return list
end

function CombatStore:GetAggregateBucketByKey(kind, key, characterKey)
    if not key then return nil end
    local list = self:GetAggregateBuckets(kind, characterKey)
    local searchKey = tostring(key)
    for _, bucket in ipairs(list) do
        if bucket.key == searchKey then
            return bucket
        end
    end
    return nil
end

function CombatStore:GetSpecBucket(specId, characterKey)
    return self:GetAggregateBucketByKey("specs", specId, characterKey)
end

function CombatStore:GetDummyBenchmarks(characterKey)
    local db = self:GetDB()
    local characterRef = nil
    if characterKey then
        characterRef = type(characterKey) == "table" and characterKey or buildCharacterRef(characterKey, nil, nil)
    end
    if characterKey then
        local filtered = {}
        for _, sessionId in ipairs(db.combats.order or {}) do
            local session = db.combats.byId[sessionId]
            if session
                and matchesCharacter(session, characterRef)
                and session.context == Constants.CONTEXT.TRAINING_DUMMY
            then
                updateDummyBenchmarkRecord(filtered, session)
            end
        end

        local results = {}
        for _, benchmark in pairs(filtered) do
            results[#results + 1] = benchmark
        end
        Helpers.SortByField(results, "lastUpdatedAt", true)
        return results
    end

    local results = {}
    for _, benchmark in pairs(db.dummyBenchmarks) do
        results[#results + 1] = benchmark
    end
    Helpers.SortByField(results, "lastUpdatedAt", true)
    return results
end

function CombatStore:GetRecentSuggestions(limit, characterKey)
    local db = self:GetDB()
    local results = {}
    local characterRef = nil
    if characterKey then
        characterRef = type(characterKey) == "table" and characterKey or buildCharacterRef(characterKey, nil, nil)
    end
    for index = #db.suggestionCache.order, 1, -1 do
        local sessionId = db.suggestionCache.order[index]
        local suggestions = db.suggestionCache.bySessionId[sessionId]
        local session = db.combats.byId[sessionId]
        if suggestions and (not characterRef or (session and matchesCharacter(session, characterRef))) then
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

function CombatStore:GetBuildBaseline(buildHash, context, excludeSessionId, characterKey)
    return self:GetSessionBaseline(buildHash, context, nil, excludeSessionId, characterKey)
end

function CombatStore:GetContextBaseline(contextKey, excludeSessionId, characterKey)
    local characterRef = nil
    if characterKey then
        characterRef = type(characterKey) == "table" and characterKey or buildCharacterRef(characterKey, nil, nil)
    end
    if not excludeSessionId then
        if not characterKey then
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
    end

    local db = self:GetDB()
    local fights = 0
    local totalPressureScore = 0
    local totalBurstScore = 0
    local totalDuration = 0

    for _, sessionId in ipairs(db.combats.order or {}) do
        if sessionId ~= excludeSessionId then
            local session = db.combats.byId[sessionId]
            if session and (not characterRef or matchesCharacter(session, characterRef)) then
                local sessionContextKey = session.subcontext and string.format("%s:%s", session.context, session.subcontext) or session.context
                if sessionContextKey == contextKey then
                    fights = fights + 1
                    totalPressureScore = totalPressureScore + (session.metrics and session.metrics.pressureScore or 0)
                    totalBurstScore = totalBurstScore + (session.metrics and session.metrics.burstScore or 0)
                    totalDuration = totalDuration + (session.duration or 0)
                end
            end
        end
    end

    if fights <= 0 then
        return nil
    end

    return {
        fights = fights,
        averagePressureScore = totalPressureScore / fights,
        averageBurstScore = totalBurstScore / fights,
        averageDuration = totalDuration / fights,
    }
end

function CombatStore:GetOpponentBaseline(opponentKey, excludeSessionId, characterKey)
    if not excludeSessionId then
        if not characterKey then
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
    end

    return self:GetSessionBaseline(nil, nil, opponentKey, excludeSessionId, characterKey)
end

function CombatStore:GetSessionBaseline(buildHash, contextKey, opponentKey, excludeSessionId, characterKey)
    local db = self:GetDB()
    local characterRef = nil
    if characterKey then
        characterRef = type(characterKey) == "table" and characterKey or buildCharacterRef(characterKey, nil, nil)
    end
    local fights = 0
    local wins = 0
    local losses = 0
    local totalDamageDone = 0
    local totalDamageTaken = 0
    local totalPressureScore = 0
    local totalBurstScore = 0
    local totalSurvivabilityScore = 0
    local totalOpenerDamage = 0
    local totalDuration = 0
    local totalFirstMajorOffensiveAt = 0
    local totalFirstMajorDefensiveAt = 0
    local firstMajorOffensiveSamples = 0
    local firstMajorDefensiveSamples = 0

    for _, sessionId in ipairs(db.combats.order or {}) do
        local session = db.combats.byId[sessionId]
        if session
            and sessionId ~= excludeSessionId
            and (not characterRef or matchesCharacter(session, characterRef))
        then
            local sessionBuildHash = session.playerSnapshot and session.playerSnapshot.buildHash or "unknown"
            local sessionContextKey = session.subcontext and string.format("%s:%s", session.context, session.subcontext) or session.context
            local sessionOpponentKey = session.primaryOpponent and (session.primaryOpponent.guid or session.primaryOpponent.name) or nil

            if (not buildHash or sessionBuildHash == buildHash)
                and (not contextKey or sessionContextKey == contextKey)
                and (not opponentKey or sessionOpponentKey == opponentKey)
            then
                local openerFingerprint = session.openerFingerprint or {}
                fights = fights + 1
                totalDamageDone = totalDamageDone + (session.totals.damageDone or 0)
                totalDamageTaken = totalDamageTaken + (session.totals.damageTaken or 0)
                totalPressureScore = totalPressureScore + (session.metrics and session.metrics.pressureScore or 0)
                totalBurstScore = totalBurstScore + (session.metrics and session.metrics.burstScore or 0)
                totalSurvivabilityScore = totalSurvivabilityScore + (session.metrics and session.metrics.survivabilityScore or 0)
                totalOpenerDamage = totalOpenerDamage + (session.metrics and session.metrics.openerDamage or 0)
                totalDuration = totalDuration + (session.duration or 0)

                if openerFingerprint.firstMajorOffensiveAt then
                    totalFirstMajorOffensiveAt = totalFirstMajorOffensiveAt + openerFingerprint.firstMajorOffensiveAt
                    firstMajorOffensiveSamples = firstMajorOffensiveSamples + 1
                end
                if openerFingerprint.firstMajorDefensiveAt then
                    totalFirstMajorDefensiveAt = totalFirstMajorDefensiveAt + openerFingerprint.firstMajorDefensiveAt
                    firstMajorDefensiveSamples = firstMajorDefensiveSamples + 1
                end

                if session.result == Constants.SESSION_RESULT.WON then
                    wins = wins + 1
                elseif session.result == Constants.SESSION_RESULT.LOST then
                    losses = losses + 1
                end
            end
        end
    end

    if fights <= 0 then
        return nil
    end

    return {
        fights = fights,
        wins = wins,
        losses = losses,
        averageDamageDone = totalDamageDone / fights,
        averageDamageTaken = totalDamageTaken / fights,
        averagePressureScore = totalPressureScore / fights,
        averageBurstScore = totalBurstScore / fights,
        averageSurvivabilityScore = totalSurvivabilityScore / fights,
        averageOpenerDamage = totalOpenerDamage / fights,
        averageDuration = totalDuration / fights,
        averageFirstMajorOffensiveAt = firstMajorOffensiveSamples > 0 and (totalFirstMajorOffensiveAt / firstMajorOffensiveSamples) or nil,
        averageFirstMajorDefensiveAt = firstMajorDefensiveSamples > 0 and (totalFirstMajorDefensiveAt / firstMajorDefensiveSamples) or nil,
    }
end

function CombatStore:GetDuelPracticeSummary(buildHash, opponentKey, characterKey)
    return self:GetSessionBaseline(buildHash, Constants.CONTEXT.DUEL, opponentKey, nil, characterKey)
end

function CombatStore:GetRatingTrend(characterKey, context, subcontext, n)
    local db = self:GetDB()
    local charKey = characterKey or self:GetCurrentCharacterKey()

    -- "All" mode: context is nil — merge all rating history entries for this
    -- character across every context key, then sort by timestamp.
    if not context then
        local merged = {}
        for historyKey, entries in pairs(db.aggregates.ratingHistory or {}) do
            -- historyKey format is "charKey:contextKey"
            if historyKey:sub(1, #charKey + 1) == charKey .. ":" then
                for _, entry in ipairs(entries) do
                    merged[#merged + 1] = entry
                end
            end
        end
        table.sort(merged, function(a, b)
            return (a.timestamp or 0) < (b.timestamp or 0)
        end)
        if n and n < #merged then
            local result = {}
            local start = #merged - n + 1
            for i = start, #merged do
                result[#result + 1] = merged[i]
            end
            return result
        end
        return merged
    end

    local contextKey = context
    if subcontext then
        contextKey = string.format("%s:%s", contextKey, subcontext)
    end
    local historyKey = string.format("%s:%s", charKey, contextKey)
    local history = db.aggregates.ratingHistory and db.aggregates.ratingHistory[historyKey] or {}
    if not n or n >= #history then
        return history
    end
    -- Return last n entries
    local result = {}
    local start = #history - n + 1
    for i = start, #history do
        result[#result + 1] = history[i]
    end
    return result
end

function CombatStore:GetBuildEffectivenessVsSpec(buildHash, specId)
    local db = self:GetDB()
    local buildBucket = db.aggregates.buildEffectiveness and db.aggregates.buildEffectiveness[buildHash]
    if not buildBucket then return nil end
    return buildBucket[tostring(specId)]
end

function CombatStore:GetBestBuildVsSpec(specId)
    local db = self:GetDB()
    local specKey = tostring(specId)
    local best, bestWinRate = nil, -1
    for buildHash, specBucket in pairs(db.aggregates.buildEffectiveness or {}) do
        local entry = specBucket[specKey]
        if entry and entry.fights >= 3 then
            local winRate = entry.wins / entry.fights
            if winRate > bestWinRate then
                bestWinRate = winRate
                best = { buildHash = buildHash, winRate = winRate, fights = entry.fights, wins = entry.wins }
            end
        end
    end
    return best
end

--- Returns ALL builds with 3+ sessions vs a given spec, sorted by win rate descending.
function CombatStore:GetAllBuildsVsSpec(specId, currentBuildHash)
    local db = self:GetDB()
    local specKey = tostring(specId)
    local list = {}
    for buildHash, specBucket in pairs(db.aggregates.buildEffectiveness or {}) do
        local entry = specBucket[specKey]
        if entry and entry.fights >= 3 then
            list[#list + 1] = {
                buildHash = buildHash,
                winRate = entry.wins / entry.fights,
                fights = entry.fights,
                wins = entry.wins,
                losses = entry.losses or (entry.fights - entry.wins),
                avgPressure = entry.totalPressureScore and entry.fights > 0
                    and (entry.totalPressureScore / entry.fights) or 0,
                isCurrent = buildHash == currentBuildHash,
            }
        end
    end
    table.sort(list, function(a, b) return a.winRate > b.winRate end)
    return list
end

function CombatStore:GetSpecDamageSignature(specId)
    local db = self:GetDB()
    local specKey = tostring(specId)
    local sig = db.aggregates.specDamageSignatures and db.aggregates.specDamageSignatures[specKey]
    if not sig or not sig.spells then return {} end

    local list = {}
    for _, entry in pairs(sig.spells) do
        local hitCount = entry.hitCount or 0
        local critCount = entry.critCount or 0
        local totalDamage = entry.totalDamage or 0
        list[#list + 1] = {
            spellId = entry.spellId,
            totalDamage = totalDamage,
            hitCount = hitCount,
            critRate = critCount / math.max(hitCount, 1),
            avgDamagePerCast = totalDamage / math.max(hitCount, 1),
        }
    end

    Helpers.SortByField(list, "totalDamage", true)

    -- Return top 15
    local result = {}
    for i = 1, math.min(15, #list) do
        result[#result + 1] = list[i]
    end
    return result
end

function CombatStore:GetSpecWinRateByMMRBand(specId, characterKey)
    local db = self:GetDB()
    local specKey = tostring(specId)

    local specBucket
    if characterKey then
        -- Rebuild spec bucket for this character
        local characterRef = type(characterKey) == "table" and characterKey or buildCharacterRef(characterKey, nil, nil)
        local tempAggregates = {
            opponents = {}, classes = {}, specs = {}, builds = {},
            contexts = {}, daily = {}, weekly = {},
            ratingHistory = {}, buildEffectiveness = {}, specDamageSignatures = {},
        }
        for _, sessionId in ipairs(db.combats.order or {}) do
            local session = db.combats.byId[sessionId]
            if session and matchesCharacter(session, characterRef) then
                updateAggregateContainerForSession(tempAggregates, session, Constants.AGGREGATE_KIND.SPEC)
                updateMMRBandStats(tempAggregates, session)
            end
        end
        specBucket = tempAggregates.specs[specKey]
    else
        specBucket = db.aggregates.specs[specKey]
    end

    if not specBucket or not specBucket.mmrBands then return {} end

    local result = {}
    for _, band in ipairs(Constants.MMR_BANDS) do
        local bandData = specBucket.mmrBands[band.label]
        if bandData then
            local fights = bandData.fights or 0
            result[#result + 1] = {
                label = band.label,
                fights = fights,
                wins = bandData.wins or 0,
                losses = bandData.losses or 0,
                winRate = fights > 0 and ((bandData.wins or 0) / fights) or 0,
            }
        else
            result[#result + 1] = {
                label = band.label,
                fights = 0,
                wins = 0,
                losses = 0,
                winRate = 0,
            }
        end
    end
    return result
end

function CombatStore:GetOpenerSequenceEffectiveness(specId)
    local db = self:GetDB()
    local specKey = tostring(specId)
    local bucket = db.aggregates.openerSequenceEffectiveness and db.aggregates.openerSequenceEffectiveness[specKey]
    if not bucket then return {} end
    return bucket
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
        ratingHistory = {},
        buildEffectiveness = {},
        specDamageSignatures = {},
        soloShuffleSpecStats = {},
        bgBlitzSpecStats = {},
        openerSequenceEffectiveness = {},
        comps = {},
        matchupArchetypes = {},
        openers = {},
        matchupMemory = {},
        duelSeries = {},
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

function CombatStore:UpdateSoloShuffleStats()
    local db = self:GetDB()
    local result = ApiCompat.GetPersonalRatedSoloShuffleSpecStats()
    if result then
        db.aggregates.soloShuffleSpecStats = result
    end
end

function CombatStore:UpdateBGBlitzStats()
    local db = self:GetDB()
    local result = ApiCompat.GetPersonalRatedBGBlitzSpecStats()
    if result then
        db.aggregates.bgBlitzSpecStats = result
    end
end

function CombatStore:GetSoloShuffleSpecStats()
    local db = self:GetDB()
    return db.aggregates.soloShuffleSpecStats or {}
end

function CombatStore:GetBGBlitzSpecStats()
    local db = self:GetDB()
    return db.aggregates.bgBlitzSpecStats or {}
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Phase 3.3: Tilt / Momentum Detection
-- ──────────────────────────────────────────────────────────────────────────────

--- Returns the last N sessions in reverse-chronological order with result + metrics.
--- @param n number  How many sessions to retrieve (default 5).
--- @return table[]  Array of {id, result, pressureScore, duration, context}.
function CombatStore:GetRecentSessionStreak(n)
    n = n or 5
    local db = self:GetDB()
    local order = db.combats.order
    local out = {}
    for i = #order, math.max(1, #order - n + 1), -1 do
        local sess = db.combats.byId[order[i]]
        if sess then
            out[#out + 1] = {
                id            = sess.id,
                result        = sess.result,
                pressureScore = sess.metrics and sess.metrics.pressureScore or 0,
                duration      = sess.duration or 0,
                context       = sess.context,
            }
        end
    end
    return out
end

--- Returns the average pressureScore over the last N sessions of a given context.
--- @param context string|nil  Filter by context (nil = all).
--- @param n number  How many sessions to average over (default 20).
function CombatStore:GetPressureBaseline(context, n)
    n = n or 20
    local db = self:GetDB()
    local order = db.combats.order
    local sum, count = 0, 0
    for i = #order, 1, -1 do
        if count >= n then break end
        local sess = db.combats.byId[order[i]]
        if sess and (not context or sess.context == context) then
            local pressure = sess.metrics and sess.metrics.pressureScore or 0
            sum = sum + pressure
            count = count + 1
        end
    end
    return count > 0 and (sum / count) or 0
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Phase 3.4: Comp-level aggregates
-- ──────────────────────────────────────────────────────────────────────────────

function CombatStore:UpdateCompAggregate(session)
    if not session or not session.opponentCompKey then return end
    local db = self:GetDB()
    db.aggregates.comps = db.aggregates.comps or {}
    local key = session.opponentCompKey
    local comp = db.aggregates.comps[key]
    if not comp then
        comp = { fights = 0, wins = 0, losses = 0, lastSessionId = nil, avgDuration = 0 }
        db.aggregates.comps[key] = comp
    end
    comp.fights = comp.fights + 1
    if session.result == Constants.SESSION_RESULT.WON then
        comp.wins = comp.wins + 1
    elseif session.result == Constants.SESSION_RESULT.LOST then
        comp.losses = comp.losses + 1
    end
    -- Running average duration
    comp.avgDuration = comp.avgDuration + ((session.duration or 0) - comp.avgDuration) / comp.fights
    comp.lastSessionId = session.id
end

function CombatStore:GetCompWinRates()
    local db = self:GetDB()
    return db.aggregates.comps or {}
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Weighted win rate helpers (lazy computation — NOT stored in SavedVariables)
-- ──────────────────────────────────────────────────────────────────────────────

-- computeWeightedWinRate
-- Exponentially decay-weighted win rate over the most recent `windowSize`
-- matching sessions.  Newest match has weight 1.0; each older match is
-- multiplied by `decay`.
-- Returns: weightedWinRate (0–1), sampleCount (int)
local function computeWeightedWinRate(sessions, filterFn, windowSize, decay)
    windowSize = windowSize or 30
    decay      = decay      or 0.9

    -- Collect matching sessions, newest first (sessions is ordered oldest→newest).
    local matching = {}
    for i = #sessions, 1, -1 do
        local s = sessions[i]
        if not filterFn or filterFn(s) then
            matching[#matching + 1] = s
            if #matching >= windowSize then break end
        end
    end

    if #matching == 0 then return 0, 0 end

    local weightedSum = 0
    local totalWeight = 0
    for i, s in ipairs(matching) do
        local weight = decay ^ (i - 1)   -- i=1 is newest → weight = 1.0
        local result = (s.result == Constants.SESSION_RESULT.WON) and 1 or 0
        weightedSum  = weightedSum + result * weight
        totalWeight  = totalWeight + weight
    end

    return weightedSum / totalWeight, #matching
end
CombatStore.ComputeWeightedWinRate = computeWeightedWinRate

--- Returns the exponentially decay-weighted win rate across all sessions.
--- @return number weightedWinRate  0–1
--- @return number sampleCount
function CombatStore:GetOverallWeightedWinRate()
    local db = self:GetDB()
    local sessions = {}
    for _, sessionId in ipairs(db.combats.order or {}) do
        local s = db.combats.byId[sessionId]
        if s then sessions[#sessions + 1] = s end
    end
    return computeWeightedWinRate(sessions, nil, 30, 0.9)
end

--- Returns the exponentially decay-weighted win rate for a specific build hash.
--- @param buildHash string
--- @return number weightedWinRate  0–1
--- @return number sampleCount
function CombatStore:GetBuildWeightedWinRate(buildHash)
    local db = self:GetDB()
    local sessions = {}
    for _, sessionId in ipairs(db.combats.order or {}) do
        local s = db.combats.byId[sessionId]
        if s then sessions[#sessions + 1] = s end
    end
    return computeWeightedWinRate(sessions, function(s)
        return s.playerSnapshot and s.playerSnapshot.buildHash == buildHash
    end, 30, 0.9)
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Build Catalog Persistence API (feature 003-build-comparator-overhaul)
-- ──────────────────────────────────────────────────────────────────────────────

-- In-memory query cache. Invalidated in PersistSession when isNew == true.
CombatStore._queryCache = {}

-- Create or merge-update a build profile entry in the catalog.
-- Only non-nil fields in |fields| overwrite existing values; firstSeenAt is
-- never overwritten after creation.
function CombatStore:UpsertBuildProfile(buildId, fields)
    if not buildId or not fields then return end
    local db = self:GetDB()
    local existing = db.buildCatalog.byId[buildId]
    if not existing then
        -- New profile: insert into order array.
        db.buildCatalog.byId[buildId] = {
            buildId               = buildId,
            buildIdentityVersion  = fields.buildIdentityVersion or Constants.BUILD_IDENTITY_VERSION,
            classId               = fields.classId,
            specId                = fields.specId,
            heroTalentSpecId      = fields.heroTalentSpecId,
            talentSignature       = fields.talentSignature or "",
            pvpTalentSignature    = fields.pvpTalentSignature or "",
            displayNames          = fields.displayNames or {},
            aliases               = fields.aliases or {},
            associatedLoadoutIds  = fields.associatedLoadoutIds or {},
            legacyBuildHashes     = fields.legacyBuildHashes or {},
            firstSeenAt           = fields.firstSeenAt or GetTime(),
            lastSeenAt            = fields.lastSeenAt or GetTime(),
            latestSessionId       = fields.latestSessionId,
            sessionCount          = fields.sessionCount or 0,
            characterKey          = fields.characterKey,
            isCurrentBuild        = fields.isCurrentBuild or false,
            isArchived            = fields.isArchived or false,
            isLowConfidence       = fields.isLowConfidence or false,
            isMigrated            = fields.isMigrated or false,
            isMigratedWithWarnings = fields.isMigratedWithWarnings or false,
        }
        db.buildCatalog.order[#db.buildCatalog.order + 1] = buildId
    else
        -- Merge update: overwrite non-nil fields except firstSeenAt.
        for k, v in pairs(fields) do
            if k ~= "firstSeenAt" and v ~= nil then
                existing[k] = v
            end
        end
        -- Append new legacy hashes without duplicates.
        if fields.legacyBuildHashes then
            existing.legacyBuildHashes = existing.legacyBuildHashes or {}
            for _, h in ipairs(fields.legacyBuildHashes) do
                local found = false
                for _, eh in ipairs(existing.legacyBuildHashes) do
                    if eh == h then found = true; break end
                end
                if not found then
                    existing.legacyBuildHashes[#existing.legacyBuildHashes + 1] = h
                end
            end
        end
    end
end

-- Return the build profile for the given buildId, or nil if not found.
function CombatStore:GetBuildProfile(buildId)
    if not buildId then return nil end
    local db = self:GetDB()
    return db.buildCatalog.byId[buildId]
end

-- Return all non-archived build profiles for a character, sorted by lastSeenAt
-- descending. If characterKey is nil, returns profiles for all characters.
function CombatStore:GetAllBuildProfiles(characterKey)
    local db = self:GetDB()
    local results = {}
    for _, bid in ipairs(db.buildCatalog.order) do
        local p = db.buildCatalog.byId[bid]
        if p and not p.isArchived then
            if not characterKey or p.characterKey == characterKey then
                results[#results + 1] = p
            end
        end
    end
    table.sort(results, function(a, b)
        return (a.lastSeenAt or 0) > (b.lastSeenAt or 0)
    end)
    return results
end

-- Set a named boolean flag on a build profile.
function CombatStore:UpdateBuildProfileFlag(buildId, flag, value)
    if not buildId or not flag then return end
    local db = self:GetDB()
    local profile = db.buildCatalog.byId[buildId]
    if profile then
        profile[flag] = value
    end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Scoped Session Query (feature 003-build-comparator-overhaul)
-- ──────────────────────────────────────────────────────────────────────────────

-- Build a stable string key from scope for cache lookups.
local function buildQueryCacheKey(buildId, scope)
    scope = scope or {}
    return table.concat({
        buildId,
        scope.characterKey or "",
        tostring(scope.specId or ""),
        scope.context or "",
        scope.bracket or "",
        tostring(scope.opponentClassId or ""),
        tostring(scope.opponentSpecId or ""),
        tostring(scope.dateFrom or ""),
        tostring(scope.dateTo or ""),
    }, ":")
end

-- Return all sessions whose playerSnapshot.buildId matches buildId, filtered
-- by the optional scope fields. Nil scope fields are treated as wildcards.
-- Results are cached per (buildId, scopeKey) for the session lifetime; cache
-- is invalidated in PersistSession when a new session is added.
function CombatStore:GetSessionsForBuild(buildId, scope)
    if not buildId then return {} end
    self._queryCache = self._queryCache or {}
    local cacheKey = buildQueryCacheKey(buildId, scope)
    if self._queryCache[cacheKey] then
        return self._queryCache[cacheKey]
    end

    local db = self:GetDB()
    scope = scope or {}
    local results = {}

    for _, sessionId in ipairs(db.combats.order) do
        local session = db.combats.byId[sessionId]
        if session then
            local snap = session.playerSnapshot
            -- Must match canonical buildId.
            if snap and snap.buildId == buildId then
                local match = true

                if scope.characterKey and session.characterKey ~= scope.characterKey then
                    match = false
                end
                if match and scope.specId and snap.specId ~= scope.specId then
                    match = false
                end
                if match and scope.context and session.context ~= scope.context then
                    match = false
                end
                if match and scope.bracket and session.subcontext ~= scope.bracket then
                    match = false
                end
                if match and scope.opponentClassId then
                    local opp = session.primaryOpponent
                    if not opp or opp.classId ~= scope.opponentClassId then
                        match = false
                    end
                end
                if match and scope.opponentSpecId then
                    local opp = session.primaryOpponent
                    if not opp or opp.specId ~= scope.opponentSpecId then
                        match = false
                    end
                end
                if match and scope.dateFrom and (session.timestamp or 0) < scope.dateFrom then
                    match = false
                end
                if match and scope.dateTo and (session.timestamp or 0) > scope.dateTo then
                    match = false
                end

                if match then
                    results[#results + 1] = session
                end
            end
        end
    end

    self._queryCache[cacheKey] = results
    return results
end

ns.Addon:RegisterModule("CombatStore", CombatStore)
