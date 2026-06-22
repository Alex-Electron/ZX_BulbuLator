/* inject.ld - link the .z80 injector at DDR 0x00200000 (xsdb `dow` loads here; clear of the
   bitstream PCAP scratch at 0x00100000). 1 MB region holds code + the embedded snapshot. */
ENTRY(_start)
MEMORY { DDR : ORIGIN = 0x00200000, LENGTH = 0x00100000 }
SECTIONS {
  .text   : { *(.vectors) *(.text*) } > DDR
  .rodata : { *(.rodata*) } > DDR
  .data   : { *(.data*) } > DDR
  .bss    : { *(.bss*) *(COMMON) } > DDR
  . = ALIGN(8);
  _stack_top = . + 0x10000;
}
