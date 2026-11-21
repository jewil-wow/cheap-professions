#!/usr/bin/env python3
"""Build Data/Recipes.lua from seemeta.com WoW Forever profession pages.

Usage:
    # 1. download the pages into an empty directory (outside this repo):
    #    for p in alchemy blacksmithing enchanting engineering leatherworking \
    #             tailoring cooking first-aid; do
    #      curl -sL -A "Mozilla/5.0" -o "$DIR/$p.html" \
    #        "https://seemeta.com/en/wow-forever/professions/$p"; sleep 2; done
    # 2. (optional) download client data from wago.tools for craft cooldowns, into another
    #    empty directory (B = the Forever build, e.g. 1.60.1.71037):
    #    for t in SkillLineAbility SpellEffect SpellCooldowns; do
    #      curl -sL -o "$WAGO/$t.csv" "https://wago.tools/db2/$t/csv?build=$B"; done
    # 3. generate:
    #    python3 -I Tools/build_recipes.py "$DIR" Data/Recipes.lua ["$WAGO"]

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
    ("first-aid", "firstaid", 129),
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


def load_cooldowns(wago_dir):
    """Cooldown seconds by (skill line, product item id or spell id), from client DB2 tables."""
    csv.field_size_limit(10**9)
    lines = {line for _, _, line in PROFESSIONS}
    spell_line = {}
    with open(os.path.join(wago_dir, "SkillLineAbility.csv"), encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if int(r["SkillLine"]) in lines:
                spell_line[int(r["Spell"])] = int(r["SkillLine"])
    cd = {}
    with open(os.path.join(wago_dir, "SpellCooldowns.csv"), encoding="utf-8") as f:
        for r in csv.DictReader(f):
            sp = int(r["SpellID"])
            if sp in spell_line:
                ms = max(int(r["RecoveryTime"] or 0), int(r["CategoryRecoveryTime"] or 0))
                if ms > 0:
                    cd[sp] = ms // 1000
    out = {}
    with open(os.path.join(wago_dir, "SpellEffect.csv"), encoding="utf-8") as f:
        for r in csv.DictReader(f):
            sp = int(r["SpellID"])
            if sp in cd and r["Effect"] == "24" and int(r["EffectItemType"] or 0):  # 24 = create item
                out[sp] = int(r["EffectItemType"])
    by_key = {}
    for sp, secs in cd.items():
        line = spell_line[sp]
        by_key[(line, "spell", sp)] = secs
        if sp in out:
            by_key[(line, "item", out[sp])] = secs
    return by_key


def emit(rec):
    parts = []
    if rec["kind"] == "item":
        parts.append(f"i={rec['id']}")
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
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    src_dir, out = sys.argv[1], sys.argv[2]
    cooldowns = load_cooldowns(sys.argv[3]) if len(sys.argv) == 4 else {}
    names = {}
    blocks = []
    total = 0
    for slug, key, line in PROFESSIONS:
        path = os.path.join(src_dir, slug + ".html")
        recs = parse(path, names)
        for r in recs:
            secs = cooldowns.get((line, r["kind"], r["id"]))
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
        f.write("-- cd = craft cooldown in seconds (from client data via wago.tools)\n")
        f.write("-- rg = {reagentItemID, count, ...}\n")
        f.write("local _, ns = ...\nlocal D = ns.Data\n\n")
        f.write("D.skillLines = { alchemy=171, blacksmithing=164, enchanting=333, engineering=202,\n"
                "    leatherworking=165, tailoring=197, cooking=185, firstaid=129 }\n\n")
        f.write("D.recipes = {}\n")
        f.write("\n".join(blocks))
        f.write("\n-- Names for reagents and recipe items (display fallback before item data is cached).\nD.names = {\n")
        for iid in sorted(names):
            f.write(f"    [{iid}]={lua_str(names[iid])},\n")
        f.write("}\n")
    print(f"total {total} recipes, {len(names)} names -> {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
