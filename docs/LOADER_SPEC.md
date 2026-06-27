# Snapshot file formats (.z80 / .sna) and how BulbuLator loads them

This document is the complete reference for the two ZX Spectrum snapshot
formats that BulbuLator can load — `.z80` and `.sna` — and for exactly what
the BulbuLator firmware does with them. It is written to stand on its own: you
can use it to learn both formats from scratch, and you can use it to understand,
debug, or re-implement BulbuLator's loader. Where the published format allows
something that the BulbuLator implementation does *not* do, both are stated
explicitly: **"the format allows X; BulbuLator does Y."**

---

## 1. Introduction

### 1.1 What a snapshot is

A *snapshot* is a frozen copy of a running ZX Spectrum: the entire contents of
RAM plus the complete CPU state (all Z80 registers, the interrupt flip-flops,
the interrupt mode), plus the small amount of machine state that lives outside
the CPU and RAM — border colour, and on a 128K machine the memory-paging latch
(port `0x7FFD`). Restoring a snapshot means writing all of that back into a
machine and letting the CPU continue from the exact instruction it was about to
execute. Unlike a tape (`.tap`/`.tzx`), a snapshot does not "load" through the
ROM loader; it is injected wholesale and resumed.

The two formats covered here are the two that matter in practice:

* **`.sna`** — the older, simpler format. Fixed size, no compression, and a
  famous quirk: the 48K variant has *no PC field* and recovers the program
  counter by popping it off the saved stack. Comes in a 48K variant and a 128K
  variant.
* **`.z80`** — the de-facto standard, richer format. Three header versions
  (v1/v2/v3), optional RLE compression, an explicit hardware-mode byte, and a
  page-based memory layout that scales from 48K to 128K and beyond.

### 1.2 What BulbuLator does with them

BulbuLator runs a real ZX Spectrum core (Atlas, a T80 / Z80 clone) in the PL
(FPGA fabric) of a Zynq-7000, with the ARM (PS) acting as a control plane —
OSD, SD-card file service, keyboard gate, and snapshot loader. The loader is
bare-metal C running on the ARM (`arm/loader_main.c`). When the user picks a
`.z80` or `.sna` from the file browser, the ARM:

1. **Cold-resets and wipes** the whole machine (Z80, AY, ULA, paging, all RAM).
2. Parses the snapshot header in DRAM.
3. **Decompresses and streams** the RAM image into the core's memory over an
   AXI back-door, one 16 KiB bank at a time.
4. Sets the paging latch (`0x7FFD`) and border, and commits them.
5. Injects the full Z80 register file directly into the T80 core via a
   dedicated "DIRSet" vector.
6. Releases the core, which resumes at the snapshot's PC.

This is a deliberately *destructive* load: the previous machine state is gone.
That is intentional and is the source of one of the loader's most important
behaviours (the cold reset, see §7.2).

### 1.3 Target hardware and the contract

* SoC: Zynq-7000 (EBAZ4205, XC7Z010).
* Core: Atlas ZX Spectrum 128 (T80 CPU).
* Control link: AXI GP0, register map in `sources/axi_ctl.v`.
* AXI `VERSION` register reads `0xB01B0009` for the build this spec describes.
* AXI `MACHINE_ID` register reads `0x00805A58` ("ZX" tag).

All multi-byte values in both file formats are **little-endian (low byte
first)** unless explicitly noted. The exceptions are the register pairs `AF`
and `AF'` in `.z80`, which are stored *A then F* (see §2.2).

---

## 2. The `.z80` format

A `.z80` file is a header followed by memory. There are three header versions.
The crucial fact is that **the original 30-byte v1 header prefixes every
version** — v2 and v3 do not replace it, they *extend* it. So you always parse
the 30-byte base header first, and only then decide whether more header
follows.

```
            ┌─────────────────────────────┐  offset 0
            │  30-byte base header (v1)    │
            ├─────────────────────────────┤  offset 30
  v1 only ─▶│  memory (raw or RLE, 48K)    │
            └─────────────────────────────┘

            ┌─────────────────────────────┐  offset 0
            │  30-byte base header         │
            ├─────────────────────────────┤  offset 30
            │  2-byte extended-header len  │  (= 23 / 54 / 55)
            ├─────────────────────────────┤  offset 32
  v2/v3  ──▶│  extended header (len bytes) │
            ├─────────────────────────────┤  offset 32 + len
            │  memory blocks (paged, RLE)  │  repeat to EOF
            └─────────────────────────────┘
```

### 2.1 Version detection — the PC-at-offset-6 rule

> Read the 16-bit word at **offset 6** (the PC field of the base header).
> * **PC ≠ 0** → this is a **v1** file. Memory begins immediately at offset 30.
> * **PC == 0** → this is an **extended** (v2 or v3) file. The real PC lives at
>   offset 32, and a 2-byte *extended-header length* word at offset 30 tells
>   you which: **23 → v2.01**, **54 → v3.0**, **55 → v3.0x** (the +3 variant
>   with one extra byte).

This is the single most important detection step and it is unambiguous: a v1
PC is never legitimately zero in a real snapshot.

**BulbuLator does exactly this:** `pc0 = d[6] | d[7]<<8`. If non-zero it takes
the v1/48K path; if zero it reads `extlen = d[30] | d[31]<<8` and the real PC
from `d[32]|d[33]<<8`.

### 2.2 The 30-byte base header (v1) — complete byte table

| Off | Len | Field | Notes |
|----:|----:|-------|-------|
| 0  | 1 | **A** | High byte of AF, stored *first*. |
| 1  | 1 | **F** | So bytes 0–1 are **A,F** — *not* a little-endian AF word. |
| 2  | 2 | **BC** | LSB first (C @2, B @3). |
| 4  | 2 | **HL** | L @4, H @5. |
| 6  | 2 | **PC** | LSB first. **== 0 ⇒ v2/v3**, real PC then at offset 32. |
| 8  | 2 | **SP** | LSB first. |
| 10 | 1 | **I** | Interrupt vector register. |
| 11 | 1 | **R** | Refresh register — **only bits 0–6 are valid here**; bit 7 comes from byte 12 bit 0. |
| 12 | 1 | **FLAGS / info byte** | Bitfield, see below. **0xFF quirk applies.** |
| 13 | 2 | **DE** | E @13, D @14. |
| 15 | 2 | **BC'** | shadow, C' @15, B' @16. |
| 17 | 2 | **DE'** | shadow. |
| 19 | 2 | **HL'** | shadow. |
| 21 | 1 | **A'** | shadow A. |
| 22 | 1 | **F'** | shadow F (so 21–22 are A',F'). |
| 23 | 2 | **IY** | LSB first. |
| 25 | 2 | **IX** | LSB first. |
| 27 | 1 | **IFF1** | 0 = DI (interrupts disabled), non-zero = EI. |
| 28 | 1 | **IFF2** | rarely important on its own. |
| 29 | 1 | **FLAGS2** | Bitfield, see below. |

**End of the v1 header is at offset 30.** In a v1 file the 48 KiB of RAM
(`0x4000`–`0xFFFF`, 49152 bytes) follows immediately, raw or compressed
according to byte 12 bit 5.

