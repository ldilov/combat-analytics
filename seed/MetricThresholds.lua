local _, ns = ...

-- Scoring bands for derived PvP metrics.
-- For "rate" metrics (lower = better): excellent < good < weak < critical.
-- For "conversion" metrics (higher = better): critical < weak < good < excellent.
-- Values are the LOWER BOUND of that band (i.e., rate >= value → in this band).

ns.SeedMetricThresholds = ns.SeedMetricThresholds or {}

ns.SeedMetricThresholds.bands = {
    -- Lower is better
    greedDeathRate = {
        excellent = 0.00,
        good      = 0.10,
        weak      = 0.25,
        critical  = 0.40,
    },
    defensiveOverlapRate = {
        excellent = 0.00,
        good      = 0.10,
        weak      = 0.20,
        critical  = 0.35,
    },
    burstWasteRate = {
        excellent = 0.00,
        good      = 0.10,
        weak      = 0.25,
        critical  = 0.40,
    },
    drWasteRate = {
        excellent = 0.00,
        good      = 0.10,
        weak      = 0.25,
        critical  = 0.40,
    },
    -- Higher is better
    killWindowConversionRate = {
        critical  = 0.20,
        weak      = 0.40,
        good      = 0.60,
        excellent = 0.75,
    },
    winRate = {
        critical  = 0.40,
        weak      = 0.48,
        good      = 0.55,
        excellent = 0.65,
    },
}

-- Minimum sample sizes before a metric is considered meaningful.
ns.SeedMetricThresholds.minSamples = {
    build      = 10,  -- matches before build win rate is shown
    matchup    = 5,   -- matches against an archetype before reporting
    weighted   = 30,  -- rolling window size for weighted win rate
    buildFull  = 30,  -- target sample for full build confidence (sampleFactor = 1.0)
}
