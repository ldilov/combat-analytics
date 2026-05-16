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

-- T025-T027: Guardian attribution — maps summoned guardian GUIDs to their owners.
-- Populated by HandleSummonEvent (SPELL_SUMMON) and cleaned on UNIT_DIED.
-- When a guardian deals damage, the pipeline re-attributes it to the owner GUID.
local summonMap = {}

-- COMBATLOG_OBJECT_TYPE_GUARDIAN flag for sourceFlags-based guardian detection.
local COMBATLOG_OBJECT_TYPE_GUARDIAN = 0x00002000

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
    -- T025: Clear summonMap on init to avoid stale cross-session references.
    wipe(summonMap)
end

-- ──────────────────────────────────────────────────────────────────────────────
-- T025-T027: Guardian / summon tracking
-- ──────────────────────────────────────────────────────────────────────────────

--- Record a SPELL_SUMMON event to map guardian GUID → owner GUID.
--- Called from CombatTracker event routing when SPELL_SUMMON fires.
function SpellAttributionPipeline:HandleSummonEvent(sourceGUID, destGUID)
    if sourceGUID and destGUID then
        summonMap[destGUID] = sourceGUID
    end
end

--- Clean up summonMap entry when a summoned unit dies (UNIT_DIED).
function SpellAttributionPipeline:HandleUnitDied(destGUID)
    if destGUID then
        summonMap[destGUID] = nil
    end
end

--- Resolve the effective source GUID for attribution purposes.
--- If sourceGUID belongs to a known guardian, returns the owner GUID instead.
--- Also checks sourceFlags for the GUARDIAN type bit as a fallback.
--- @param sourceGUID string  The damage source GUID.
--- @param sourceFlags number|nil  The CLEU sourceFlags bitmask.
--- @return string  The resolved owner GUID, or the original sourceGUID.
function SpellAttributionPipeline:ResolveOwnerGUID(sourceGUID, sourceFlags)
    -- Direct summonMap lookup (most reliable).
    local owner = sourceGUID and summonMap[sourceGUID]
    if owner then
        return owner
    end
    -- Fallback: if sourceFlags indicate a guardian but summonMap missed it,
    -- return nil to signal "unknown owner". The caller should use sourceGUID as-is.
    if sourceFlags and bit.band(sourceFlags, COMBATLOG_OBJECT_TYPE_GUARDIAN) > 0 then
        -- Guardian without a known owner — flag it for diagnostics but
        -- keep the original sourceGUID so damage isn't lost.
        return sourceGUID
    end
    return sourceGUID
end

--- Get the current summonMap (for diagnostics / testing).
function SpellAttributionPipeline:GetSummonMap()
    return summonMap
end

--- Clear guardian tracking state (called on session reset / new match).
function SpellAttributionPipeline:ResetSummonMap()
    wipe(summonMap)
end

--- B5: Populate summonMap from UnitGraphService pet-owner state.
--- SPELL_SUMMON never fires in instanced PvP (no CLEU), so the only
--- guardian->owner signal available is UnitGraphService's UNIT_PET-derived
--- petOwners map ([petGuid] = ownerGuid). Copy each known relationship into
--- summonMap so MergeDamageMeterSource:ResolveOwnerGUID re-attributes
--- pet/totem/guardian damage to the owner. Additive and idempotent: a pet
--- GUID maps to a stable owner GUID, so re-running cannot corrupt state.
function SpellAttributionPipeline:PopulateSummonMapFromUnitGraph()
    local ugs = ns.Addon:GetModule("UnitGraphService")
    if not ugs then return 0 end
    local added = 0
    pcall(function()
        local petOwners = ugs.state and ugs.state.petOwners
        if type(petOwners) ~= "table" then return end
        for petGuid, ownerGuid in pairs(petOwners) do
            if petGuid and ownerGuid and petGuid ~= ownerGuid
                and not summonMap[petGuid]
            then
                summonMap[petGuid] = ownerGuid
                added = added + 1
            end
        end
    end)
    return added
end

-- ──────────────────────────────────────────────────────────────────────────────
-- DamageMeter source merge
-- Called from DamageMeterService after CollectEnemyDamageSnapshotForSession.
-- Merges per-source, per-spell, per-target detail rows into attribution.
-- Uses max() for totals (not addition) to deduplicate overlapping snapshots.
-- ──────────────────────────────────────────────────────────────────────────────

