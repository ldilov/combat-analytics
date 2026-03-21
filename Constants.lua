local ADDON_NAME, ns = ...

ns.Constants = {
    ADDON_NAME = ADDON_NAME,
    SCHEMA_VERSION = 5,
    RAW_EVENT_VERSION = 2,
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
        -- Used when the arena subcontext cannot be determined (transitional
        -- queue states, unrecognised brawl types). Prevents false RATED_ARENA
        -- labels on skirmishes and brawls.
        UNKNOWN_ARENA = "unknown_arena",
        WARGAME = "wargame",
        TRAINING_GROUNDS = "training_grounds",
    },
    -- Analysis confidence labels attached to session.captureQuality.
    -- Used by the UI confidence badge and by the suggestion engine.
    ANALYSIS_CONFIDENCE = {
        FULL_RAW     = "full_raw",      -- CLEU unrestricted, delta < 5 %
        ENRICHED     = "enriched",      -- CLEU unrestricted + DamageMeter detail merged
        RESTRICTED_RAW = "restricted_raw", -- CLEU restricted, DamageMeter is primary source
        DEGRADED     = "degraded",      -- delta > 12 % or major subevent gaps
        PARTIAL_ROSTER = "partial_roster", -- arena slot coverage < 100 %
        UNKNOWN      = "unknown",       -- could not determine
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
        RATING_HISTORY = "ratingHistory",
        BUILD_EFFECTIVENESS = "buildEffectiveness",
        SPEC_DAMAGE_SIGNATURES = "specDamageSignatures",
    },
    MMR_BANDS = {
        { label = "<1400",     min = 0,    max = 1399  },
        { label = "1400-1600", min = 1400, max = 1599  },
        { label = "1600-1800", min = 1600, max = 1799  },
        { label = "1800-2100", min = 1800, max = 2099  },
        { label = "2100+",     min = 2100, max = 99999 },
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
        -- Pet units for arena enemies. Warlocks, Hunters, and Unholy DKs
        -- deal significant damage through pets; excluding them skews enemy
        -- spell attribution. Added in schema v2.
        arena1pet = true,
        arena2pet = true,
        arena3pet = true,
        arena4pet = true,
        arena5pet = true,
    },
    ROUTER_EVENTS = {
        "ADDON_LOADED",
        "PLAYER_LOGIN",
        "PLAYER_ENTERING_WORLD",
        "TRAIT_CONFIG_LIST_UPDATED",
        -- COMBAT_LOG_EVENT_UNFILTERED intentionally omitted: registering this
        -- event on an addon frame is restricted in Midnight and raises
        -- ADDON_ACTION_BLOCKED.  CLEU is consumed via C_CombatLog callbacks.
        "PLAYER_REGEN_DISABLED",
        "PLAYER_REGEN_ENABLED",
        "DAMAGE_METER_COMBAT_SESSION_UPDATED",
        "DAMAGE_METER_CURRENT_SESSION_UPDATED",
        "DAMAGE_METER_RESET",
        "UNIT_SPELLCAST_SUCCEEDED",
        "SPELL_DATA_LOAD_RESULT",
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
        "ARENA_CROWD_CONTROL_SPELL_UPDATE",
        "INSPECT_READY",
        "CHAT_MSG_ADDON",
        "UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED",
        "LOSS_OF_CONTROL_ADDED",
        "LOSS_OF_CONTROL_UPDATE",
        "PLAYER_CONTROL_LOST",
        "PLAYER_CONTROL_GAINED",
    },
    DEFAULT_SETTINGS = {
        showSummaryAfterCombat = false,
        enableDebugLogging = false,
        keepRawEvents = true,
        includeGeneralCombat = false,
        autoOpenMainFrame = false,
        enableTraceLogging = true,
        showMinimapButton = true,
        minimapAngle = 225,
        themePreset = "modern_steel_ember",
        showConfidenceBadges = true,
        showPreMatchAdvisory = true,
        enablePartySync = false,
    },
    -- ──────────────────────────────────────────────────────────────────────────
    -- Combat Log Object Flags (Midnight-native, replaces deprecated globals)
    -- ──────────────────────────────────────────────────────────────────────────
    -- These are authoritative values from Enum.CombatLogObject. The old globals
    -- (COMBATLOG_OBJECT_AFFILIATION_MINE, etc.) only exist when the CVar
    -- "loadDeprecationFallbacks" is true, which is false by default in Midnight.
    CLEU_FLAGS = {
        AFFILIATION_MINE     = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.AffiliationMine) or 1,
        AFFILIATION_PARTY    = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.AffiliationParty) or 2,
        AFFILIATION_RAID     = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.AffiliationRaid) or 4,
        AFFILIATION_OUTSIDER = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.AffiliationOutsider) or 8,
        REACTION_FRIENDLY    = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.ReactionFriendly) or 16,
        REACTION_NEUTRAL     = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.ReactionNeutral) or 32,
        REACTION_HOSTILE     = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.ReactionHostile) or 64,
        CONTROL_PLAYER       = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.ControlPlayer) or 256,
        CONTROL_NPC          = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.ControlNpc) or 512,
        TYPE_PLAYER          = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.TypePlayer) or 1024,
        TYPE_NPC             = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.TypeNpc) or 2048,
        TYPE_PET             = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.TypePet) or 4096,
        TYPE_GUARDIAN        = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.TypeGuardian) or 8192,
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