#### Byte 12 — the info/flags bitfield

| Bit(s) | Meaning |
|---|---|
| 0 | **Bit 7 of the R register** (the "R-bit-7 trick"). |
| 1–3 | Border colour (0–7). |
| 4 | 1 = Basic SamRom switched in. |
| 5 | 1 = the memory data block is **compressed** (v1 RLE). |
| 6–7 | No meaning. |

**The 0xFF quirk:** if the *whole* byte 12 equals `0xFF`, treat it as if it
were `0x01` before decoding any bits. This is purely for compatibility with
very old files. Apply it *first*. (Resulting state: border 0, R-bit7 set,
uncompressed.)

#### Byte 29 — FLAGS2 bitfield

| Bit(s) | Meaning |
|---|---|
| 0–1 | Interrupt Mode (IM 0, 1 or 2). |
| 2 | 1 = Issue-2 emulation. |
| 3 | 1 = double interrupt frequency. |
| 4–5 | Video sync (1 = high, 3 = low, 0/2 = normal). |
| 6–7 | Joystick: 0 = Cursor/Protek/AGF, 1 = Kempston, 2 = Sinclair-2-Left / user-defined (v3), 3 = Sinclair-2-Right. |

#### The R-register bit-7 reconstruction

The R register's bit 7 is *not* stored in byte 11. Reconstruct the full value:

```
R = (byte11 & 0x7F) | ((byte12 & 0x01) << 7)
```

Using byte 11 alone gives a wrong R (off by `0x80`) in roughly half of all
snapshots. **BulbuLator does this correctly:** `R = (d[11]&0x7F) | ((d[12]&1)<<7)`.

#### What BulbuLator reads from the v1 header

`A=d0, F=d1, BC=d2/3, HL=d4/5, PC=d6/7, SP=d8/9, I=d10`,
`R=(d11&0x7F)|((d12&1)<<7)`, `border=(d12>>1)&7`,
`DE=d13/14, BC'=d15/16, DE'=d17/18, HL'=d19/20, A'=d21, F'=d22, IY=d23/24, IX=d25/26`,
`IFF1 = d27?1:0`, `IFF2 = d28?1:0`, `IM = d29 & 3`.

Note BulbuLator reads `IFF1` and `IFF2` **independently** from bytes 27 and 28
(unlike `.sna`, where only IFF2 exists — see §3). BulbuLator does **not** read
the SamRom bit, the issue-2/double-interrupt/video-sync/joystick fields, nor
does it apply the `0xFF`→`0x01` clamp on byte 12 (it reads the border and
compressed bits directly; in practice byte 12 == 0xFF is essentially never seen
in modern files, but this is a strict-spec deviation).

### 2.3 v1 memory compression (RLE)

v1 RAM is either raw 49152 bytes (byte 12 bit 5 clear) or RLE-compressed (bit
5 set). The RLE scheme:

* A run of **≥ 5 identical bytes** is encoded as the 4-byte sequence
  **`ED ED xx yy`** = "byte `yy` repeated `xx` times" (`xx` = count, `yy` =
  value).
* `xx` is a single byte, so the **maximum run per code is 255**; longer runs
  need multiple `ED ED` codes.
* **ED exception:** a run of even **two** `0xED` bytes is encoded
  (`ED ED 02 ED`), because a literal `ED ED` pair would otherwise be mistaken
  for the escape prefix.
* **Single-ED passthrough:** the byte immediately following a *lone* (un-escaped)
  `0xED` is never folded into a run. Example: `ED` followed by six `0x00` is
  encoded as `ED 00` (literal ED, literal 00) then `ED ED 05 00` (the remaining
  five zeros) — i.e. `ED 00 ED ED 05 00`, **not** `ED ED ED 06 00`. A decoder
  must respect this or it will mis-resync.
* **End marker:** the v1 compressed block is terminated by the 4-byte marker
  **`00 ED ED 00`**. This marker exists **only in v1**.

**BulbuLator's v1 path:** a single block from offset 30; compressed iff
`d[12] & 0x20`, else a raw copy. It decompresses into a 49152-byte buffer, then
writes that flat buffer to banks 5, 2, 0 in that order (§5).

### 2.4 The v2/v3 extended header

After the 30-byte base header, an extended header begins:

| Off | Len | Field | Notes |
|----:|----:|-------|-------|
| 30 | 2 | **Extended-header length** | Counts bytes **starting at offset 32**; excludes the length word and the first 30 bytes. **23 → v2.01, 54 → v3.0, 55 → v3.0x (+3).** |
| 32 | 2 | **PC** (real) | LSB first. |
| 34 | 1 | **Hardware mode** | See the table in §2.5. |
| 35 | 1 | **Port 0x7FFD** (128K) / 74LS259 latch (SamRam) / port 245 (Timex). | The last value OUT to the 128K paging port. |
| 36 | 1 | `0xFF` if Interface I ROM paged. (Timex: last OUT to port 255.) |
| 37 | 1 | **FLAGS3** — see below. |
| 38 | 1 | Last OUT to port `0xFFFD` = selected AY register number (0–15). |
| 39 | 16 | **AY register dump** — registers 0–15, so AY reg N is at offset 39+N (offsets 39–54). |

**v2 ends here** (23 bytes from offset 32 = offsets 32–54). For v2, memory
blocks begin at offset **55**.

v3 continues:

| Off | Len | Field |
|----:|----:|-------|
| 55 | 2 | Low T-state counter (v3 only). |
| 57 | 1 | Hi T-state counter (mod 4) (v3 only). |
| 58 | 1 | Spectator (QL emulator) flag — ignored on load, written 0. |
| 59 | 1 | `0xFF` if MGT (DISCiPLE/Plus-D) ROM paged. |
| 60 | 1 | `0xFF` if Multiface ROM paged. **Should always be 0** — Multiface RAM is not saved, and a snapshot taken with it paged will likely crash on resume. |
| 61 | 1 | `0xFF` if `0x0000`–`0x1FFF` is ROM, `0` if RAM. |
| 62 | 1 | `0xFF` if `0x2000`–`0x3FFF` is ROM, `0` if RAM. (Bytes 61/62 are a function of bytes 34, 59, 60, 83.) |
| 63 | 10 | 5 user-defined-joystick keyboard-mapping WORDs (low = row 0–7, high = column mask). |
| 73 | 10 | 5 ASCII WORDs (high byte 0) naming the keys for Left, Right, Down, Up, Fire. |
| 83 | 1 | MGT type: 0 = DISCiPLE+Epson, 1 = DISCiPLE+HP, 16 = Plus-D. |
| 84 | 1 | DISCiPLE inhibit-button status (0 = out, 0xFF = in). |
| 85 | 1 | DISCiPLE inhibit flag (0 = ROM pageable, 0xFF = not). **Last byte of the 54-byte v3.0 header.** |
| 86 | 1 | **(only when length word == 55)** Last OUT to port `0x1FFD` — the +3/+2A secondary paging port. Added by XZX-Pro. |

