/*
 * patwr -- write a self-describing pattern to the raw disk and say, for every
 * word that comes back wrong, *where that word came from*.
 *
 * ---------------------------------------------------------------------------
 * Why
 * ---------------------------------------------------------------------------
 * The DECA corrupts exactly one 16-bit word per damaged sector when the machine
 * writes to its micro-SD card, about one word in a hundred thousand, and only
 * in the memory-to-device direction.  Every accounting check from BrianHG's
 * controller up to the master's capture reads zero: one response per request,
 * none unbidden, the right 32-bit quarter of the 128-bit line, the right 16-bit
 * half of that word, one capture per cycle.  So the read returns the wrong
 * *contents*, and what has never been available is where those contents came
 * from.  Matching the bad values against the source file found only chance
 * collisions in a 16-bit fold, which is no evidence at all.
 *
 * A pattern that describes its own position turns each bad word into a pointer.
 *
 * ---------------------------------------------------------------------------
 * The encoding
 * ---------------------------------------------------------------------------
 *      bit 15      always 1 -- "this is pattern data"
 *      bits 14:8   sector index, modulo 128
 *      bits  7:0   word offset within the sector, 0..255
 *
 * So every word is unique within a 64 KiB window, and position and value each
 * determine the other.  A wrong word decodes to the sector and offset it was
 * really taken from, and the *displacement* from where it should have been is
 * the number that names the mechanism:
 *
 *   - one longword back, or one word back: a read returning held-over contents,
 *     which is what is left after the accounting came back clean;
 *   - a fixed larger step: compare against the DVMA chunk (4 bytes), the
 *     128-bit line (16), the sector (512) or the filesystem block (8192);
 *   - bit 15 clear: not our pattern at all, so it came from outside the
 *     transfer entirely.
 *
 * The tag bit costs half the window and is worth it: without it every value is
 * a legal position and foreign data is indistinguishable from a short
 * displacement.  It is not proof -- foreign data has an even chance of having
 * bit 15 set -- but a clear bit is conclusive one way.
 *
 * Note the half of the longword is not encoded separately: it is bit 0 of the
 * offset, so a half-swap shows up as a displacement of one and needs no bit of
 * its own.  Spending a bit on it, as first sketched, would have made every word
 * at the same half within a sector identical and hidden every short-range
 * displacement -- exactly the range the remaining suspects live in.
 *
 * ---------------------------------------------------------------------------
 * Where it runs
 * ---------------------------------------------------------------------------
 * On the machine, against the *raw* device: contiguous sectors, no allocator to
 * reason about, and physio DMAs straight out of this program's buffer, so what
 * the controller reads is what is written here.  A filesystem would put block
 * allocation between the pattern and the disk and lose the one thing being
 * measured.
 *
 * Compile on the machine:   cc -O -o patwr patwr.c
 * Run:                      ./patwr /dev/rsd0b 1000 256 4
 *                           (device, start sector, sectors per pass, passes)
 *
 * ---------------------------------------------------------------------------
 * Two ways this measured nothing, both worth keeping
 * ---------------------------------------------------------------------------
 * **Reading a file back does not check what reached the disk.**  The first
 * version wrote a 128 KiB file and read it straight back: 262,144 words, zero
 * errors, on a machine that reliably corrupts.  The read was served out of the
 * buffer cache, so it compared memory against memory and could not have failed.
 * That is the same reason every `cmp' in this investigation needed a reboot
 * first.  Hence the chunked I/O and the -v mode below: make the file far larger
 * than the cache so the read-back mostly misses it, and be able to verify in a
 * separate run after a reboot, which misses it entirely.
 *
 * **The raw device does not exercise the failing path.**  Against /dev/rsd0b,
 * 262,144 words came back clean -- and that result is real, not an artefact:
 * physio DMAs out of this program's own pages with no buffer cache in the way.
 * The workload that corrupts is a filesystem copy, which stages through kernel
 * buffers.  So the raw device is a useful *control* and not the reproduction.
 *
 * **A verify is only meaningful if the write finished.**  The first fill-mode
 * run came back with sector 0 almost entirely "OLD content, same place", which
 * reads like a catastrophic write failure and was nothing of the kind: the
 * machine had slowed to about two sectors a second, the pattern pass had not
 * finished after an hour, and resetting it left a half-written file.  Check
 * that the write pass printed its summary before believing any verify -- and if
 * the machine is crawling, that is its own finding and not this one's.
 *
 * **It writes to the raw device, and the partition matters.**  In Sun's scheme
 * partition 3 -- `c' -- is normally the *whole disk*, overlapping `a' and `b',
 * so writing to `rsd0c' scribbles on the label and the root filesystem and
 * takes the machine down with it.  That is fine on a secondary disk or a
 * netbooted machine and fatal on the boot disk, which is what this project
 * runs on.  Use `rsd0b': it is the swap partition, 46 MB, bounded, does not
 * overlap root, and is untouched on an idle single-user machine.  Nothing here
 * checks the device it is given.
 */

