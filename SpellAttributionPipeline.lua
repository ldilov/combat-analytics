local _, ns = ...

local Constants = ns.Constants

-- SpellAttributionPipeline  (DamageMeter-only attribution)
-- Tracks enemy-source damage attribution independently of session.spells.
-- session.spells is player-only and feeds existing rotation/metric views.
-- session.attribution is enemy-source-aware and feeds PvP analytics:
--   "which enemy did how much damage with which spell to the player"
--
-- Data sources:
--   All attribution is derived from C_DamageMeter via MergeDamageMeterSource,
--   called post-combat by DamageMeterService. No CLEU ingestion paths exist.
--   Provides per-source, per-spell, per-target rows with provenance tagging.
--
-- Attribution state is stored on session.attribution. It is initialized to false
-- on session create (schema v2) and replaced with the live table on first event.
-- This distinction lets downstream code know whether attribution was computed.
local SpellAttributionPipeline = {}

-- ──────────────────────────────────────────────────────────────────────────────
-- Internal helpers
-- ──────────────────────────────────────────────────────────────────────────────

local function ensureTable(t, key)
    t[key] = t[key] or {}
    return t[key]
end

-- Aggregate for a single spell from a single source.
local function newDamageAggregate(spellId)
    return {
        spellId     = spellId,
        totalAmount = 0,
        hitCount    = 0,
        critCount   = 0,
        missCount   = 0,
        overkill    = 0,
        absorbed    = 0,
        blocked     = 0,
        resisted    = 0,
        minAmount   = nil,
        maxAmount   = 0,
        missByType  = {},
    }
end

-- Build a stable string key for a target. GUID-based when available so keys
-- survive name changes. Fallback is name+class+spec to handle NPC targets.
local function targetKey(guid, name, classFile, specIconId)
    if guid and guid ~= "" then
        return "guid:" .. guid
    end
    return string.format("n=%s|c=%s|si=%s",
        tostring(name      or "?"),
        tostring(classFile or "?"),
        tostring(specIconId or 0)
    )
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Attribution state initialization
-- ──────────────────────────────────────────────────────────────────────────────

local function getOrInitState(session)
    if type(session.attribution) ~= "table" then
        session.attribution = {
            -- [guid] = { guid, name, classFile, specId, specIconId,
            --            totalAmount, spells = {[spellId] = aggregate} }
            bySource         = {},
            -- [targetKey] = { key, guid, name, classFile, totalAmount,
            --                 spells = {[spellId] = aggregate} }
            byTarget         = {},
            -- [sourceGuid][spellId] = aggregate
            bySourceSpell    = {},
            -- [sourceGuid][targetKey][spellId] = aggregate
            bySourceTargetSpell = {},
            reconciliation   = {
                localDamage    = 0,
                importedDamage = 0,
                selectedSource = "none",
                confidence     = Constants.ANALYSIS_CONFIDENCE.UNKNOWN,
                delta          = 0,
            },
        }
    end
    return session.attribution
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Lazy ensurers (create on first use)
-- ──────────────────────────────────────────────────────────────────────────────

local function ensureSource(state, guid)
    state.bySource[guid] = state.bySource[guid] or {
        guid        = guid,
        name        = nil,
        classFile   = nil,
        specId      = nil,
        specIconId  = nil,
        totalAmount = 0,
        spells      = {},
    }
    return state.bySource[guid]
end

local function ensureTargetRecord(state, key, guid)
    state.byTarget[key] = state.byTarget[key] or {
        key         = key,
        guid        = guid,
        name        = nil,
        classFile   = nil,
        specIconId  = nil,
        totalAmount = 0,
        spells      = {},
    }
    return state.byTarget[key]
end

local function ensureSourceSpell(state, sourceGuid, spellId)
    local bySpell = ensureTable(state.bySourceSpell, sourceGuid)
    bySpell[spellId] = bySpell[spellId] or newDamageAggregate(spellId)
    return bySpell[spellId]
end

local function ensureSourceTargetSpell(state, sourceGuid, tKey, spellId)
    local byTarget = ensureTable(state.bySourceTargetSpell, sourceGuid)
    local bySpell  = ensureTable(byTarget, tKey)
    bySpell[spellId] = bySpell[spellId] or newDamageAggregate(spellId)
    return bySpell[spellId]
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Module lifecycle
-- ──────────────────────────────────────────────────────────────────────────────

function SpellAttributionPipeline:Initialize()
    -- Stateless module; attribution state lives on sessions.
end

-- ──────────────────────────────────────────────────────────────────────────────
-- DamageMeter source merge
-- Called from DamageMeterService after CollectEnemyDamageSnapshotForSession.
-- Merges per-source, per-spell, per-target detail rows into attribution.
-- Uses max() for totals (not addition) to deduplicate overlapping snapshots.
-- ──────────────────────────────────────────────────────────────────────────────

