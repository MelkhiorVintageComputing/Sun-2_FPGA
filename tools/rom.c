#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

unsigned char data[64*1024];

void usage()
{
    fprintf(stderr, "usage: ./rom {0|1} <bin-file\n");
    exit(1);
}

int main(int argc, char *argv[])
{
  int ret, low = 0, a = 0, word = 0, doubleword = 0;
    if (argc != 2) usage();
    if (argv[1][0] == '0') low = 1;
    if (argv[1][0] == '1') low = 0;
    if (argv[1][0] == 'W') word = 1;
    if (argv[1][0] == 'D') doubleword = 1;
    ret = read(0, data, sizeof(data));
    if (ret > 0) {
      if (!word & !doubleword) {
        for (int o = low; o < ret; o += 2) {
	  unsigned char b = data[o];
	  printf("    15'h%04x: out = 8'h%02x;\n", a, b);
	  a++;
	}
      } else if (word) {
        for (int o = 0; o < ret/2; o++) {
	  unsigned short w = ((unsigned short*)data)[o];
	  /* 14 bits, not 15.  The Sun-2 boot PROM is 32 KiB = 16384 words, so
	     bit 14 of a word index is always zero -- but a case whose selector
	     is wider than its labels populate is *incomplete*, and Quartus
	     declines to infer a ROM from an incomplete case.  It says nothing
	     when it declines: the boot PROM simply becomes 23,000 logic
	     elements, which is most of a 10M50.  Measured, on the first Altera
	     build of this design: 397,056 memory bits where 659,200 were
	     expected, the whole difference being this ROM.  Vivado infers it
	     either way, which is why the width went unnoticed for years. */
	  printf("    14'h%04x: dout <= 16'h%04x;\n", o, ((w>>8)&0xFF)|((w<<8)&0xFF00));
	}
      }else if (doubleword) {
        for (int o = 0; o < ret/4; o++) {
	  unsigned int w = ((unsigned int*)data)[o];
	  printf("    14'h%08x: dout <= 32'h%08x;\n", o, __builtin_bswap32(w));
	}
      }
    }
    return 0;
}
	
