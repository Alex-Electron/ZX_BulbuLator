# Step 0 — Setup: from a bare board to a flashed bitstream

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

## 2. Boot mode = SD card (soldering)

Set the board to boot from the SD card. We program the PL over JTAG while the PS
is running, and a clean SD boot leaves the PS in a known-good state.

- **Solder the MicroSD socket** if your board doesn't have one (many ship without).
- **Move the 0-ohm boot-select resistor to the SD position.** On this board that
  is **R2577** (moved off the NAND position, **R2584**). This drives the MIO[5:4]
  boot strap to SD. Designators shift between board revisions (R2577 / R2584 /
  R2585 show up depending on the batch) — match the silkscreen, the idea is the
  same: one 0-ohm resistor, NAND position vs SD position.
- Put a **bootable image** on the card so the PS comes up. Building your own
  FSBL/U-Boot/PetaLinux is a later step; for now a community EBAZ4205 PetaLinux
  or PYNQ SD image works. (The blink itself is pure PL and uses the chip's own
  oscillator, but the board still needs to boot far enough that JTAG PL
  programming is clean.)

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
errors.)

**Wire the Pico to the board's JTAG header.** Both are 3.3V, so they connect
directly. The signal names match — no crossing of TDI/TDO.

| JTAG signal | Pico        | EBAZ4205 JTAG header |
|-------------|-------------|----------------------|
| TDI         | GPIO16      | TDI                  |
| TDO         | GPIO17      | TDO                  |
| TCK         | GPIO18      | TCK                  |
| TMS         | GPIO19      | TMS                  |
| GND         | pin 23      | GND                  |

The EBAZ4205 JTAG header pin order, top to bottom, is: **3.3V, GND, TCK, TDO,
TDI, TMS**. Match by name on the silkscreen. You don't need to connect the
header's 3.3V to the Pico — just the four signals and a common GND.

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
2,083,856 bytes — that exact size is a handy check that the build hit the 7010
and not the 7020.

## Result

Two LEDs (D18 and H18) alternate at about 1–2 Hz. That's the whole toolchain
working end to end. Head to [Step 1](../01-board-bringup-blink/) for what the
design actually does and why it's built the way it is.