function SpellAttributionPipeline:MergeDamageMeterSource(session, combatSource, combatSourceDetail)
    if not session or not combatSource then return end
    local state = getOrInitState(session)

    local srcGuid = combatSource.sourceGUID
    local srcKey  = srcGuid or string.format("n=%s|c=%s",
        tostring(combatSource.name or "?"),
        tostring(combatSource.classFilename or "?")
    )

    local src = ensureSource(state, srcKey)
    src.guid      = src.guid      or srcGuid
    src.source    = Constants.PROVENANCE_SOURCE.DAMAGE_METER
    -- Use max to deduplicate overlapping DM snapshots.
    src.totalAmount = math.max(src.totalAmount or 0, tonumber(combatSource.totalAmount) or 0)

    -- T026: When a GUID is available, enrich identity fields via UnitGraphService
    -- (which may carry higher-confidence data than the DM summary rows).
    if srcGuid then
        local ugs = ns.Addon:GetModule("UnitGraphService")
        if ugs then
            local okUgs = pcall(function()
                local identity = ugs:GetBestDisplayIdentity(srcGuid)
                if identity then
                    src.name      = src.name      or identity.name
                    src.classFile = src.classFile or identity.classFile
                    src.specId    = src.specId    or identity.specId
                    src.arenaSlot = src.arenaSlot or identity.arenaSlot
                    -- Carry forward the UGS confidence when it outranks "summary_derived".
                    if not src.confidence or src.confidence == "summary_derived" then
                        src.confidence = identity.confidence
                    end
                end
            end)
            if not okUgs then
                -- Non-fatal; fall back to DM-supplied values below.
            end
        end
    end
    -- Fallback to DM-supplied identity fields when UGS could not enrich.
    src.name      = src.name      or combatSource.name
    src.classFile = src.classFile or combatSource.classFilename
    src.specIconId = src.specIconId or combatSource.specIconID

    -- Merge per-spell details from this source.
    for _, combatSpell in ipairs(combatSourceDetail and combatSourceDetail.combatSpells or {}) do
        local spellId  = combatSpell.spellID or 0
        local srcSpell = ensureSourceSpell(state, srcKey, spellId)
        srcSpell.source = Constants.PROVENANCE_SOURCE.DAMAGE_METER
        srcSpell.totalAmount = math.max(
            srcSpell.totalAmount or 0,
            tonumber(combatSpell.totalAmount) or 0
        )
        srcSpell.overkill = math.max(
            srcSpell.overkill or 0,
            tonumber(combatSpell.overkillAmount) or 0
        )

        -- Per-target rows within the spell.
        for _, detail in ipairs(combatSpell.combatSpellDetails or {}) do
            local tKey  = targetKey(nil, detail.unitName, detail.unitClassFilename, detail.specIconID)
            local tgt   = ensureTargetRecord(state, tKey, nil)
            tgt.name      = tgt.name      or detail.unitName
            tgt.classFile = tgt.classFile or detail.unitClassFilename
            tgt.specIconId = tgt.specIconId or detail.specIconID

            local srcTgtSpell = ensureSourceTargetSpell(state, srcKey, tKey, spellId)
            srcTgtSpell.source = Constants.PROVENANCE_SOURCE.DAMAGE_METER
            local detailAmount = tonumber(detail.amount) or 0
            -- Use addition here — DamageMeter rows within a spell are per-hit entries.
            srcTgtSpell.totalAmount = (srcTgtSpell.totalAmount or 0) + detailAmount
            tgt.totalAmount = (tgt.totalAmount or 0) + detailAmount
        end
    end

    return src
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Reconciliation finalization
-- Called from DamageMeterService:ImportSession() after all sources are merged.
-- ──────────────────────────────────────────────────────────────────────────────

function SpellAttributionPipeline:FinalizeReconciliation(session, importedTotal, selectedSource)
    if not session then return end
    local state = getOrInitState(session)
    local r = state.reconciliation

    local localDmg    = tonumber(r.localDamage) or 0
    local importedDmg = tonumber(importedTotal) or 0

    r.importedDamage = importedDmg
    r.selectedSource = selectedSource or "none"

    if importedDmg <= 0 and localDmg > 0 then
        r.delta      = 0
        r.confidence = Constants.ANALYSIS_CONFIDENCE.FULL_RAW
        return r
    end

    if importedDmg <= 0 then
        r.delta      = 1
        r.confidence = Constants.ANALYSIS_CONFIDENCE.UNKNOWN
        return r
    end

    local delta = math.abs(localDmg - importedDmg) / math.max(importedDmg, 1)
    r.delta = delta

    if delta <= 0.05 then
        r.confidence = Constants.ANALYSIS_CONFIDENCE.ENRICHED
    elseif delta <= 0.12 then
        r.confidence = Constants.ANALYSIS_CONFIDENCE.RESTRICTED_RAW
    else
        r.confidence = Constants.ANALYSIS_CONFIDENCE.DEGRADED
    end

    ns.Addon:Trace("attribution.reconciliation", {
        delta          = delta,
        importedDamage = importedDmg,
        localDamage    = localDmg,
        confidence     = r.confidence,
    })
    return r
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Query helpers (used by UI and suggestion engine)
-- ──────────────────────────────────────────────────────────────────────────────

-- Returns the enemy source with the highest total incoming damage, or nil.
function SpellAttributionPipeline:GetTopIncomingSource(session)
    if not session or type(session.attribution) ~= "table" then return nil end
    local best, bestAmount = nil, 0
    for _, src in pairs(session.attribution.bySource) do
        if (src.totalAmount or 0) > bestAmount then
            best       = src
            bestAmount = src.totalAmount
        end
    end
    return best
end

-- Returns the spell aggregate with the highest total from the given source guid.
function SpellAttributionPipeline:GetTopSpellForSource(session, sourceGuid)
    if not session or type(session.attribution) ~= "table" or not sourceGuid then
        return nil
    end
    local spells = session.attribution.bySourceSpell[sourceGuid]
    if not spells then return nil end
    local best, bestAmount = nil, 0
    for _, agg in pairs(spells) do
        if (agg.totalAmount or 0) > bestAmount then
            best       = agg
            bestAmount = agg.totalAmount
        end
    end
    return best
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Registration
-- ──────────────────────────────────────────────────────────────────────────────
ns.Addon:RegisterModule("SpellAttributionPipeline", SpellAttributionPipeline)
