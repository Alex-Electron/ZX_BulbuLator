# Step 0 — Setup: from a bare board to a flashed bitstream

Languages: **English** · [Русский](README.ru.md)

This is the from-scratch guide. By the end you'll have the board powered, a JTAG
link to it, the software installed, and the prebuilt Step 1 bitstream flashed —
two LEDs blinking. No prior FPGA experience assumed.

One honest warning up front: an EBAZ4205 bought as a bare board needs a bit of
soldering (the boot-mode resistor, and sometimes the JTAG header and the MicroSD
socket). If yours already has those, skip the soldering bits.

## What you need

- An **EBAZ4205** board, Zynq-7010 (`XC7Z010`) variant.
- A **power source** — 5V or 12V (see below).
- A **JTAG programmer**, either of:
  - a Vivado-supported cable (Xilinx Platform Cable, Digilent HS2/HS3) — simplest, or
  - a **Raspberry Pi Pico** plus 5 jumper wires — cheap, and what this project uses.
- A **MicroSD card** (any size) with a bootable image (see step 2).
- A **soldering iron** with a fine tip, for the board prep below.
- A computer. Linux is the smoothest for the Pico daemon; Windows works for the
  Vivado GUI path.

## 1. Power the board

The EBAZ4205 came out of mining hardware, so powering it is a little hands-on.
Two common options:

- **5V** into the power pins of the JTAG/UART header (needs a small Schottky
  diode or a jumper added), or
- **12V** into the fan/power connector — **mind the polarity**, reversed power
  can kill the board.

A green LED on the board lights when power is good. Don't go further until it's lit.

## 2. Boot mode

The EBAZ4205 picks its boot source from two strap pins — IO0 (MIO5) and IO2
(MIO4) — set by a handful of resistors near the NAND chip:

| Mode | IO0 (MIO5) | IO2 (MIO4) |
|------|:----------:|:----------:|
| JTAG | 0 | 0 |
| NAND | 0 | 1 |
| SD   | 1 | 1 |

![EBAZ4205 boot-strap schematic and truth table](images/Boot-Mode.jpg)

Out of the factory the board is in **NAND** mode: `R2584` (20k) pulls IO0 to GND
and `R2578` (20k) pulls IO2 to Vcc. To get **SD** mode you only need IO0 high
(IO2 is already high), so add the IO0 pull-up at **R2577** — the empty "NC"
position right next to R2584.

The article moves the resistor from R2584 over to R2577. You don't have to be
that tidy: **I just bridged R2577 with a blob of solder and it booted from SD on
the first try** — a solid pull-up to Vcc beats the 20k pull-down.

![Where R2577 and R2584 sit on the board, magnified](images/r2577-location.jpg)

*R2577 (the SD pull-up to add/bridge) and the factory R2584, under a loupe.*

Two things that make life easier:

- **With no MicroSD inserted, the board falls back to JTAG mode automatically.**
  For pure JTAG work you can leave the card out and not touch the resistors at all.
- The MicroSD socket is **already populated on most boards** — no soldering there.

For the blink in Step 1 the bitstream goes in over JTAG, so you don't need a
bootable card yet; building an SD boot image is a later step.

Next time I'd rather flip boot modes with a **switch or jumper** than re-solder —
the article's author wired up two SPDT switches for exactly that. The solder
bridge on R2577 is permanent-but-fine for now.

