local _, ns = ...

-- Arena and battleground map seed data.
-- mapId = the instanceMapID returned by C_Map / zone context APIs.
-- losRating: 0=open, 1=partial, 2=heavy, 3=pillar-city
-- objectiveType: "elimination" | "flag" | "node" | "cart" | "teamfight"

ns.SeedMaps = ns.SeedMaps or {}

ns.SeedMaps.arenas = {
    [562]  = { name = "Blade's Edge Arena",        losRating = 2, objectiveType = "elimination" },
    [559]  = { name = "Nagrand Arena",              losRating = 1, objectiveType = "elimination" },
    [572]  = { name = "Ruins of Lordaeron",         losRating = 2, objectiveType = "elimination" },
    [617]  = { name = "Dalaran Arena",              losRating = 1, objectiveType = "elimination" },
    [618]  = { name = "Ring of Valor",              losRating = 1, objectiveType = "elimination" },
    [980]  = { name = "Tol'viron Arena",            losRating = 2, objectiveType = "elimination" },
    [1134] = { name = "Tiger's Peak",               losRating = 1, objectiveType = "elimination" },
    [1504] = { name = "Ashamane's Fall",            losRating = 2, objectiveType = "elimination" },
    [1552] = { name = "Mugambala",                  losRating = 2, objectiveType = "elimination" },
    [1911] = { name = "Hook Point",                 losRating = 2, objectiveType = "elimination" },
    [2167] = { name = "The Robodrome",              losRating = 0, objectiveType = "elimination" },
    [2373] = { name = "Empyrean Domain",            losRating = 2, objectiveType = "elimination" },
    [2509] = { name = "Nokhudon Proving Grounds",   losRating = 2, objectiveType = "elimination" },
    [2547] = { name = "Maldraxxus Coliseum",        losRating = 1, objectiveType = "elimination" },
}

ns.SeedMaps.battlegrounds = {
    [30]   = { name = "Alterac Valley",             objectiveType = "teamfight", isBG = true },
    [489]  = { name = "Warsong Gulch",              objectiveType = "flag",      isBG = true },
    [529]  = { name = "Arathi Basin",               objectiveType = "node",      isBG = true },
    [566]  = { name = "Eye of the Storm",           objectiveType = "flag",      isBG = true },
    [628]  = { name = "Isle of Conquest",           objectiveType = "teamfight", isBG = true },
    [726]  = { name = "Twin Peaks",                 objectiveType = "flag",      isBG = true },
    [761]  = { name = "The Battle for Gilneas",     objectiveType = "node",      isBG = true },
    [998]  = { name = "Temple of Kotmogu",          objectiveType = "teamfight", isBG = true },
    [1105] = { name = "Deepwind Gorge",             objectiveType = "node",      isBG = true },
    [1280] = { name = "Seething Shore",             objectiveType = "node",      isBG = true },
    [2118] = { name = "Silvershard Mines",          objectiveType = "cart",      isBG = true },
}
