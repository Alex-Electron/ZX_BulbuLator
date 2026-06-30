# ZX BulbuLator Project Rules

- **Firmware Version Bumping:** During ANY build or new step, you MUST strictly update the firmware version constant (`BULB_FW`) in the OSD application code (e.g., `loader_main.c`). The F1 Help screen and the splash screen rely on this constant to display the current version. Never leave an old version string in a new build.
- **Hardware vs Software Validation:** Since the PL core version (`VERSION` register) and the ARM software version (`BULB_FW`) are displayed together, ensuring both are bumped appropriately helps identify mismatches between the bitstream and the ARM ELF.
