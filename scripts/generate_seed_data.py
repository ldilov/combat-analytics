import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "seed" / "raw"
GENERATED = ROOT / "seed" / "generated"


def load_json(path: Path):
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def lua_quote(value: str) -> str:
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def emit_scalar(value):
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return "nil"
    if isinstance(value, (int, float)):
        return str(value)
    return lua_quote(str(value))


def emit_table(mapping, indent=""):
    lines = ["{"]
    next_indent = indent + "    "
    for key, value in mapping.items():
        if isinstance(key, int):
            lua_key = f"[{key}]"
        else:
            lua_key = f"[{lua_quote(str(key))}]"
        if isinstance(value, dict):
            lines.append(f"{next_indent}{lua_key} = {emit_table(value, next_indent)},")
        elif isinstance(value, list):
            items = ", ".join(emit_scalar(item) for item in value)
            lines.append(f"{next_indent}{lua_key} = {{ {items} }},")
        else:
            lines.append(f"{next_indent}{lua_key} = {emit_scalar(value)},")
    lines.append(indent + "}")
    return "\n".join(lines)


def write_lua_module(path: Path, table_name: str, data: dict):
    body = emit_table(data)
    text = "\n".join([
        "local _, ns = ...",
        "",
        "ns.GeneratedSeedData = ns.GeneratedSeedData or {}",
        "",
        f"ns.GeneratedSeedData.{table_name} = {body}",
        "",
    ])
    path.write_text(text, encoding="utf-8")


def generate_dummy_catalog():
    raw = load_json(RAW / "dummy_catalog_overrides.json")
    records = {}
    for item in raw.get("dummies", []):
        records[int(item["creatureID"])] = item
    write_lua_module(GENERATED / "SeedDummyCatalog.lua", "dummyCatalog", records)


def generate_spell_intelligence():
    raw = load_json(RAW / "spell_intelligence_overrides.json")
    records = {}
    for item in raw.get("spells", []):
        records[int(item["spellID"])] = item
    write_lua_module(GENERATED / "SeedSpellIntelligence.lua", "spellIntelligence", records)


def generate_spec_archetypes():
    raw = load_json(RAW / "spec_archetypes.json")
    records = {}
    for item in raw.get("specs", []):
        records[int(item["specId"])] = item
    write_lua_module(GENERATED / "SeedSpecArchetypes.lua", "specArchetypes", records)


def generate_arena_control():
    records = {
        "ccFamilies": {
            "stun": ["Cheap Shot", "Bash"],
            "interrupt": ["Kick", "Pummel", "Counterspell", "Mind Freeze"],
        },
        "immunityTags": {
            1022: "physical_immunity",
            642: "full_immunity",
        },
        "breakCcTags": {
            42292: True,
        },
    }
    write_lua_module(GENERATED / "SeedArenaControl.lua", "arenaControl", records)


def main():
    GENERATED.mkdir(parents=True, exist_ok=True)
    generate_dummy_catalog()
    generate_spell_intelligence()
    generate_spec_archetypes()
    generate_arena_control()
    print("Generated seed data into seed/generated")


if __name__ == "__main__":
    main()
