local _, ns = ...

local BuildHash = {}

local function serializeTalentNodes(snapshot)
    local parts = {}
    for _, node in ipairs(snapshot.talentNodes or {}) do
        parts[#parts + 1] = table.concat({
            tostring(node.nodeId or 0),
            tostring(node.entryId or 0),
            tostring(node.definitionSpellId or 0),
            tostring(node.activeRank or 0),
        }, ":")
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

function BuildHash.FromSnapshot(snapshot)
    if not snapshot then
        return "unknown"
    end

    local pvpTalents = ns.Helpers.CopyTable(snapshot.pvpTalents or {}, false)
    table.sort(pvpTalents)

    local input = table.concat({
        tostring(snapshot.classId or 0),
        tostring(snapshot.specId or 0),
        tostring(snapshot.activeConfigId or 0),
        tostring(snapshot.heroTalentSpecId or 0),
        tostring(snapshot.importString or ""),
        table.concat(pvpTalents, ","),
        serializeTalentNodes(snapshot),
    }, "#")

    return string.format("%08x", ns.Math.HashString32(input))
end

-- Compute canonical build identity. Excludes activeConfigId and importString so
-- identical talent setups in different loadout slots produce the same buildId.
-- Prefixed with BUILD_IDENTITY_VERSION so future field changes create a new hash
-- space without collision with prior values.
function BuildHash.ComputeBuildId(snapshot)
    if not snapshot then return nil end

    local C = ns.Constants
    local version = tostring(C.BUILD_IDENTITY_VERSION or 1)

    local pvpTalents = ns.Helpers.CopyTable(snapshot.pvpTalents or {}, false)
    table.sort(pvpTalents)

    local input = table.concat({
        version,
        tostring(snapshot.classId or 0),
        tostring(snapshot.specId or 0),
        tostring(snapshot.heroTalentSpecId or 0),
        table.concat(pvpTalents, ","),
        serializeTalentNodes(snapshot),
    }, "#")

    return string.format("%08x%08x%08x%08x%08x",
        ns.Math.HashString32(input),
        ns.Math.HashString32(input .. "_b"),
        ns.Math.HashString32(input .. "_c"),
        ns.Math.HashString32(input .. "_d"),
        ns.Math.HashString32(input .. "_e"))
end

-- Compute loadout identity from Blizzard slot metadata. This is a secondary
-- identifier stored alongside buildId; it does NOT influence canonical build
-- identity and is used only to track which loadout slot a session was recorded
-- under.
function BuildHash.ComputeLoadoutId(snapshot)
    if not snapshot then return nil end

    local activeConfigId = tostring(snapshot.activeConfigId or 0)
    local importPrefix  = tostring(snapshot.importString or ""):sub(1, 64)

    local input = activeConfigId .. "#" .. importPrefix
    return string.format("%08x%08x%08x%08x%08x",
        ns.Math.HashString32(input),
        ns.Math.HashString32(input .. "_b"),
        ns.Math.HashString32(input .. "_c"),
        ns.Math.HashString32(input .. "_d"),
        ns.Math.HashString32(input .. "_e"))
end

ns.BuildHash = BuildHash
