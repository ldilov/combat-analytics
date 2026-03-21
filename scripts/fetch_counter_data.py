#!/usr/bin/env python3
"""
fetch_counter_data.py
=====================
Fetches per-spec PvP data from the Blizzard Battle.net API and murlok.io,
then generates  seed/generated/SeedCounterTips.lua  for the CombatAnalytics
addon.

Run once after install, or whenever you want fresh data:

    cd scripts/
    pip install -r requirements.txt
    python fetch_counter_data.py

The script writes  seed/generated/SeedCounterTips.lua  relative to the
addon root (one directory up from scripts/).

Environment variables (set or pass as --env-file):
    BNET_CLIENT_ID      – Battle.net OAuth client ID
    BNET_CLIENT_SECRET  – Battle.net OAuth client secret
    BNET_REGION         – us | eu | kr | tw  (default: eu)

Murlok.io is scraped without auth (public JSON endpoint).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any

try:
    import requests
except ImportError:
    sys.exit("Missing dependency: pip install requests")

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR  = Path(__file__).resolve().parent
ADDON_ROOT  = SCRIPT_DIR.parent
SEED_OUT    = ADDON_ROOT / "seed" / "generated" / "SeedCounterTips.lua"
RAW_DIR     = ADDON_ROOT / "data" / "raw"
RAW_DIR.mkdir(parents=True, exist_ok=True)

# ---------------------------------------------------------------------------
# Blizzard OAuth
# ---------------------------------------------------------------------------
BNET_TOKEN_URL = {
    "us": "https://oauth.battle.net/token",
    "eu": "https://eu.battle.net/oauth/token",
    "kr": "https://kr.battle.net/oauth/token",
    "tw": "https://tw.battle.net/oauth/token",
}
BNET_API_URL = {
    "us": "https://us.api.blizzard.com",
    "eu": "https://eu.api.blizzard.com",
    "kr": "https://kr.api.blizzard.com",
    "tw": "https://tw.api.blizzard.com",
}


def get_bnet_token(client_id: str, client_secret: str, region: str) -> str:
    resp = requests.post(
        BNET_TOKEN_URL[region],
        data={"grant_type": "client_credentials"},
        auth=(client_id, client_secret),
        timeout=15,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def bnet_get(token: str, region: str, path: str, params: dict | None = None) -> Any:
    url = BNET_API_URL[region] + path
    headers = {"Authorization": f"Bearer {token}"}
    resp = requests.get(url, headers=headers, params=params or {}, timeout=15)
    resp.raise_for_status()
    return resp.json()


# ---------------------------------------------------------------------------
# Murlok.io — public spec win-rate endpoint
# ---------------------------------------------------------------------------
MURLOK_URL = "https://murlok.io/arena/spec-distribution"

# Mapping from murlok spec name → WoW spec ID
# (only the most common PvP specs; extend as needed)
MURLOK_SPEC_ID_MAP: dict[str, int] = {
    "Affliction Warlock":    265,
    "Destruction Warlock":   267,
    "Demonology Warlock":    266,
    "Assassination Rogue":   259,
    "Outlaw Rogue":          260,
    "Subtlety Rogue":        261,
    "Holy Paladin":          65,
    "Retribution Paladin":   70,
    "Protection Paladin":    66,
    "Arms Warrior":          71,
    "Fury Warrior":          72,
    "Protection Warrior":    73,
    "Balance Druid":         102,
    "Feral Druid":           103,
    "Guardian Druid":        104,
    "Restoration Druid":     105,
    "Marksmanship Hunter":   254,
    "Beast Mastery Hunter":  253,
    "Survival Hunter":       255,
    "Arcane Mage":           62,
    "Fire Mage":             63,
    "Frost Mage":            64,
    "Elemental Shaman":      262,
    "Enhancement Shaman":    263,
    "Restoration Shaman":    264,
    "Shadow Priest":         258,
    "Holy Priest":           257,
    "Discipline Priest":     256,
    "Blood Death Knight":    250,
    "Frost Death Knight":    251,
    "Unholy Death Knight":   252,
    "Windwalker Monk":       269,
    "Brewmaster Monk":       268,
    "Mistweaver Monk":       270,
    "Havoc Demon Hunter":    577,
    "Vengeance Demon Hunter":581,
    "Devastation Evoker":    1467,
    "Preservation Evoker":   1468,
    "Augmentation Evoker":   1473,
}


def fetch_murlok_winrates() -> dict[int, float]:
    """
    Returns {specId: winRate (0.0-1.0)} scraped from murlok.io.
    Falls back to empty dict on any error.
    """
    try:
        resp = requests.get(MURLOK_URL, timeout=20, headers={"User-Agent": "CombatAnalytics/1.0"})
        resp.raise_for_status()
        # Murlok returns HTML; look for embedded JSON
        match = re.search(r'window\.__INITIAL_STATE__\s*=\s*({.*?});\s*</script>', resp.text, re.S)
        if not match:
            # Try alternate JSON endpoint
            alt = requests.get("https://murlok.io/api/specs", timeout=15,
                               headers={"User-Agent": "CombatAnalytics/1.0"})
            if alt.ok:
                data = alt.json()
                result: dict[int, float] = {}
                for entry in (data if isinstance(data, list) else []):
                    name = entry.get("specName", "") + " " + entry.get("className", "")
                    spec_id = MURLOK_SPEC_ID_MAP.get(name.strip())
                    wr = entry.get("winRate") or entry.get("win_rate")
                    if spec_id and wr is not None:
                        result[spec_id] = float(wr) / 100.0 if float(wr) > 1 else float(wr)
                return result
            return {}
        raw_json = json.loads(match.group(1))
        # Walk the state tree looking for spec win rates
        result = {}
        def walk(obj: Any) -> None:
            if isinstance(obj, dict):
                spec_id = obj.get("specId") or obj.get("spec_id")
                wr      = obj.get("winRate") or obj.get("win_rate")
                if spec_id and wr is not None:
                    result[int(spec_id)] = float(wr) / 100.0 if float(wr) > 1 else float(wr)
                for v in obj.values():
                    walk(v)
            elif isinstance(obj, list):
                for item in obj:
                    walk(item)
        walk(raw_json)
        return result
    except Exception as exc:
        print(f"[warn] murlok.io fetch failed: {exc}")
        return {}


# ---------------------------------------------------------------------------
# Static counter-tip seed  (curated, always present)
# ---------------------------------------------------------------------------
# Format: specId → { tips=[], interruptPriority=[], safeWindows=[] }
STATIC_TIPS: dict[int, dict] = {
    # Affliction Warlock
    265: {
        "tips": [
            "Dispel Unstable Affliction only when you have DR on silence or you will silence yourself.",
            "Interrupt Malefic Rapture channels to slow the DoT stack pressure.",
            "Purge/decurse Haunt to remove the damage amplifier.",
            "Defensive CDs are best used when Darkglare is active.",
        ],
        "interruptPriority": ["Malefic Rapture", "Drain Life"],
        "safeWindows": ["After Darkglare expires", "After Soul Rot is on CD"],
    },
    # Destruction Warlock
    267: {
        "tips": [
            "Interrupt Chaos Bolt — it is the primary kill threat.",
            "CC the Warlock before Havoc is applied to prevent cleaved kills.",
            "Darkness or personal defensive when Rain of Fire + Conflagrate combo lands.",
            "Dispel Immolate to reduce Conflagrate damage.",
        ],
        "interruptPriority": ["Chaos Bolt", "Rain of Fire"],
        "safeWindows": ["After Conflagrate stack is spent", "After Infernal expires"],
    },
    # Fire Mage
    63: {
        "tips": [
            "Save interrupt for Pyroblast during Combustion — all other casts can be juke bait.",
            "Use defensives AFTER Combustion ends, not during (too late during).",
            "Grounding/reflect Fireball to prevent Hot Streak procs.",
            "Combustion window is ~10 s; survive it with an immunity if available.",
        ],
        "interruptPriority": ["Pyroblast (instant during Combustion)", "Fireball"],
        "safeWindows": ["After Combustion expires", "When Mage trinket is on CD"],
    },
    # Frost Mage
    64: {
        "tips": [
            "Break Freeze before it is used for Glacial Spike setup.",
            "Trinket Water Elemental Freeze, not Frost Nova (Frost Nova shares DR with it).",
            "Interrupt Ebonbolt to prevent guaranteed Shatter.",
            "Use anti-magic shell / immune ability to eat one Glacial Spike.",
        ],
        "interruptPriority": ["Glacial Spike", "Ebonbolt"],
        "safeWindows": ["After Frozen Orb ends", "After Icy Veins expires"],
    },
    # Subtlety Rogue
    261: {
        "tips": [
            "Use tremor/fear break when Blind + Kidney combo is set up.",
            "Trade defensives with Symbols of Death + Shadowstrike burst window.",
            "Shadow Dance has a 6 s window — stack defensives through it.",
            "Kick Eviscerate/Secret Technique when they are stuck in place.",
        ],
        "interruptPriority": ["Eviscerate", "Kidney Shot setup"],
        "safeWindows": ["After Shadow Dance expires", "After Vanish CD"],
    },
    # Holy Paladin
    65: {
        "tips": [
            "CC the Paladin through Avenging Crusader — the burst heal window is dangerous.",
            "Interrupt Word of Glory during go from their team.",
            "Stun landing on Paladin during Forbearance is their most vulnerable window.",
            "Poison/curse application reduces Holy Paladin's efficient output.",
        ],
        "interruptPriority": ["Word of Glory", "Holy Shock (if no instant)"],
        "safeWindows": ["When Avenging Crusader is on CD", "During Forbearance window"],
    },
    # Restoration Druid
    105: {
        "tips": [
            "Purge Lifebloom to force expensive recasting.",
            "Interrupt Tranquility if not immune.",
            "CC RDruid during Convoke — or pre-CC before they channel.",
            "Pressure during Incarnation: Tree of Life window when all HoTs are amplified.",
        ],
        "interruptPriority": ["Tranquility", "Regrowth (low mana phases)"],
        "safeWindows": ["After Innervate is used", "After Convoke on CD"],
    },
    # Arms Warrior
    71: {
        "tips": [
            "Kite during Bladestorm — you cannot be CC'd but damage is high.",
            "Interrupt Mortal Strike setup when Warbreaker is active.",
            "Fear/CC outside of Berserker Rage window.",
            "Defensive during Avatar + Colossus Smash + Warbreaker combo.",
        ],
        "interruptPriority": ["Pummel into Disarm attempt"],
        "safeWindows": ["After Avatar expires", "When Warbreaker is on CD"],
    },
    # Havoc Demon Hunter
    577: {
        "tips": [
            "Do not trinket Imprison — wait for Chaos Nova follow-up stun.",
            "Defensives during Metamorphosis + Blade Dance window.",
            "Grounding Totem eats Fel Rush momentum.",
            "CC during Eye Beam channel to interrupt the stun setup.",
        ],
        "interruptPriority": ["Fel Eruption", "Eye Beam (interrupt breaks stun)"],
        "safeWindows": ["After Metamorphosis expires", "After Blur on CD"],
    },
    # Shadow Priest
    258: {
        "tips": [
            "Purge Vampiric Embrace to reduce self-sustain.",
            "Interrupt Void Bolt (interrupt resets DR efficiently).",
            "CC before Voidform to prevent the damage amp.",
            "Death during Surrender to Madness is self-inflicted — don't trinket early.",
        ],
        "interruptPriority": ["Mind Blast", "Void Bolt (if no kick available use CC)"],
        "safeWindows": ["After Voidform expires", "After Power Infusion CD"],
    },
}


# ---------------------------------------------------------------------------
# Lua writer
# ---------------------------------------------------------------------------
def lua_string(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_lua(spec_tips: dict[int, dict], murlok_wr: dict[int, float], generated_at: str) -> None:
    lines = [
        "-- AUTO-GENERATED by scripts/fetch_counter_data.py",
        f"-- Generated: {generated_at}",
        "-- Do NOT edit manually — run the script to regenerate.",
        "",
        "local _, ns = ...",
        "ns.GeneratedSeedData = ns.GeneratedSeedData or {}",
        "",
        "--- Counter tips, interrupt priorities, and safe-window hints per spec.",
        "--- @field tips string[]              General counter advice.",
        "--- @field interruptPriority string[] Spells to kick in priority order.",
        "--- @field safeWindows string[]       Windows when the spec is vulnerable.",
        "--- @field murlokWinRate number|nil   Global win rate from murlok.io (0-1).",
        "ns.GeneratedSeedData.counterTips = {",
    ]

    all_spec_ids = sorted(set(list(spec_tips.keys()) + list(murlok_wr.keys())))

    for spec_id in all_spec_ids:
        tips_entry = spec_tips.get(spec_id, {})
        wr = murlok_wr.get(spec_id)

        lines.append(f"    [{spec_id}] = {{")

        # tips
        tips = tips_entry.get("tips", [])
        lines.append("        tips = {")
        for tip in tips:
            lines.append(f"            {lua_string(tip)},")
        lines.append("        },")

        # interruptPriority
        interrupts = tips_entry.get("interruptPriority", [])
        lines.append("        interruptPriority = {")
        for it in interrupts:
            lines.append(f"            {lua_string(it)},")
        lines.append("        },")

        # safeWindows
        windows = tips_entry.get("safeWindows", [])
        lines.append("        safeWindows = {")
        for w in windows:
            lines.append(f"            {lua_string(w)},")
        lines.append("        },")

        # murlokWinRate
        if wr is not None:
            lines.append(f"        murlokWinRate = {wr:.4f},")
        else:
            lines.append("        murlokWinRate = nil,")

        lines.append("    },")

    lines.append("}")
    lines.append("")

    SEED_OUT.parent.mkdir(parents=True, exist_ok=True)
    SEED_OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"[ok] Wrote {SEED_OUT}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(description="Fetch PvP counter data and generate Lua seed.")
    parser.add_argument("--region",        default=os.getenv("BNET_REGION", "eu"),
                        choices=["us", "eu", "kr", "tw"])
    parser.add_argument("--client-id",     default=os.getenv("BNET_CLIENT_ID", ""))
    parser.add_argument("--client-secret", default=os.getenv("BNET_CLIENT_SECRET", ""))
    parser.add_argument("--skip-murlok",   action="store_true",
                        help="Skip murlok.io scrape (use static tips only)")
    parser.add_argument("--skip-bnet",     action="store_true",
                        help="Skip Battle.net API calls")
    args = parser.parse_args()

    print("=== CombatAnalytics counter-data fetch ===")
    print(f"Region: {args.region}")

    murlok_wr: dict[int, float] = {}
    if not args.skip_murlok:
        print("Fetching murlok.io win rates …")
        murlok_wr = fetch_murlok_winrates()
        print(f"  → {len(murlok_wr)} spec win rates retrieved")

        # Cache raw data
        raw_path = RAW_DIR / "murlok_winrates.json"
        raw_path.write_text(json.dumps(murlok_wr, indent=2), encoding="utf-8")
        print(f"  → Cached to {raw_path}")
    else:
        print("Skipping murlok.io (--skip-murlok)")
        # Try loading cached data
        cached = RAW_DIR / "murlok_winrates.json"
        if cached.exists():
            murlok_wr = {int(k): v for k, v in json.loads(cached.read_text()).items()}
            print(f"  → Loaded {len(murlok_wr)} cached win rates from {cached}")

    generated_at = datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC")
    write_lua(STATIC_TIPS, murlok_wr, generated_at)

    print("")
    print("Done. Reload your addon or restart WoW to pick up the new seed file.")
    print(f"Output: {SEED_OUT}")


if __name__ == "__main__":
    main()
