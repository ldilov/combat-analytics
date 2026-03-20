local _, ns = ...

ns.GeneratedSeedData = ns.GeneratedSeedData or {}

ns.GeneratedSeedData.arenaControl = {
    -- DR families: each entry is {spellId=N, name="...", duration=N}
    ccFamilies = {
        stun = {
            { spellId = 408,    name = "Kidney Shot",       duration = 6 },  -- Rogue
            { spellId = 1833,   name = "Cheap Shot",        duration = 4 },  -- Rogue
            { spellId = 5211,   name = "Bash",              duration = 4 },  -- Druid
            { spellId = 22570,  name = "Maim",              duration = 5 },  -- Druid (Feral)
            { spellId = 853,    name = "Hammer of Justice", duration = 6 },  -- Paladin
            { spellId = 46968,  name = "Shockwave",         duration = 4 },  -- Warrior
            { spellId = 107570, name = "Storm Bolt",        duration = 4 },  -- Warrior
            { spellId = 119381, name = "Leg Sweep",         duration = 3 },  -- Monk
            { spellId = 117526, name = "Binding Shot",      duration = 3 },  -- Hunter
            { spellId = 118329, name = "Intimidation",      duration = 3 },  -- Hunter (BM)
            { spellId = 30283,  name = "Shadowfury",        duration = 3 },  -- Warlock
            { spellId = 89766,  name = "Axe Toss",          duration = 4 },  -- Warlock (Felguard)
            { spellId = 192058, name = "Capacitor Totem",   duration = 3 },  -- Shaman
            { spellId = 179057, name = "Chaos Nova",        duration = 5 },  -- Demon Hunter
            { spellId = 211881, name = "Fel Eruption",      duration = 4 },  -- Demon Hunter (talent)
            { spellId = 221562, name = "Asphyxiate",        duration = 5 },  -- Death Knight (Blood)
            { spellId = 108194, name = "Asphyxiate",        duration = 5 },  -- Death Knight (Unholy/talent)
            { spellId = 91800,  name = "Gnaw",              duration = 3 },  -- Death Knight (Ghoul pet)
            { spellId = 20549,  name = "War Stomp",         duration = 2 },  -- Tauren racial
        },
        incapacitate = {
            { spellId = 3355,   name = "Freezing Trap",              duration = 60 }, -- Hunter
            { spellId = 187650, name = "Freezing Trap",              duration = 60 }, -- Hunter (updated ID)
            { spellId = 20066,  name = "Repentance",                 duration = 60 }, -- Paladin (Holy/Ret)
            { spellId = 51514,  name = "Hex",                        duration = 60 }, -- Shaman
            { spellId = 211004, name = "Hex: Spider",                duration = 60 }, -- Shaman
            { spellId = 210873, name = "Hex: Compy",                 duration = 60 }, -- Shaman
            { spellId = 211010, name = "Hex: Snake",                 duration = 60 }, -- Shaman
            { spellId = 211015, name = "Hex: Cockroach",             duration = 60 }, -- Shaman
            { spellId = 269352, name = "Hex: Skeletal Hatchling",    duration = 60 }, -- Shaman
            { spellId = 99,     name = "Incapacitating Roar",        duration = 3  }, -- Druid
            { spellId = 33786,  name = "Cyclone",                    duration = 6  }, -- Druid
            { spellId = 2637,   name = "Hibernate",                  duration = 40 }, -- Druid (vs Beasts/Dragonkin)
            { spellId = 710,    name = "Banish",                     duration = 30 }, -- Warlock (vs Demons/Elementals)
            { spellId = 200196, name = "Holy Word: Chastise",        duration = 4  }, -- Priest (Holy)
            { spellId = 115078, name = "Paralysis",                  duration = 60 }, -- Monk
            { spellId = 198909, name = "Imprison",                   duration = 60 }, -- Demon Hunter
            { spellId = 107079, name = "Quaking Palm",               duration = 4  }, -- Pandaren racial
            { spellId = 360806, name = "Sleep Walk",                 duration = 8  }, -- Evoker (also in sleep)
            { spellId = 6358,   name = "Seduction",                  duration = 30 }, -- Warlock (Succubus pet)
        },
        polymorph = {
            { spellId = 118,    name = "Polymorph",                  duration = 60 }, -- Mage
            { spellId = 28271,  name = "Polymorph: Turtle",          duration = 60 }, -- Mage
            { spellId = 28272,  name = "Polymorph: Pig",             duration = 60 }, -- Mage
            { spellId = 61305,  name = "Polymorph: Black Cat",       duration = 60 }, -- Mage
            { spellId = 61721,  name = "Polymorph: Rabbit",          duration = 60 }, -- Mage
            { spellId = 61780,  name = "Polymorph: Turkey",          duration = 60 }, -- Mage
            { spellId = 126819, name = "Polymorph: Porcupine",       duration = 60 }, -- Mage
            { spellId = 161353, name = "Polymorph: Penguin",         duration = 60 }, -- Mage
            { spellId = 161354, name = "Polymorph: Polar Bear Cub",  duration = 60 }, -- Mage
            { spellId = 161355, name = "Polymorph: Monkey",          duration = 60 }, -- Mage
            { spellId = 161372, name = "Polymorph: Peacock",         duration = 60 }, -- Mage
            { spellId = 277787, name = "Polymorph: Direhorn",        duration = 60 }, -- Mage
            { spellId = 391895, name = "Polymorph: Duck",            duration = 60 }, -- Mage
        },
        root = {
            { spellId = 122,    name = "Frost Nova",          duration = 8  }, -- Mage
            { spellId = 33395,  name = "Freeze",              duration = 8  }, -- Mage (Water Elemental pet)
            { spellId = 339,    name = "Entangling Roots",    duration = 30 }, -- Druid
            { spellId = 170855, name = "Entangling Roots",    duration = 30 }, -- Druid (alternate ID)
            { spellId = 102359, name = "Mass Entanglement",   duration = 30 }, -- Druid (talent)
            { spellId = 64803,  name = "Entrapment",          duration = 4  }, -- Hunter (talent)
            { spellId = 162480, name = "Steel Trap",          duration = 20 }, -- Hunter
            { spellId = 45524,  name = "Chains of Ice",       duration = 8  }, -- Death Knight
            { spellId = 116706, name = "Disable",             duration = 8  }, -- Monk
            { spellId = 204490, name = "Sigil of Chains",     duration = 6  }, -- Demon Hunter
        },
        fear = {
            { spellId = 5246,   name = "Intimidating Shout", duration = 8  }, -- Warrior
            { spellId = 5782,   name = "Fear",               duration = 20 }, -- Warlock
            { spellId = 5484,   name = "Howl of Terror",     duration = 20 }, -- Warlock
            { spellId = 8122,   name = "Psychic Scream",     duration = 8  }, -- Priest
        },
        horror = {
            { spellId = 6789,   name = "Mortal Coil",        duration = 3  }, -- Warlock
            { spellId = 119905, name = "Psychic Horror",     duration = 4  }, -- Priest (Shadow)
            { spellId = 323639, name = "Mindgames",          duration = 5  }, -- Priest (Venthyr)
        },
        disorientation = {
            { spellId = 1776,   name = "Gouge",              duration = 4  }, -- Rogue
            { spellId = 2094,   name = "Blind",              duration = 8  }, -- Rogue
            { spellId = 6770,   name = "Sap",                duration = 60 }, -- Rogue
            { spellId = 31661,  name = "Dragon's Breath",    duration = 4  }, -- Mage
            { spellId = 213691, name = "Scatter Shot",       duration = 4  }, -- Hunter (MM)
            { spellId = 51490,  name = "Thunderstorm",       duration = 2  }, -- Shaman (Elemental)
            { spellId = 357214, name = "Oppressing Roar",    duration = 3  }, -- Evoker
        },
        silence = {
            { spellId = 1330,   name = "Garrote",            duration = 3  }, -- Rogue
            { spellId = 15487,  name = "Silence",            duration = 5  }, -- Priest
            { spellId = 34490,  name = "Silencing Shot",     duration = 3  }, -- Hunter (MM)
            { spellId = 78675,  name = "Solar Beam",         duration = 8  }, -- Druid (Balance)
            { spellId = 47476,  name = "Strangulate",        duration = 5  }, -- Death Knight
            { spellId = 202137, name = "Sigil of Silence",   duration = 5  }, -- Demon Hunter
        },
        knockback = {
            { spellId = 186387, name = "Bursting Shot",      duration = 1  }, -- Hunter
        },
        sleep = {
            { spellId = 360806, name = "Sleep Walk",         duration = 8  }, -- Evoker
        },
    },

    -- Per-spec primary CC spell list: {spellId=N, family="string"}
    specCCLists = {
        -- Mage
        [62] = { -- Arcane
            { spellId = 118,    family = "polymorph"     },
            { spellId = 122,    family = "root"          },
            { spellId = 31661,  family = "disorientation"},
        },
        [63] = { -- Fire
            { spellId = 118,    family = "polymorph"     },
            { spellId = 122,    family = "root"          },
            { spellId = 31661,  family = "disorientation"},
        },
        [64] = { -- Frost
            { spellId = 118,    family = "polymorph"     },
            { spellId = 122,    family = "root"          },
            { spellId = 33395,  family = "root"          },
        },
        -- Paladin
        [65] = { -- Holy
            { spellId = 20066,  family = "incapacitate"  },
            { spellId = 853,    family = "stun"          },
        },
        [66] = { -- Protection
            { spellId = 853,    family = "stun"          },
        },
        [70] = { -- Retribution
            { spellId = 853,    family = "stun"          },
            { spellId = 20066,  family = "incapacitate"  },
        },
        -- Warrior
        [71] = { -- Arms
            { spellId = 107570, family = "stun"          },
            { spellId = 5246,   family = "fear"          },
            { spellId = 46968,  family = "stun"          },
        },
        [72] = { -- Fury
            { spellId = 107570, family = "stun"          },
            { spellId = 5246,   family = "fear"          },
            { spellId = 46968,  family = "stun"          },
        },
        [73] = { -- Protection
            { spellId = 46968,  family = "stun"          },
            { spellId = 5246,   family = "fear"          },
            { spellId = 107570, family = "stun"          },
        },
        -- Druid
        [102] = { -- Balance
            { spellId = 78675,  family = "silence"       },
            { spellId = 339,    family = "root"          },
            { spellId = 102359, family = "root"          },
            { spellId = 33786,  family = "incapacitate"  },
        },
        [103] = { -- Feral
            { spellId = 5211,   family = "stun"          },
            { spellId = 22570,  family = "stun"          },
            { spellId = 33786,  family = "incapacitate"  },
            { spellId = 339,    family = "root"          },
            { spellId = 99,     family = "incapacitate"  },
        },
        [104] = { -- Guardian
            { spellId = 5211,   family = "stun"          },
            { spellId = 99,     family = "incapacitate"  },
            { spellId = 339,    family = "root"          },
        },
        [105] = { -- Restoration
            { spellId = 33786,  family = "incapacitate"  },
            { spellId = 339,    family = "root"          },
            { spellId = 102359, family = "root"          },
        },
        -- Death Knight
        [250] = { -- Blood
            { spellId = 221562, family = "stun"          },
            { spellId = 45524,  family = "root"          },
        },
        [251] = { -- Frost
            { spellId = 108194, family = "stun"          },
            { spellId = 45524,  family = "root"          },
        },
        [252] = { -- Unholy
            { spellId = 108194, family = "stun"          },
            { spellId = 45524,  family = "root"          },
            { spellId = 91800,  family = "stun"          },
            { spellId = 6789,   family = "horror"        },
        },
        -- Hunter
        [253] = { -- Beast Mastery
            { spellId = 118329, family = "stun"          },
            { spellId = 3355,   family = "incapacitate"  },
            { spellId = 117526, family = "stun"          },
        },
        [254] = { -- Marksmanship
            { spellId = 213691, family = "disorientation"},
            { spellId = 3355,   family = "incapacitate"  },
            { spellId = 117526, family = "stun"          },
            { spellId = 34490,  family = "silence"       },
        },
        [255] = { -- Survival
            { spellId = 3355,   family = "incapacitate"  },
            { spellId = 117526, family = "stun"          },
            { spellId = 186387, family = "knockback"     },
        },
        -- Priest
        [256] = { -- Discipline
            { spellId = 8122,   family = "fear"          },
            { spellId = 15487,  family = "silence"       },
        },
        [257] = { -- Holy
            { spellId = 8122,   family = "fear"          },
            { spellId = 200196, family = "incapacitate"  },
            { spellId = 15487,  family = "silence"       },
        },
        [258] = { -- Shadow
            { spellId = 8122,   family = "fear"          },
            { spellId = 15487,  family = "silence"       },
            { spellId = 119905, family = "horror"        },
        },
        -- Rogue
        [259] = { -- Assassination
            { spellId = 408,    family = "stun"          },
            { spellId = 1833,   family = "stun"          },
            { spellId = 2094,   family = "disorientation"},
            { spellId = 6770,   family = "disorientation"},
            { spellId = 1330,   family = "silence"       },
        },
        [260] = { -- Outlaw
            { spellId = 408,    family = "stun"          },
            { spellId = 1833,   family = "stun"          },
            { spellId = 2094,   family = "disorientation"},
            { spellId = 6770,   family = "disorientation"},
        },
        [261] = { -- Subtlety
            { spellId = 408,    family = "stun"          },
            { spellId = 1833,   family = "stun"          },
            { spellId = 2094,   family = "disorientation"},
            { spellId = 6770,   family = "disorientation"},
            { spellId = 1330,   family = "silence"       },
        },
        -- Shaman
        [262] = { -- Elemental
            { spellId = 51514,  family = "incapacitate"  },
            { spellId = 51490,  family = "disorientation"},
            { spellId = 192058, family = "stun"          },
        },
        [263] = { -- Enhancement
            { spellId = 51514,  family = "incapacitate"  },
            { spellId = 192058, family = "stun"          },
        },
        [264] = { -- Restoration
            { spellId = 51514,  family = "incapacitate"  },
            { spellId = 192058, family = "stun"          },
        },
        -- Warlock
        [265] = { -- Affliction
            { spellId = 5782,   family = "fear"          },
            { spellId = 5484,   family = "fear"          },
            { spellId = 6789,   family = "horror"        },
            { spellId = 30283,  family = "stun"          },
            { spellId = 89766,  family = "stun"          },
        },
        [266] = { -- Demonology
            { spellId = 5782,   family = "fear"          },
            { spellId = 5484,   family = "fear"          },
            { spellId = 6789,   family = "horror"        },
            { spellId = 30283,  family = "stun"          },
            { spellId = 89766,  family = "stun"          },
        },
        [267] = { -- Destruction
            { spellId = 5782,   family = "fear"          },
            { spellId = 5484,   family = "fear"          },
            { spellId = 6789,   family = "horror"        },
            { spellId = 30283,  family = "stun"          },
        },
        -- Monk
        [268] = { -- Brewmaster
            { spellId = 119381, family = "stun"          },
            { spellId = 115078, family = "incapacitate"  },
        },
        [269] = { -- Windwalker
            { spellId = 119381, family = "stun"          },
            { spellId = 115078, family = "incapacitate"  },
        },
        [270] = { -- Mistweaver
            { spellId = 119381, family = "stun"          },
            { spellId = 115078, family = "incapacitate"  },
        },
        -- Demon Hunter
        [577] = { -- Havoc
            { spellId = 179057, family = "stun"          },
            { spellId = 211881, family = "stun"          },
            { spellId = 198909, family = "incapacitate"  },
            { spellId = 204490, family = "root"          },
        },
        [580] = { -- Vengeance
            { spellId = 179057, family = "stun"          },
            { spellId = 198909, family = "incapacitate"  },
            { spellId = 204490, family = "root"          },
            { spellId = 202137, family = "silence"       },
        },
        [1456] = { -- Devourer
            { spellId = 179057, family = "stun"          },
            { spellId = 211881, family = "stun"          },
            { spellId = 198909, family = "incapacitate"  },
        },
        -- Evoker
        [1465] = { -- Devastation
            { spellId = 360806, family = "sleep"         },
            { spellId = 357214, family = "disorientation"},
        },
        [1467] = { -- Augmentation
            { spellId = 360806, family = "sleep"         },
            { spellId = 357214, family = "disorientation"},
        },
        [1468] = { -- Preservation
            { spellId = 360806, family = "sleep"         },
            { spellId = 357214, family = "disorientation"},
        },
    },

    immunityTags = {
        [642]    = "full_immunity",      -- Divine Shield (Paladin)
        [45438]  = "full_immunity",      -- Ice Block (Mage)
        [1022]   = "physical_immunity",  -- Blessing of Protection (Paladin)
        [31224]  = "magic_immunity",     -- Cloak of Shadows (Rogue)
        [48707]  = "magic_immunity",     -- Anti-Magic Shell (Death Knight)
        [186265] = "physical_immunity",  -- Aspect of the Turtle (Hunter)
        [198589] = "physical_immunity",  -- Blur (Demon Hunter)
    },

    breakCcTags = {
        [42292] = true,  -- PvP Trinket
        [59752] = true,  -- Will to Survive (Human racial)
        [20600] = true,  -- Escape Artist (Gnome racial)
        [7744]  = true,  -- Will of the Forsaken (Undead racial, breaks fear/charm/sleep)
    },
}
