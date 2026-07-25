#!/usr/bin/env python3
"""Multi-frame snow analyser (a request from the second agent 2026-07-24: "сравнивать несколько
последовательных frame captures, а не один screenshot").

Takes N >= 2 screen-mirror .bin dumps of the SAME running program (captured a few
frames apart) and decides which failure mode we have:

  STATIC SNOW  - the SAME columns are corrupted in every frame  -> faithful ULA
                 snow (real hardware behaviour; demo shows stable striped bars).
  FLICKER      - the corrupted column set WANDERS frame to frame  -> our bug:
                 CPU-M1-refresh vs ULA-fetch phase is not cycle-locked.
  CLEAN        - all frames identical                            -> no corruption.

Method: per-column bitmap fingerprint (zxscr.column_fingerprint). A column is
"dynamic" if its fingerprint changes across the frame set. STATIC vs FLICKER is
then: are the dynamic columns a small STABLE set, or do inter-frame diffs keep
touching different columns?

CLI: snow_diff.py f0.bin f1.bin [f2.bin ...]
"""
import sys
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from zxscr import column_fingerprint

def main(paths):
    if len(paths) < 2:
        print("need >= 2 frames"); return 2
    frames = [open(p, "rb").read() for p in paths]
    for i, f in enumerate(frames):
        if len(f) != 6912:
            print(f"frame {i} ({paths[i]}) is {len(f)}B, expected 6912"); return 2
    fps = [column_fingerprint(f) for f in frames]

    # Which columns differ from frame 0 in AT LEAST one later frame (dynamic set),
    # and per adjacent pair, which columns changed.
    dynamic = set()
    pair_sets = []
    for a in range(len(fps)-1):
        changed = {c for c in range(32) if fps[a][c] != fps[a+1][c]}
        pair_sets.append(changed)
        dynamic |= changed

    if not dynamic:
        print("VERDICT: CLEAN  (all %d frames byte-identical in bitmap)" % len(frames))
        return 0

    if len(frames) < 3:
        # one adjacent pair cannot separate static from wandering: union==pair by
        # construction. Report the change and ask for more frames.
        print(f"changed columns: {sorted(dynamic)}")
        print("VERDICT: CHANGED (need >=3 frames to classify static-snow vs flicker)")
        return 0

    # STATIC snow: the wandering is small - every adjacent pair touches nearly the
    # same column set. FLICKER: the union is much larger than any single pair, i.e.
    # different columns break each frame.
    union = len(dynamic)
    max_pair = max(len(s) for s in pair_sets)
    # Jaccard stability across adjacent pairs
    inter = set(range(32))
    onion = set()
    for s in pair_sets:
        inter &= s if s else inter
        onion |= s
    stable = len(inter)
    print(f"dynamic columns (union): {sorted(dynamic)}")
    print(f"  union={union}  max single-pair={max_pair}  always-changing={sorted(inter)}")
    if union <= max_pair + 2 and stable >= max(1, union//2):
        print("VERDICT: STATIC SNOW  (same columns corrupt every frame = faithful ULA)")
    else:
        print("VERDICT: FLICKER  (corrupted column set wanders = phase not cycle-locked)")
    return 0

if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
