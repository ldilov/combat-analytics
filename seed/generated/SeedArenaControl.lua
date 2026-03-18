local _, ns = ...

ns.GeneratedSeedData = ns.GeneratedSeedData or {}

ns.GeneratedSeedData.arenaControl = {
    ccFamilies = {
        stun = { "Cheap Shot", "Bash" },
        interrupt = { "Kick", "Pummel", "Counterspell", "Mind Freeze" },
    },
    immunityTags = {
        [1022] = "physical_immunity",
        [642] = "full_immunity",
    },
    breakCcTags = {
        [42292] = true,
    },
}
