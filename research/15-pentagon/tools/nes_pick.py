#!/usr/bin/env python3
"""nes_pick.py - подобрать из коллекции ромы, которые РЕАЛЬНО пойдут на нашем железе, и разложить
их в стейдж с сохранением структуры каталогов.

    python3 nes_pick.py <каталог коллекции> <каталог стейджа> [--all] [--limit N]

Фильтр (пределы нашего картриджа в блочной памяти ПЛИС, см. sources/nes_core/nes_mem_bram.v):
    PRG <= 128 КБ (PRG_AW=17), CHR <= 32 КБ (CHR_AW=15), маппер из списка me[] в cart.sv.
Полный путь на карте должен быть < 77 знаков - таков предел браузера прошивки (curpath + имя < 78).
Без --all берётся только классика по канону (см. CANON), по одному файлу на название,
с приоритетом региона USA -> World -> Europe -> русские переводы -> Japan.
Из имён-назначений убираются [!] и (dupN); варианты (dup)/(VC)/Anniversary/Beta/Proto отбрасываются.

Проверено 2026-07-31 на коллекции владельца: из 27342 ромов подходит 12068
(не влезает по объёму 14696, маппер не поддержан 143, битых заголовков 17).
"""
import os, re, sys, json, shutil

SUPPORTED = set([0,1,2,3,4,5,7,9,10,11,13,15,16,18,19,20,21,22,23,24,25,26,27,28,30,31,32,33,34,35,
    36,37,38,41,42,46,47,48,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,82,83,85,86,87,88,89,
    90,91,92,93,94,95,97,101,105,107,111,112,113,118,119,132,133,136,137,138,139,140,141,143,145,146,
    147,148,149,150,152,153,154,155,158,159,162,163,164,165,171,172,173,180,184,185,190,191,192,194,
    195,206,207,209,210,211,218,225,228,232,234,243,255])

MAX_PRG, MAX_CHR, MAX_PATH = 131072, 32768, 77
CARD_PREFIX = "0:/NES/"

CANON = """super mario bros|mario bros|battle city|tank 1990|tank 90|contra|chip 'n dale|chip n dale|
chip and dale|duck tales|darkwing duck|teenage mutant ninja turtles|double dragon|mega man|rockman|
castlevania|legend of zelda|metroid|kirby|adventure island|bomberman|tetris|dr. mario|prince of persia|
batman|jackal|rush'n attack|snow bros|felix the cat|tiny toon|little nemo|mitsume ga tooru|talespin|
tale spin|rescue rangers|circus charlie|balloon fight|ice climber|excitebike|galaga|pac-man|donkey kong|
kung fu|ninja gaiden|rockin' kats|gremlins 2|silver surfer|journey to silius|blaster master|life force|
salamander|gradius|twinbee|twin bee|solomon's key|lode runner|mappy|dig dug|star force|yie ar kung-fu|
bubble bobble|rainbow islands|bad dudes|karnov|ghosts'n goblins|wrecking crew|elevator action|flintstones|
tom & jerry|road fighter|antarctic adventure|nuts & milk|lunar ball|mach rider|spy hunter|zanac|
guardian legend|crisis force|faxanadu|power blade|shatterhand|vice - project doom|shadow of the ninja|
gun-nac|adventures of lolo|kickle cubicle|goonies|arkanoid|city connection|clu clu land|donkey kong jr|
paperboy|pinball|punch-out|robocop|section-z|sky kid|spartan x|super dodge ball|urban champion|xevious|
yoshi|kid icarus|kid niki|magmax|milon's secret castle|ninja kid|pooyan|rambo|star soldier|
wizards & warriors|hyper olympic|ikari warriors|karateka|ninja jajamaru|spelunker|tiger heli|trojan|
warpman|wagan land|dragon buster|exed exes|front line|hogan's alley|joust|ms. pac-man|
nintendo world cup|super pitfall|wild gunman|b-wings|challenger|chack'n pop|field combat|formation z|
geimos|route-16|seicross|space hunter|takahashi meijin|tennis|volleyball|soccer|golf|baseball|
track & field"""
CANON = [c.strip() for c in CANON.replace("\n", "").split("|") if c.strip()]

