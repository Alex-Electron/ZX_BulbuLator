CROSS=arm-none-eabi-
CFLAGS=-ffreestanding -fno-builtin -nostdlib -mlittle-endian -march=armv7-a -O2 -I.
all: osd.bin
osd.elf: start.S osd.c osd.lds
	$(CROSS)gcc $(CFLAGS) -Wl,-Tosd.lds -Wl,--build-id=none -Wl,--no-warn-rwx-segments start.S osd.c -o osd.elf
osd.bin: osd.elf
	$(CROSS)objcopy -O binary osd.elf osd.bin
clean:
	rm -f osd.elf osd.bin