#include <stdio.h>

#define SECSZ   512
#define WPS     (SECSZ / 2)             /* words per sector */

/* K&R: undeclared functions are assumed to return int.  atol and lseek both
 * return long.  int and long are both 32 bits on a Sun-2 so it happens not to
 * bite, but a silently truncated seek offset is not a thing to leave to the
 * word size. */
char *malloc();
long  atol();
long  lseek();

/*
 * Two generations of the same encoding, differing only in the tag bit.
 *
 *   fillword  bit 15 = 0   written first, and left on the medium
 *   patword   bit 15 = 1   written over it, and what should be read back
 *
 * Because only the tag differs, a corrupted word decodes to a position either
 * way and the tag says which generation it belongs to.  That is the whole
 * discrimination:
 *
 *   tag 0 at its own position  the new word was never written -- the medium
 *                              still holds what was there before
 *   tag 0 at another position  old content from somewhere else
 *   tag 1 at another position  new data displaced, by that many words
 *
 * Filling with zeros, as the first run did, cannot tell the first case from the
 * third: every bad word came back 0000/0001/00ef with no position in it.
 */

/*
 * `-u' makes the pattern **the same in every sector**: halfword i of a sector is
 * 0x8000 | i, so byte 2i is 0x80 and byte 2i+1 is i (the 68010 is big-endian).
 *
 * That looks like a downgrade -- it throws away the sector field, so a bad word
 * no longer says which sector it came from -- and it buys something no software
 * check can have: **the FPGA can verify it**.  Anything that sees every
 * byte going to the card with its buffer address, and with a pattern that
 * depends only on the offset within the sector the expected byte is
 * `addr[0] ? addr[8:1] : 8'h80' -- a comparison in a few LUTs, with no
 * knowledge of files, inodes or LBAs.  So the corruption can be caught *as it
 * happens*, at the last point inside the FPGA before the SD card, instead of
 * being inferred from a checksum after a reboot.
 *
 * Use -u with a hardware checker, and the default encoding when the
 * displacement of a bad word matters more.
 */

/* The word that belongs at (sector, offset). */
static int uniform = 0;         /* -u: same pattern in every sector */

unsigned short
patword(sec, off)
long sec;
int off;
{
    if (uniform) return (unsigned short)(0x8000 | (off & 0xff));
    return (unsigned short)(0x8000 | (((sec & 0x7f) << 8)) | (off & 0xff));
}

unsigned short
fillword(sec, off)
long sec;
int off;
{
    return (unsigned short)((((sec & 0x7f) << 8)) | (off & 0xff));
}

/* Decode a word to its position; returns the generation tag. */
int
decode(w, secp, offp)
unsigned short w;
long *secp;
int *offp;
{
    *secp = (w >> 8) & 0x7f;
    *offp = w & 0xff;
    return (w >> 15) & 1;
}

static char *dev;
static long  start;                     /* first sector */
static long  nsec;                      /* sectors per pass */
static int   passes;
static long  nbad = 0;
static long  nchecked = 0;

/*
 * Report one bad word.  The displacement is the point: `sector' here is modulo
 * 128, so the difference is taken modulo 128 too and reported as the signed
 * distance in *words*, which is what can be compared against a chunk, a line or
 * a sector.
 */
void
report(sec, off, want, got)
long sec;
int off;
unsigned short want, got;
{
    long gsec;
    int  goff, gen;
    long dw;

    printf("BAD  sector %5ld  word %3d  want %04x  got %04x  ",
           sec, off, want, got);

    gen  = decode(got, &gsec, &goff);
    dw   = ((gsec - (sec & 0x7f)) & 0x7f) * (long)WPS + (goff - off);
    if (dw > (64L * WPS)) dw -= 128L * WPS;

    if (gen == 0 && dw == 0) {
        printf("OLD content, same place: this word was never written\n");
        return;
    }
    printf("%s gen, sector %ld word %d, %+ld words (%+ld bytes)\n",
           gen ? "new" : "OLD", gsec, goff, dw, dw * 2);
}

