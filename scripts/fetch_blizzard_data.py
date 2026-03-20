#!/usr/bin/env python3
"""
fetch_blizzard_data.py

Fetch playable-class, specialization, and PvP talent data from the
Battle.net Game Data API using OAuth2 client credentials.

Setup:
    Register an app at https://develop.battle.net/access
    export BNET_CLIENT_ID=your_client_id
    export BNET_CLIENT_SECRET=your_client_secret

Usage:
    python scripts/fetch_blizzard_data.py --region us --output data/raw/
"""

import os
import sys
import json
import argparse
import requests

OAUTH_URL = "https://oauth.battle.net/token"
API_BASE  = "https://{region}.api.blizzard.com"
NAMESPACE = "static-{region}"


def get_token(client_id: str, client_secret: str) -> str:
    resp = requests.post(
        OAUTH_URL,
        data={"grant_type": "client_credentials"},
        auth=(client_id, client_secret),
        timeout=15,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def api_get(session: requests.Session, url: str, params: dict) -> dict:
    resp = session.get(url, params=params, timeout=15)
    resp.raise_for_status()
    return resp.json()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Fetch Battle.net API data for CombatAnalytics seed generation"
    )
    parser.add_argument("--region", default="us", choices=["us", "eu", "kr", "tw"])
    parser.add_argument("--output", default="data/raw/")
    args = parser.parse_args()

    client_id     = os.environ.get("BNET_CLIENT_ID")
    client_secret = os.environ.get("BNET_CLIENT_SECRET")
    if not client_id or not client_secret:
        print("ERROR: BNET_CLIENT_ID and BNET_CLIENT_SECRET env vars are required.",
              file=sys.stderr)
        sys.exit(1)

    os.makedirs(args.output, exist_ok=True)

    print("Acquiring OAuth2 token...")
    token = get_token(client_id, client_secret)

    http = requests.Session()
    http.headers["Authorization"] = f"Bearer {token}"

    base   = API_BASE.format(region=args.region)
    ns     = NAMESPACE.format(region=args.region)
    locale = "en_US"
    params = {"namespace": ns, "locale": locale}

    # ── Classes ──────────────────────────────────────────────────────────────
    print("Fetching playable classes...")
    index = api_get(http, f"{base}/data/wow/playable-class/index", params)
    classes = {}
    for cls in index.get("classes", []):
        detail = api_get(http, cls["key"]["href"], {"locale": locale})
        classes[cls["id"]] = detail
    out_path = os.path.join(args.output, "classes.json")
    with open(out_path, "w") as f:
        json.dump(classes, f, indent=2)
    print(f"  Saved {len(classes)} classes → {out_path}")

    # ── Specializations ───────────────────────────────────────────────────────
    print("Fetching specializations...")
    index = api_get(http, f"{base}/data/wow/playable-specialization/index", params)
    specs = {}
    for spec in index.get("character_specializations", []):
        detail = api_get(http, spec["key"]["href"], {"locale": locale})
        specs[spec["id"]] = detail
    out_path = os.path.join(args.output, "specs.json")
    with open(out_path, "w") as f:
        json.dump(specs, f, indent=2)
    print(f"  Saved {len(specs)} specs → {out_path}")

    # ── PvP Talents ───────────────────────────────────────────────────────────
    print("Fetching PvP talents...")
    index = api_get(http, f"{base}/data/wow/pvp-talent/index", params)
    pvp_talents = {}
    for talent in index.get("pvp_talents", []):
        detail = api_get(http, talent["key"]["href"], {"locale": locale})
        pvp_talents[talent["id"]] = detail
    out_path = os.path.join(args.output, "pvp_talents.json")
    with open(out_path, "w") as f:
        json.dump(pvp_talents, f, indent=2)
    print(f"  Saved {len(pvp_talents)} PvP talents → {out_path}")

    print(f"\nAll raw data saved to: {args.output}")


if __name__ == "__main__":
    main()
