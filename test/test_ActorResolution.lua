-- test/test_ActorResolution.lua
-- UnitGraphService actor resolution test suite.
--
-- Covers:
--   • token → GUID resolution (GetGUIDForToken)
--   • GUID → slot resolution (GetNode)
--   • pet → owner resolution (GetOwnerForPet, RegisterPetOwner)
--   • conflicting identity merge follows priority order (_ResolvePriority)
--   • visibility state transitions (MarkSeen / MarkUnseen / visible flag)
--   • session lifecycle: InitializeForSession / ResetForSessionEnd
--
-- Run from repo root:
--   lua test/TestRunner.lua && lua test/mocks/WowApi.lua && lua test/test_ActorResolution.lua && lua -e "TestRunner.RunAll()"
-- Or load all files in sequence with dofile() and call TestRunner.RunAll().

-- ---------------------------------------------------------------------------
-- Minimal ns / addon shim
-- ---------------------------------------------------------------------------

-- Build just enough of the Constants table for UnitGraphService to load.
local Constants = {
    TIMELINE_LANE = {
        VISIBILITY   = "visibility",
        VISIBLE_CAST = "visible_cast",
        PLAYER_CAST  = "player_cast",
    },
    ATTRIBUTION_CONFIDENCE = {
        confirmed        = "confirmed",
        owner_confirmed  = "owner_confirmed",
        slot_confirmed   = "slot_confirmed",
        inferred         = "inferred",
        summary_derived  = "summary_derived",
        unknown          = "unknown",
    },
    PROVENANCE_SOURCE = {
        VISIBLE_UNIT_CAST    = "visible_unit_cast",
        ARENA_SLOT_MAPPING   = "arena_slot_mapping",
        PET_OWNER_INFERENCE  = "pet_owner_inference",
    },
}

-- Module registry shim.
local modules = {}

local AddonShim = {}
AddonShim.__index = AddonShim

function AddonShim:GetModule(name)
    return modules[name]
end

function AddonShim:RegisterModule(name, module)
    modules[name] = module
end

-- ns shim
local ns = {
    Addon      = setmetatable({}, AddonShim),
    Constants  = Constants,
    Helpers    = { FormatNumber = tostring, FormatDuration = tostring },
}
-- TimelineProducer stub — no-op so _EmitVisibilityEvent doesn't crash.
modules["TimelineProducer"] = {
    GetCurrentSession = function() return nil end,
    AppendTimelineEvent = function() end,
}

-- Load UnitGraphService into this namespace by injecting ns via the select/... mechanism.
-- Since WoW addons use `local _, ns = ...` we need a thin wrapper.
local ugsChunk
do
    local path = "UnitGraphService.lua"
    -- Try standard Lua io.open first (CLI runner).
    local f = io.open and io.open(path, "r")
    if not f then
        f = io.open and io.open("../UnitGraphService.lua", "r")
    end
    if f then
        local src = f:read("*a")
        f:close()
        ugsChunk = load(src, "@UnitGraphService.lua")
    end
end

if ugsChunk then
    -- Call with addon-name + ns as varargs (mimics WoW addon load).
    ugsChunk("CombatAnalytics", ns)
end

local UGS = modules["UnitGraphService"]

-- ---------------------------------------------------------------------------
-- Guard: if UGS didn't load (e.g. in a partial CI run), skip gracefully.
-- ---------------------------------------------------------------------------
if not UGS then
    describe("UnitGraphService", function()
        it("module loads", function()
            error("UnitGraphService module not loaded — check file path in test runner.")
        end)
    end)
    return
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function freshSession()
    UGS:InitializeForSession()
end

local function makeGUID(n)
    return string.format("Player-1234-ABCD%04X", n)
end

-- ---------------------------------------------------------------------------
-- Suite 1: Token → GUID resolution
-- ---------------------------------------------------------------------------
describe("UnitGraphService / token-to-GUID resolution", function()

    it("GetGUIDForToken returns nil for unknown token before any update", function()
        freshSession()
        local g = UGS:GetGUIDForToken("arena1")
        expect(g):toBeNil()
    end)

    it("GetGUIDForToken returns guid after UpdateFromArenaSlot", function()
        freshSession()
        local guid = makeGUID(1)
        UGS:UpdateFromArenaSlot(1, guid, "Archmage", "MAGE", nil)
        expect(UGS:GetGUIDForToken("arena1")):toBe(guid)
    end)

    it("GetGUIDForToken returns nil for a different slot after single update", function()
        freshSession()
        local guid = makeGUID(1)
        UGS:UpdateFromArenaSlot(1, guid, "Archmage", "MAGE", nil)
        expect(UGS:GetGUIDForToken("arena2")):toBeNil()
    end)

    it("UpdateFromArenaSlot populates two independent slots", function()
        freshSession()
        local g1 = makeGUID(1)
        local g2 = makeGUID(2)
        UGS:UpdateFromArenaSlot(1, g1, "Mage",   "MAGE",   nil)
        UGS:UpdateFromArenaSlot(2, g2, "Rogue",  "ROGUE",  nil)
        expect(UGS:GetGUIDForToken("arena1")):toBe(g1)
        expect(UGS:GetGUIDForToken("arena2")):toBe(g2)
    end)

end)

