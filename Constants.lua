local ADDON_NAME, ns = ...

ns.Constants = {
    ADDON_NAME = ADDON_NAME,
    SCHEMA_VERSION = 8,
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
    -- Legacy confidence labels — preserved for migration compatibility.
    -- New code should use SESSION_CONFIDENCE instead.
    ANALYSIS_CONFIDENCE = {
        FULL_RAW     = "full_raw",
        ENRICHED     = "enriched",
        RESTRICTED_RAW = "restricted_raw",
        DEGRADED     = "degraded",
        PARTIAL_ROSTER = "partial_roster",
        UNKNOWN      = "unknown",
    },
    -- Provenance source: which sanctioned API produced a persisted field.
    PROVENANCE_SOURCE = {
        STATE               = "state",               -- REGEN, PVP_MATCH, DUEL events
        DAMAGE_METER        = "damage_meter",         -- C_DamageMeter APIs
        VISIBLE_UNIT        = "visible_unit",         -- Legacy: UNIT_AURA, UNIT_SPELLCAST_SUCCEEDED
        VISIBLE_UNIT_CAST   = "visible_unit_cast",   -- Observed via UNIT_SPELLCAST_* (v7+)
        VISIBLE_UNIT_AURA   = "visible_unit_aura",   -- Observed via UNIT_AURA (v7+)
        ARENA_SLOT_MAPPING  = "arena_slot_mapping",  -- From ARENA_OPPONENT_UPDATE (v7+)
        SNAPSHOT_SERVICE    = "snapshot_service",    -- From SnapshotService (v7+)
        PET_OWNER_INFERENCE = "pet_owner_inference", -- Derived pet→owner link (v7+)
        DEATH_RECAP_SUMMARY = "death_recap_summary", -- From C_DamageMeter DeathRecap (v7+)
        INSPECT             = "inspect",             -- NotifyInspect / INSPECT_READY
        LOSS_OF_CONTROL     = "loss_of_control",     -- LOSS_OF_CONTROL_*, PLAYER_CONTROL_*
        SPELL_DIMINISH      = "spell_diminish",      -- UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED
        ESTIMATED           = "estimated",           -- derived / calculated
        LEGACY_IMPORT       = "legacy_import",       -- migrated from pre-v6 schema
    },
    -- Session-level confidence — replaces ANALYSIS_CONFIDENCE for v6+ sessions.
    SESSION_CONFIDENCE = {
        STATE_PLUS_DAMAGE_METER = "state_plus_damage_meter", -- full state + DM import
        DAMAGE_METER_ONLY       = "damage_meter_only",       -- DM succeeded, limited state
        VISIBLE_CC_ONLY         = "visible_cc_only",         -- only CC/LOC data, no DM
        PARTIAL_ROSTER          = "partial_roster",          -- arena with incomplete slots
        ESTIMATED               = "estimated",               -- insufficient direct observation
        LEGACY_CLEU_IMPORT      = "legacy_cleu_import",      -- old session from pre-v6
    },
    -- Per-event source identity certainty. Orthogonal to SESSION_CONFIDENCE
    -- (which measures session-level data quality) and ANALYSIS_CONFIDENCE
    -- (legacy session quality). New code should use ATTRIBUTION_CONFIDENCE for
    -- individual event attribution certainty.
    ATTRIBUTION_CONFIDENCE = {
        confirmed        = "confirmed",        -- Direct visible unit observation
        owner_confirmed  = "owner_confirmed",  -- Pet action, owner identity confirmed
        slot_confirmed   = "slot_confirmed",   -- Arena slot mapping confirmed identity
        inferred         = "inferred",         -- Derived from context (target/focus, timing)
        summary_derived  = "summary_derived",  -- From DamageMeter summary data
        unknown          = "unknown",          -- Cannot determine source
    },
    -- Timeline lane types for the timelineEvents system (v6+).
    TIMELINE_LANE = {
        PLAYER_CAST    = "player_cast",     -- Legacy alias; prefer VISIBLE_CAST for new code
        VISIBLE_CAST   = "visible_cast",    -- All visible spellcast lifecycle events (v7+)
        VISIBILITY     = "visibility",      -- Actor visibility/identity transition events (v7+)
        VISIBLE_AURA   = "visible_aura",
        CC_RECEIVED    = "cc_received",
        DR_UPDATE      = "dr_update",
        KILL_WINDOW    = "kill_window",
        DEATH          = "death",
        MATCH_STATE    = "match_state",
        INSPECT        = "inspect",
        DM_CHECKPOINT  = "dm_checkpoint",
        DM_SPELL       = "dm_spell",
        DM_ENEMY_SPELL = "dm_enemy_spell",
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
        TIMELINE_OK = "timeline_ok",
        ROSTER_OK = "roster_ok",
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
        "TRAIT_CONFIG_UPDATED",
        -- NOTE: COMBAT_LOG_EVENT_UNFILTERED is NOT registered here.
        -- Frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED") is forbidden in
        -- Midnight arena (raises ADDON_ACTION_BLOCKED / lua error). Damage data
        -- is sourced from C_DamageMeter (DamageMeterService) instead.
        "PLAYER_REGEN_DISABLED",
        "PLAYER_REGEN_ENABLED",
        "DAMAGE_METER_COMBAT_SESSION_UPDATED",
        "DAMAGE_METER_CURRENT_SESSION_UPDATED",
        "DAMAGE_METER_RESET",
        "UNIT_SPELLCAST_SUCCEEDED",
        -- T016: Cast lifecycle events for arena opponent tracking.
        -- NOTE: These may be forbidden in Midnight restricted sessions;
        -- ADDON_ACTION_BLOCKED diagnostic in Events.lua will surface violations.
        "UNIT_SPELLCAST_START",
        "UNIT_SPELLCAST_STOP",
        "UNIT_SPELLCAST_INTERRUPTED",
        "UNIT_SPELLCAST_FAILED",
        "UNIT_SPELLCAST_CHANNEL_START",
        "UNIT_SPELLCAST_CHANNEL_STOP",
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
        -- UnitGraphService: identity graph events
        "PLAYER_TARGET_CHANGED",
        "PLAYER_FOCUS_CHANGED",
        "GROUP_ROSTER_UPDATE",
        "UNIT_PET",
        "NAME_PLATE_UNIT_ADDED",
        "NAME_PLATE_UNIT_REMOVED",
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
    -- Creature IDs synced from seed/generated/SeedDummyCatalog.lua.
    -- Enables fast creature-ID-based dummy detection (score 100) without
    -- falling back to name-pattern matching (score 70-85).
    TRAINING_DUMMY_CREATURE_IDS = {
        [31144]  = true,  -- Training Dummy
        [31146]  = true,  -- Raider's Training Dummy
        [31147]  = true,  -- Dungeoneer's Training Dummy
        [32666]  = true,  -- Training Dummy
        [44171]  = true,  -- Training Dummy
        [44614]  = true,  -- Training Dummy
        [194643] = true,  -- Training Grounds Damage Dummy
        [194644] = true,  -- Training Grounds Tank Dummy
        [194648] = true,  -- Training Grounds DPS Dummy
        [194649] = true,  -- Training Grounds Healer Dummy
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
    -- ──────────────────────────────────────────────────────────────────────────
    -- Build Identity (feature 003-build-comparator-overhaul)
    -- ──────────────────────────────────────────────────────────────────────────
    BUILD_IDENTITY_VERSION = 1,
    SNAPSHOT_FRESHNESS = {
        FRESH           = "fresh",
        PENDING_REFRESH = "pending_refresh",
        DEGRADED        = "degraded",
        UNAVAILABLE     = "unavailable",
    },
    CONFIDENCE_TIER = {
        NO_DATA = "no_data",
        LOW     = "low",
        MEDIUM  = "medium",
        HIGH    = "high",
    },
    -- Minimum session counts per tier. Read by BuildComparisonService; never
    -- hardcode these values elsewhere.
    CONFIDENCE_TIER_THRESHOLDS = {
        LOW_MIN    = 1,
        MEDIUM_MIN = 5,
        HIGH_MIN   = 15,
    },
    -- ──────────────────────────────────────────────────────────────────────────
    -- Damage import status (feature midnight-correctness-overhaul)
    -- Machine-readable outcome of the C_DamageMeter import attempt.
    -- Set on session.importedTotals.importStatus after each finalization.
    -- ──────────────────────────────────────────────────────────────────────────
    IMPORT_STATUS = {
        -- Authoritative totals imported from the matched historical DM session
        IMPORTED_AUTHORITATIVE               = "imported_authoritative",
        -- Totals taken from the live current-session snapshot (less reliable)
        IMPORTED_CURRENT_SNAPSHOT            = "imported_current_snapshot",
        -- Totals inferred from enemy damage taken (may miss pet/DoT damage)
        IMPORTED_ENEMY_DAMAGE_TAKEN_FALLBACK = "imported_enemy_damage_taken_fallback",
        -- Totals estimated from local cast records (weakest approximation)
        ESTIMATED_FROM_CASTS                 = "estimated_from_casts",
        -- C_DamageMeter was unavailable or returned zero sessions
        FAILED_DAMAGE_METER_UNAVAILABLE      = "failed_damage_meter_unavailable",
        -- No candidate session could be matched to this encounter
        FAILED_NO_CANDIDATE                  = "failed_no_candidate",
        -- A candidate was found but no player source row could be resolved
        FAILED_NO_PLAYER_SOURCE              = "failed_no_player_source",
        -- Import returned zero/nil damage with no usable fallback
        FAILED_NO_MEANINGFUL_DATA            = "failed_no_meaningful_data",
        -- Session was finalized before damage-meter data settled
        FAILED_FINALIZED_TOO_EARLY           = "failed_finalized_too_early",
    },
    -- Maps each IMPORT_STATUS to one of three authority tiers.
    -- Avoids long if-chains in CombatTracker and UI layers.
    IMPORT_AUTHORITY = {
        authoritative = {
            imported_authoritative = true,
        },
        estimated = {
            imported_current_snapshot            = true,
            imported_enemy_damage_taken_fallback  = true,
            estimated_from_casts                 = true,
        },
        failed = {
            failed_damage_meter_unavailable = true,
            failed_no_candidate             = true,
            failed_no_player_source         = true,
            failed_no_meaningful_data       = true,
            failed_finalized_too_early      = true,
        },
    },
    -- Context-aware minimum settle delay (seconds) before the first
    -- finalization attempt. Referenced by CombatTracker:ScheduleFinalize.
    DAMAGE_SETTLE_DELAY = {
        arena          = 3.0,
        battleground   = 2.0,
        duel           = 1.0,
        world_pvp      = 1.0,
        training_dummy = 0.5,
        general        = 0.5,
    },
}
