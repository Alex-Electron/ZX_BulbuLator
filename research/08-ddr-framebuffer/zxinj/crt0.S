@ crt0.S - minimal Cortex-A9 bare-metal startup for the .z80 injector.
@ MMU/cache stay off (flat addressing): GP0 MMIO @0x40000000 + DDR code @0x00200000 both work.
    .section .vectors,"ax"
    .global _start
_start:
    cps     #0x13                @ SVC mode
    ldr     sp, =_stack_top
    bl      main
hang:
    b       hang
