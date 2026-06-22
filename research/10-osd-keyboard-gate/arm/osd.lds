ENTRY(start)
SECTIONS {
  . = 0x00100000;                 /* FSBL loads + jumps here (matches the BOOT.BIN bif) */
  .text   : { *(.text*) }
  . = ALIGN(4); .rodata : { *(.rodata*) }
  . = ALIGN(4); .data   : { *(.data*) }
  . = ALIGN(8); .bss    : { *(.bss*) *(COMMON) }
  _end = .;
}
