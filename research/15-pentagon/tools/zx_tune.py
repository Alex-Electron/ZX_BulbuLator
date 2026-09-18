#!/usr/bin/env python3
# zx_tune.py - Interactive Live ULA Timing & Phase Tuner for BulbuLator ZX Spectrum
import sys, os, subprocess, tty, termios

ADDR_ULA_TUNE = 0x43C001C0
ADDR_ULA_TUNE2 = 0x43C001C4

class XsdbBridge:
    def __init__(self, host="localhost", port=3121):
        self.host = host
        self.port = port
        cmd = ["bash", "-c", "source /tools/Xilinx/Vivado/2023.1/settings64.sh && xsdb"]
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1
        )
        self._init_xsdb()

    def _send(self, cmd_str):
        self.proc.stdin.write(cmd_str + "\n")
        self.proc.stdin.flush()

    def _init_xsdb(self):
        self._send(f"connect -url tcp:{self.host}:{self.port}")
        self._send('targets -set -filter {name =~ "*Cortex-A9*#0"}')
        self._send("configparams force-mem-accesses 1")
        self._send("puts READY")
        while True:
            line = self.proc.stdout.readline()
            if "READY" in line:
                break

    def write_reg(self, addr, val):
        self._send(f"mwr -force 0x{addr:08X} 0x{val:08X}")

    def close(self):
        try:
            self._send("exit")
            self.proc.terminate()
        except:
            pass

class UlaState:
    def __init__(self):
        self.tune_en      = 1
        self.bord_phase   = 4   # 0..7 (Potapov default: 4/8)
        self.io_cont_tap  = 0   # 0..7 (0=B0153 early); 0=B0153 (esh2 match), 2=B0154 (+1T)
        self.mem_cont_tap = 0   # 0..7
        self.fbus_tap     = 1   # 0=B0153, 1=B0154
        self.border_live  = 0   # 0=phase latch, 1=pixel live
        self.bord_delay   = 3   # 0..3 (Potapov default: 3 px)
        self.pap_delay    = 9   # 0..15 (Potapov default: 9 px)
        self.irq_delta    = 0   # -256..+255
        self.ula_delta    = 0   # -32..+31
        self.int_src      = 0   # 0..2

    def to_reg(self):
        val = 0
        if self.tune_en:
            val |= (1 << 31)
        val |= (self.bord_phase & 0xF)
        val |= ((self.io_cont_tap & 0x7) << 4)
        val |= ((self.int_src & 0x3) << 7)
        val |= ((self.ula_delta & 0x3F) << 9)
        val |= ((self.irq_delta & 0x1FF) << 15)
        val |= ((self.bord_delay & 0x3) << 24)
        val |= ((self.pap_delay & 0xF) << 26)
        return val

    def to_reg2(self):
        return ((self.fbus_tap & 0x3) |
                ((self.mem_cont_tap & 0x7) << 2) |
                ((self.border_live & 0x1) << 5))

