#!/usr/bin/env python3
"""Build Data/Recipes.lua from seemeta.com WoW Forever profession pages.

Usage:
    # 1. download the pages into an empty directory (outside this repo):
    #    for p in alchemy blacksmithing enchanting engineering leatherworking \
    #             tailoring cooking; do
    #      curl -sL -A "Mozilla/5.0" -o "$DIR/$p.html" \
    #        "https://seemeta.com/en/wow-forever/professions/$p"; sleep 2; done
    # 2. (optional) download client data from wago.tools for spell IDs and craft cooldowns,
    #    into another empty directory (B = the Forever build, e.g. 1.60.1.71037):
    #    for t in SkillLineAbility SpellEffect SpellCooldowns SpellReagents; do
    #      curl -sL -o "$WAGO/$t.csv" "https://wago.tools/db2/$t/csv?build=$B"; done
    # 3. generate:
    #    python3 -I Tools/build_recipes.py "$DIR" Data/Recipes.lua ["$WAGO"]
    #
    # Or enrich an existing Data/Recipes.lua with spell IDs from wago.tools DB2 CSVs:
    #    python3 -I Tools/build_recipes.py --enrich Data/Recipes.lua "$WAGO"

Each recipe row on seemeta has: the product (item=ID, or spell=ID for enchants),
reagents with counts, four skill thresholds (orange/yellow/green/grey) and a
source line. Trainer recipes omit the orange (learn) threshold; the addon
estimates it and corrects it from the trainer window in game.
"""
import csv
import html
import os
import re
import sys

PROFESSIONS = [
    # page slug, addon key, skill line id
    ("alchemy", "alchemy", 171),
    ("blacksmithing", "blacksmithing", 164),
    ("enchanting", "enchanting", 333),
    ("engineering", "engineering", 202),
    ("leatherworking", "leatherworking", 165),
    ("tailoring", "tailoring", 197),
    ("cooking", "cooking", 185),
]

WH = r'href="https://www\.wowhead\.com/forever/(item|spell)=(\d+)"'


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'


def parse(path, names):
    s = open(path, encoding="utf-8").read()
    s = re.sub(r"<!--.*?-->", "", s, flags=re.S)
    start = s.find('id="wf-prof-recipes"')
    if start < 0:
        raise SystemExit(f"{path}: recipe list not found (page layout changed?)")
    s = s[start:]
    recipes, seen = [], set()
    for blk in s.split("<a data-name ")[1:]:
        m = re.match(WH, blk)
        kind, pid = m.group(1), int(m.group(2))
        name = html.unescape(re.search(r"<span data-t[^>]*>(.*?)</span>", blk, re.S).group(1)).strip()

        reag_html = re.search(r"<ul data-reag>(.*?)</ul>", blk, re.S).group(1)
        rg = []
        for li in re.findall(r"<li>(.*?)</li>", reag_html, re.S):
            rm = re.search(r'href="https://www\.wowhead\.com/forever/item=(\d+)"[^>]*title="([^"]*)"', li)
            if not rm:
                continue
            cm = re.search(r"<b data-n>(\d+)</b>", li)
            rid = int(rm.group(1))
            names.setdefault(rid, html.unescape(rm.group(2)))
            rg += [rid, int(cm.group(1)) if cm else 1]

        sk = re.search(r"<p data-skill>(.*?)</p>", blk, re.S).group(1)
        nums = [int(x) for x in re.findall(r"<span>(\d+)</span>", sk)]
        if len(nums) == 4:
            k, est = nums, False
        elif len(nums) == 3:
            k, est = [None] + nums, True
        else:
            raise SystemExit(f"{path}: {name}: unexpected skill cell {sk[:120]}")

        src_html = re.search(r"<p data-src>(.*?)</p>", blk, re.S).group(1)
        rec = {"kind": kind, "id": pid, "n": name, "k": k, "rg": rg}
        bm = re.search(r'<a data-book href="https://www\.wowhead\.com/forever/item=(\d+)"', src_html)
        if bm:
            rec["src"] = "b"
            rec["book"] = int(bm.group(1))
            bn = re.search(r"<a data-book.*?<span data-t[^>]*>(.*?)</span>", src_html, re.S)
            if bn:
                names.setdefault(rec["book"], html.unescape(bn.group(1)))
            req = re.search(r"</a><span>(.*?)</span>", src_html, re.S)
            if req:
                txt = html.unescape(req.group(1))
                for part in [p.strip() for p in txt.split(",")]:
                    sm = re.fullmatch(r"skill (\d+)", part)
                    if sm:
                        rec["req"] = int(sm.group(1))
                    elif part:
                        rec["rep"] = part
        elif "automatically" in src_html:
            rec["src"] = "a"
        else:
            rec["src"] = "t"
        rec["est"] = est

        key = (kind, pid, tuple(rg), tuple(x or 0 for x in k))
        if key in seen:  # e.g. faction-specific duplicates with identical data
            continue
        seen.add(key)
        recipes.append(rec)
    return recipes