Boot-strap details and schematic from the
[theokelo.co.ke EBAZ4205 guide](https://theokelo.co.ke/getting-starting-with-ebaz4205-zynq-7000/).

## 3. Install the software

We use **Vivado / Vivado Lab Edition 2023.1**. Newer versions should work too —
nothing here is version-specific.

- To just **flash** a bitstream, the small free **Vivado Lab Edition** is enough
  (it's only the Hardware Manager).
- To **compile** a bitstream yourself (optional, step 6), you need the full free
  **Vivado ML Standard**.
- Download both from AMD/Xilinx (free account). The full install is large
  (tens of GB); Lab Edition is much smaller.

## 4. Connect the JTAG programmer

### Option A — a Vivado-supported cable (simplest)

Plug a Digilent or Xilinx JTAG cable into the board's JTAG header. In Vivado
Hardware Manager you'll use **Auto Connect**. Skip to step 5.

### Option B — Raspberry Pi Pico (cheap, what we use)

**Flash the Pico firmware:** hold the Pico's BOOTSEL button, plug it into USB —
it shows up as a `RPI-RP2` drive. Copy
[`firmware/xvcPico_v2_soft_edges.uf2`](firmware/) onto that drive. The Pico
reboots as a JTAG adapter. (This is the "soft edges" build — slow slew rate and
2 mA drive — which is what makes dense bitstreams flash without BAD_PACKET
errors. Source: the `zynq-dense-bitstreams` branch of the fork, also offered
upstream as [kholia/xvc-pico#3](https://github.com/kholia/xvc-pico/pull/3).)

**Wire the Pico to the board's JTAG header.** The JTAG header is **J8** (pins
labelled TDI, TDO, TCK, TMS, VCC). The serial console, if you want it later, sits
on **J7** (VCC, RXD, TXD, GND).

![EBAZ4205 J7 (UART) and J8 (JTAG) headers](images/uart-jtag.jpg)

Both the Pico and the board run at 3.3V, so they connect directly, and the signal
names line up — no crossing of TDI/TDO.

| JTAG signal | Pico   | EBAZ4205 J8 |
|-------------|--------|-------------|
| TDI         | GPIO16 | TDI         |
| TDO         | GPIO17 | TDO         |
| TCK         | GPIO18 | TCK         |
| TMS         | GPIO19 | TMS         |
| GND         | pin 23 | GND         |

You don't need to wire J8's VCC to the Pico — just the four signals plus a common
ground. (Header photo from the [xvc-pico](https://github.com/Alex-Electron/xvc-pico)
project's EBAZ4205 notes.)

**Run the XVC daemon on the host.** It bridges the Pico's USB to a Xilinx
Virtual Cable on TCP port 2542. Either build it from the
[xvc-pico](https://github.com/Alex-Electron/xvc-pico) repo:

```
sudo apt install cmake gcc-arm-none-eabi libnewlib-arm-none-eabi \
  libstdc++-arm-none-eabi-newlib git libusb-1.0-0-dev build-essential make g++ gcc
git clone https://github.com/Alex-Electron/xvc-pico.git
cd xvc-pico/daemon && cmake . && make
./xvcd-pico        # turn the Pico on first
```

To run it **without sudo**, install the included udev rule once and replug the
Pico:

```
sudo cp 99-programming-adapters.rules /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger
```

## 5. Flash the prebuilt bitstream

The blink bitstream is already built:
[`../01-board-bringup-blink/blink_z010.bit`](../01-board-bringup-blink/).

### Easiest — official Vivado Hardware Manager (GUI)

1. Open Vivado (or Vivado Lab) → **Hardware Manager** → **Open Target**.
2. Pick the cable:
   - Option A (real cable): **Auto Connect**.
   - Option B (Pico): **Add Xilinx Virtual Cable (XVC)**, host `localhost`, port `2542`.
3. The `xc7z010` shows up. Right-click it → **Program Device** → choose
   `blink_z010.bit` → **Program**.
4. Wait for `End of startup status: HIGH`.

### Scripted (Linux + Pico) — optional

```
bash ../01-board-bringup-blink/jtag_flash.sh ../01-board-bringup-blink/blink_z010.bit
```

The script (re)starts the `xvcd-pico` + `hw_server` stack, opens the XVC target,
finds the `xc7z010`, and programs it. Override paths with the `XVCD_PICO` and
`VIVADO_LAB` environment variables if yours differ.

## 6. (Optional) Compile the bitstream yourself

With the full Vivado (not Lab Edition):

```
cd ../01-board-bringup-blink
vivado -mode batch -source build_blink_z010.tcl
```

Target part is `xc7z010clg400-1`. You should get a `blink_z010.bit` of about
2,083,856 bytes — that exact size is a handy check that the build hit the 7010.

## Result

Two LEDs (D18 and H18) alternate at about 1–2 Hz. That's the whole toolchain
working end to end. Head to [Step 1](../01-board-bringup-blink/) for what the
design actually does and why it's built the way it is.

## Expansion board reference

The shield (an AliExpress EBAZ4205 adapter) carries an HDMI connector, four LEDs,
four buttons, and a 5V DC jack, and plugs onto the board's DATA1/DATA2/DATA3 edge
connectors.

![EBAZ4205 expansion board: HDMI, 5V jack, buttons, LEDs, labelled GPIO](images/expansion-board.jpg)

**HDMI is "family B" wiring — TMDS clock on F19/F20.** Two incompatible HDMI
pinouts exist for these adapters; the other one ("family A", clock on H16/H17)
gives a blank screen here, because on this board H16/H17 are the UART. Step 3
uses family B.

| Function | FPGA pins |
|----------|-----------|
| TMDS clock | F19 / F20 |
| TMDS data 0/1/2 | D19/D20, C20/B20, B19/A20 |
| LED1..LED4 | D18, H18, E19, K17 (active high) |
| KEY1..KEY4 | P19, T19, U20, U19 (active low) |

All verified on hardware. The bitstreams map **FPGA pins** to functions, not the
silkscreen labels.

Full DATA1/2/3 connector → FPGA pin map:

![EBAZ4205 DATA1/2/3 connector to FPGA pin map](images/data-connectors-pinout.jpg)

## Further reading

Theodore Okelo's [Getting started with the EBAZ4205
(Zynq-7000)](https://theokelo.co.ke/getting-starting-with-ebaz4205-zynq-7000/) is
a great walkthrough and the source for a lot of the board specifics here — the
boot-mode resistor, the JTAG-on-no-card behaviour, and the boot-mode switch idea.