For v3.0 (len 54) memory begins at offset `32 + 54 = 86`; for v3.0x (len 55) at
offset `32 + 55 = 87`. Some emulators reject 55-byte headers.

> **Header start arithmetic, in general:** total bytes before the first memory
> block = `30 (base) + 2 (length word) + extlen` = `32 + extlen`. The length
> word at offset 30 is part of the *extended* header that sits after the base
> 30 bytes; never skip the base header.

#### Byte 37 — FLAGS3 bitfield

| Bit(s) | Meaning |
|---|---|
| 0 | R-register emulation on. |
| 1 | LDIR emulation on. |
| 2 | AY registers in use / always saved (even on 48K, XZX-Pro/Fuller convention). |
| 6 | (with bit 2) Fuller Box emulation. |
| 7 | **"Modified hardware" flag** — reinterpret byte 34: 48K→16K, 128K→+2, +3→+2A (Spectaculator). |

#### What BulbuLator reads from the extended header

Only `extlen` (d[30]/d[31]), `PC` (d[32]/d[33]), `hw` (d[34]), and `p7ffd`
source `d[35]`. **Everything else is ignored** — the T-state counters, the AY
register dump (d38–54), the joystick/keymap fields, the modified-hardware flag,
SamRam, the Interface I / MGT / Multiface flags. See §8 for the consequences
(most visibly: AY sound state is not restored).

### 2.5 Hardware-mode byte 34 — the complete table

> **The meaning of values 3–6 SHIFTS between v2 and v3.** You must know the
> version (from the length word) before interpreting byte 34.

| Value | v2.01 meaning | v3.0x meaning |
|------:|---------------|---------------|
| 0 | 48K | 48K |
| 1 | 48K + IF1 | 48K + IF1 |
| 2 | SamRam | **48K + MGT** |
| 3 | **128K** | **SamRam** |
| 4 | **128K + IF1** | **128K** |
| 5 | (unused) | **128K + IF1** |
| 6 | (unused) | **128K + MGT** |

Extended / emulator-established codes (v3-era de-facto):