BAD = re.compile(r"\(dup\d*\)|\(VC\)|anniversary|e-reader|\(GBA|classic series|\(Beta|\(Proto|"
                 r"\(Sample|\(Rev [B-Z]\)|virtual console", re.I)
BUCKET_PRIO = {"USA": 0, "World & Multi-region": 1, "Europe": 2, "Translations - Russian": 3,
               "Japan": 4, "Translations - English": 5, "Asia & Other regions": 6}


def ines(path):
    """-> (prg_bytes, chr_bytes, mapper) или None, если это не iNES."""
    try:
        with open(path, "rb") as h:
            hd = h.read(16)
    except OSError:
        return None
    if len(hd) < 16 or hd[:4] != b"NES\x1a":
        return None
    return hd[4] * 16384, hd[5] * 8192, ((hd[7] & 0xF0) | ((hd[6] & 0xF0) >> 4))


def norm(name):
    s = re.sub(r"\.nes$", "", os.path.basename(name).lower())
    s = re.sub(r"\s*\([^)]*\)", "", s)
    s = re.sub(r"\s*\[[^]]*\]", "", s)
    return re.sub(r"[^a-z0-9 &'.\-]", "", re.sub(r"\s+", " ", s)).strip()


def dest_name(rel):
    b = re.sub(r"\s*\(dup\d*\)", "", re.sub(r"\s*\[!\]", "", os.path.basename(rel)))
    return re.sub(r"\s+", " ", b).strip()


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    root, stage = sys.argv[1], sys.argv[2]
    take_all = "--all" in sys.argv
    limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else 0

    fits, big, unsup, broken = [], 0, 0, 0
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if not d.startswith("_")]          # служебные каталоги коллекции
        for f in fn:
            if not f.lower().endswith(".nes"):
                continue
            p = os.path.join(dp, f)
            h = ines(p)
            if not h:
                broken += 1
                continue
            prg, chr_, mapper = h
            if prg == 0 or prg > MAX_PRG or chr_ > MAX_CHR:
                big += 1
                continue
            if mapper not in SUPPORTED:
                unsup += 1
                continue
            fits.append((os.path.relpath(p, root), prg, chr_, mapper, os.path.getsize(p)))
    print("подходит по железу: %d   не влезает: %d   маппер не поддержан: %d   битых: %d"
          % (len(fits), big, unsup, broken))

    best = {}
    for rel, prg, chr_, mapper, size in fits:
        bucket = rel.split(os.sep)[0]
        if not take_all:
            if bucket not in BUCKET_PRIO or BAD.search(os.path.basename(rel)):
                continue
            n = norm(rel)
            if not any(c in n for c in CANON):
                continue
        else:
            n = rel
        dest = "/".join(os.path.dirname(rel).split(os.sep) + [dest_name(rel)])
        if len(CARD_PREFIX + dest) >= MAX_PATH:
            continue
        score = (BUCKET_PRIO.get(bucket, 9), len(n), size)
        if n not in best or score < best[n][0]:
            best[n] = (score, rel, dest, prg, chr_, mapper, size)

    sel = sorted((v[1], v[2], v[3], v[4], v[5], v[6]) for v in best.values())
    if limit:
        sel = sel[:limit]
    total = sum(s[5] for s in sel)
    print("отобрано: %d файлов, %.1f МБ" % (len(sel), total / 1048576))

    shutil.rmtree(stage, ignore_errors=True)
    for rel, dest, prg, chr_, mapper, size in sel:
        dst = os.path.join(stage, dest)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(os.path.join(root, rel), dst)
    json.dump(sel, open(os.path.join(stage, "_selection.json"), "w"))
    print("стейдж готов: %s (список в _selection.json)" % stage)
    return 0


if __name__ == "__main__":
    sys.exit(main())
