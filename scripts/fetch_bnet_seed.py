#!/usr/bin/env python3
"""
fetch_bnet_seed.py
==================
Fetches WoW game-data from the Battle.net API and generates two Lua seed files:

  seed/generated/SeedSpecMeta.lua   — official spec names, roles, class IDs,
                                      and spec icon file-data IDs for all 40 specs
  seed/generated/SeedPvpTalents.lua — all PvP talents per spec with spell ID,
                                      name, description, and cast time

Run once after install, or let the GitHub Actions workflow refresh weekly:

    cd scripts/
    pip install -r requirements.txt
    python fetch_bnet_seed.py

Environment variables:
    BNET_CLIENT_ID     – Battle.net OAuth client ID
    BNET_CLIENT_SECRET – Battle.net OAuth client secret
    BNET_REGION        – us | eu | kr | tw  (default: eu)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
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
SCRIPT_DIR = Path(__file__).resolve().parent
ADDON_ROOT  = SCRIPT_DIR.parent
RAW_DIR     = ADDON_ROOT / "seed" / "raw"
SEED_DIR    = ADDON_ROOT / "seed" / "generated"
RAW_DIR.mkdir(parents=True, exist_ok=True)
SEED_DIR.mkdir(parents=True, exist_ok=True)

SPEC_META_OUT    = SEED_DIR / "SeedSpecMeta.lua"
PVP_TALENTS_OUT  = SEED_DIR / "SeedPvpTalents.lua"

# ---------------------------------------------------------------------------
# Battle.net OAuth + helpers
# ---------------------------------------------------------------------------
BNET_TOKEN_URL = {
    "us": "https://oauth.battle.net/token",
    "eu": "https://eu.battle.net/oauth/token",
    "kr": "https://kr.battle.net/oauth/token",
    "tw": "https://tw.battle.net/oauth/token",
}
BNET_API_BASE = {
    "us": "https://us.api.blizzard.com",
    "eu": "https://eu.api.blizzard.com",
    "kr": "https://kr.api.blizzard.com",
    "tw": "https://tw.api.blizzard.com",
}

# Blizzard classId → WoW classFile (used in RAID_CLASS_COLORS etc.)
CLASS_ID_TO_FILE: dict[int, str] = {
    1:  "WARRIOR",
    2:  "PALADIN",
    3:  "HUNTER",
    4:  "ROGUE",
    5:  "PRIEST",
    6:  "DEATHKNIGHT",
    7:  "SHAMAN",
    8:  "MAGE",
    9:  "WARLOCK",
    10: "MONK",
    11: "DRUID",
    12: "DEMONHUNTER",
    13: "EVOKER",
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


class BnetClient:
    def __init__(self, token: str, region: str):
        self.base    = BNET_API_BASE[region]
        self.headers = {"Authorization": f"Bearer {token}"}
        self.region  = region
        self._static_ns = f"static-{region}"

    def get(self, path: str, namespace: str | None = None, retries: int = 3) -> Any:
        params = {"locale": "en_US"}
        if namespace:
            params["namespace"] = namespace
        url = self.base + path
        for attempt in range(retries):
            try:
                r = requests.get(url, headers=self.headers, params=params, timeout=20)
                if r.status_code == 429:
                    time.sleep(2 ** attempt)
                    continue
                r.raise_for_status()
                return r.json()
            except requests.RequestException as exc:
                if attempt == retries - 1:
                    raise
                time.sleep(1)

    def get_static(self, path: str) -> Any:
        return self.get(path, namespace=self._static_ns)


# ---------------------------------------------------------------------------
# Spec metadata
# ---------------------------------------------------------------------------
def fetch_spec_index(client: BnetClient) -> list[int]:
    """Return list of all character spec IDs."""
    data = client.get_static("/data/wow/playable-specialization/index")
    return [s["id"] for s in data.get("character_specializations", [])]


def fetch_spec_detail(client: BnetClient, spec_id: int) -> dict | None:
    """Return full spec detail dict or None on error."""
    try:
        return client.get_static(f"/data/wow/playable-specialization/{spec_id}")
    except Exception as exc:
        print(f"[warn] spec {spec_id}: {exc}")
        return None


def fetch_spec_icon(client: BnetClient, spec_id: int) -> int | None:
    """Return the file_data_id for the spec icon, or None."""
    try:
        data = client.get_static(f"/data/wow/media/playable-specialization/{spec_id}")
        for asset in data.get("assets", []):
            if asset.get("key") == "icon":
                return asset.get("file_data_id")
    except Exception:
        pass
    return None


# ---------------------------------------------------------------------------
# PvP talent data
# ---------------------------------------------------------------------------
def fetch_pvp_talent_index(client: BnetClient) -> list[int]:
    """Return list of all PvP talent IDs."""
    data = client.get_static("/data/wow/pvp-talent/index")
    return [t["id"] for t in data.get("pvp_talents", [])]


def fetch_pvp_talent(client: BnetClient, talent_id: int) -> dict | None:
    """Return pvp-talent detail or None on error."""
    try:
        return client.get_static(f"/data/wow/pvp-talent/{talent_id}")
    except Exception as exc:
        print(f"[warn] pvp-talent {talent_id}: {exc}")
        return None


# ---------------------------------------------------------------------------
# Build data structures
# ---------------------------------------------------------------------------
def build_spec_meta(
    client: BnetClient,
    spec_ids: list[int],
    workers: int = 8,
) -> dict[int, dict]:
    """
    Fetch spec detail + icon for all specs concurrently.
    Returns {specId: {specName, className, classId, classFile, role, iconFileDataId, pvpTalentRefs}}.
    pvpTalentRefs is a list of {talentId, talentName, description, castTime} from the
    spec endpoint (no spellId yet — that comes from the pvp-talent endpoint).
    """
    result: dict[int, dict] = {}

    def _fetch_one(spec_id: int) -> tuple[int, dict | None, int | None]:
        detail = fetch_spec_detail(client, spec_id)
        icon   = fetch_spec_icon(client, spec_id)
        return spec_id, detail, icon

    print(f"  Fetching {len(spec_ids)} spec details + icons …")
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(_fetch_one, sid): sid for sid in spec_ids}
        done = 0
        for future in as_completed(futures):
            spec_id, detail, icon = future.result()
            done += 1
            if done % 10 == 0 or done == len(spec_ids):
                print(f"  → {done}/{len(spec_ids)} specs done")
            if not detail:
                continue

            cls      = detail.get("playable_class", {})
            role_obj = detail.get("role", {})
            class_id = cls.get("id", 0)

            pvp_refs = []
            for entry in detail.get("pvp_talents", []):
                t = entry.get("talent", {})
                tip = entry.get("spell_tooltip", {})
                pvp_refs.append({
                    "talentId":    t.get("id"),
                    "talentName":  t.get("name", ""),
                    "description": tip.get("description", ""),
                    "castTime":    tip.get("cast_time", ""),
                })

            result[spec_id] = {
                "specId":        spec_id,
                "specName":      detail.get("name", ""),
                "className":     cls.get("name", ""),
                "classId":       class_id,
                "classFile":     CLASS_ID_TO_FILE.get(class_id, "UNKNOWN"),
                "role":          role_obj.get("type", "DAMAGE"),
                "iconFileDataId": icon,
                "pvpTalentRefs": pvp_refs,
            }
    return result


def build_pvp_talents(
    client: BnetClient,
    talent_ids: list[int],
    workers: int = 12,
) -> dict[int, list[dict]]:
    """
    Fetch all PvP talent details and group by specId.
    Returns {specId: [{talentId, spellId, name, description, castTime, compatibleSlots}]}.
    """
    raw_talents: list[dict] = []

    print(f"  Fetching {len(talent_ids)} PvP talent details …")
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(fetch_pvp_talent, client, tid): tid for tid in talent_ids}
        done = 0
        for future in as_completed(futures):
            data = future.result()
            done += 1
            if done % 50 == 0 or done == len(talent_ids):
                print(f"  → {done}/{len(talent_ids)} talents done")
            if data:
                raw_talents.append(data)

    # Group by spec
    by_spec: dict[int, list[dict]] = {}
    for t in raw_talents:
        spec = t.get("playable_specialization", {})
        spec_id = spec.get("id")
        if not spec_id:
            continue
        spell = t.get("spell", {})
        entry = {
            "talentId":       t.get("id"),
            "spellId":        spell.get("id"),
            "name":           spell.get("name") or t.get("spell", {}).get("name", ""),
            "description":    t.get("description", ""),
            "castTime":       "",   # not in this endpoint; populated from spec detail
            "compatibleSlots": t.get("compatible_slots", []),
        }
        by_spec.setdefault(spec_id, []).append(entry)

    # Sort each spec's list by talentId for determinism
    for spec_id in by_spec:
        by_spec[spec_id].sort(key=lambda x: x["talentId"] or 0)

    return by_spec


def merge_cast_times(
    pvp_talent_by_spec: dict[int, list[dict]],
    spec_meta: dict[int, dict],
) -> None:
    """
    Backfill castTime from spec_meta.pvpTalentRefs into pvp_talent_by_spec.
    The spec endpoint carries cast times; the pvp-talent endpoint does not.
    """
    for spec_id, meta in spec_meta.items():
        cast_map: dict[int, str] = {
            ref["talentId"]: ref["castTime"]
            for ref in meta.get("pvpTalentRefs", [])
            if ref.get("talentId")
        }
        for talent in pvp_talent_by_spec.get(spec_id, []):
            tid = talent.get("talentId")
            if tid and tid in cast_map:
                talent["castTime"] = cast_map[tid]


# ---------------------------------------------------------------------------
# Lua writers
# ---------------------------------------------------------------------------
def _escape(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\r\n", " ").replace("\n", " ").replace("\r", " ") + '"'


HEADER = """\
-- AUTO-GENERATED by scripts/fetch_bnet_seed.py
-- Generated: {ts}
-- Do NOT edit manually — run the script to regenerate.

