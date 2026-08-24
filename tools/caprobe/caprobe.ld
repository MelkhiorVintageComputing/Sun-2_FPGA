/*
 * The monitor loads a boot program to LOADADDR and jumps to it.
 *
 * LOADADDR is 0x4000 (msun/mon/h/sasun.h:14) and BBSIZE is 8192, of which
 * blocks 1..15 are read -- so 7680 bytes are available and everything has to
 * be in one contiguous image with no BSS to clear, because nothing clears it.
 * .bss is therefore placed inside the image and mkxydisk writes the whole
 * thing out, zeroes included.
 */
ENTRY(_start)

SECTIONS
{
  . = 0x4000;

  .text : {
    *(.text.start)
    *(.text.startup)
    *(.text*)
    *(.rodata*)
  }

  .data : { *(.data*) }

  /* _start clears this: objcopy -O binary drops NOBITS whatever we do here. */
  .bss : { __bss_start = .; *(.bss*) *(COMMON) ; __bss_end = .; }

  _end = .;

  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
