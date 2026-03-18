# CombatAnalytics Seed Data

This folder holds long-lived local seed data for the addon. Runtime addon code does not read from `seed/raw/` directly.

## Layout
- `raw/`
  - downloaded source files or curated JSON overrides
- `generated/`
  - normalized Lua modules loaded by the addon

## Source Policy
- Prefer Blizzard UI/API references you already keep locally.
- Use structured exports like `wow.tools` only when official sources do not provide stable identifiers or names.
- Avoid patch-sensitive PvP meta, build rankings, or rotation guides.

## Current Seed Families
- training dummy catalog
- spell intelligence
- spec archetypes
- arena/control helpers

## Regeneration
1. Put raw exports or curated override JSON files into `seed/raw/`.
2. Run:

```powershell
python scripts/generate_seed_data.py
```

3. Review the files written into `seed/generated/`.

## Provenance Notes
- `dummy_catalog_overrides.json`
  - curated creature IDs and grouping labels for known training dummies
- `spell_intelligence_overrides.json`
  - curated PvP semantic tags for high-value spells only
- `spec_archetypes.json`
  - stable spec-to-archetype tags

Refresh only on major patches or when you discover new stable IDs that materially improve recognition.
