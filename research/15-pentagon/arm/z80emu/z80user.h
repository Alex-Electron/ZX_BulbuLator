/* gs_z80user.h - привязка z80emu к памяти и портам General Sound.
 * Заменяет штатный z80user.h из поставки (тот сделан под тест zexdoc на плоской памяти CP/M). */
#ifndef __Z80USER_INCLUDED__
#define __Z80USER_INCLUDED__

#include <stdint.h>

uint8_t gs_mem_read(uint16_t a);
void    gs_mem_write(uint16_t a, uint8_t v);
uint8_t gs_port_read(uint16_t port);
void    gs_port_write(uint16_t port, uint8_t v);

#define Z80_READ_BYTE(address, x)   do { (x) = gs_mem_read((uint16_t)(address)); } while(0)
#define Z80_FETCH_BYTE(address, x)  Z80_READ_BYTE((address), (x))
#define Z80_READ_WORD(address, x)   do {                                        \
        uint16_t _a = (uint16_t)(address);                                       \
        (x) = (unsigned)gs_mem_read(_a) | ((unsigned)gs_mem_read((uint16_t)(_a+1)) << 8); \
    } while(0)
#define Z80_FETCH_WORD(address, x)  Z80_READ_WORD((address), (x))
#define Z80_WRITE_BYTE(address, x)  do { gs_mem_write((uint16_t)(address), (uint8_t)(x)); } while(0)
#define Z80_WRITE_WORD(address, x)  do {                                        \
        uint16_t _a = (uint16_t)(address); unsigned _v = (unsigned)(x);          \
        gs_mem_write(_a, (uint8_t)_v);                                           \
        gs_mem_write((uint16_t)(_a+1), (uint8_t)(_v >> 8));                      \
    } while(0)
#define Z80_READ_WORD_INTERRUPT(address, x)  Z80_READ_WORD((address), (x))
#define Z80_WRITE_WORD_INTERRUPT(address, x) Z80_WRITE_WORD((address), (x))
#define Z80_INPUT_BYTE(port, x)     do { (x) = gs_port_read((uint16_t)(port)); } while(0)
#define Z80_OUTPUT_BYTE(port, x)    do { gs_port_write((uint16_t)(port), (uint8_t)(x)); } while(0)

#endif
