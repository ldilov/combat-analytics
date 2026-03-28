local _, ns = ...

local Constants   = ns.Constants
local BuildHash   = ns.BuildHash

local BuildCatalogService = {}

-- ──────────────────────────────────────────────────────────────────────────────
-- Internal helpers
-- ──────────────────────────────────────────────────────────────────────────────

local function getStore()
    return ns.Addon:GetModule("CombatStore")
end

local function getSnapshotService()
    return ns.Addon:GetModule("SnapshotService")
end

-- Clear isCurrentBuild on every profile belonging to characterKey+specId except
-- the one being set as current. Called before marking the new current profile.
local function clearCurrentBuildFlags(characterKey, specId, exceptBuildId)
    local store = getStore()
    if not store then return end
    local profiles = store:GetAllBuildProfiles(characterKey)
    for _, p in ipairs(profiles) do
        if p.isCurrentBuild and p.buildId ~= exceptBuildId then
            -- Only clear flag if same spec (don't disturb other specs' current build).
            if not specId or p.specId == specId then
                store:UpdateBuildProfileFlag(p.buildId, "isCurrentBuild", false)
            end
        end
    end
end

-- Build a human-readable display label for a profile. Uses WoW APIs for
-- spec and hero talent names; falls back gracefully when unavailable.
local function buildDisplayLabel(profile)
    if not profile then return "Unknown Build" end

    -- Spec name.
    local specName = nil
    if profile.specId then
        local ok, _, name = pcall(GetSpecializationInfoByID, profile.specId)
        if ok and name then specName = name end
    end
    specName = specName or ("Spec " .. tostring(profile.specId or "?"))

    -- Hero talent tree name (optional).
    local heroName = nil
    if profile.heroTalentSpecId and profile.heroTalentSpecId ~= 0 then
        -- GetHeroTalentSpecInfo is not always available; guard it.
        if C_ClassTalents and C_ClassTalents.GetHeroTalentSpecInfo then
            local ok2, info = pcall(C_ClassTalents.GetHeroTalentSpecInfo, profile.heroTalentSpecId)
            if ok2 and info and info.name then
                heroName = info.name
            end
        end
        if not heroName then
            -- Fallback: use the spec name suffix from seeded archetype data if available.
            heroName = "Hero " .. tostring(profile.heroTalentSpecId)
        end
    end

    -- Abbreviated PvP talent summary (first two talent names or IDs).
    local pvpParts = {}
    if profile.pvpTalentSignature and profile.pvpTalentSignature ~= "" then
        for idStr in profile.pvpTalentSignature:gmatch("[^,]+") do
            local talentId = tonumber(idStr)
            if talentId then
                local spellName
                if C_Spell and C_Spell.GetSpellName then
                    local ok3, n = pcall(C_Spell.GetSpellName, talentId)
                    spellName = ok3 and n or nil
                else
                    local ok3, n = pcall(GetSpellInfo, talentId)
                    spellName = ok3 and n or nil
                end
                pvpParts[#pvpParts + 1] = spellName or tostring(talentId)
            end
            if #pvpParts >= 2 then break end
        end
    end
    local pvpSuffix = #pvpParts > 0 and (" / " .. table.concat(pvpParts, " + ")) or ""

    if heroName then
        return specName .. " / " .. heroName .. pvpSuffix
    else
        return specName .. pvpSuffix
    end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Core catalog operations (T010)
-- ──────────────────────────────────────────────────────────────────────────────

-- Register or update the catalog entry for the talent setup described by
-- |snapshot|. Sets isCurrentBuild=true on the new/updated profile and clears
-- the flag on all other profiles for the same character+spec.
-- Returns the buildId string, or nil if snapshot is nil/insufficient.
function BuildCatalogService:RefreshFromSnapshot(snapshot)
    if not snapshot then return nil end
    local store = getStore()
    if not store then return nil end

    local buildId = snapshot.buildId or BuildHash.ComputeBuildId(snapshot)
    if not buildId then return nil end

    local loadoutId   = snapshot.loadoutId or BuildHash.ComputeLoadoutId(snapshot)
    local characterKey = snapshot.name and snapshot.realm
        and (snapshot.name .. "-" .. snapshot.realm) or nil
    local specId       = snapshot.specId

    -- Build the initial display label.
    local label = buildDisplayLabel({
        specId           = specId,
        heroTalentSpecId = snapshot.heroTalentSpecId,
        pvpTalentSignature = snapshot.pvpTalents and table.concat(snapshot.pvpTalents, ",") or "",
    })

    -- Serialize identity signatures for storage.
    local pvpSig = ""
    if snapshot.pvpTalents then
        local sorted = {}
        for _, v in ipairs(snapshot.pvpTalents) do sorted[#sorted + 1] = tostring(v) end
        table.sort(sorted)
        pvpSig = table.concat(sorted, ",")
    end

    local talentSig = ""
    if snapshot.talentNodes then
        local parts = {}
        for _, node in ipairs(snapshot.talentNodes) do
            parts[#parts + 1] = table.concat({
                tostring(node.nodeId or 0),
                tostring(node.entryId or 0),
                tostring(node.activeRank or 0),
            }, ":")
        end
        table.sort(parts)
        talentSig = table.concat(parts, "|")
    end

    -- Legacy hash for audit/migration.
    local legacyHash = snapshot.buildHash
    local legacyHashes = legacyHash and { legacyHash } or {}

    -- Loadout ID list.
    local existingProfile = store:GetBuildProfile(buildId)
    local loadoutIds = existingProfile and existingProfile.associatedLoadoutIds or {}
    if loadoutId then
        local found = false
        for _, lid in ipairs(loadoutIds) do
            if lid == loadoutId then found = true; break end
        end
        if not found then
            local newList = {}
            for _, lid in ipairs(loadoutIds) do newList[#newList + 1] = lid end
            newList[#newList + 1] = loadoutId
            loadoutIds = newList
        end
    end

    -- Session count: preserve existing + 1 only on new session attachment.
    -- Actual sessionCount is authoritative from migration/PersistSession callbacks;
    -- here we just ensure the field exists.
    local sessionCount = existingProfile and existingProfile.sessionCount or 0

    clearCurrentBuildFlags(characterKey, specId, buildId)

    store:UpsertBuildProfile(buildId, {
        buildIdentityVersion  = Constants.BUILD_IDENTITY_VERSION,
        classId               = snapshot.classId,
        specId                = specId,
        heroTalentSpecId      = snapshot.heroTalentSpecId,
        talentSignature       = talentSig,
        pvpTalentSignature    = pvpSig,
        displayNames          = { label },
        associatedLoadoutIds  = loadoutIds,
        legacyBuildHashes     = legacyHashes,
        lastSeenAt            = GetTime(),
        sessionCount          = sessionCount,
        characterKey          = characterKey,
        isCurrentBuild        = true,
        isLowConfidence       = sessionCount < Constants.CONFIDENCE_TIER_THRESHOLDS.LOW_MIN,
    })

    ns.Addon:Trace("catalog.refresh", {
        buildId        = buildId,
        specId         = specId or 0,
        freshness      = snapshot.snapshotFreshness or "unknown",
        isCurrentBuild = true,
    })

    return buildId
end

-- Return the catalog profile where isCurrentBuild == true for the current
-- character. Falls back to constructing a transient (non-persisted) profile
-- from the live snapshot if none is flagged.
function BuildCatalogService:GetCurrentLiveBuild()
    local store = getStore()
    if not store then return nil end
    local svc = getSnapshotService()

    local snapshot = svc and svc:GetLatestPlayerSnapshot()
    if not snapshot then return nil end

    local characterKey = snapshot.name and snapshot.realm
        and (snapshot.name .. "-" .. snapshot.realm) or nil

    -- Look for the flagged current profile first.
    if characterKey then
        local profiles = store:GetAllBuildProfiles(characterKey)
        for _, p in ipairs(profiles) do
            if p.isCurrentBuild then return p end
        end
    end

    -- No flagged profile: build and return a transient one without persisting.
    local buildId = snapshot.buildId or BuildHash.ComputeBuildId(snapshot)
    if not buildId then return nil end

    local pvpSig = ""
    if snapshot.pvpTalents then
        local sorted = {}
        for _, v in ipairs(snapshot.pvpTalents) do sorted[#sorted + 1] = tostring(v) end
        table.sort(sorted)
        pvpSig = table.concat(sorted, ",")
    end

    return {
        buildId           = buildId,
        specId            = snapshot.specId,
        heroTalentSpecId  = snapshot.heroTalentSpecId,
        pvpTalentSignature = pvpSig,
        characterKey      = characterKey,
        isCurrentBuild    = true,
        sessionCount      = 0,
        firstSeenAt       = GetTime(),
        lastSeenAt        = GetTime(),
        displayNames      = { buildDisplayLabel({
            specId           = snapshot.specId,
            heroTalentSpecId = snapshot.heroTalentSpecId,
            pvpTalentSignature = pvpSig,
        })},
        _isTransient = true,  -- marker: not persisted to catalog
    }
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Catalog query methods (T011)
-- ──────────────────────────────────────────────────────────────────────────────

-- Return all non-archived profiles for characterKey, sorted by lastSeenAt desc
-- with the current live build pinned first.
function BuildCatalogService:GetAllProfiles(characterKey)
    local store = getStore()
    if not store then return {} end

    -- Default to current character key if nil.
    if not characterKey then
        local svc = getSnapshotService()
        local snap = svc and svc:GetLatestPlayerSnapshot()
        if snap and snap.name and snap.realm then
            characterKey = snap.name .. "-" .. snap.realm
        end
    end

    local profiles = store:GetAllBuildProfiles(characterKey)

    -- Pin current live build at index 1.
    local result = {}
    local currentIdx = nil
    for i, p in ipairs(profiles) do
        if p.isCurrentBuild then currentIdx = i; break end
    end
    if currentIdx then
        result[1] = profiles[currentIdx]
        for i, p in ipairs(profiles) do
            if i ~= currentIdx then
                result[#result + 1] = p
            end
        end
    else
        -- No persisted current build; prepend a transient one.
        local live = self:GetCurrentLiveBuild()
        if live then result[1] = live end
        for _, p in ipairs(profiles) do result[#result + 1] = p end
    end

    return result
end

-- Return a single profile by buildId.
function BuildCatalogService:GetProfile(buildId)
    if not buildId then return nil end
    local store = getStore()
    return store and store:GetBuildProfile(buildId) or nil
end

-- Return a human-readable label for a buildId. Never returns nil.
-- If the profile has at least one user-assigned alias (FR-039), the first alias
-- is appended in brackets so it is visible everywhere the label is shown.
function BuildCatalogService:GetDisplayLabel(buildId)
    if not buildId then return "Unknown Build" end
    local profile = self:GetProfile(buildId)
    if profile then
        local base
        if profile.displayNames and profile.displayNames[1] then
            base = profile.displayNames[1]
        else
            base = buildDisplayLabel(profile)
        end
        -- Append the first user alias when present (FR-039: aliases visible in comparator).
        if profile.aliases and profile.aliases[1] then
            return base .. "  [" .. profile.aliases[1] .. "]"
        end
        return base
    end
    return "Unknown Build"
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Management methods (T012)
-- ──────────────────────────────────────────────────────────────────────────────

-- Add an alias to a build profile. Deduplicates case-insensitively.
-- Returns true on success, false if buildId not found or alias is invalid.
function BuildCatalogService:SetAlias(buildId, alias)
    if not buildId or type(alias) ~= "string" or alias == "" or #alias > 64 then
        return false
    end
    local store = getStore()
    if not store then return false end
    local profile = store:GetBuildProfile(buildId)
    if not profile then return false end

    profile.aliases = profile.aliases or {}
    local aliasLower = alias:lower()
    for _, existing in ipairs(profile.aliases) do
        if existing:lower() == aliasLower then return true end  -- already present
    end
    profile.aliases[#profile.aliases + 1] = alias
    return true
end

-- Set isArchived=true on a profile, removing it from selector listings.
function BuildCatalogService:ArchiveProfile(buildId)
    if not buildId then return false end
    local store = getStore()
    if not store then return false end
    if not store:GetBuildProfile(buildId) then return false end
    store:UpdateBuildProfileFlag(buildId, "isArchived", true)
    return true
end

-- Return migration warnings recorded during v6→v7 migration.
-- Returns an empty table until the migration phase populates this.
function BuildCatalogService:GetMigrationWarnings()
    local store = getStore()
    if not store then return {} end
    local db = store:GetDB()
    return (db.maintenance and db.maintenance.buildMigrationWarnings) or {}
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Event wiring (T013)
-- Called from SnapshotService after each successful refresh.
-- ──────────────────────────────────────────────────────────────────────────────

-- This is the post-refresh callback wired in SnapshotService (T013).
-- Called after every snapshot refresh; updates the catalog with the new live build.
function BuildCatalogService:OnSnapshotRefreshed(snapshot)
    if not snapshot then return end
    local ok, err = pcall(function()
        self:RefreshFromSnapshot(snapshot)
    end)
    if not ok then
        ns.Addon:Warn("BuildCatalogService:OnSnapshotRefreshed error: %s", tostring(err))
    end
end

ns.Addon:RegisterModule("BuildCatalogService", BuildCatalogService)