def render(state):
    os.system("clear")
    reg = state.to_reg()
    reg2 = state.to_reg2()
    print("=" * 80)
    print("       BULBULATOR ZX SPECTRUM 48K/128K LIVE ULA & CONTENTION TUNER")
    print("=" * 80)
    print(f"  [SPACE] TUNE OVERRIDE : {'[ON] (Live Active)' if state.tune_en else '[OFF] (Baked RTL Defaults)'}")
    print("-" * 80)
    print(f"  [W / S] IO_CONT_DELAY : {state.io_cont_tap} clk ({state.io_cont_tap*0.5:.1f} T)")
    print(f"  [Y / H] MEM_CONT_DELAY: {state.mem_cont_tap} clk ({state.mem_cont_tap*0.5:.1f} T)")
    print(f"  [O]     FLOAT_BUS_TAP : {state.fbus_tap} (0=B0153, 1=B0154)")
    print(f"  [P]     BORDER_MODE   : {'PIXEL LIVE' if state.border_live else 'PHASE LATCH'}")
    print(f"  [E / D] BORD_PHASE    : {state.bord_phase:2d} (1/8 group)   <- BORDER QUANTIZATION PHASE")
    print(f"  [R / F] BORD_DELAY    : {state.bord_delay} px           <- BORDER SUBPIXEL DELAY")
    print(f"  [T / G] PAP_DELAY     : {state.pap_delay:2d} px          <- PAPER SHIFT DELAY (SHOCK SEAM)")
    print(f"  [Q / A] IRQ_DELTA     : {state.irq_delta:+4d} px ({state.irq_delta*0.5:+5.1f} T)  <- /INT START POSITION")
    print(f"  [U / J] ULA_DELTA     : {state.ula_delta:+4d} px ({state.ula_delta*0.5:+5.1f} T)  <- ULA BEAM PHASE")
    print(f"  [I]     INT_SRC       : {state.int_src} ({['pc3M5','raw_vduI','irq_ne'][state.int_src]})")
    print("-" * 80)
    print(f"  REGISTER 0x43C001C0   : 0x{reg:08X} (binary: {reg:032b})")
    print(f"  REGISTER 0x43C001C4   : 0x{reg2:08X}")
    print("-" * 80)
    print("  Controls:")
    print("    [W]/[S] : IO Contention Phase (+/- 1 clk = 0.5 T)")
    print("    [Y]/[H] : Memory Contention Phase (+/- 1 clk = 0.5 T)")
    print("    [O]     : Cycle floating-bus delay tap")
    print("    [P]     : Toggle phase-latched/pixel-live border")
    print("    [E]/[D] : Border Quantization Phase (+/- 1)")
    print("    [R]/[F] : Border Output Delay (+/- 1 px)")
    print("    [T]/[G] : Paper Output Delay (+/- 1 px)")
    print("    [Q]/[A] : /INT Start Timing (+/- 2 px = 1 T)")
    print("    [U]/[J] : ULA Beam Coordinate (+/- 2 px = 1 T)")
    print("    [SPACE] : Toggle Live Override (A/B Test)")
    print("    [0]     : Reset all parameters to 0 (default)")
    print("    [ESC/X] : Exit Tuner")
    print("=" * 80)

def main():
    print("Connecting to XSDB bridge...")
    bridge = XsdbBridge()
    state = UlaState()
    
    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        bridge.write_reg(ADDR_ULA_TUNE2, state.to_reg2())
        bridge.write_reg(ADDR_ULA_TUNE, state.to_reg())
        render(state)
        
        while True:
            ch = sys.stdin.read(1)
            if not ch:
                continue
            
            if ch in ["x", "X", "\x1b"]:
                break
            elif ch == " ":
                state.tune_en = 1 - state.tune_en
            elif ch in ["w", "W"]:
                state.io_cont_tap = (state.io_cont_tap + 1) % 8
            elif ch in ["s", "S"]:
                state.io_cont_tap = (state.io_cont_tap - 1 + 8) % 8
            elif ch in ["y", "Y"]:
                state.mem_cont_tap = (state.mem_cont_tap + 1) % 8
            elif ch in ["h", "H"]:
                state.mem_cont_tap = (state.mem_cont_tap - 1 + 8) % 8
            elif ch in ["o", "O"]:
                state.fbus_tap = (state.fbus_tap + 1) % 4
            elif ch in ["p", "P"]:
                state.border_live = 1 - state.border_live
            elif ch in ["e", "E"]:
                state.bord_phase = (state.bord_phase + 1) % 8
            elif ch in ["d", "D"]:
                state.bord_phase = (state.bord_phase - 1 + 8) % 8
            elif ch in ["r", "R"]:
                state.bord_delay = (state.bord_delay + 1) % 4
            elif ch in ["f", "F"]:
                state.bord_delay = (state.bord_delay - 1 + 4) % 4
            elif ch in ["t", "T"]:
                state.pap_delay = (state.pap_delay + 1) % 16
            elif ch in ["g", "G"]:
                state.pap_delay = (state.pap_delay - 1 + 16) % 16
            elif ch in ["q", "Q"]:
                state.irq_delta = min(255, state.irq_delta + 2)
            elif ch in ["a", "A"]:
                state.irq_delta = max(-256, state.irq_delta - 2)
            elif ch in ["u", "U"]:
                state.ula_delta = min(31, state.ula_delta + 2)
            elif ch in ["j", "J"]:
                state.ula_delta = max(-32, state.ula_delta - 2)
            elif ch in ["i", "I"]:
                state.int_src = (state.int_src + 1) % 3
            elif ch == "0":
                state = UlaState()
            
            bridge.write_reg(ADDR_ULA_TUNE2, state.to_reg2())
            bridge.write_reg(ADDR_ULA_TUNE, state.to_reg())
            render(state)
            
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
        bridge.close()
        print("\nTuner closed.")

if __name__ == "__main__":
    main()
