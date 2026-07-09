# atlas-zx-ps2-watchdog

`ps2.v` here is the PS/2 keyboard decoder from the ZX Spectrum core by Sorgelig and
contributors (`sorgelig/ZX_Spectrum-128K_MIST`; downstream `AtlasFPGA/zx`), a
**GPL-2.0-or-later** work, modified for BulbuLator with a watchdog that resyncs the
PS/2 bit counter (fixes "fuzzy" keys).

`assemble.sh` overlays this file onto the fetched core so a clean clone reproduces the
on-hardware keyboard fix. It remains under **GPL-2.0-or-later** — see the repository
[LICENSE](../../LICENSE) and [THIRD_PARTY.md](../../THIRD_PARTY.md).

Original © 2016-2019 Sorgelig; modifications © 2026 Alexander Lavrinovich.
