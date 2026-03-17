local ADDON_NAME, ns = ...

ns.Constants = {
    ADDON_NAME = ADDON_NAME,
    SCHEMA_VERSION = 1,
    RAW_EVENT_VERSION = 1,
    MAX_RAW_EVENTS_PER_SESSION = 25000,
    RAW_EVENT_WARNING_THRESHOLD = 500000,
    TRACE_LOG_LIMIT = 200,
    WORLD_PVP_IDLE_TIMEOUT = 8,
    DUEL_IDLE_TIMEOUT = 6,
    DUEL_PENDING_TIMEOUT_SECONDS = 20,
    TRAINING_DUMMY_IDLE_TIMEOUT = 2,
    GENERAL_IDLE_TIMEOUT = 3,
    SUMMARY_AUTO_OPEN_DELAY = 0.5,
    HISTORY_PAGE_SIZE = 50,
    DETAIL_RAW_PAGE_SIZE = 100,
    WINDOW_OPENERS_SECONDS = 12,
    WINDOW_RECOVERY_SECONDS = 6,
    WINDOW_BURST_MIN_DAMAGE_SHARE = 0.25,
    WINDOW_BURST_MIN_SECONDS = 2,
    WINDOW_BURST_MAX_SECONDS = 10,
    PRESSURE_SPIKE_THRESHOLD = 0.30,
    TRAINING_DUMMY_PROMOTION_THRESHOLD = 70,
    WORLD_PVP_PROMOTION_THRESHOLD = 80,
    DUEL_PROMOTION_THRESHOLD = 90,
    SESSION_RESULT = {
        WON = "won",
        LOST = "lost",
        TRADED = "traded",
        DISENGAGED = "disengaged",
        DRAW = "draw",
        UNKNOWN = "unknown",
    },
    MATCH_RESULT = {
        WIN = "win",
        LOSS = "loss",
        DRAW = "draw",
        UNKNOWN = "unknown",
    },
    CONTEXT = {
        DUEL = "duel",
        ARENA = "arena",
        BATTLEGROUND = "battleground",
        WORLD_PVP = "world_pvp",
        TRAINING_DUMMY = "training_dummy",
        GENERAL = "general",
    },
    SUBCONTEXT = {
        SOLO_SHUFFLE = "solo_shuffle",
        RATED_ARENA = "rated_arena",
        SKIRMISH = "skirmish",
        BRAWL = "brawl",
        RATED_BATTLEGROUND = "rated_battleground",
        SOLO_RBG = "solo_rbg",
        RANDOM_BATTLEGROUND = "random_battleground",
        WORLD = "world",
        TO_THE_DEATH = "to_the_death",
    },
    WINDOW_TYPE = {
        OPENER = "opener",
        BURST = "burst",
        DEFENSIVE = "defensive",
        KILL_ATTEMPT = "kill_attempt",
        RECOVERY = "recovery",
    },
    AGGREGATE_KIND = {
        OPPONENT = "opponent",
        CLASS = "class",
        SPEC = "spec",
        BUILD = "build",
        CONTEXT = "context",
        DAILY = "daily",
        WEEKLY = "weekly",
    },
    CAPTURE_QUALITY = {
        OK = "ok",
        DEGRADED = "degraded",
        OVERFLOW = "overflow",
        RESTRICTED = "restricted",
    },
    INVENTORY_SLOTS = {
        1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17,
    },
    TRACKED_UNITS = {
        player = true,
        pet = true,
        target = true,
        focus = true,
        arena1 = true,
        arena2 = true,
        arena3 = true,
        arena4 = true,
        arena5 = true,
    },
    ROUTER_EVENTS = {
        "ADDON_LOADED",
        "PLAYER_LOGIN",
        "PLAYER_ENTERING_WORLD",
        "TRAIT_CONFIG_LIST_UPDATED",
        "PLAYER_REGEN_DISABLED",
        "PLAYER_REGEN_ENABLED",
        "DAMAGE_METER_COMBAT_SESSION_UPDATED",
        "DAMAGE_METER_CURRENT_SESSION_UPDATED",
        "DAMAGE_METER_RESET",
        "UNIT_SPELLCAST_SUCCEEDED",
        "UNIT_AURA",
        "PLAYER_SPECIALIZATION_CHANGED",
        "PLAYER_JOINED_PVP_MATCH",
        "PVP_MATCH_ACTIVE",
        "PVP_MATCH_COMPLETE",
        "PVP_MATCH_INACTIVE",
        "PVP_MATCH_STATE_CHANGED",
        "ARENA_OPPONENT_UPDATE",
        "ARENA_PREP_OPPONENT_SPECIALIZATIONS",
        "UPDATE_BATTLEFIELD_STATUS",
        "ZONE_CHANGED_NEW_AREA",
        "DUEL_REQUESTED",
        "DUEL_TO_THE_DEATH_REQUESTED",
        "DUEL_INBOUNDS",
        "DUEL_OUTOFBOUNDS",
        "DUEL_FINISHED",
        "PLAYER_PVP_TALENT_UPDATE",
    },
    DEFAULT_SETTINGS = {
        showSummaryAfterCombat = false,
        enableDebugLogging = false,
        keepRawEvents = true,
        includeGeneralCombat = false,
        autoOpenMainFrame = false,
        enableTraceLogging = true,
        showMinimapButton = false,
        minimapAngle = 225,
        themePreset = "modern_steel_ember",
        showConfidenceBadges = true,
    },
    TRAINING_DUMMY_PATTERNS = {
        "training dummy",
        "raider's training dummy",
        "dungeoneer's training dummy",
        "damage dummy",
        "healing dummy",
    },
    TRAINING_DUMMY_CREATURE_IDS = {
    },
    SPELL_CATEGORY = {
        OFFENSIVE = "offensive",
        DEFENSIVE = "defensive",
        UTILITY = "utility",
        CROWD_CONTROL = "crowd_control",
        MOBILITY = "mobility",
    },
    SPELL_CATEGORIES = {
        [42292] = "defensive",  -- PvP Trinket / Will to Survive
        [12042] = "offensive",  -- Arcane Power
        [31884] = "offensive",  -- Avenging Wrath
        [1719] = "offensive",   -- Recklessness
        [19574] = "offensive",  -- Bestial Wrath
        [12472] = "offensive",  -- Icy Veins
        [1022] = "defensive",   -- Hand of Protection
        [642] = "defensive",    -- Divine Shield
        [22812] = "defensive",  -- Barkskin
        [5277] = "defensive",   -- Evasion
        [31224] = "defensive",  -- Cloak of Shadows
        [104773] = "defensive", -- Unending Resolve
        [871] = "defensive",    -- Shield Wall
        [6940] = "defensive",   -- Hand of Sacrifice
        [196718] = "defensive", -- Darkness (Demon Hunter)
        [1766] = "utility",     -- Kick
        [6552] = "utility",     -- Pummel
        [2139] = "utility",     -- Counterspell
        [47528] = "crowd_control", -- Mind Freeze
        [1833] = "crowd_control",  -- Cheap Shot
        [5211] = "crowd_control",  -- Bash
        [78675] = "mobility",   -- Solar Beam
        [1953] = "mobility",    -- Blink
        [36554] = "mobility",   -- Shadow Step
    },
}