def rg_signature(rg):
    """Normalized sorted tuple of (itemID, totalCount) from flat [id, count, ...] list."""
    counts = {}
    for j in range(0, len(rg), 2):
        rid, cnt = rg[j], rg[j + 1]
        counts[rid] = counts.get(rid, 0) + cnt
    return tuple(sorted(counts.items()))


def load_wago(wago_dir):
    """Load spell IDs, reagent signatures, skill ranks, and cooldowns from client DB2 tables."""
    csv.field_size_limit(10**9)
    lines = {line for _, _, line in PROFESSIONS}
    spell_lines = {}
    sla_ranks = {}
    with open(os.path.join(wago_dir, "SkillLineAbility.csv"), encoding="utf-8") as f:
        for r in csv.DictReader(f):
            line = int(r["SkillLine"])
            if line in lines:
                sp = int(r["Spell"])
                spell_lines.setdefault(sp, set()).add(line)
                sla_ranks[(line, sp)] = (
                    int(r["TrivialSkillLineRankLow"] or 0),
                    int(r["TrivialSkillLineRankHigh"] or 0),
                )

    cooldowns = {}
    with open(os.path.join(wago_dir, "SpellCooldowns.csv"), encoding="utf-8") as f:
        for r in csv.DictReader(f):
            sp = int(r["SpellID"])
            if sp in spell_lines:
                ms = max(int(r["RecoveryTime"] or 0), int(r["CategoryRecoveryTime"] or 0))
                if ms > 0:
                    cooldowns[sp] = ms // 1000

    item_spells = {}
    with open(os.path.join(wago_dir, "SpellEffect.csv"), encoding="utf-8") as f:
        for r in csv.DictReader(f):
            sp = int(r["SpellID"])
            if sp in spell_lines and r["Effect"] == "24" and int(r["EffectItemType"] or 0):  # 24 = create item
                iid = int(r["EffectItemType"])
                for line in spell_lines[sp]:
                    item_spells.setdefault((line, iid), set()).add(sp)

    spell_reagents = {}
    reagents_path = os.path.join(wago_dir, "SpellReagents.csv")
    if os.path.exists(reagents_path):
        with open(reagents_path, encoding="utf-8") as f:
            for r in csv.DictReader(f):
                sp = int(r["SpellID"])
                if sp in spell_lines:
                    counts = {}
                    for i in range(8):
                        rid = int(r[f"Reagent_{i}"] or 0)
                        cnt = int(r[f"ReagentCount_{i}"] or 0)
                        if rid > 0 and cnt > 0:
                            counts[rid] = counts.get(rid, 0) + cnt
                    spell_reagents[sp] = tuple(sorted(counts.items()))

    return {
        "cooldowns": cooldowns,
        "item_spells": item_spells,
        "spell_reagents": spell_reagents,
        "sla_ranks": sla_ranks,
    }


def resolve_spell(wago, line, iid, rg, k=None):
    """Find the unique crafting spell ID for an item-producing recipe, or None."""
    if not wago:
        return None
    cands = sorted(wago["item_spells"].get((line, iid), ()))
    if not cands:
        return None
    if len(cands) == 1:
        return cands[0]
    sig = rg_signature(rg)
    by_rg = [sp for sp in cands if wago["spell_reagents"].get(sp) == sig]
    if len(by_rg) == 1:
        return by_rg[0]
    pool = by_rg if by_rg else cands
    if k is not None:
        by_sk = [sp for sp in pool if wago["sla_ranks"].get((line, sp)) == (k[1], k[3])]
        if len(by_sk) == 1:
            return by_sk[0]
    return None


