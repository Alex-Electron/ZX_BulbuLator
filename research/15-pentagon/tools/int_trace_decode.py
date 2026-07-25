#!/usr/bin/env python3
"""Decode the B0050 interrupt-timing TRACE snapshot (a diagnostic bit from the second agent, 2026-07-24).

Packing is read directly from atlas_core/main.v:483-485 (int_dbg0/1/2_o) and the
tuner word (ula_tune = PENT_INT reg). AXI map (ROMTRAP must be OFF):
  CONFIG (ula_tune)  = GP0+0xC4  (PENT_INT reg, reused on native48)
  TRACE0 (int_dbg0)  = GP0+0xF4  (REG4 / fe_trace_count)
  TRACE1 (int_dbg1)  = GP0+0xF8  (REG5 / fe_trace_hash)
  TRACE2 (int_dbg2)  = GP0+0xFC  (REG6 / fe_trace_last)
Read TRACE0, TRACE1, TRACE2, TRACE0 again; retry if ack_seq changed (coherent snapshot).

Usage: int_trace_decode.py <cfg_hex> <t0_hex> <t1_hex> <t2_hex>
"""
import sys

def s6(v):                      # signed 6-bit two's complement -> int (half-T units)
    v &= 0x3F
    return v - 64 if v & 0x20 else v

def s9(v):                      # signed 9-bit two's complement -> int (half-T units, B0053)
    v &= 0x1FF
    return v - 512 if v & 0x100 else v

SRC = {0: "legacy(pc3M5 resample, Early)", 1: "raw vduI (-1 CPU-T)",
       2: "irq_ne(nc3M5 half, -0.5 CPU-T)", 3: "reserved->legacy"}

def decode(cfg, t0, t1, t2):
    o = {}
    # config word (ula_tune)
    o["tune_en"]   = (cfg >> 31) & 1
    o["freeze"]    = (cfg >> 30) & 1
    o["cfg_irq_delta"] = s6((cfg >> 18) & 0x3F)
    o["cfg_ula_delta"] = s6((cfg >> 12) & 0x3F)
    o["cfg_int_source"] = (cfg >> 10) & 3
    # TRACE0
    o["ack_seq"]   = (t0 >> 24) & 0xFF
    o["valid"]     = (t0 >> 23) & 1
    o["missed_raw"]= (t0 >> 22) & 1
    o["source"]    = (t0 >> 20) & 3
    o["irq_delta"] = s6((t0 >> 14) & 0x3F)
    o["ula_delta"] = s6((t0 >> 8) & 0x3F)
    o["raw_n"]     = (t0 >> 7) & 1
    o["legacy_n"]  = (t0 >> 6) & 1
    o["half_n"]    = (t0 >> 5) & 1
    o["cpu_n"]     = (t0 >> 4) & 1
    o["pc3M5_d"]   = (t0 >> 3) & 1
    o["nc3M5_d"]   = (t0 >> 2) & 1
    o["raw_seen"]  = (t0 >> 1) & 1
    o["sel_seen"]  = (t0 >> 0) & 1
    # TRACE1
    o["v"]         = (t1 >> 23) & 0x1FF
    o["h"]         = (t1 >> 14) & 0x1FF
    o["raw_age"]   = (t1 >> 7) & 0x7F
    o["cpu_age"]   = (t1 >> 0) & 0x7F
    # TRACE2
    o["pc"]        = (t2 >> 16) & 0xFFFF
    o["r"]         = (t2 >> 8) & 0xFF
    o["raw_seq"]   = (t2 >> 0) & 0xFF
    return o

def main(a):
    cfg, t0, t1, t2 = (int(x, 16) for x in a[:4])
    o = decode(cfg, t0, t1, t2)
    print(f"CONFIG: en={o['tune_en']} freeze={o['freeze']} "
          f"IRQ_DELTA={o['cfg_irq_delta']:+d} ULA_DELTA={o['cfg_ula_delta']:+d} "
          f"INT_SOURCE={o['cfg_int_source']} [{SRC[o['cfg_int_source']]}]")
    if not o["valid"]:
        print("TRACE: not valid (no interrupt captured since last config change)"); return 0
    print(f"TRACE: ack_seq={o['ack_seq']} source={o['source']} [{SRC[o['source']]}]  "
          f"applied IRQ_DELTA={o['irq_delta']:+d} ULA_DELTA={o['ula_delta']:+d}")
    print(f"  levels @ACK  raw(vduI)={o['raw_n']} legacy(irq)={o['legacy_n']} "
          f"half(irq_ne)={o['half_n']} SELECTED(cpu_irq)={o['cpu_n']}  (0=asserted)")
    print(f"  raster v={o['v']} h={o['h']}   PC=0x{o['pc']:04X} R=0x{o['r']:02X} raw_seq={o['raw_seq']}")
    print(f"  raw_age={o['raw_age']} half-T  cpu_age={o['cpu_age']} half-T  "
          f"missed_raw={o['missed_raw']} raw_seen={o['raw_seen']} sel_seen={o['sel_seen']}")
    # SELECTED-vs-RAW edge offset. AGE counts up FROM the fall, so a LATER edge has had
    # LESS time to age -> SMALLER age. Hence (cpu_age - raw_age): NEGATIVE = selected fell
    # LATER than raw (resample delay); POSITIVE = selected fell EARLIER. Measured on B0050:
    # legacy -2 (pc3M5 resample = 1 CPU-T later), half -1 (nc3M5 = 0.5T later), raw 0 (edge-
    # aligned). INT_SOURCE can only ADD delay - it never advances the edge earlier than raw=0.
    # B0053 later proved that moving the raw edge by as much as -256 half-T crosses many ACK
    # buckets but leaves the original timing test's Type-1 verdict unchanged. The test measures a
    # tight loop between consecutive frame interrupts, so translating every frame edge together
    # does not implement a real Type-1/Type-2 ULA change. The bucket remains useful evidence about
    # T80 interrupt acceptance; it is not a detector-flip oracle.
    if o["raw_age"] != 0x7F and o["cpu_age"] != 0x7F:
        eff = o["cpu_age"] - o["raw_age"]
        rel = "selected==raw (edge-aligned)" if eff==0 else \
              (f"selected {-eff} half-T LATER (resample delay)" if eff<0 else
               f"selected {eff} half-T EARLIER")
        print(f"  >>> selected-vs-raw = {eff:+d} half-T ({eff/2.0:+.1f} CPU-T): {rel}")
        print(f"  >>> ACCEPTANCE BUCKET = (h={o['h']}, PC=0x{o['pc']:04X})")
    return 0

if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