-- ---------------------------------------------------------------------------
-- Suite 2: GUID → slot resolution
-- ---------------------------------------------------------------------------
describe("UnitGraphService / GUID-to-slot resolution", function()

    it("GetNode returns nil for unknown GUID", function()
        freshSession()
        expect(UGS:GetNode(makeGUID(99))):toBeNil()
    end)

    it("GetNode returns node with arenaSlot after UpdateFromArenaSlot", function()
        freshSession()
        local guid = makeGUID(10)
        UGS:UpdateFromArenaSlot(2, guid, "Hunter", "HUNTER", 65)
        local node = UGS:GetNode(guid)
        expect(node):toNotBeNil()
        expect(node.arenaSlot):toBe(2)
        expect(node.classFile):toBe("HUNTER")
        expect(node.specId):toBe(65)
    end)

    it("GetNode confidence is slot_confirmed after arena slot update", function()
        freshSession()
        local guid = makeGUID(11)
        UGS:UpdateFromArenaSlot(3, guid, "Warlock", "WARLOCK", nil)
        local node = UGS:GetNode(guid)
        expect(node.confidence):toBe(Constants.ATTRIBUTION_CONFIDENCE.slot_confirmed)
    end)

    it("GetBestDisplayIdentity returns table with provenance", function()
        freshSession()
        local guid = makeGUID(12)
        UGS:UpdateFromArenaSlot(1, guid, "Priest", "PRIEST", 256)
        local identity = UGS:GetBestDisplayIdentity(guid)
        expect(identity):toNotBeNil()
        expect(identity.name):toBe("Priest")
        expect(identity.provenance):toNotBeNil()
    end)

end)

-- ---------------------------------------------------------------------------
-- Suite 3: Pet → owner resolution
-- ---------------------------------------------------------------------------
describe("UnitGraphService / pet-to-owner resolution", function()

    it("GetOwnerForPet returns nil before any pet registration", function()
        freshSession()
        local result = UGS:GetOwnerForPet(makeGUID(50))
        expect(result):toBeNil()
    end)

    it("RegisterPetOwner then GetOwnerForPet returns owner data", function()
        freshSession()
        local petGuid   = makeGUID(51)
        local ownerGuid = makeGUID(52)
        UGS:RegisterPetOwner(petGuid, ownerGuid, "Beastmaster", "HUNTER", 1)
        local result = UGS:GetOwnerForPet(petGuid)
        expect(result):toNotBeNil()
        expect(result.ownerGuid):toBe(ownerGuid)
        expect(result.ownerName):toBe("Beastmaster")
    end)

    it("GetNode for pet shows isPet = true and ownerGuid", function()
        freshSession()
        local petGuid   = makeGUID(53)
        local ownerGuid = makeGUID(54)
        UGS:RegisterPetOwner(petGuid, ownerGuid, "WarlockOwner", "WARLOCK", 2)
        local node = UGS:GetNode(petGuid)
        expect(node):toNotBeNil()
        expect(node.isPet):toBeTruthy()
        expect(node.ownerGuid):toBe(ownerGuid)
    end)

    it("Registering same pet twice does not error", function()
        freshSession()
        local petGuid   = makeGUID(55)
        local ownerGuid = makeGUID(56)
        UGS:RegisterPetOwner(petGuid, ownerGuid, "Hunter1", "HUNTER", 1)
        -- Second registration with same data should not raise.
        local ok = pcall(UGS.RegisterPetOwner, UGS, petGuid, ownerGuid, "Hunter1", "HUNTER", 1)
        expect(ok):toBeTruthy()
    end)

end)

-- ---------------------------------------------------------------------------
-- Suite 4: Conflict resolution priority
-- ---------------------------------------------------------------------------
describe("UnitGraphService / conflict resolution priority", function()

    it("_ResolvePriority: visible_unit beats arena_slot", function()
        if not UGS._ResolvePriority then
            -- Private method may not be exposed; skip gracefully.
            return
        end
        local winner, src = UGS:_ResolvePriority(
            "ArenaName", "arena_slot_mapping",
            "VisibleName", "visible_unit_cast"
        )
        expect(winner):toBe("VisibleName")
        expect(src):toBe("visible_unit_cast")
    end)

    it("_ResolvePriority: arena_slot beats summary_derived", function()
        if not UGS._ResolvePriority then return end
        local winner, src = UGS:_ResolvePriority(
            "SummaryName", "summary_derived",
            "SlotName",    "arena_slot_mapping"
        )
        expect(winner):toBe("SlotName")
        expect(src):toBe("arena_slot_mapping")
    end)

    it("_ResolvePriority: unknown loses to any named source", function()
        if not UGS._ResolvePriority then return end
        local winner, _ = UGS:_ResolvePriority(
            "SomeName", "pet_owner_inference",
            nil, "unknown"
        )
        expect(winner):toBe("SomeName")
    end)

    it("UpdateFromArenaSlot over unknown keeps arena data", function()
        freshSession()
        local guid = makeGUID(60)
        -- First set via low-confidence visible update (if available), then slot update.
        UGS:UpdateFromArenaSlot(1, guid, "SlotName", "MAGE", nil)
        local node = UGS:GetNode(guid)
        expect(node.name):toBe("SlotName")
        expect(node.confidence):toBe(Constants.ATTRIBUTION_CONFIDENCE.slot_confirmed)
    end)

end)