def enrich_lua(lua_path, wago_dir):
    """Inject/update sp=<spellID> on item-producing recipe rows in an existing Data/Recipes.lua."""
    wago = load_wago(wago_dir)
    prof_lines = {key: line for _, key, line in PROFESSIONS}
    prof = None
    out_lines = []
    matched, missing = 0, 0
    with open(lua_path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r'^D\.recipes\["(\w+)"\]', line)
            if m:
                prof = m.group(1)
                out_lines.append(line)
                continue
            mi = re.match(r"^(\s*\{i=(\d+))(?:,sp=\d+)?(,.*)$", line)
            if prof in prof_lines and mi:
                prefix, iid = mi.group(1), int(mi.group(2))
                rest = mi.group(3)
                km = re.search(r"k=\{(nil|\d+),(\d+),(\d+),(\d+)\}", rest)
                k = [None if km.group(1) == "nil" else int(km.group(1)),
                     int(km.group(2)), int(km.group(3)), int(km.group(4))] if km else None
                rm = re.search(r"rg=\{([^}]*)\}", rest)
                rg = [int(x) for x in rm.group(1).split(",") if x] if rm else []
                sp = resolve_spell(wago, prof_lines[prof], iid, rg, k)
                if sp is not None:
                    out_lines.append(f"{prefix},sp={sp}{rest}\n")
                    matched += 1
                else:
                    out_lines.append(line)
                    missing += 1
                    print(f"  WARN: no unique spell ID for {prof} i={iid}: {line.strip()[:80]}", file=sys.stderr)
            else:
                out_lines.append(line)
    with open(lua_path, "w", encoding="utf-8") as f:
        f.writelines(out_lines)
    print(f"enriched {matched} item recipes ({missing} unmatched) -> {lua_path}", file=sys.stderr)


def emit(rec):
    parts = []
    if rec["kind"] == "item":
        parts.append(f"i={rec['id']}")
        if rec.get("sp"):
            parts.append(f"sp={rec['sp']}")
    else:
        parts.append(f"sp={rec['id']}")
    parts.append(f"n={lua_str(rec['n'])}")
    o, y, g, gr = rec["k"]
    parts.append("k={%s,%d,%d,%d}" % ("nil" if o is None else o, y, g, gr))
    parts.append(f'src="{rec["src"]}"')
    if rec.get("book"):
        parts.append(f"book={rec['book']}")
    if rec.get("req"):
        parts.append(f"req={rec['req']}")
    if rec.get("rep"):
        parts.append(f"rep={lua_str(rec['rep'])}")
    if rec.get("cd"):
        parts.append(f"cd={rec['cd']}")
    parts.append("rg={%s}" % ",".join(map(str, rec["rg"])))
    return "{" + ",".join(parts) + "}"


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--enrich":
        enrich_lua(sys.argv[2], sys.argv[3])
        return
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    src_dir, out = sys.argv[1], sys.argv[2]
    wago = load_wago(sys.argv[3]) if len(sys.argv) == 4 else None
    names = {}
    blocks = []
    total = 0
    for slug, key, line in PROFESSIONS:
        path = os.path.join(src_dir, slug + ".html")
        recs = parse(path, names)
        for r in recs:
            sp = r["id"] if r["kind"] == "spell" else resolve_spell(wago, line, r["id"], r["rg"], r["k"])
            if r["kind"] == "item" and sp:
                r["sp"] = sp
            if wago and sp:
                secs = wago["cooldowns"].get(sp)
                if secs:
                    r["cd"] = secs
                    print(f"  cooldown {secs // 3600}h {secs % 3600 // 60}m: {r['n']}", file=sys.stderr)
        total += len(recs)
        rows = "\n".join("    " + emit(r) + "," for r in recs)
        blocks.append(f'D.recipes["{key}"] = {{ -- skill line {line}, {len(recs)} recipes\n{rows}\n}}\n')
        print(f"{key}: {len(recs)} recipes", file=sys.stderr)

    with open(out, "w", encoding="utf-8") as f:
        f.write("-- GENERATED by Tools/build_recipes.py from seemeta.com (WoW Forever 1.60.1 datamine).\n")
        f.write("-- Do not edit by hand; re-run the script instead.\n")
        f.write("-- k = {orange(learn), yellow, green, grey}; orange is nil for trainer recipes (estimated in game).\n")
        f.write('-- src: "t" trainer, "a" automatic with rank, "b" recipe item (book=item id, req=skill, rep=reputation).\n')
        f.write("-- sp = crafting spell id, cd = craft cooldown in seconds (from client data via wago.tools)\n")
        f.write("-- rg = {reagentItemID, count, ...}\n")
        f.write("local _, ns = ...\nlocal D = ns.Data\n\n")
        f.write("D.skillLines = { alchemy=171, blacksmithing=164, enchanting=333, engineering=202,\n"
                "    leatherworking=165, tailoring=197, cooking=185 }\n\n")
        f.write("D.recipes = {}\n")
        f.write("\n".join(blocks))
        f.write("\n-- Names for reagents and recipe items (display fallback before item data is cached).\nD.names = {\n")
        for iid in sorted(names):
            f.write(f"    [{iid}]={lua_str(names[iid])},\n")
        f.write("}\n")
    print(f"total {total} recipes, {len(names)} names -> {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
