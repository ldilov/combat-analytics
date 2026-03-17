local _, ns = ...

ns.StaticPvpData = {
    THEME_PRESETS = {
        modern_steel_ember = {
            background = { 0.05, 0.06, 0.08, 0.97 },
            panel = { 0.09, 0.10, 0.13, 0.97 },
            panelAlt = { 0.12, 0.13, 0.17, 0.97 },
            border = { 0.22, 0.24, 0.29, 1.0 },
            borderStrong = { 0.58, 0.42, 0.27, 1.0 },
            accent = { 0.92, 0.47, 0.22, 1.0 },
            accentSoft = { 0.30, 0.20, 0.15, 1.0 },
            text = { 0.93, 0.94, 0.96, 1.0 },
            textMuted = { 0.67, 0.70, 0.75, 1.0 },
            success = { 0.45, 0.74, 0.56, 1.0 },
            warning = { 0.95, 0.67, 0.26, 1.0 },
            panelHover = { 0.17, 0.14, 0.14, 0.98 },
            panelDisabled = { 0.07, 0.08, 0.10, 0.95 },
            barShell = { 0.08, 0.09, 0.11, 1.0 },
            header = { 0.08, 0.09, 0.12, 0.98 },
            contentShell = { 0.08, 0.09, 0.12, 0.97 },
            severityHigh = { 0.33, 0.16, 0.14, 1.0 },
            severityMedium = { 0.30, 0.21, 0.13, 1.0 },
            severityLow = { 0.15, 0.19, 0.24, 1.0 },
        },
    },
    SPELL_TAXONOMY = {
        majorOffensive = {
            [12042] = true,
            [31884] = true,
            [1719] = true,
            [19574] = true,
            [12472] = true,
        },
        majorDefensive = {
            [42292] = true,
            [1022] = true,
            [642] = true,
            [22812] = true,
            [5277] = true,
            [31224] = true,
            [104773] = true,
            [871] = true,
            [6940] = true,
            [196718] = true,
        },
    },
}
