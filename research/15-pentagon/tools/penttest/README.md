# PENTTEST: Pentagon timing test

Languages: **English** · [Русский](README.ru.md)

A self-checking test for the Pentagon 128/1024 machine, in the spirit of the 48K Timing Tests.
Every line prints what it measured and then PASS or FAIL, and the last line gives the totals. It runs
on BulbuLator, but nothing in it is specific to BulbuLator, so any Pentagon or Pentagon emulator can
be checked with the same tape.

The cycle-exact parts come from Jan Bobrowski's zxtests (`minfo`): `DELAY`, `ALIGNINT`, `FRAME_TIME`,
`INT_TIME` and `EI_PREFIX`, licensed GPL/LGPL. The only change is where the IM2 table and handler
live (`instint.asm`), because the test pages other banks in at #C000.

## Running it

Load `penttest.tap` in 128 BASIC or 48 BASIC and let it run. It takes a few seconds and ends with
`Result: N passed, M failed`. It uses memory from #6000 up, so the BASIC loader does `CLEAR 24575`.

## What it checks

| Line | Expected on a Pentagon | Where the number comes from |
|---|---|---|
| Frame time | 71680 T (320 lines x 224 T) | Sizif-512, MiSTer, Unreal and Fuse all agree |
| Stable | eight frames in a row give the same length | |
| EI is prefix | yes: an INT does not fire right after `EI` | Z80 behaviour, `minfo` |
| INT time | 32, 36 or 44 T | this is a machine option, see below |
| IM2 vector #FF | the data bus reads #FF during the interrupt acknowledge | Pentagon has no floating bus |
| Port #FF | `always #FF`, or `attributes N` in ATTRIBUTE mode | machine option, see below |
| RAM banks | 128K, 256K, 512K or 1024K, as configured | paging `{7FFD[5], 7FFD[7], 7FFD[6], 7FFD[2:0]}` |
| No contention @6000 | 71680 | `FRAME_TIME` running from bank 5 |
| Banks @C000 | all 71680 | `FRAME_TIME` copied into every bank at #C000 except 2 and 5 |

The RAM test writes a signature into bank 63 first and bank 0 last. On a smaller machine the upper
banks are mirrors of the lower ones, so the real bank always gets written last. The size is the first
bank that reads back someone else's signature. Every bank above that must then mirror bank
`k & (N-1)` exactly, otherwise the test fails.

## Why two lines accept more than one answer

The references disagree, and software has been written against each of them. BulbuLator therefore
exposes these as machine options rather than picking one.

INT length: 36 T is what Fuse, ZEsarUX and Potapov's ep4spectrum use, and it is our default.
Sizif-512, MiSTer, Unreal Speccy, ZX-Evo and TS-Conf use 32 T. `minfo` measured 44 T on a real board,
where an RC circuit sets the length, and that varies from board to board. The test passes on any of
the three and prints the value it saw, so you can tell whether the option took effect.

Port #FF: MiSTer and our default return #FF, because a Pentagon has no floating bus. Sizif-512
(`cpld/rtl/video.sv`) returns the last fetched attribute while the paper is being drawn, and some
real clones behave the same way. Games written for the Sinclair that sync on the floating bus with
`IN A,(#FF)` (Arkanoid, Cobra and similar) hang or flicker without it. In ATTRIBUTE mode the test
first builds a table of every attribute value on the screen. It then requires every non-#FF read to
be one of them, and prints how many reads returned an attribute.

## Raster tests: rastime and rasbord

PENTTEST cannot see the raster, so two more tapes answer the "where is INT relative to the picture"
question. They are Bobrowski's `stime` and `btime` with the frame body kept byte for byte, so `T`
means exactly what it means there. The only difference is that the program steps `T` itself instead of
waiting for Q/A.

- `rastime.tap` (stime): every frame writes #00 to 16384 and then #FF on T-state `T`. Cell (0,0) is red
  ink on yellow paper, so red means the write landed before the ULA fetched the byte.
- `rasbord.tap` (btime): on T-state `T` the border turns red, and 12 T later it turns white again.

Each `T` gets 16 frames and a fresh `ALIGNINT`. The current `T` is drawn as a 16-bit bar in character
rows 1 and 22, next to a flag that marks the frame as a measured one. The host reads them from frame
snapshots (`host/rsweep.py`, mailbox command 14). It only counts a frame when both bars agree and the
flag is set, which throws out torn buffers and the frames between two `T` values.

Measured on BulbuLator B0200 (Pentagon, INT H 327), against a real Pentagon:

| Test | BulbuLator | Real Pentagon |
|---|---|---|
| stime | 17984 visible, 17985 not | 17983 visible, 17984 flickers at 25 Hz, 17985 not |
| btime | 17762 | 17762-17763 |

The real machine sits exactly half a T-state between our two nearest settings. At INT H 328, stime
becomes 17983/17984 but btime drops to 17761. The CPU only sees INT on a T-state boundary, so two INT H
units make one T-state, and 327 is the better of the two. The remaining half T is smaller than the
spread between real boards.

## Frame rate: fcount

`framerate/fcount.tap` copies the FRAMES system variable to the top of the screen once per frame.
`host/frate.py <seconds> <T per frame>` reads it together with the ARM global timer twice. On
BulbuLator every machine runs its CPU at 56.667 MHz / 16 = 3.5416 MHz, which was measured as 50.673 Hz
on the 48K and 49.409 Hz on the Pentagon. A real 48K or Pentagon runs at 3.5000 MHz, so ours are
1.2 % fast. Nobody hears that. It does mean the machine and the 50.00 Hz HDMI output drift apart, so
a frame is dropped or repeated every 1.5 to 1.7 seconds.

## Building

`build.sh` needs `pasmo` (with `--alocal`, so labels starting with `_` are local) and Python 3:

```
./build.sh      # -> penttest.tap, rastime.tap, rasbord.tap, framerate/fcount.tap
```

`mktap.py` writes a one-line BASIC loader and the code block at 32768.
