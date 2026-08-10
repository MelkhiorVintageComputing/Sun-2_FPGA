/*
 * rompatch - apply a word-granular patch list to a Sun-2 boot PROM image.
 *
 * usage: rompatch <in-file> <out-file> <patch-file>...
 *
 * Several patch files may be given; they are applied in order, so a file can
 * build on the state an earlier one left behind.
 *
 * The patch file holds one patch per line:
 *
 *     <address> <expected> <new>      ; all hexadecimal, 16-bit words
 *
 * <address> is a CPU address in PROM space (the PROM appears at 0xef0000 on a
 * Sun-2, which is what the ROM disassembly uses); it must be even.  The word
 * currently at that address must equal <expected>, otherwise the patch is
 * rejected -- that guards against silently mis-patching a different image.
 * Blank lines and lines starting with '#' are ignored.
 *
 * All values are big-endian, as the 68010 sees them.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ROM_BASE 0xef0000u
#define ROM_SIZE (32u * 1024u)

static unsigned char rom[ROM_SIZE];

static void usage(void)
{
	fprintf(stderr, "usage: rompatch <in-file> <out-file> <patch-file>...\n");
	exit(1);
}

static int apply(FILE *pf, const char *pname)
{
	char line[1024];
	int lineno = 0, applied = 0;

	while (fgets(line, sizeof(line), pf)) {
		unsigned addr, expected, replacement, offset, old;
		char *p = line;

		lineno++;
		while (*p == ' ' || *p == '\t') p++;
		if (*p == '#' || *p == '\n' || *p == '\0') continue;

		if (sscanf(p, "%x %x %x", &addr, &expected, &replacement) != 3) {
			fprintf(stderr, "%s:%d: expected '<addr> <expected> <new>'\n",
				pname, lineno);
			exit(2);
		}
		if (addr < ROM_BASE || addr >= ROM_BASE + ROM_SIZE || (addr & 1)) {
			fprintf(stderr, "%s:%d: address %06x out of PROM range or odd\n",
				pname, lineno, addr);
			exit(2);
		}
		if (expected > 0xffff || replacement > 0xffff) {
			fprintf(stderr, "%s:%d: values must be 16-bit\n", pname, lineno);
			exit(2);
		}

		offset = addr - ROM_BASE;
		old = (rom[offset] << 8) | rom[offset + 1];
		if (old != expected) {
			fprintf(stderr, "%s:%d: %06x holds %04x, expected %04x\n",
				pname, lineno, addr, old, expected);
			exit(3);
		}

		rom[offset]     = replacement >> 8;
		rom[offset + 1] = replacement & 0xff;
		printf("  %06x: %04x -> %04x\n", addr, old, replacement);
		applied++;
	}

	return applied;
}

int main(int argc, char *argv[])
{
	FILE *fin, *fout, *fpatch;
	int applied = 0, i;

	if (argc < 4) usage();

	fin = fopen(argv[1], "rb");
	if (!fin) { perror(argv[1]); return 1; }
	if (fread(rom, 1, ROM_SIZE, fin) != ROM_SIZE) {
		fprintf(stderr, "%s: expected a %u-byte PROM image\n", argv[1], ROM_SIZE);
		return 1;
	}
	fclose(fin);

	for (i = 3; i < argc; i++) {
		fpatch = fopen(argv[i], "r");
		if (!fpatch) { perror(argv[i]); return 1; }
		applied += apply(fpatch, argv[i]);
		fclose(fpatch);
	}

	fout = fopen(argv[2], "wb");
	if (!fout) { perror(argv[2]); return 1; }
	if (fwrite(rom, 1, ROM_SIZE, fout) != ROM_SIZE) { perror(argv[2]); return 2; }
	fclose(fout);

	printf("%d patch(es) applied to %s\n", applied, argv[2]);
	return 0;
}
