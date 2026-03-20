local _, ns = ...

ns.GeneratedSeedData = ns.GeneratedSeedData or {}

ns.GeneratedSeedData.spellIntelligence = {

    -- =========================================================
    -- TRINKET / GENERIC BREAK-CC
    -- =========================================================
    [42292]  = { category = "defensive", isMajorDefensive = true, isTrinketLike = true, breaksCC = true, notesTag = "break_cc", cooldownSeconds = 120, isPvPTrinket = true },

    -- =========================================================
    -- MAJOR OFFENSIVE CDs
    -- =========================================================

    -- Mage
    [190319] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "fire_burst" },           -- Combustion
    [12042]  = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "mage_burst" },            -- Arcane Power
    [12472]  = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "caster_haste_go" },       -- Icy Veins

    -- Paladin
    [31884]  = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "paladin_burst" },         -- Avenging Wrath
    [216331] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "holy_paladin_burst" },    -- Avenging Crusader

    -- Warrior
    [1719]   = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "warrior_burst" },         -- Recklessness
    [107574] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "warrior_avatar" },        -- Avatar

    -- Hunter
    [19574]  = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "hunter_burst" },          -- Bestial Wrath
    [288613] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "mm_burst" },              -- Trueshot
    [266779] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "sv_burst" },              -- Coordinated Assault

    -- Rogue
    [51690]  = { category = "offensive", isMajorOffensive = true, notesTag = "outlaw_burst" },                                 -- Killing Spree
    [79140]  = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "assassination_burst" },   -- Vendetta
    [185313] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "sub_burst" },             -- Shadow Dance
    [121471] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "sub_burst_blades" },      -- Shadow Blades
    [13750]  = { category = "offensive", isMajorOffensive = true, notesTag = "outlaw_adrenaline" },                            -- Adrenaline Rush

    -- Priest
    [228260] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "shadow_burst" },          -- Voidform
    [10060]  = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "power_infusion" },        -- Power Infusion

    -- Warlock
    [205180] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "affliction_burst" },      -- Summon Darkglare
    [267171] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "demo_burst" },            -- Demonic Tyrant
    [1122]   = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "destro_burst" },          -- Summon Infernal

    -- Druid
    [106951] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "feral_burst" },           -- Berserk
    [102543] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "feral_incarn" },          -- Incarnation: King of the Jungle
    [194223] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "balance_burst" },         -- Celestial Alignment
    [102560] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "balance_incarn" },        -- Incarnation: Chosen of Elune

    -- Shaman
    [191634] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "ele_burst" },             -- Stormkeeper
    [114051] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "ele_ascendance" },        -- Ascendance (Elemental)
    [114049] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "enh_ascendance" },        -- Ascendance (Enhancement)
    [2825]   = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "bloodlust" },             -- Bloodlust
    [32182]  = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "heroism" },               -- Heroism

    -- Death Knight
    [47568]  = { category = "offensive", isMajorOffensive = true, notesTag = "dk_rune_weapon" },                               -- Empower Rune Weapon
    [42650]  = { category = "offensive", isMajorOffensive = true, notesTag = "unholy_army" },                                  -- Army of the Dead
    [63560]  = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "unholy_transform" },      -- Dark Transformation

    -- Demon Hunter
    [162264] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "havoc_meta" },            -- Metamorphosis (Havoc)
    [200166] = { category = "offensive", isMajorOffensive = true, notesTag = "havoc_momentum" },                               -- Momentum
    [442520] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "devourer_burst" },        -- Ravenous Frenzy (Devourer)

    -- Monk
    [137639] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "ww_sef" },                -- Storm, Earth, and Fire
    [152173] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "ww_serenity" },           -- Serenity
    [123904] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "ww_xuen" },               -- Invoke Xuen

    -- Evoker
    [375087] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "dev_dragonrage" },        -- Dragonrage
    [359073] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "aug_boe" },               -- Breath of Eons (Augmentation)

    -- =========================================================
    -- MAJOR DEFENSIVE CDs
    -- =========================================================

    -- Mage
    [45438]  = { category = "defensive", isMajorDefensive = true, isImmunity = true, notesTag = "ice_block", cooldownSeconds = 240 },                 -- Ice Block
    [55342]  = { category = "defensive", isMajorDefensive = true, notesTag = "mirror_image", cooldownSeconds = 120 },                                 -- Mirror Image
    [11426]  = { category = "defensive", isMajorDefensive = true, notesTag = "ice_barrier", cooldownSeconds = 25 },                                   -- Ice Barrier

    -- Paladin
    [642]    = { category = "defensive", isMajorDefensive = true, isImmunity = true, notesTag = "full_immunity", cooldownSeconds = 300 },             -- Divine Shield
    [1022]   = { category = "defensive", isMajorDefensive = true, isImmunity = true, notesTag = "physical_immunity", cooldownSeconds = 25 },          -- Blessing of Protection
    [498]    = { category = "defensive", isMajorDefensive = true, notesTag = "divine_protection", cooldownSeconds = 60 },                             -- Divine Protection
    [204018] = { category = "defensive", isMajorDefensive = true, isImmunity = true, notesTag = "magic_immunity_bless", cooldownSeconds = 60 },       -- Blessing of Spellwarding
    [6940]   = { category = "defensive", isMajorDefensive = true, isRecoveryTool = true, notesTag = "external_save", cooldownSeconds = 120 },         -- Blessing of Sacrifice

    -- Warrior
    [871]    = { category = "defensive", isMajorDefensive = true, notesTag = "warrior_wall", cooldownSeconds = 240 },                                 -- Shield Wall
    [18499]  = { category = "defensive", isMajorDefensive = true, notesTag = "berserker_rage", cooldownSeconds = 30 },                                -- Berserker Rage (fear immunity)
    [97463]  = { category = "defensive", isMajorDefensive = true, notesTag = "rallying_cry", cooldownSeconds = 180 },                                 -- Rallying Cry
    [23920]  = { category = "defensive", isMajorDefensive = true, isImmunity = true, notesTag = "spell_reflect", cooldownSeconds = 25 },              -- Spell Reflection

    -- Rogue
    [5277]   = { category = "defensive", isMajorDefensive = true, notesTag = "avoidance", cooldownSeconds = 90 },                                     -- Evasion
    [31224]  = { category = "defensive", isMajorDefensive = true, notesTag = "magic_avoidance", cooldownSeconds = 120 },                              -- Cloak of Shadows
    [1966]   = { category = "defensive", isMajorDefensive = true, notesTag = "feint", cooldownSeconds = 15 },                                         -- Feint
    [45182]  = { category = "defensive", isMajorDefensive = true, notesTag = "cheat_death", cooldownSeconds = 30 },                                   -- Cheat Death

    -- Hunter
    [186265] = { category = "defensive", isMajorDefensive = true, isImmunity = true, notesTag = "turtle", cooldownSeconds = 180 },                    -- Aspect of the Turtle
    [264735] = { category = "defensive", isMajorDefensive = true, notesTag = "survival_fittest", cooldownSeconds = 180 },                             -- Survival of the Fittest
    [109248] = { category = "defensive", isMajorDefensive = true, notesTag = "feign_death", cooldownSeconds = 30 },                                   -- Feign Death

    -- Priest
    [47585]  = { category = "defensive", isMajorDefensive = true, isImmunity = true, notesTag = "dispersion", cooldownSeconds = 180 },                -- Dispersion
    [47788]  = { category = "defensive", isMajorDefensive = true, isRecoveryTool = true, notesTag = "guardian_spirit", cooldownSeconds = 180 },       -- Guardian Spirit
    [33206]  = { category = "defensive", isMajorDefensive = true, notesTag = "pain_suppression", cooldownSeconds = 120 },                             -- Pain Suppression
    [19236]  = { category = "defensive", isMajorDefensive = true, isRecoveryTool = true, notesTag = "desperate_prayer", cooldownSeconds = 90 },       -- Desperate Prayer

    -- Druid
    [22812]  = { category = "defensive", isMajorDefensive = true, isRecoveryTool = true, notesTag = "druid_wall", cooldownSeconds = 60 },             -- Barkskin
    [61336]  = { category = "defensive", isMajorDefensive = true, notesTag = "survival_instincts", cooldownSeconds = 180 },                           -- Survival Instincts
    [102342] = { category = "defensive", isMajorDefensive = true, notesTag = "ironbark", cooldownSeconds = 90 },                                      -- Ironbark

    -- Shaman
    [108271] = { category = "defensive", isMajorDefensive = true, notesTag = "astral_shift", cooldownSeconds = 90 },                                  -- Astral Shift
    [204393] = { category = "defensive", isMajorDefensive = true, notesTag = "ancestral_protection", cooldownSeconds = 300 },                         -- Ancestral Protection Totem

    -- Warlock
    [104773] = { category = "defensive", isMajorDefensive = true, notesTag = "warlock_wall", cooldownSeconds = 180 },                                 -- Unending Resolve
    [108416] = { category = "defensive", isMajorDefensive = true, notesTag = "dark_pact", cooldownSeconds = 60 },                                     -- Dark Pact

    -- Death Knight
    [48792]  = { category = "defensive", isMajorDefensive = true, notesTag = "icebound_fortitude", cooldownSeconds = 180 },                           -- Icebound Fortitude
    [48707]  = { category = "defensive", isMajorDefensive = true, isImmunity = true, notesTag = "anti_magic_shell", cooldownSeconds = 60 },           -- Anti-Magic Shell
    [49039]  = { category = "defensive", isMajorDefensive = true, isRecoveryTool = true, notesTag = "lichborne", cooldownSeconds = 120 },              -- Lichborne

    -- Demon Hunter
    [187827] = { category = "defensive", isMajorDefensive = true, notesTag = "veng_meta", cooldownSeconds = 180 },                                    -- Metamorphosis (Vengeance)
    [198589] = { category = "defensive", isMajorDefensive = true, notesTag = "blur", cooldownSeconds = 60 },                                          -- Blur
    [204021] = { category = "defensive", isMajorDefensive = true, notesTag = "fiery_brand", cooldownSeconds = 60 },                                    -- Fiery Brand
    [196718] = { category = "defensive", isMajorDefensive = true, notesTag = "group_darkness", cooldownSeconds = 180 },                               -- Darkness (Havoc)

    -- Monk
    [122278] = { category = "defensive", isMajorDefensive = true, notesTag = "dampen_harm", cooldownSeconds = 120 },                                  -- Dampen Harm
    [116849] = { category = "defensive", isMajorDefensive = true, notesTag = "life_cocoon", cooldownSeconds = 90 },                                   -- Life Cocoon
    [243435] = { category = "defensive", isMajorDefensive = true, notesTag = "fortifying_brew", cooldownSeconds = 420 },                              -- Fortifying Brew

    -- Evoker
    [363916] = { category = "defensive", isMajorDefensive = true, notesTag = "obsidian_scales", cooldownSeconds = 90 },                               -- Obsidian Scales
    [374348] = { category = "defensive", isMajorDefensive = true, isRecoveryTool = true, notesTag = "renewing_blaze", cooldownSeconds = 90 },         -- Renewing Blaze

    -- =========================================================
    -- INTERRUPTS
    -- =========================================================

    -- Already existing (reclassified to utility/interrupt)
    [1766]   = { category = "utility", isInterrupt = true, interruptFamily = "kick", notesTag = "rogue_kick" },                -- Kick (Rogue)
    [6552]   = { category = "utility", isInterrupt = true, interruptFamily = "pummel", notesTag = "warrior_interrupt" },       -- Pummel (Warrior)
    [2139]   = { category = "utility", isInterrupt = true, interruptFamily = "counterspell", notesTag = "mage_interrupt" },    -- Counterspell
    [47528]  = { category = "utility", isInterrupt = true, interruptFamily = "mind_freeze", notesTag = "dk_interrupt" },       -- Mind Freeze (DK)

    -- New interrupts
    [96231]  = { category = "utility", isInterrupt = true, interruptFamily = "rebuke", notesTag = "paladin_interrupt" },       -- Rebuke
    [57994]  = { category = "utility", isInterrupt = true, interruptFamily = "wind_shear", notesTag = "shaman_interrupt" },    -- Wind Shear
    [116705] = { category = "utility", isInterrupt = true, interruptFamily = "spear_hand", notesTag = "monk_interrupt" },      -- Spear Hand Strike
    [183752] = { category = "utility", isInterrupt = true, interruptFamily = "consume_magic", notesTag = "dh_interrupt" },     -- Consume Magic (DH)
    [351338] = { category = "utility", isInterrupt = true, interruptFamily = "quell", notesTag = "evoker_interrupt" },         -- Quell
    [147362] = { category = "utility", isInterrupt = true, interruptFamily = "counter_shot", notesTag = "hunter_interrupt" },  -- Counter Shot
    [187707] = { category = "utility", isInterrupt = true, interruptFamily = "muzzle", notesTag = "sv_interrupt" },            -- Muzzle (Survival)
    [78675]  = { category = "crowd_control", isInterrupt = true, isCrowdControlStarter = true, interruptFamily = "solar_beam", ccFamily = "silence", notesTag = "balance_silence" }, -- Solar Beam
    [15487]  = { category = "crowd_control", isInterrupt = true, isCrowdControlStarter = true, interruptFamily = "silence", ccFamily = "silence", notesTag = "priest_silence" },     -- Silence (Priest)
    [1330]   = { category = "crowd_control", isInterrupt = true, isCrowdControlStarter = true, interruptFamily = "garrote", ccFamily = "silence", notesTag = "rogue_silence" },      -- Garrote (silence)

    -- =========================================================
    -- CROWD CONTROL
    -- =========================================================

    -- Stuns
    [1833]   = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "stun", notesTag = "stun_setup" },       -- Cheap Shot (Rogue)
    [5211]   = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "stun", notesTag = "stun_setup" },       -- Bash (Druid)
    [408]    = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "stun", notesTag = "kidney_shot" },       -- Kidney Shot
    [853]    = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "stun", notesTag = "paladin_stun" },      -- Hammer of Justice
    [30283]  = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "stun", notesTag = "warlock_stun" },      -- Shadowfury
    [119381] = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "stun", notesTag = "monk_stun" },         -- Leg Sweep
    [179057] = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "stun", notesTag = "dh_stun" },           -- Chaos Nova
    [118000] = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "stun", notesTag = "stormbolt" },         -- Stormbolt (Warrior)
    [192058] = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "stun", notesTag = "lightning_lasso" },   -- Lightning Lasso (Shaman)
    [91800]  = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "stun", notesTag = "gnaw" },              -- Gnaw (Unholy DK ghoul)
    [91797]  = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "stun", notesTag = "monstrous_blow" },    -- Monstrous Blow (DK)

    -- Roots
    [339]    = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "root", notesTag = "entangling_roots" },  -- Entangling Roots
    [122]    = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "root", notesTag = "frost_nova" },        -- Frost Nova
    [233395] = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "root", notesTag = "earthgrab" },         -- Earthgrab Totem (Shaman)
    [162480] = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "root", notesTag = "dh_root" },           -- Throw Glaive root proc

    -- Fears
    [5782]   = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "fear", notesTag = "warlock_fear" },      -- Fear
    [8122]   = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "fear", notesTag = "psychic_scream" },    -- Psychic Scream
    [5246]   = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "fear", notesTag = "intimidating_shout" },-- Intimidating Shout

    -- Incapacitates / Soft CC
    [118]    = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "polymorph", notesTag = "polymorph" },    -- Polymorph
    [51514]  = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "incapacitate", notesTag = "hex" },       -- Hex
    [3355]   = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "incapacitate", notesTag = "freezing_trap" }, -- Freezing Trap
    [20066]  = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "incapacitate", notesTag = "repentance" }, -- Repentance
    [33786]  = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "incapacitate", notesTag = "cyclone" },    -- Cyclone
    [115078] = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "incapacitate", notesTag = "paralysis" },  -- Paralysis (Monk)
    [198909] = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "incapacitate", notesTag = "imprison" },   -- Imprison (DH)
    [217832] = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "incapacitate", notesTag = "sheep_like" }, -- Turn Evil (Paladin)

    -- Disorientations
    [2094]   = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "disorientation", notesTag = "blind" },   -- Blind (Rogue)
    [6770]   = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "disorientation", notesTag = "sap" },     -- Sap (Rogue)
    [1776]   = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "disorientation", notesTag = "gouge" },   -- Gouge (Rogue)
    [31661]  = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "disorientation", notesTag = "dragons_breath" }, -- Dragon's Breath
    [213691] = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "disorientation", notesTag = "scatter_shot" }, -- Scatter Shot (Hunter)

    -- Horror
    [6789]   = { category = "crowd_control", isCrowdControlStarter = true, isRecoveryTool = true, ccFamily = "horror", notesTag = "mortal_coil" }, -- Mortal Coil (Warlock)

    -- Sleep
    [360806] = { category = "crowd_control", isCrowdControlStarter = true, ccFamily = "sleep", notesTag = "sleep_walk" },       -- Sleep Walk (Evoker)

    -- =========================================================
    -- MOBILITY
    -- =========================================================

    [1953]   = { category = "mobility", isMobility = true, notesTag = "mage_blink" },                                          -- Blink (Mage)
    [212653] = { category = "mobility", isMobility = true, notesTag = "mage_shimmer" },                                        -- Shimmer (Mage)
    [26297]  = { category = "mobility", isMobility = true, notesTag = "warrior_leap" },                                        -- Heroic Leap
    [73828]  = { category = "mobility", isMobility = true, notesTag = "masters_call" },                                        -- Master's Call (Hunter)
    [781]    = { category = "mobility", isMobility = true, notesTag = "hunter_disengage" },                                    -- Disengage
    [36554]  = { category = "mobility", isMobility = true, notesTag = "rogue_shadowstep" },                                    -- Shadowstep (Rogue)
    [198793] = { category = "mobility", isMobility = true, notesTag = "outlaw_hook" },                                         -- Grappling Hook (Outlaw Rogue)
    [106898] = { category = "mobility", isMobility = true, notesTag = "stampeding_roar" },                                     -- Stampeding Roar (Druid)
    [195072] = { category = "mobility", isMobility = true, notesTag = "dh_fel_rush" },                                        -- Fel Rush (DH)
    [189110] = { category = "mobility", isMobility = true, notesTag = "dh_infernal_strike" },                                  -- Infernal Strike (DH)
    [109132] = { category = "mobility", isMobility = true, notesTag = "monk_roll" },                                           -- Roll (Monk)
    [115008] = { category = "mobility", isMobility = true, notesTag = "chi_torpedo" },                                         -- Chi Torpedo (Monk)
    [344359] = { category = "mobility", isMobility = true, notesTag = "evoker_hover" },                                        -- Hover (Evoker)
    [58875]  = { category = "mobility", isMobility = true, notesTag = "dk_death_grip" },                                       -- Death Grip (DK)
    [49576]  = { category = "mobility", isMobility = true, notesTag = "dk_death_grip_charge" },                                 -- Death Grip pull component
    [202138] = { category = "mobility", isMobility = true, notesTag = "dh_vengeful_retreat" },                                  -- Vengeful Retreat (DH)

    -- =========================================================
    -- HEALING / RECOVERY
    -- =========================================================

    [49998]  = { category = "healing", isRecoveryTool = true, notesTag = "death_strike" },                                     -- Death Strike (DK)
    [98008]  = { category = "healing", isRecoveryTool = true, notesTag = "spirit_link" },                                      -- Spirit Link Totem (Shaman)
    [207230] = { category = "healing", isRecoveryTool = true, notesTag = "ward_of_envelopment" },                              -- Enveloping Mist (Mistweaver Monk)
    [115175] = { category = "healing", isRecoveryTool = true, notesTag = "soothing_mist" },                                    -- Soothing Mist (Monk)
    [740]    = { category = "healing", isRecoveryTool = true, notesTag = "tranquility" },                                      -- Tranquility (Druid)
    [64843]  = { category = "healing", isRecoveryTool = true, notesTag = "divine_hymn" },                                      -- Divine Hymn (Priest)
    [108405] = { category = "healing", isRecoveryTool = true, notesTag = "disconnect_soul" },                                  -- Disconnect Soul / Soul Link passthrough
    [15286]  = { category = "healing", isRecoveryTool = true, notesTag = "vampiric_embrace" },                                 -- Vampiric Embrace (Shadow Priest)

    -- =========================================================
    -- ADDITIONAL OFFENSIVE UTILITY
    -- =========================================================

    [34026]  = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "bm_beast_cleave" },       -- Kill Command (BM trigger for burst)
    [185245] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "assassination_symbols" }, -- Symbols of Death (Sub Rogue)
    [386344] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "dk_abomination" },        -- Abomination Limb (DK)
    [323546] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "fleshcraft_absorb" },     -- Fleshcraft (Necrolord, legacy)
    [326702] = { category = "offensive", isMajorOffensive = true, isBurstEnabler = true, notesTag = "shattered_psyche" },      -- Mindgames (Priest covenant)

}
