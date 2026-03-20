local _, ns = ...

-- Comp archetype classification rules.
-- Order matters: first match wins.
-- Roles used: "melee_dps", "ranged_dps", "healer"
-- Fields:
--   minMelee      (int)  — minimum melee DPS players required
--   minCaster     (int)  — minimum ranged/caster DPS required
--   minAnyDps     (int)  — minimum any DPS (melee or ranged) required
--   requiresHealer (bool) — archetype requires at least one healer
--   dangerProfile  (str)  — "early_burst" | "setup_mid" | "dampening" | "unknown"

ns.SeedCompArchetypes = ns.SeedCompArchetypes or {}

ns.SeedCompArchetypes.archetypes = {
    -- ── 3v3 ─────────────────────────────────────────────────────────────────
    {
        id             = "double_melee_healer",
        label          = "Double Melee Cleave",
        bracket        = "3v3",
        minMelee       = 2,
        requiresHealer = true,
        dangerProfile  = "early_burst",
    },
    {
        id             = "melee_caster_healer",
        label          = "Melee Caster",
        bracket        = "3v3",
        minMelee       = 1,
        minCaster      = 1,
        requiresHealer = true,
        dangerProfile  = "setup_mid",
    },
    {
        id             = "wizard_cleave",
        label          = "Wizard Cleave",
        bracket        = "3v3",
        minCaster      = 2,
        requiresHealer = true,
        dangerProfile  = "setup_mid",
    },
    {
        id             = "double_dps_healer",
        label          = "Double DPS + Healer",
        bracket        = "3v3",
        minAnyDps      = 2,
        requiresHealer = true,
        dangerProfile  = "unknown",
    },
    -- ── 2v2 ─────────────────────────────────────────────────────────────────
    {
        id             = "melee_healer",
        label          = "Melee + Healer",
        bracket        = "2v2",
        minMelee       = 1,
        requiresHealer = true,
        dangerProfile  = "early_burst",
    },
    {
        id             = "caster_healer",
        label          = "Caster + Healer",
        bracket        = "2v2",
        minCaster      = 1,
        requiresHealer = true,
        dangerProfile  = "setup_mid",
    },
    {
        id             = "double_dps",
        label          = "Double DPS",
        bracket        = "2v2",
        minAnyDps      = 2,
        requiresHealer = false,
        dangerProfile  = "early_burst",
    },
    -- ── Fallback ─────────────────────────────────────────────────────────────
    {
        id            = "unknown",
        label         = "Unknown Comp",
        dangerProfile = "unknown",
    },
}