| Value | Machine |
|------:|---------|
| 7 | Spectrum +3 (XZX-Pro writes 7 and adds the byte-86 #1FFD byte) |
| 8 | also +3 (XZX-Pro quirk — treat as +3) |
| 9 | Pentagon 128K (paging ≈ standard 128K) |
| 10 | Scorpion 256K (snapshot has **16** RAM pages) |
| 11 | Didaktik-Kompakt |
| 12 | Spectrum +2 |
| 13 | Spectrum +2A |
| 14 | Timex TC2048 |
| 128 (0x80) | Timex TS2068 (Warajevo) |

**Modified-hardware variant (byte 37 bit 7 set):** reinterpret a 48K id as 16K,
a 128K id as +2, a +3 id (7/8) as +2A.

**The v2→v3 shift (codes 2–4):** v3 inserts **48K+MGT** at code 2, which pushes
SamRam to code 3 and 128K to code 4; v2 keeps SamRam at 2 and 128K at 3. The
canonical nvg / FUSE ordering is v3 `2 = 48K+MGT, 3 = SamRam` — so always read
byte 34 together with the version. (Bytes 61/62 were also documented wrong up to
v3.04.)

#### BulbuLator's 128K-vs-48K decision (version-dependent!)

```c
is128 = (extlen == 23) ? (hw >= 3) : (hw >= 4);
p7ffd = is128 ? (d[35] & 0x3F) : 0x30;
```

This matches the table: in a **v2** file (extlen 23) the 128K modes start at
code 3; in a **v3** file (extlen 54/55) they start at code 4 (codes 2 and 3 are
48K+MGT and SamRam — both 48K-class). So `hw == 3` in a v3 file is treated as
**48K**, which is correct.
Note the `& 0x3F`: BulbuLator masks the saved 7FFD to 6 bits because the
hardware `PORT_7FFD` register is only `[5:0]` (see §6/§7). For 48K mode it
forces `0x30` (bank 0 at `0xC000`, 48K ROM selected, screen = bank 5, paging
locked).

> **Caveat:** BulbuLator does *not* special-case Scorpion (16 pages → banks
> 8–15), +2/+2A/+3 disk paging, or Timex. Any of codes 7–14/128 simply takes
> the `hw >= 4` 128K path and is mapped through the *standard* 128K bank scheme
> (§5). For genuine Pentagon-128 / standard-128K content this is correct; for
> Scorpion or +3-specific paging it is not. See §8.

### 2.6 The v2/v3 memory-block format

In v2/v3 the memory is a sequence of blocks, **repeating until EOF with no
count field and no end marker.** Each block:

```
byte 0–1 : length of the (possibly compressed) data, WORD, LSB first
           — NOT counting this 3-byte header.
byte 2   : page number (which logical 16 KiB page this is).
byte 3.. : the data.
```

* **Special sentinel:** if the length word == **`0xFFFF`**, the data is exactly
  **16384 bytes stored uncompressed (raw)**.
* Otherwise the data is RLE-compressed with the **same `ED ED xx yy` scheme as
  v1, but with NO `00 ED ED 00` end marker** — the length word delimits it.
* Each block always decompresses to a full **16 KiB (16384-byte) page**.

A parser reads `(3-byte header + data)` repeatedly until EOF. A v2/v3 parser
that looks for the v1 end marker will overrun; a v1 parser that ignores the
length and counts to 49152 will mis-handle v2/v3.

**BulbuLator's page loop:**

```c
off = 32 + extlen;
while (more) {
    clen = d[off] | d[off+1]<<8;
    pg   = d[off+2];
    data = &d[off+3];
    if (clen == 0xFFFF) { raw 16384 } else { z80_unrle(...) }
    // map pg -> bank (see §5), wr_bank if bank != -1
    off += 3 + (clen == 0xFFFF ? 16384 : clen);
}
```

`z80_unrle` recognises the `ED ED` escape, reads count then value, expands the
run, and zero-fills any short tail to 16384. The `0xFFFF` sentinel copies 16384
raw bytes.

### 2.7 Page-id → logical block mapping

The page number in byte 2 means **different things in different machine modes.**
This is the subtle part.

**'48 mode** (page id → address region or ROM):

| Page | Meaning |
|---:|---|
| 0 | 48K ROM |
| 1 | IF1 / DISCiPLE / Plus-D ROM |
| 4 | `0x8000`–`0xBFFF` |
| 5 | `0xC000`–`0xFFFF` |
| 8 | `0x4000`–`0x7FFF` |
| 11 | Multiface ROM |

**'128 mode** (page id → 128K RAM **bank number**, via `bank = page − 3`):

| Page | Meaning | Page | Meaning |
|---:|---|---:|---|
| 0 | ROM (basic/editor) | 7 | RAM bank 4 |
| 1 | IF1/DISCiPLE/PlusD ROM | 8 | RAM bank 5 |
| 2 | ROM (reset/48-basic) | 9 | RAM bank 6 |
| 3 | RAM bank 0 | 10 | RAM bank 7 |
| 4 | RAM bank 1 | 11 | Multiface ROM |
| 5 | RAM bank 2 | | |
| 6 | RAM bank 3 | | |

**SamRam mode:** page0 = 48K ROM, 2 = samram ROM (basic), 3 = samram ROM
(monitor), 4 = normal `0x8000`–`0xBFFF`, 5 = normal `0xC000`–`0xFFFF`, 6 =
shadow `0x8000`–`0xBFFF`, 7 = shadow `0xC000`–`0xFFFF`, 8 = `0x4000`–`0x7FFF`.

**Which pages are saved:**

| Mode | Pages saved | Blocks |
|---|---|---:|
| 48K | 4, 5, 8 | 3 |
| SamRam | 4–8 | 5 |
| 128K | 3–10 (all 8 RAM banks 0–7) | 8 |
| Scorpion 256K | (16 pages) | 16 |

> **The key semantic distinction:** the *same numeric page id* means different
> things in 48K vs 128K. Page 8 is "address `0x4000`–`0x7FFF`" in 48K but "RAM
> bank 5" in 128K. Page 4 is "`0x8000`–`0xBFFF`" in 48K but "RAM bank 1" in
> 128K. A loader must branch on machine mode before mapping. See §5 for how
> BulbuLator handles this and the **collision warning**.

---

## 3. The `.sna` format

`.sna` is older and simpler: a fixed 27-byte register header, then a raw
(uncompressed) RAM dump. There is no compression, which makes the file size
fixed and the dispatch-by-size reliable. All values are little-endian; `AF`
and `AF'` store **F in the low byte, A in the high byte** (a common off-by-one
source).

### 3.1 48K `.sna` — exactly 49179 bytes

`49179 = 27 (header) + 49152 (RAM)`.

| Off | Len | Field | Notes |
|----:|----:|-------|-------|
| 0x00 | 1 | **I** | |
| 0x01 | 2 | **HL'** | shadow |
| 0x03 | 2 | **DE'** | shadow |
| 0x05 | 2 | **BC'** | shadow |
| 0x07 | 2 | **AF'** | F' @0x07, A' @0x08 |
| 0x09 | 2 | **HL** | |
| 0x0B | 2 | **DE** | |
| 0x0D | 2 | **BC** | |
| 0x0F | 2 | **IY** | |
| 0x11 | 2 | **IX** | |
| 0x13 | 1 | **Interrupt byte** | **Only bit 2 defined = IFF2** (1 = EI, 0 = DI). Mask with `& 0x04`; do not test the whole byte. |
| 0x14 | 1 | **R** | full 8 bits |
| 0x15 | 2 | **AF** | F @0x15, A @0x16 |
| 0x17 | 2 | **SP** | as saved — points at the pushed PC (see below) |
| 0x19 | 1 | **IM** | 0/1/2 |
| 0x1A | 1 | **Border** | 0–7, low 3 bits |

RAM region: bytes **27..49178** (49152 bytes) = a flat dump of `0x4000`–`0xFFFF`.
The first `0x4000` → RAM **bank 5** (`0x4000`–`0x7FFF`, contains the screen at
`0x4000`–`0x5AFF`, i.e. file offset 27..27+0x1AFF). The next `0x4000` → bank 2
(`0x8000`–`0xBFFF`). The last `0x4000` → the bank paged at `0xC000` (bank 0 on a
plain 48K).

#### The PC-on-stack trick (the defining `.sna` quirk)

48K `.sna` has **no PC field.** At save time the emulator effectively executes a
`PUSH PC`: it decrements SP by 2 and writes the two PC bytes to `[SP]` (low) and
`[SP+1]` (high). The stored SP therefore points at this pushed value.

**Loader procedure to recover PC:**

```
PC_low  = memory[SP]
PC_high = memory[SP+1]
PC      = PC_low | (PC_high << 8)
SP      = SP + 2          // pop it back off
```

**Why this works — RETN:** the original 48K snapshot was captured from an
NMI-style routine. The snapshot is designed to be resumed by executing `RETN`
("return from non-maskable interrupt"), which both pops the return address (the
real PC) *and* restores IFF1 from IFF2. That is exactly why only **IFF2** is
stored: `RETN` reconstructs IFF1 from it.

**Consequences (inherent, by design, not bugs):**

* The two bytes just below the original SP in the RAM image are
  **overwritten** with the pushed PC. After load + RETN, SP is restored but
  those two bytes remain clobbered. This matches real hardware at snapshot time
  and is unavoidable in 48K `.sna`.
* IFF1 is not stored; standard practice is **IFF1 := IFF2**.

#### ROM-stack corner case

If the saved `SP < 0x4000`, the pushed PC bytes landed in ROM space
(`0x0000`–`0x3FFF`), which `.sna` does **not** store — so the PC is
unrecoverable from the file and the snapshot is malformed for this path.
`SP = 0xFFFF` is also problematic (`SP+1` wraps to `0x0000`, ROM). Robustly,
both `[SP]` and `[SP+1]` must lie in the stored RAM, i.e.
**`0x4002 ≤ SP ≤ 0xFFFE`** (some implementations accept `0x4000`–`0xFFFE`).

**BulbuLator** guards this: it pops PC from `ram[SP-0x4000] | ram[SP-0x4000+1]<<8`
**only when `SP` is in `0x4000..0xFFFE`**, then `SP = (SP+2) & 0xFFFF` and the 48K
paging is forced to `0x30`. On guard failure PC falls back to **0**
deterministically — the two PC bytes are pre-initialised to 0 *and* the register
struct is zero-initialised (`zregs z = {0}`). A well-formed 48K `.sna` always has
SP pointing into RAM, so the guard never fires in practice.

### 3.2 128K `.sna` — 131103 or 147487 bytes

The front block (bytes 0..49178) has the **identical structure** to a 48K
`.sna`: 27-byte header + 49152 bytes. But the three 16 KiB chunks at offset 27
are: **bank 5, then bank 2, then the bank currently paged at `0xC000`** (per
`7FFD` bits 0–2) — even if that paged bank is itself 5 or 2.

Then a **4-byte trailer** at offset 49179:

| Off | Len | Field |
|----:|----:|-------|
| 49179 | 2 | **PC** (explicit — 128K does **not** use the stack trick) |
| 49181 | 1 | Last value written to port `0x7FFD` |
| 49182 | 1 | TR-DOS / Beta-disk ROM paged flag (1 = paged) — Pentagon/Beta extension |

Then the **remaining five banks** at offset 49183 onward: the other 16 KiB
banks in **ascending numeric order (0,1,2,...,7)**, *skipping* the three already
written in the front block (bank 5, bank 2, and the `7FFD`-paged bank). That is
`5 × 16384 = 81920` bytes.

Size arithmetic: `49179 + 4 + 5×16384 = 131103 bytes` — the canonical 128K
`.sna`.

```
 offset 0       27                       49179  49181  49183                131103
 ┌────────────┬───────────────────────┬──────┬─────┬─┬───────────────────────┐
 │ 27-byte    │ 49152 bytes:          │ PC   │7FFD │T│ 5 remaining banks      │
 │ register   │ bank5, bank2, paged   │ (2B) │(1B) │R│ ascending 0..7,        │
 │ header     │ (3×16 KiB)            │      │     │D│ skipping {5,2,paged}   │
 │            │                       │      │     │S│ (5×16 KiB = 81920)     │
 └────────────┴───────────────────────┴──────┴─────┴─┴───────────────────────┘
                                       └──── 4-byte trailer ────┘
```

#### The 147487-byte variant

`147487 = 131103 + 16384` — exactly **one extra 16 KiB bank** (six trailing banks
instead of five). This happens when the bank paged at `0xC000` is itself **bank 5
or bank 2**: the front 49152 block then holds only **two distinct** banks (5 and 2,
with the third chunk a duplicate), so **six** banks — every bank except 5 and 2 —
follow in the trailing list instead of five. (A trailing list of all *eight* banks
would be `27 + 49152 + 4 + 8×16384 = 180255`, not 147487, so "all 8 in the trailing
list" is a misreading.) The extra 16 KiB is **not** a TR-DOS ROM image. A correct
reader takes `8 − (distinct front banks)` trailing banks; see §5.2 for how
BulbuLator does exactly that.

#### 128K paging from the trailer `7FFD` byte (offset 49181)

| Bit(s) | Meaning |
|---|---|
| 0–2 | RAM bank paged at `0xC000` |
| 3 | Displayed screen: 0 → bank 5 (normal), 1 → bank 7 (shadow) |
| 4 | ROM select: 0 = 128K editor ROM, 1 = 48K BASIC ROM |
| 5 | Paging disable / lock latch |

> The **displayed screen is independent** of the `0xC000`-paged bank: it comes
> from bit 3 (bank 5 vs bank 7), while bits 0–2 only choose what's mapped at
> `0xC000`. A renderer must read bank 5 or bank 7 per bit 3, not the paged bank.

#### What BulbuLator reads from `.sna`

Header: `I=d0, HL'=d1/2, DE'=d3/4, BC'=d5/6, F'=d7, A'=d8, HL=d9/10, DE=d11/12,
BC=d13/14, IY=d15/16, IX=d17/18`, `IFF2 = (d19 & 0x04)?1:0` **with `IFF1 := IFF2`**,
`R=d20, F=d21, A=d22, SP=d23/24, IM = d25 & 3, border = d26 & 7`.

* **48K path** (`len < 131000`): banks 5, 2, 0 from the 49152 bytes after the
  header; PC popped from stack (guarded, §3.1); `p7ffd = 0x30`.
* **128K path** (`len >= 131000`): `PC = ram[49152] | ram[49153]<<8`,
  `p7 = ram[49154]`, `paged = p7 & 7`; banks 5, 2, `paged` from the first 49152;
  the remaining banks 0..7 skipping `{5, 2, paged}` from offset
  `27 + 49152 + 4`; `p7ffd = p7 & 0x3F`. The `+4` is the trailer (PC 2B + 7FFD
  1B + 1 TR-DOS byte).

> BulbuLator dispatches purely on the `len < 131000` threshold — **not** on the
> exact sizes 49179/131103/147487. The format's TR-DOS flag at 49182 is read as
> part of the 4-byte gap but is not acted on. It then reads exactly **five**
> trailing banks — the loop walks `b = 0..7` skipping `{5, 2, paged}`, one 16 KiB
> chunk per non-skipped bank — which is exactly the 131103 layout, so **131103 is
> handled correctly**. A **147487** file, however, stores *all eight* banks in the
> trailing list (the paged bank is duplicated, not skipped); reading only five
> chunks at the 131103 offsets lands the wrong 16 KiB on the wrong banks,
> **corrupting the upper RAM**. So 147487 is *not* correctly supported despite
> being accepted by the `len >= 131000` test. See §8.

---

## 4. Soft-detection — formal rules and what BulbuLator does

### 4.1 Formal detection

* **Format:** `.z80` vs `.sna` is normally by file extension (neither format
  has a magic number; `.sna` is recognised by its fixed sizes, `.z80` by the
  PC-at-6 rule).
* **`.sna` size dispatch:** `49179` → 48K; `131103` or `147487` → 128K;
  anything else → not a `.sna`.
* **`.z80` version:** PC at offset 6 ≠ 0 → v1; == 0 → extended, then length word
  23/54/55 → v2.01/v3.0/v3.0x.
* **`.z80` machine:** byte 34, interpreted per version (§2.5).

### 4.2 What BulbuLator actually does

Dispatch is by **case-insensitive file extension only** — `.sna` → `load_sna`,
**everything else** → `load_z80`. There is no content sniffing. Inside each:

```
                       ┌───────────────────────────┐
                       │ file extension (lowercased)│
                       └─────────────┬──────────────┘
                          ".sna"?     │   else
                  ┌──────────────────┘└────────────────────┐
                  ▼                                          ▼
          ┌───────────────┐                          ┌───────────────┐
          │   load_sna    │                          │   load_z80    │
          └──────┬────────┘                          └──────┬────────┘
       len<131000│  len>=131000                  pc0=d[6|7]  │
        (48K)    │   (128K)                    pc0!=0│  pc0==0│
        ┌────────┘└────────┐                  (v1)  │  (v2/v3)
        ▼                  ▼                   ┌─────┘└──────────┐
  stack-pop PC       explicit PC               ▼                ▼
  banks 5,2,0        banks 5,2,paged     48K flat block   extlen=d[30|31]
  p7ffd=0x30         + remaining 0..7    banks 5,2,0      PC=d[32|33] hw=d[34]
                     p7ffd=p7&0x3F       p7ffd=0x30       is128 = (extlen==23)
                                                            ? hw>=3 : hw>=4
                                                          p7ffd = is128
                                                            ? d[35]&0x3F : 0x30
                                                          page loop (§2.6)
```

Two BulbuLator-specific facts the formal rules don't capture:

* **`.sna` 48K/128K split is the `len < 131000` threshold**, not the exact
  sizes. A 49179-byte file and any other file under 131000 are both treated as
  48K; 131103 and 147487 are both 128K.
* **`.z80` 128K test is version-dependent:** `(extlen==23) ? (hw>=3) : (hw>=4)`.
  A flat "hw 3 or 4 → 128K regardless of version" rule is **wrong** for v3,
  where hw 3 is SamRam (a 48K-class machine), not 128K.

---

## 5. Memory / page → physical bank mapping

The core has 8 × 16 KiB RAM banks (0–7). The loader writes each bank by setting
`RAM_ADDR = bank << 14` and streaming 16384 bytes (§7.3).

### 5.1 Per-machine mapping (formal)

* **48K page id → address region:** page 8 → `0x4000`, page 4 → `0x8000`,
  page 5 → `0xC000` (and pages 0/1/11 are ROMs). On a 128K-bank machine those
  three address regions correspond to **banks 5, 2, 0** respectively.
* **128K page id → bank number:** `bank = page − 3` (page 3 → bank 0 … page 10
  → bank 7).

### 5.2 BulbuLator's exact mapping

| Source | Mapping |
|---|---|
| `.z80` v1 / 48K flat image | sequential split: bytes 0..16383 → **bank 5**, 16384..32767 → **bank 2**, 32768..49151 → **bank 0**. |
| `.z80` v2/v3 **128K** | `pg` in `[3..10]` → bank `pg-3`; **any other page is silently dropped** (`bank = -1`, no write). |
| `.z80` v2/v3 **48K** | `pg5 → bank5`, `pg4 → bank2`, `pg8 → bank0`; **all other pages silently dropped**. |
| `.sna` 48K | banks 5, 2, 0 from the 49152 bytes after the 27-byte header. |
| `.sna` 128K | banks 5, 2, `paged(=p7&7)` from the first 49152; remaining banks 0..7 excluding `{5,2,paged}` in ascending order from offset `27+49152+4`. |

### 5.3 Collision warning — do not blindly do `pg − 3`

The `.z80` 48K and 128K page-id spaces overlap numerically but mean different
things (§2.7). BulbuLator uses the **right** mapping for each mode — for 48K it
maps pages 4/5/8 to banks 2/5/0, *not* `pg-3` (which would give banks 1/2/5 and
corrupt the image). The lesson for any re-implementation: **branch on the
machine mode first**, then map. Applying `pg − 3` to a 48K snapshot's page 8
would write bank 5 instead of bank 0; applying the 48K address map to a 128K
snapshot would scramble it.

Also note BulbuLator's **page-drop** behaviour: in 128K mode any page outside
3–10 (e.g. ROM pages 0/1/2, Multiface 11, or a Scorpion page > 10) is ignored;
in 48K mode anything but 4/5/8 is ignored. This is correct for standard content
(ROM pages are not loaded into RAM banks) but means Scorpion's banks 8–15 are
never written (§8).

---

## 6. CPU register & state restore

### 6.1 The full restored set

From the snapshot, BulbuLator restores: `AF, BC, DE, HL` and shadows
`AF', BC', DE', HL'`, `IX, IY, SP, PC, I, R`, the interrupt mode `IM`, both
interrupt flip-flops `IFF1`/`IFF2`, the border colour, and the 128K paging
latch `0x7FFD`. It does **not** restore AY registers or T-state position (§8).

* `.z80` reads IFF1 and IFF2 independently (bytes 27/28).
* `.sna` stores only IFF2 (byte 0x13 bit 2) and **sets IFF1 := IFF2**.
* `.sna` 48K recovers PC via the stack-pop trick (§3.1, guarded);
  `.sna` 128K and all `.z80` files have an explicit PC.

### 6.2 The T80 DIR vector — word-by-word

Registers are injected directly into the T80 core via a "DIRSet" facility: the
loader writes a wide register-state vector to `DIR0..DIR6` (AXI offsets
`0x20..0x38`), then pulses `COMMIT` bit 1 to latch the whole vector into the
T80's internal registers in one shot. The vector is **212 bits wide**; it is
transferred as **7 words**. The 7th word (DIR6) maps to the **top 20 bits of the
212-bit vector**: the fabric latches `ctl_dir[211:192] <= s_wdata[19:0]` and
ignores the upper 12 bits of the written word. The loader writes a normal 32-bit
word for DIR6 with only the low 20 bits populated (upper bits zero), which is
harmless.

| Word | AXI off | Packing (bit fields within the 32-bit write) |
|---|---|---|
| DIR0 | 0x20 | `A \| F<<8 \| A'<<16 \| F'<<24` |
| DIR1 | 0x24 | `I \| R<<8 \| SP<<16` |
| DIR2 | 0x28 | `PC \| BC<<16` |
| DIR3 | 0x2C | `DE \| HL<<16` |
| DIR4 | 0x30 | `IX \| BC'<<16` |
| DIR5 | 0x34 | `DE' \| HL'<<16` |
| DIR6 | 0x38 | `IY \| IM<<16 \| IFF1<<18 \| IFF2<<19` (only low ~20 bits used) |

So the DIR6 layout is: bits 0–15 = IY, bits 16–17 = IM, bit 18 = IFF1, bit
19 = IFF2.

### 6.3 How the rest maps to AXI writes

* **Border** → `PORT_FE` (`[2:0]`). Source: `.z80` v1 `(d[12]>>1)&7`; `.sna`
  `d[26]&7`.
* **Paging** → `PORT_7FFD` (`[5:0]`). Source: the masked `p7ffd` computed in
  §2.5 / §3.2 (`0x30` for 48K).
* Both ports are latched by `COMMIT` bit 0 (port-commit) *before* the DIR
  vector is committed.

---

## 7. The BulbuLator hardware loading pipeline

### 7.1 AXI GP0 register table (loader-relevant)

| Off | Name | Bits used | Meaning |
|----:|------|-----------|---------|
| 0x00 | VERSION | r/o | `0xB01B0009` |
| 0x04 | CONTROL | bit0 HALT, **bit2 RESET+wipe** | drive the core FSM |
| 0x08 | STATUS | bit0 HALT_ACK, bit1 RAM_BUSY, **bit2 reset_busy** | core status |
| 0x0C | COUNTER | — | (diagnostic) |
| 0x10 | RAM_ADDR | 17-bit, auto-inc | back-door RAM write address |
| 0x14 | RAM_DATA | byte | back-door RAM write data (auto-increments addr) |
| 0x18 | SCRATCH | — | (diagnostic) |
| 0x20–0x38 | DIR0..DIR6 | 212-bit vector (DIR6 = top 20b) | T80 register inject |
| 0x3C | PORT_7FFD | `[5:0]` | 128K paging latch |
| 0x40 | PORT_FE | `[2:0]` | border |
| 0x44 | COMMIT | bit0 port-commit, bit1 DIRSet | latch pulses |
| 0x60 | MACHINE_ID | r/o | `0x00805A58` |

> **Note on the Verilog header comment:** `axi_ctl.v`'s register-map comment
> documents only CONTROL bit0 / STATUS bit0/bit1. **Bit 2 on both registers is
> used by `machine_reset()` but is undocumented in that comment** — it is real
> and load-bearing (the cold-reset/wipe FSM). (OSD/keyboard registers
> 0x48–0x5C also exist but are out of scope here.)

### 7.2 Phase 1 — reset-on-load (the wipe), then HALT

This runs at the **start of both** `load_z80` and `load_sna`, *before* any
parsing-dependent writes. `machine_reset()`:

```
1. CONTROL = 0x4              // pulse RESET+wipe (the F11 cold-reset FSM)
2. wait STATUS bit2 == 1      // reset_busy ASSERTS  (up to 500000 iters)
3. wait STATUS bit2 == 0      // reset_busy CLEARS   (up to 8000000 iters)
                              //   — the wipe+reset is now complete
4. CONTROL = 1                // assert HALT to the T80 core
5. wait STATUS bit0 == 1      // HALT_ACK
```

The **0 → 1 → 0** wait on `reset_busy` is deliberate: the loader waits for
`busy` to *rise* first and never treats the initial 0 as "done". On an older
bitstream that lacks CONTROL bit 2, this degrades to a brief delay + HALT (no
hardware wipe).

**Why the cold-reset+wipe matters.** Without it, the core would still hold the
*previous* program's RAM, AY state, ULA state and paging. Injecting a new
snapshot on top of that leaves stale bytes in pages the snapshot does not
write, and — most audibly — leaves the **AY-3-8912 producing whatever tone it
was last programmed to**, so a new load can start with a continuous squeal. The
cold reset zeroes RAM, resets the AY/ULA, and resets paging to a known state,
giving every load a clean slate. (The flip side: see §8 — because the AY is
reset and the snapshot's AY registers are *not* re-applied, 128K music can be
wrong until the running program re-inits the AY itself.)

### 7.3 Phase 2 — RAM streaming

For each bank to write (per §5):

```
RAM_ADDR = bank << 14;             // 16 KiB-aligned
for (i = 0; i < 16384; i++) {
    RAM_DATA = data[i];            // write byte; address auto-increments
    while (STATUS & 0x2) {}        // poll RAM_BUSY AFTER the write, spin until clear
}
```

> The RAM_BUSY poll is **after** each byte write only — there is no pre-write
> poll.

### 7.4 Phase 3 — port init and port-commit

```
PORT_7FFD = p7ffd;     // §2.5 / §3.2 (masked to [5:0]; 0x30 for 48K)
PORT_FE   = border;    // [2:0]
COMMIT    = 0x1;       // port-commit pulse — latches 7FFD + FE
```

### 7.5 Phase 4 — register inject (DIRSet)

```
write DIR0..DIR6 (7 words) to GP0 + IJ_DIR0 + 4*k   // §6.2
COMMIT = 0x2;          // DIRSet pulse — latches the whole 212-bit vector
                       //   into the T80's registers
```

### 7.6 Phase 5 — resume

```
CONTROL = 0;           // release HALT; the core runs from the injected PC
```

There is no separate "un-reset" step — `CONTROL = 0` *is* the resume. The
ordering across phases is **load-bearing**: ports must be committed (bit 0)
before the DIR vector is committed (bit 1), and `CONTROL = 0` is the final act.

### 7.7 Operational facts

* The browser only triggers `load_snapshot` for `.z80`/`.sna` extensions.
* `load_snapshot` reads up to `sizeof(snapbuf)` = **160 KiB (163840 bytes)**
  into DRAM and **rejects files shorter than 30 bytes**.
* Before injecting, the OSD is turned off and the screen is handed to the game
  (so the user sees the snapshot, not the menu, when the core resumes).

---

## 8. Nuances, corner cases & limitations

This section lists the real, user-visible limitations of the current
implementation. Some matter in everyday use; others only bite on malformed input.

### 8.1 Format nuances every parser must respect

* **R bit 7** lives in byte 12 bit 0 of the `.z80` header, not in byte 11.
  Merge them. BulbuLator does.
* **`.z80` AF / AF'** are stored A-then-F, *not* as a little-endian word.
* **Byte-12 == 0xFF clamp to 0x01** is a genuine historical `.z80` quirk;
  BulbuLator does not apply it (negligible in modern files, but a strict
  deviation).
* **v1 vs v2/v3 RLE end marker:** v1 has `00 ED ED 00`; v2/v3 have none (length
  word delimits). Mixing them up overruns or truncates.
* **Single-ED passthrough** and the **2-byte ED run** are the subtlest
  compression rules; a decoder that ignores them mis-resyncs.
* **RLE count is one byte** (max run 255 per code).
* **`.z80` v2/v3 byte-12 bits 4/5 (SamRom/compressed) are meaningless** —
  per-block compression is implied by the block's length word (`0xFFFF` = raw).
* **`.z80` 55-byte v3.0x headers** (with the byte-86 #1FFD) are rejected by some
  emulators; only the length word (23/54/55) reliably tells you the variant.
* **Hardware-code 3–6 shift between v2 and v3** (§2.5). Codes 7 and 8 both mean
  +3; code 9 = Pentagon; code 10 = Scorpion (16 pages, not 8).
* **`.z80` T-state counters:** low counts *down* from 17471 (17726 in 128K), hi
  counts *up* mod 4; together they place you within the 69888 (70908 in 128K)
  T-states of the frame. (Older nvg text said 17472 — corrected to 17471.)
* **`.sna` interrupt byte:** only bit 2 (IFF2) is defined — mask `& 0x04`.
* **`.sna` is uncompressed**, which is why dispatch-by-size works.

### 8.2 The 48K `.sna` stack corner case (guarded)

If `SP` is not in `0x4000..0xFFFE`, the pushed PC bytes are not in the stored
RAM (they were in ROM, or `SP+1` wrapped). **BulbuLator guards the read** so it
never fetches PC from outside the RAM image, and PC falls back to **0**
deterministically (the PC bytes are pre-zeroed and `zregs z = {0}` zero-initialises
the register struct). For any well-formed 48K `.sna` the guard never fires.
Separately, the two bytes just below the original SP are genuinely overwritten by
the pushed PC in every 48K `.sna` RAM image — that is by design, not a bug.

### 8.3 48K paging lock

For any 48K load BulbuLator forces `p7ffd = 0x30`: bank 0 at `0xC000`, 48K
BASIC ROM (bit 4 = 1), screen = bank 5, **paging locked (bit 5 = 1)**. This
emulates the fixed 48K memory map and prevents the running program from
accidentally re-paging.

### 8.4 AY / TurboSound state is NOT restored

This is the most important user-visible limitation. `inject_finish` writes **no
AY registers**, and `machine_reset` **cold-resets the AY** before every load.
The `.z80` extended header *does* carry the 16 AY registers (offsets 39–54) and
the selected register (offset 38), but BulbuLator ignores them. **Consequence:**
on a 128K snapshot that had music or sound effects playing, the AY starts
silent/reset; the audio will be wrong **until the running program re-initialises
the AY itself** (most do, within a frame or two, since they re-write the AY each
interrupt). Programs that set the AY once and never again will lose their sound.

### 8.5 Unimplemented / aspirational machine modes

BulbuLator implements exactly two bank maps: **standard 48K** (pages 4/5/8 →
banks 2/5/0) and **standard 128K** (pages 3–10 → banks 0–7). Everything else
falls onto the 128K scheme with no special-casing:

* **Scorpion 256K (hw 10):** has 16 pages → banks 8–15. BulbuLator has **no**
  pages > 10 logic; those banks are silently dropped. Not supported.
* **+2 / +2A / +3 (hw 7/8/12/13):** the +3/+2A secondary paging port `0x1FFD`
  (byte 86) is never read; disk/special paging is not modelled. Treated as
  generic 128K.
* **Interface I / DISCiPLE / Plus-D / Multiface:** their ROM-paged flags and ROM
  pages are ignored (correct — they are not RAM — but an IF1-dependent snapshot
  won't have its IF1 state).
* **Pentagon 128 (hw 9):** paging is ≈ standard 128K, so this generally works.
* **Timex (hw 14/128):** not modelled.

### 8.6 `.sna` 131103 and 147487 both load correctly (bounded read)

The 128K loader walks `b = 0..7`, skips `{5, 2, paged}`, and writes one trailing
16 KiB bank per non-skipped index — i.e. `8 − (distinct front banks)` banks. That
is **5** for a 131103 file (paged ∉ {2,5}) and **6** for a 147487 file (paged ∈
{2,5}), exactly the right count for each, so both sizes load correctly. Each
trailing read is now **bounded by the file length** (`if (ex+16384 > d+len)
break;`), so a short or malformed file can never make the loop read past the
snapshot data. (That bound was missing in an earlier revision — see §8.11.)

### 8.7 Ignored `.z80` extended fields

Beyond `p7ffd` (d[35]), BulbuLator reads none of: T-state lo/hi (d55–58),
Spectator/MGT flags (d58–60), the AY/sound-chip selected register (d38) and AY
dump (d39–54), the joystick/keymap WORDs (d63–82), the DISCiPLE bytes (d83–85),
the +3 #1FFD byte (d86), the modified-hardware flag (d37 bit 7), or SamRom.

### 8.8 Size cap and rejects

* Files **> 160 KiB are silently truncated** to `snapbuf` (163840 bytes). The
  canonical 147487-byte 128K `.sna` fits; a hypothetical larger snapshot would
  not. Not surfaced to the user.
* Files **< 30 bytes are rejected**.

### 8.9 No cycle-exact resume

PC is injected and the core released immediately. There is **no T-state
alignment, no contended-memory timing, no cycle-exact frame position**. The
`.z80` v3 T-state counters are not used. For the vast majority of games and
demos this is invisible; for the rare raster-exact effect that depends on the
sub-frame T-state position at snapshot time, the first frame may differ.

### 8.10 The load is destructive (by design)

Every load is a full cold reset + wipe + re-inject. There is no "merge" or
"resume previous machine." This is intentional and is what makes loads
repeatable and free of stale state.

### 8.11 128K `.sna` paged-bank-5/2 over-read — FIXED

When `7FFD` bits `[2:0]` select bank **5 or 2** as the `0xC000`-paged bank, the
skip set `{5, 2, paged}` collapses to two distinct values, so the trailing loop
writes **six** banks — correct for a genuine 147487 file (which carries six trailing
banks). The previous code read those six chunks unconditionally, so a *131103* file
that claimed paged ∈ {2,5} (a short/malformed case) read 16 KiB past its data. The
loop now **bounds each read by the file length** and `break`s when a bank would fall
past EOF, so it loads only what is present and never over-reads.

### 8.12 RLE decoder bounds — FIXED

The v1 inline decompressor and `z80_unrle` previously bounds-checked only the
`ED ED` escape pair (`i+1 < len`), then read the count and value bytes
(`d[i+2]`, `d[i+3]`) without checking them — so a truncated block whose final
`ED ED` sat at the very end could read up to two bytes past the parsed region. The
escape test is now `i+3 < len` (and `i+3 < clen` in `z80_unrle`), guaranteeing the
count and value bytes are in range. A valid run always has all four bytes present,
so well-formed files are unaffected.

### 8.13 Reset/wipe silently skipped on an older bitstream

`machine_reset` waits for `reset_busy` (STATUS bit 2) with bounded spin counts
(≈500k then ≈8M iterations) and then proceeds regardless. On a bitstream that does
not implement CONTROL/STATUS bit 2, `reset_busy` never asserts: the first loop
times out, the second exits immediately, and the load **silently degrades to
"brief delay + HALT" with no RAM wipe and no AY/ULA reset**. On the `0xB01B0009`
build this document describes, bit 2 is implemented and the full wipe runs; the
degradation only matters if this loader image is run on an older core.

---

## 9. Verification / test matrix

| # | Format / mode | File property | What to check |
|--:|---|---|---|
| 1 | `.z80` v1, 48K, raw | PC@6≠0, byte12 bit5=0 | Loads; border = `(d12>>1)&7`; banks 5/2/0 correct; PC resumes. |
| 2 | `.z80` v1, 48K, RLE | byte12 bit5=1, `00 ED ED 00` end marker | Decompresses to exactly 49152; ED-run and single-ED-passthrough handled. |
| 3 | `.z80` v1, R-bit7 set | byte12 bit0 = 1 | Reconstructed R has bit 7 set (verify via a program that reads R). |
| 4 | `.z80` v2, 48K | extlen=23, hw=0 | 3 blocks (pages 4/5/8 → banks 2/5/0); `0xFFFF` raw block handled. |
| 5 | `.z80` v2, 128K | extlen=23, hw=3 | `is128` true (hw≥3 for v2); 8 blocks (pages 3–10 → banks 0–7); 7FFD = `d[35]&0x3F`. |
| 6 | `.z80` v3, hw=3 | extlen=54, hw=3 | Treated as **48K** (v3 hw=3 = SamRam, 48K-class) — `is128` false (hw≥4 for v3). Confirms version-dependent test. |
| 7 | `.z80` v3, 128K | extlen=54, hw=4 | `is128` true; 8 banks; paging from `d[35]`. |
| 8 | `.z80` v3.0x | extlen=55 (+3) | Loads via generic 128K path; byte-86 #1FFD ignored (document expected deviation). |
| 9 | `.z80` Scorpion | hw=10, 16 pages | Banks 8–15 dropped — **known unsupported**; verify it at least doesn't crash. |
| 10 | `.sna` 48K | size 49179 | `len<131000` → 48K; PC popped from stack; SP += 2; the two bytes at old SP are the PC bytes. |
| 11 | `.sna` 48K, SP in ROM | SP < 0x4000 | Guard hits → no out-of-RAM read; PC falls back to **0** deterministically (zero-init). |
| 12 | `.sna` 128K | size 131103 | `len≥131000`; explicit PC@49179; 7FFD@49181 masked `&0x3F`; banks 5/2/paged + remaining ascending skipping {5,2,paged}. |
| 13 | `.sna` 128K, paged∈{2,5} | size 147487 | Loads correctly: six trailing banks (8 − {5,2}) read in ascending order, bounded by file length. |
| 14 | 128K shadow screen | 7FFD bit3 = 1 | Displayed screen from bank 7, independent of the `0xC000`-paged bank. |
| 15 | AY music snapshot | 128K with AY playing | Audio is silent/wrong on resume **until the program re-inits AY** — confirms §8.4. |
| 16 | Cold-reset/wipe | load over a noisy AY squeal | Squeal stops at load (machine_reset resets AY); RAM pages not in the snapshot read as 0. |
| 17 | Reject/truncate | <30-byte file; >160 KiB file | <30 B rejected; >160 KiB truncated (document, not necessarily fixed). |
| 18 | Border + IFF | any snapshot with EI and a coloured border | Border matches; interrupts enabled (`.sna`: IFF1 = IFF2). |

---

*This document describes BulbuLator build `VERSION 0xB01B0009`. Where the file
formats permit behaviour BulbuLator does not implement (Scorpion banks, +3 disk
paging, AY restore, cycle-exact timing, the byte-12 0xFF clamp, SamRom, Timex),
those are flagged above as deviations or limitations rather than silently
omitted.*