--- Begin a new import generation. Call once per ImportSession run BEFORE the
--- per-source MergeDamageMeterSource loop. Clears the additive per-target
--- accumulators so a re-import recomputes them instead of double-counting,
--- while max()-based source/spell totals stay naturally idempotent.
function SpellAttributionPipeline:BeginImportGeneration(session)
    if not session then return end
    local state = getOrInitState(session)
    state.importGeneration = (state.importGeneration or 0) + 1
    state.byTarget = {}
    state.bySourceTargetSpell = {}
    -- This is the per-import reset point: clear the cross-validation flags so
    -- the freshly-regenerated (unscaled) per-target rows get re-scaled on a
    -- re-import (e.g. Solo Shuffle rounds). Leaving crossValidationApplied
    -- sticky would let ApplyScalingFactor early-return and leave the new
    -- generation's rows unscaled. Idempotency is tied to importGeneration via
    -- this reset, not to a permanently-sticky boolean.
    if type(state.reconciliation) == "table" then
        state.reconciliation.crossValidationApplied = nil
        state.reconciliation.crossValidationFactor = nil
        state.reconciliation.crossValidationSkipped = nil
    end
end

function SpellAttributionPipeline:MergeDamageMeterSource(session, combatSource, combatSourceDetail)
    if not session or not combatSource then return end
    local state = getOrInitState(session)

    local srcGuid = combatSource.sourceGUID
    -- T025-T027: Resolve guardian → owner attribution before keying.
    -- If this source GUID belongs to a known guardian, re-attribute to the owner.
    if srcGuid then
        local resolvedGuid = self:ResolveOwnerGUID(srcGuid, nil)
        if resolvedGuid and resolvedGuid ~= srcGuid then
            -- Track the summon relationship in attribution state for diagnostics.
            state.summons = state.summons or {}
            state.summons[srcGuid] = resolvedGuid
            srcGuid = resolvedGuid
        end
    end
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
-- T029-T030: CLEU Cross-Validation — Scaling Factor Application
--
-- When DamageMeterService detects that CLEU-derived totals under-report compared
-- to DM authoritative totals, this method proportionally scales per-spell breakdown
-- amounts so relative distribution is preserved while totals match DM.
--
-- Stub implementation — full logic deferred until CLEU ingestion is re-enabled.
-- ──────────────────────────────────────────────────────────────────────────────

--- Scale all per-spell attribution amounts by a given factor.
--- Preserves relative distribution while adjusting absolute totals.
--- @param session table  A session with populated attribution state.
--- @param factor number  The scaling factor (> 1.0 means CLEU under-reported).
function SpellAttributionPipeline:ApplyScalingFactor(session, factor)
    if not session or not factor or factor <= 1.0 then return end
    if type(session.attribution) ~= "table" then return end

    -- Idempotency guard: never scale the same attribution state twice (a
    -- re-import would otherwise compound the factor).
    local state = session.attribution
    state.reconciliation = state.reconciliation or {}
    if state.reconciliation.crossValidationApplied then return end

    -- Clamp to a sane range: a >3x correction means the source data is too
    -- unreliable to scale meaningfully — skip rather than fabricate damage.
    if factor > 3.0 then
        state.reconciliation.crossValidationFactor = factor
        state.reconciliation.crossValidationApplied = false
        state.reconciliation.crossValidationSkipped = "factor_out_of_range"
        return
    end

    for _, src in pairs(state.bySource or {}) do
        src.totalAmount = (src.totalAmount or 0) * factor
    end

    for _, spells in pairs(state.bySourceSpell or {}) do
        for _, agg in pairs(spells) do
            agg.totalAmount = (agg.totalAmount or 0) * factor
        end
    end

    for _, byTgt in pairs(state.bySourceTargetSpell or {}) do
        for _, spells in pairs(byTgt) do
            for _, agg in pairs(spells) do
                agg.totalAmount = (agg.totalAmount or 0) * factor
            end
        end
    end

    for _, tgt in pairs(state.byTarget or {}) do
        tgt.totalAmount = (tgt.totalAmount or 0) * factor
    end

    state.reconciliation.crossValidationFactor = factor
    state.reconciliation.crossValidationApplied = true
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Registration
-- ──────────────────────────────────────────────────────────────────────────────
ns.Addon:RegisterModule("SpellAttributionPipeline", SpellAttributionPipeline)
