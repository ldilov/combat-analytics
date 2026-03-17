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

ns.BuildHash = BuildHash