local _, ns = ...
ns.GeneratedSeedData = ns.GeneratedSeedData or {{}}
"""


def write_spec_meta(spec_meta: dict[int, dict], ts: str) -> None:
    lines = [HEADER.format(ts=ts)]
    lines.append("--- Official spec metadata sourced from the Blizzard Game Data API.")
    lines.append("--- @field specId        number")
    lines.append("--- @field specName      string")
    lines.append("--- @field className     string")
    lines.append("--- @field classId       number")
    lines.append("--- @field classFile     string  e.g. DEATHKNIGHT, DRUID …")
    lines.append("--- @field role          string  DAMAGE | HEALER | TANK")
    lines.append("--- @field iconFileDataId number|nil  WoW internal texture ID")
    lines.append("ns.GeneratedSeedData.specMeta = {")

    for spec_id in sorted(spec_meta.keys()):
        m = spec_meta[spec_id]
        icon = str(m["iconFileDataId"]) if m.get("iconFileDataId") else "nil"
        lines.append(f"    [{spec_id}] = {{")
        lines.append(f"        specId        = {spec_id},")
        lines.append(f"        specName      = {_escape(m['specName'])},")
        lines.append(f"        className     = {_escape(m['className'])},")
        lines.append(f"        classId       = {m['classId']},")
        lines.append(f"        classFile     = {_escape(m['classFile'])},")
        lines.append(f"        role          = {_escape(m['role'])},")
        lines.append(f"        iconFileDataId = {icon},")
        lines.append("    },")

    lines.append("}")
    lines.append("")
    SPEC_META_OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"[ok] Wrote {SPEC_META_OUT}")


def write_pvp_talents(
    pvp_talent_by_spec: dict[int, list[dict]],
    spec_meta: dict[int, dict],
    ts: str,
) -> None:
    lines = [HEADER.format(ts=ts)]
    lines.append("--- PvP talents per spec, sourced from the Blizzard Game Data API.")
    lines.append("--- Each entry: { talentId, spellId, name, description, castTime, slots }.")
    lines.append("--- spellId can be used with C_Spell.GetSpellInfo(spellId) for icon lookup.")
    lines.append("--- slots: compatible PvP talent slot numbers (usually 1-4).")
    lines.append("ns.GeneratedSeedData.pvpTalents = {")

    for spec_id in sorted(pvp_talent_by_spec.keys()):
        talents = pvp_talent_by_spec[spec_id]
        meta = spec_meta.get(spec_id, {})
        comment = f"{meta.get('specName', '?')} {meta.get('className', '?')}"
        lines.append(f"    [{spec_id}] = {{  -- {comment}")

        for t in talents:
            spell_id  = t.get("spellId") or "nil"
            talent_id = t.get("talentId") or "nil"
            name      = _escape(t.get("name", ""))
            desc      = _escape(t.get("description", ""))
            cast_time = _escape(t.get("castTime", ""))
            slots_raw = t.get("compatibleSlots") or []
            slots_str = "{ " + ", ".join(str(s) for s in slots_raw) + " }" if slots_raw else "{}"
            lines.append(f"        {{ talentId = {talent_id}, spellId = {spell_id}, name = {name},")
            lines.append(f"          description = {desc},")
            lines.append(f"          castTime = {cast_time}, slots = {slots_str} }},")

        lines.append("    },")

    lines.append("}")
    lines.append("")
    PVP_TALENTS_OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"[ok] Wrote {PVP_TALENTS_OUT}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(description="Fetch Battle.net game data and generate Lua seed files.")
    parser.add_argument("--region",        default=os.getenv("BNET_REGION", "eu"),
                        choices=["us", "eu", "kr", "tw"])
    parser.add_argument("--client-id",     default=os.getenv("BNET_CLIENT_ID", ""))
    parser.add_argument("--client-secret", default=os.getenv("BNET_CLIENT_SECRET", ""))
    parser.add_argument("--workers",       type=int, default=10,
                        help="Concurrent HTTP workers (default 10)")
    parser.add_argument("--skip-talents",  action="store_true",
                        help="Skip PvP talent fetch (generate SeedSpecMeta only)")
    parser.add_argument("--skip-spec-meta", action="store_true",
                        help="Skip spec meta fetch (generate SeedPvpTalents only)")
    args = parser.parse_args()

    if not args.client_id or not args.client_secret:
        sys.exit(
            "ERROR: Battle.net credentials required.\n"
            "  Set BNET_CLIENT_ID / BNET_CLIENT_SECRET env vars, or pass --client-id / --client-secret."
        )

    print("=== CombatAnalytics Battle.net seed fetch ===")
    print(f"Region : {args.region}")
    print(f"Workers: {args.workers}")
    print()

    print("Authenticating …")
    token = get_bnet_token(args.client_id, args.client_secret, args.region)
    client = BnetClient(token, args.region)
    print("  Token OK")
    print()

    ts = datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC")

    # ── Spec metadata ────────────────────────────────────────────────────────
    spec_meta: dict[int, dict] = {}
    if not args.skip_spec_meta:
        print("Fetching spec index …")
        spec_ids = fetch_spec_index(client)
        print(f"  → {len(spec_ids)} specs found")
        spec_meta = build_spec_meta(client, spec_ids, workers=args.workers)
        # Cache raw data
        raw_path = RAW_DIR / "bnet_spec_meta.json"
        raw_path.write_text(json.dumps(spec_meta, indent=2, default=str), encoding="utf-8")
        print(f"  → Cached to {raw_path}")
        write_spec_meta(spec_meta, ts)
        print()

    # ── PvP talents ──────────────────────────────────────────────────────────
    if not args.skip_talents:
        print("Fetching PvP talent index …")
        talent_ids = fetch_pvp_talent_index(client)
        print(f"  → {len(talent_ids)} PvP talents found")
        pvp_by_spec = build_pvp_talents(client, talent_ids, workers=args.workers)
        # Merge cast times from spec detail
        if spec_meta:
            merge_cast_times(pvp_by_spec, spec_meta)
        # If spec_meta was skipped, load from cache
        elif (RAW_DIR / "bnet_spec_meta.json").exists():
            cached = json.loads((RAW_DIR / "bnet_spec_meta.json").read_text())
            spec_meta = {int(k): v for k, v in cached.items()}
            merge_cast_times(pvp_by_spec, spec_meta)
        # Cache raw talent data
        raw_path = RAW_DIR / "bnet_pvp_talents.json"
        raw_path.write_text(json.dumps(pvp_by_spec, indent=2, default=str), encoding="utf-8")
        print(f"  → Cached to {raw_path}")
        write_pvp_talents(pvp_by_spec, spec_meta, ts)
        print()

    print("Done.")
    print(f"  {SPEC_META_OUT}")
    print(f"  {PVP_TALENTS_OUT}")


if __name__ == "__main__":
    main()
