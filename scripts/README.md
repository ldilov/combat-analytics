# CombatAnalytics Data Scripts

Developer tools for refreshing seed data from the official Battle.net Game Data API.
The raw JSON outputs are committed to the repo so the Lua generator can be re-run
without needing API credentials (useful for CI or offline environments).

## Prerequisites

```bash
pip install -r scripts/requirements.txt
```

Register a Battle.net developer app at https://develop.battle.net/access to obtain
a Client ID and Client Secret.

## Workflow

### Step 1: Fetch raw API data

```bash
export BNET_CLIENT_ID=your_client_id
export BNET_CLIENT_SECRET=your_client_secret
python scripts/fetch_blizzard_data.py --region us --output data/raw/
```

Fetches:
- `data/raw/classes.json`     — playable class index + details
- `data/raw/specs.json`       — specialization index + details
- `data/raw/pvp_talents.json` — PvP talent index + details

### Step 2: Generate Lua seed files

```bash
python scripts/generate_seed_from_api.py --input data/raw/ --output seed/generated/
```

Generates:
- `seed/generated/SeedSpecBaseline.lua`     — new baseline file with API-derived spec/role data (does **not** replace the hand-authored `SeedSpecArchetypes.lua`)
- `seed/generated/SeedPvpTalentCatalog.lua` — new file (add to TOC if not already present)

### Step 3: Add new generated files to TOC (first time only)

If `SeedPvpTalentCatalog.lua` is new, add it to `CombatAnalytics.toc` before
`StaticPvpData.lua`:

```
seed\generated\SeedPvpTalentCatalog.lua
StaticPvpData.lua
```

Then wire it into `StaticPvpData.lua` following the existing pattern:

```lua
local generated = ns.GeneratedSeedData or {}
-- add:
local pvpTalentCatalog = Helpers.CopyTable(generated.pvpTalentCatalog or {}, true)
-- expose:
ns.StaticPvpData = { ..., PVP_TALENT_CATALOG = pvpTalentCatalog }
```

## When to Re-run

| Trigger | Action |
|---|---|
| New WoW patch | Re-run both scripts — specs/talents may have changed |
| New PvP season | Re-run to pick up new PvP talents |
| New class/spec added | Re-run both scripts |
| Offline Lua regen | Run `generate_seed_from_api.py` only (uses committed JSON) |

## Committed Files

`data/raw/*.json` files are committed to the repo. This means:
- Lua seed files can be regenerated without API credentials.
- Diffs are visible when the API data changes after a re-fetch.
