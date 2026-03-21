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
---

## Counter Data Script

Fetches spec win rates from murlok.io and generates 
with curated counter tips, interrupt priority lists, and safe-window hints per spec.

### Step 1: Run after install (or to update)

```bash
# With Battle.net credentials (fetches live spec data too):
python scripts/fetch_counter_data.py

# Without credentials (murlok.io only):
python scripts/fetch_counter_data.py --skip-bnet

# Completely offline (uses cached data + static tips only):
python scripts/fetch_counter_data.py --skip-murlok --skip-bnet
```

Environment variables:
| Variable | Description |
|---|---|
|  | Battle.net OAuth client ID |
|  | Battle.net OAuth client secret |
|  | /// (default: ) |

### GitHub Actions (automated weekly refresh)

The workflow === CombatAnalytics counter-data fetch ===
Region: eu
Fetching murlok.io win rates …
[warn] murlok.io fetch failed: 404 Client Error: Not Found for url: https://murlok.io/arena/spec-distribution
  → 0 spec win rates retrieved
  → Cached to D:\Workspaceepos\combat-analytics\dataaw\murlok_winrates.json
[ok] Wrote D:\Workspaceepos\combat-analytics\seed\generated\SeedCounterTips.lua

Done. Reload your addon or restart WoW to pick up the new seed file.
Output: D:\Workspaceepos\combat-analytics\seed\generated\SeedCounterTips.lua
[main 012e699] chore(seed): auto-update seed data 2026-03-21
 2 files changed, 184 insertions(+)
 create mode 100644 data/raw/murlok_winrates.json
 create mode 100644 seed/generated/SeedCounterTips.lua runs every Monday at 06:00 UTC
and commits updated seed files automatically.

**Required repository secrets:**
- 
- 

To trigger manually: GitHub → Actions tab → **Update Seed Data** → **Run workflow**.

### CurseForge integration

After installing the addon via CurseForge, run the script once to get fresh data:

```bash
cd <path-to-CombatAnalytics-addon-folder>
python scripts/fetch_counter_data.py
```

The addon will pick up the new  on next WoW reload.