int
main(argc, argv)
int argc;
char **argv;
{
    unsigned short *buf;
    long sec, base, done;
    int  off, fd, i, vonly, fill;
    long chunk = 64;                    /* sectors per I/O, 32 KiB */
    long off_bytes;

    if (argc < 5) {
        fprintf(stderr,
          "usage: %s <path> <startsec> <nsec> <passes> [-v|-f|-u]\n", argv[0]);
        fprintf(stderr,
          "       -v verify only, for a run after a reboot\n");
        fprintf(stderr,
          "       -f write the OLD generation (tag 0) and stop: run this,\n");
        fprintf(stderr,
          "          then a normal pass, then -v after a reboot\n");
        fprintf(stderr,
          "       -u sector-uniform pattern, which the FPGA can check itself\n");
    fprintf(stderr,
          "       flags combine: -u -v verifies a uniform file after a reboot\n");
        return 1;
    }
    dev    = argv[1];
    start  = atol(argv[2]);
    nsec   = atol(argv[3]);
    passes = atoi(argv[4]);
    /* Initialise before the loop.  These are auto locals: the old code
     * assigned them unconditionally, and replacing that with a loop that only
     * assigns inside its branches left them holding garbage when no flag was
     * given -- a plain write ran as "verify only" against a zero-filled file
     * and reported 5531 bad words, which reads exactly like catastrophic
     * corruption. */
    vonly = 0; fill = 0; uniform = 0;

    /* Flags combine.  They used to be exclusive, which made a -u file
     * impossible to verify after a reboot: -u wrote the uniform pattern and
     * -v verified the default one, so the cold check that anchors every
     * hardware counter could not be run at all.  `-u -v' is the useful pair. */
    for (i = 5; i < argc; i++) {
        if      (argv[i][1] == 'v') vonly   = 1;
        else if (argv[i][1] == 'f') fill    = 1;
        else if (argv[i][1] == 'u') uniform = 1;
        else { fprintf(stderr, "patwr: unknown flag %s\n", argv[i]); exit(2); }
    }

    buf = (unsigned short *)malloc((unsigned)(chunk * SECSZ));
    if (buf == 0) { fprintf(stderr, "out of memory\n"); return 1; }

    printf("patwr: %s sectors %ld..%ld, %d pass(es)%s\n",
           dev, start, start + nsec - 1, passes,
           vonly ? ", verify only"
                 : (fill ? ", fill (old generation)"
                         : (uniform ? ", uniform (hardware-checkable)" : "")));

    for (i = 0; i < passes; i++) {
        if (!vonly) {
            fd = open(dev, 2);
            if (fd < 0) { perror(dev); return 1; }
            for (base = 0; base < nsec; base += chunk) {
                long n = (nsec - base < chunk) ? (nsec - base) : chunk;
                for (sec = 0; sec < n; sec++)
                    for (off = 0; off < WPS; off++)
                        buf[sec * WPS + off] = fill
                            ? fillword(start + base + sec, off)
                            : patword(start + base + sec, off);
                off_bytes = (start + base) * (long)SECSZ;
                if (lseek(fd, off_bytes, 0) != off_bytes) {perror("lseek w");return 1;}
                if (write(fd, (char *)buf, (int)(n * SECSZ)) != n * SECSZ) {
                    perror("write"); return 1;
                }
            }
            close(fd);
            sync();
            /* The fill has to reach the medium before the real pass overwrites
             * it, or the two coalesce in the buffer cache and the medium never
             * holds the old generation at all -- which is what makes the
             * "never written" case visible. */
            if (fill) { printf("fill written and synced\n"); return 0; }
        }

        /* Read-only for the verify: after a reboot the root is mounted ro,
         * and opening O_RDWR fails with "Read-only file system" before a
         * single word is checked. */
        fd = open(dev, vonly ? 0 : 2);
        if (fd < 0) { perror(dev); return 1; }
        for (base = 0; base < nsec; base += chunk) {
            long n = (nsec - base < chunk) ? (nsec - base) : chunk;
            off_bytes = (start + base) * (long)SECSZ;
            if (lseek(fd, off_bytes, 0) != off_bytes) {perror("lseek r");return 1;}
            if (read(fd, (char *)buf, (int)(n * SECSZ)) != n * SECSZ) {
                perror("read"); return 1;
            }
            for (sec = 0; sec < n; sec++) {
                for (off = 0; off < WPS; off++) {
                    unsigned short want = patword(start + base + sec, off);
                    unsigned short got  = buf[sec * WPS + off];
                    nchecked++;
                    if (got != want) {
                        nbad++;
                        report(start + base + sec, off, want, got);
                    }
                }
            }
        }
        close(fd);
        printf("pass %d: %ld words checked, %ld bad so far\n",
               i + 1, nchecked, nbad);
        fflush(stdout);
    }

    printf("patwr: %ld of %ld words wrong\n", nbad, nchecked);
    return nbad != 0;
}