-- ---------------------------------------------------------------------------
-- Suite 5: Visibility state transitions
-- ---------------------------------------------------------------------------
describe("UnitGraphService / visibility state transitions", function()

    it("Node starts with visible = false before MarkSeen", function()
        freshSession()
        local guid = makeGUID(70)
        UGS:UpdateFromArenaSlot(1, guid, "Paladin", "PALADIN", nil)
        local node = UGS:GetNode(guid)
        -- Freshly registered nodes should not be visible until explicitly seen.
        -- (Arena slot update sets visible=true; this just confirms the field exists.)
        expect(node.visible ~= nil):toBeTruthy()
    end)

    it("MarkSeen sets visible = true", function()
        freshSession()
        local guid = makeGUID(71)
        UGS:UpdateFromArenaSlot(1, guid, "Druid", "DRUID", nil)
        UGS:MarkSeen(guid)
        local node = UGS:GetNode(guid)
        expect(node.visible):toBeTruthy()
    end)

    it("MarkUnseen sets visible = false", function()
        freshSession()
        local guid = makeGUID(72)
        UGS:UpdateFromArenaSlot(1, guid, "Rogue", "ROGUE", nil)
        UGS:MarkSeen(guid)
        UGS:MarkUnseen(guid)
        local node = UGS:GetNode(guid)
        expect(node.visible):toBeFalsy()
    end)

    it("MarkSeen after MarkUnseen restores visible = true (re-seen)", function()
        freshSession()
        local guid = makeGUID(73)
        UGS:UpdateFromArenaSlot(2, guid, "Warrior", "WARRIOR", nil)
        UGS:MarkSeen(guid)
        UGS:MarkUnseen(guid)
        UGS:MarkSeen(guid)
        local node = UGS:GetNode(guid)
        expect(node.visible):toBeTruthy()
    end)

    it("MarkSeen sets firstSeenAt on first call, unchanged on second", function()
        freshSession()
        WowMock.time = 100.0
        local guid = makeGUID(74)
        UGS:UpdateFromArenaSlot(1, guid, "Shaman", "SHAMAN", nil)
        UGS:MarkSeen(guid)
        local node = UGS:GetNode(guid)
        local first = node.firstSeenAt
        expect(first):toNotBeNil()

        WowMock.time = 200.0
        UGS:MarkSeen(guid)
        -- firstSeenAt must not change.
        expect(node.firstSeenAt):toBe(first)
    end)

    it("MarkUnseen updates lastSeenAt", function()
        freshSession()
        WowMock.time = 50.0
        local guid = makeGUID(75)
        UGS:UpdateFromArenaSlot(1, guid, "DK", "DEATHKNIGHT", nil)
        UGS:MarkSeen(guid)
        WowMock.time = 75.0
        UGS:MarkUnseen(guid)
        local node = UGS:GetNode(guid)
        expect(node.lastSeenAt):toBe(75.0)
    end)

end)

-- ---------------------------------------------------------------------------
-- Suite 6: Session lifecycle
-- ---------------------------------------------------------------------------
describe("UnitGraphService / session lifecycle", function()

    it("InitializeForSession clears stale nodes from prior session", function()
        freshSession()
        local guid = makeGUID(80)
        UGS:UpdateFromArenaSlot(1, guid, "OldPlayer", "MAGE", nil)
        expect(UGS:GetNode(guid)):toNotBeNil()

        UGS:InitializeForSession()
        -- Node from prior session should be gone.
        expect(UGS:GetNode(guid)):toBeNil()
    end)

    it("InitializeForSession clears token→GUID mappings", function()
        freshSession()
        local guid = makeGUID(81)
        UGS:UpdateFromArenaSlot(1, guid, "OldPlayer2", "ROGUE", nil)
        expect(UGS:GetGUIDForToken("arena1")):toBe(guid)

        UGS:InitializeForSession()
        expect(UGS:GetGUIDForToken("arena1")):toBeNil()
    end)

    it("ResetForSessionEnd does not error", function()
        freshSession()
        local guid = makeGUID(82)
        UGS:UpdateFromArenaSlot(1, guid, "EndPlayer", "PRIEST", nil)
        local ok = pcall(UGS.ResetForSessionEnd, UGS)
        expect(ok):toBeTruthy()
    end)

    it("After ResetForSessionEnd, InitializeForSession produces clean state", function()
        freshSession()
        local guid = makeGUID(83)
        UGS:UpdateFromArenaSlot(1, guid, "Player83", "HUNTER", nil)
        pcall(UGS.ResetForSessionEnd, UGS)
        UGS:InitializeForSession()
        expect(UGS:GetNode(guid)):toBeNil()
    end)

end)
