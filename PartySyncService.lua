local _, ns = ...

local Constants = ns.Constants
local Helpers = ns.Helpers
local ApiCompat = ns.ApiCompat

local PartySyncService = {
    enabled = false,
    PREFIX = "CA3",
    PROTOCOL_VERSION = 3,
}

-- Store peer summaries received from party members.
-- Key: senderName, Value: { specId, topSpells, metrics, result, duration, timestamp }
ns.Addon.runtime = ns.Addon.runtime or {}
ns.Addon.runtime.partyPeerSessions = ns.Addon.runtime.partyPeerSessions or {}

function PartySyncService:Initialize()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(self.PREFIX)
    end
    self.enabled = ns.Addon:GetSetting("enablePartySync") or false
end

function PartySyncService:BroadcastSession(session)
    if not self.enabled then return end
    if not session then return end
    if not IsInGroup or not IsInGroup() then return end
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return end

    local specId = session.playerSnapshot and session.playerSnapshot.specId or 0
    local result = session.result or "unknown"
    local duration = math.floor(session.duration or 0)
    local pressure = Helpers.Round(session.metrics and session.metrics.pressureScore or 0, 1)
    local burst = Helpers.Round(session.metrics and session.metrics.burstScore or 0, 1)
    local damageDone = session.totals and session.totals.damageDone or 0

    -- Top 3 spells by damage
    local topSpells = {}
    if session.spells then
        local sorted = {}
        for spellId, data in pairs(session.spells) do
            sorted[#sorted + 1] = { spellId = spellId, damage = data.totalDamage or 0 }
        end
        table.sort(sorted, function(a, b) return a.damage > b.damage end)
        for i = 1, math.min(3, #sorted) do
            topSpells[#topSpells + 1] = tostring(sorted[i].spellId)
        end
    end

    local payload = table.concat({
        "v=" .. self.PROTOCOL_VERSION,
        "s=" .. specId,
        "r=" .. result,
        "d=" .. duration,
        "p=" .. pressure,
        "b=" .. burst,
        "dmg=" .. damageDone,
        "sp=" .. table.concat(topSpells, ","),
    }, ";")

    local channel = IsInRaid() and "RAID" or "PARTY"
    C_ChatInfo.SendAddonMessage(self.PREFIX, payload, channel)
end

function PartySyncService:HandleAddonMessage(prefix, payload, channel, sender)
    if prefix ~= self.PREFIX then return end
    if not self.enabled then return end

    -- Parse payload
    local data = {}
    for kv in payload:gmatch("[^;]+") do
        local k, v = kv:match("^(%w+)=(.+)$")
        if k and v then
            data[k] = v
        end
    end

    -- Version check — ignore higher versions
    local version = tonumber(data.v) or 0
    if version > self.PROTOCOL_VERSION then return end

    local peerSession = {
        sender = sender,
        specId = tonumber(data.s) or 0,
        result = data.r or "unknown",
        duration = tonumber(data.d) or 0,
        pressureScore = tonumber(data.p) or 0,
        burstScore = tonumber(data.b) or 0,
        damageDone = tonumber(data.dmg) or 0,
        topSpellIds = {},
        receivedAt = Helpers.Now(),
    }

    if data.sp and data.sp ~= "" then
        for spellId in data.sp:gmatch("%d+") do
            peerSession.topSpellIds[#peerSession.topSpellIds + 1] = tonumber(spellId)
        end
    end

    ns.Addon.runtime.partyPeerSessions[sender] = peerSession
end

function PartySyncService:GetPeerSessions()
    return ns.Addon.runtime.partyPeerSessions or {}
end

function PartySyncService:ClearPeerSessions()
    ns.Addon.runtime.partyPeerSessions = {}
end

ns.Addon:RegisterModule("PartySyncService", PartySyncService)
